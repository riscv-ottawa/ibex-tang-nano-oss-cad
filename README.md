# Ibex RISC-V on the Tang Nano 9K

A complete RISC-V SoC (lowRISC **Ibex** CPU + UART + memory + Wishbone bus) for
the Sipeed Tang Nano 9K (Gowin GW1NR-9), built with LiteX and the fully open
FPGA flow (yosys + nextpnr-himbaechel + apicula).

The whole flow is driven by the repo-root `Makefile`; run `make help` to see
every target. Each target shells into the container (which holds the toolchain),
so you run `make` from the host.

## What you need

- A Sipeed Tang Nano 9K.
- Podman (or Docker, substitute `docker` for `podman` in the `Makefile`).

Everything else (the open FPGA toolchain, RISC-V GCC, LiteX) is in the container image.

## Quick start

```bash
make image            # once: build the toolchain container image
make up               # start the container (once per host boot)
make soc              # build the gateware + BIOS
make flash            # flash the bitstream and BIOS to the board

make blink            # build + flash the external-LED blink app; runs on reset
make run APP=echo     # or serial-boot the UART echo + on-board-LED app
```

`make help` lists all targets. Any setting is overridable on the command line,
for example `make run APP=echo TTY=/dev/ttyUSB1` or `make soc SYS_CLK_FREQ=13.5e6`;
the defaults live at the top of the `Makefile`.

## Editor setup: code completion and navigation (Zed)

The toolchain and every header and Python package live in the container, so the
smoothest way to get full completion and go-to-definition (including into the
included libraries) is to let Zed open the project inside the dev container,
where clangd and pyright can see all of it. A host-side setup would have nothing
to resolve against without replicating the whole toolchain locally.

You need Zed 0.221 or newer and Podman. Add `"use_podman": true` to your Zed
`settings.json` (the global one). Open this folder in Zed and accept the "open in
dev container" prompt, or run "Project: Open Remote" from the command palette.
Zed builds the image from the `Containerfile`, mounts the repo at `/work`, and
runs the language servers inside it.

Run `make soc` once first (from the host, or in the dev container's own terminal,
the `Makefile` detects when it is already inside and skips Podman) so the
generated headers exist; clangd needs them to resolve `<generated/csr.h>` and the
CSR accessors. After that you get completion and go-to-definition across the
firmware and into picolibc, LiteX libbase, and the Ibex CPU headers for C, and
into the LiteX / litex_boards / migen sources for `tn9k_ibex.py`.

The configuration is in `.devcontainer/devcontainer.json`, `.clangd`,
`pyrightconfig.json`, and `.zed/settings.json`.

## Building the SoC (`make soc`)

`make soc` runs this project's board target, `tn9k_ibex.py`, with the settings
that work on this board. Three of them are non-obvious:

- `MAIN_RAM_SIZE=0x2000` puts 8 KB of main RAM in BRAM. This one is required:
  dropping it brings up the on-board HyperRAM as main RAM, and that controller
  fails memtest badly (256/256 bus errors, ~99.6% data corruption).
- `BAUD=9600` is the serial baud that gives the least trouble. At 115200 the BIOS
  receiver overran during a binary upload and every `serialboot` aborted with a
  frame or CRC error; at 9600 the upload completes.
- `SYS_CLK_FREQ=13.5e6` is what worked here. At 27 MHz the design does not boot at
  all (the CPU is silent), not sure why.

Synthesis runs yosys, then nextpnr-himbaechel places and routes, then `gowin_pack`
writes the bitstream to `build/sipeed_tang_nano_9k/gateware/`. The design lands
around 80% of the GW1NR-9's LUT4s, and nextpnr can fail placement right at that
utilisation ("Unable to find legal placement for all cells"). It is seed-sensitive,
so just re-run `make soc` and it places on a later attempt.

`tn9k_ibex.py` subclasses the upstream litex-boards Tang Nano 9K SoC and adds the
two board-level tweaks this project needs: an external LED GPIO on J6 pin 25, and
`FLASH_BOOT_ADDRESS` for flash auto-boot (both covered under Apps below). Board
configuration like that belongs in the target script; the patches applied in the
`Containerfile` are only for upstream *source* fixes (Ibex-under-slang, the
register file, the clock gate, the BIOS linker).

## USB permissions (one-time host setup)

The board enumerates as two USB-serial ports: interface A is JTAG (used by
openFPGALoader, often `/dev/ttyUSB0`) and interface B is the UART console (often
`/dev/ttyUSB1`). Access is set by udev rules, and udev runs on the host, so this
is a host change even though flashing happens from the container.

The stock openFPGALoader rule grants access with a `uaccess` ACL for your
logged-in user, which is enough host-side but does not survive into the rootless
container that `make flash` uses, so the device ends up read-only there and
openFPGALoader fails with `usb_open() failed: -4`. This repo ships a rule that
sets `MODE="0666"` on the FT2232 instead, which works both host-side and from the
container. Install it once:

```bash
sudo cp udev/99-tangnano9k.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Confirm with `make detect`. See [docs/flashing-from-the-container.md](docs/flashing-from-the-container.md)
for the full explanation of the namespace permission mismatch.

## Flashing (`make flash`)

The bitstream and the BIOS live on two separate chips: the bitstream in the FPGA's
embedded configuration flash, the BIOS in the external W25Q32 SPI NOR. `make flash`
writes both (`make flash-bitstream` and `make flash-bios` do them individually).
Because they are different chips, the BIOS at external offset 0 and the bitstream
never overwrite each other.

Both writes go through JTAG bitbanging, which is slow and occasionally fails its
post-write CRC (`CRC check : FAIL`). If that happens, just run the target again.

## Hello world (LiteX BIOS)

Open the console in one terminal and reset the board in another:

```bash
make console          # litex_term on $(TTY)
make reset            # reload from flash (or press the board's reset button)
```

The banner appears: the ASCII-art logo, `CPU: Ibex @ 13MHz`, `BIOS CRC passed`,
`Memtest OK`, and a `litex>` prompt that answers `help`, `ident`, and friends.

## Apps

Bare-metal firmware lives under [`apps/`](apps/), one directory per app plus a
shared [`common/`](apps/common/) with the startup code:

```
apps/
  common/     crt0.S, linker.ld   (shared startup + link script)
  echo/       main.c              (UART echo + on-board LED, serial-booted)
  blink/      main.c              (external LED, flash-booted, runs on power-up)
  blink_irq/  main.c, crt0.S      (same, but timer + interrupt driven)
```

`make apps` builds them all; `make app APP=<name>` builds one. Output is
out-of-tree, in `build/apps/<name>/` (`<name>.elf`, `.bin`, and the `.fbi`
flash-boot image). Adding an app is just a new `apps/<name>/main.c`; the build
picks it up automatically. An app can also drop in its own `crt0.S` (as
`blink_irq` does) and the build uses it instead of the shared one.

### Serial app: UART echo + on-board LED

`apps/echo/main.c` prints once on boot, then echoes serial input and toggles the
on-board LED on each keypress. `make run APP=echo` builds it and opens the console
with the binary queued. At the `litex>` prompt (press the board's reset button to
get a fresh one) run `serialboot`: the BIOS reaches "Booting from serial",
litex_term sends the binary into the 8 KB BRAM main RAM, and the CPU jumps to it.
Keep such binaries small, since main RAM is only 8 KB.

### Flash app: external LED, runs on power-up

`apps/blink/main.c` blinks an **external LED** with no host attached, straight from
flash on power-up. Two pieces make that work, both in `tn9k_ibex.py` (no patches):

- An external LED on **J6 pin 25**, added with `platform.add_extension()` and driven
  by a dedicated `GPIOOut`. The CPU controls it through the `ext_led_out` CSR, so C
  calls `ext_led_out_write(1)` / `ext_led_out_write(0)`. The on-board LEDs are
  untouched.
- `FLASH_BOOT_ADDRESS` at flash offset `0x100000`, added with `soc.add_constant()`.
  The BIOS tries serialboot first, then flashboot: on a headless boot serialboot
  times out and the BIOS copies the flash image into main RAM and runs it.

Wire the LED to pin 25: FPGA pin 25 -> current-limiting resistor (~330R) -> LED
anode, LED cathode -> GND. Then:

```bash
make blink            # builds apps/blink and flashes it to offset 0x100000
```

Power-cycle or `make reset` with nothing driving serial. Watch it with `make console`
if you like: after serialboot times out the BIOS prints `Booting from flash...` and
`Copying 0x00100000 to 0x40000000 ...`, jumps, and the external LED blinks. The
on-board LEDs stay off; serial-booting the echo app still drives them as before.

The `.fbi` image is `[length][crc32][payload]` with the header written little-endian
(`crcfbigen -f -l`) to match this little-endian Ibex. If the console ever shows
`Error: invalid image length` or `CRC failed`, the flashed image is wrong or stale;
re-run `make blink` to rebuild and reflash.

### Interrupt + timer version

`apps/blink_irq/main.c` does the same thing as `blink`, but instead of a busy-loop
it uses the timer. It programs `timer0` to count down from half a second and
auto-reload, so it raises a periodic event that LiteX wires to a fast local
interrupt on the Ibex. The interrupt service routine (`isr()`) clears the event,
toggles the LED, and bumps a counter; `main()` watches that counter and prints
`Toggling LED...` on each change, keeping the slow serial work out of the ISR.

Enabling it is three calls in `main()`: set up `timer0`, unmask the timer IRQ with
`irq_setmask()`, and enable interrupts globally with `irq_setie()`. This app ships
its own `apps/blink_irq/crt0.S`, which points `mtvec` at a trap handler that saves
the caller-saved registers, calls `isr()`, restores them, and returns with `mret`.
It uses direct trap mode (one handler, dispatched in software off the pending mask)
rather than a vectored table, which keeps the startup small and avoids the
compressed-jump alignment pitfall a vector table has under the C extension.

Build and flash it like the other flash-boot app:
```bash
make flash-app APP=blink_irq
```
Then `make reset` with `make console` open: you get the same blinking LED and
`Toggling LED...` stream, now paced by the timer interrupt.

### Why the startup code is what it is

`apps/common/crt0.S` is local rather than the shared Ibex crt0 on purpose. The
shared one places a 256-byte trap table at the start of the image with the reset
entry at offset 0x80, because the Ibex hardware reset vector is `boot_addr + 0x80`.
Both boot paths here are different: serialboot and flashboot each copy the image
into main RAM and jump to its base, so the entry point has to sit at offset 0. This
crt0 puts `_start` there, sets the stack, clears `.bss`, copies `.data`, and calls
`main`, which is all a polling, interrupt-free program needs.

## Tools and resources

The build framework and SoC generator:

- [LiteX](https://github.com/enjoy-digital/litex): SoC builder that generates the gateware, bus, and BIOS; installed via its `litex_setup.py`.
- [litex-boards](https://github.com/litex-hub/litex-boards): board targets, including `sipeed_tang_nano_9k`, which `tn9k_ibex.py` subclasses.
- [pythondata-cpu-ibex](https://github.com/litex-hub/pythondata-cpu-ibex): LiteX packaging of the Ibex RTL; a data-only wrapper LiteX reads the SystemVerilog from.
- [lowRISC Ibex](https://github.com/lowRISC/ibex): the RISC-V CPU core itself, vendored into pythondata-cpu-ibex.

The open FPGA toolchain (all already in the [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) container):

- [yosys](https://github.com/YosysHQ/yosys): synthesis (RTL to gate-level netlist).
- [yosys-slang](https://github.com/povik/yosys-slang): SystemVerilog frontend plugin for yosys; needed to parse the lowRISC Ibex sources.
- [nextpnr-himbaechel](https://github.com/YosysHQ/nextpnr): place and route for the Gowin GW1NR-9.
- [apicula](https://github.com/YosysHQ/apicula): Gowin bitstream tooling (`gowin_pack`).
- [openFPGALoader](https://github.com/trabucayre/openFPGALoader): flashes the bitstream and BIOS over JTAG.

Toolchain and hardware:

- [riscv64-unknown-elf GCC](https://packages.ubuntu.com/gcc-riscv64-unknown-elf): cross-compiler for the BIOS and the bare-metal [apps](./apps).
- [Sipeed Tang Nano 9K](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html): the target board (Gowin GW1NR-9 FPGA).
