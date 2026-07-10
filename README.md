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

`make help` lists all targets. Runtime settings like `APP`, `TTY`, and `BAUD` are
overridable on the command line, for example `make run APP=echo TTY=/dev/ttyUSB1`;
their defaults live at the top of the `Makefile`. The SoC build parameters (clock,
main RAM, baud) live in `tn9k_ibex.py` instead, as described below.

## Building the SoC (`make soc`)

`make soc` runs this project's board target, `python3 tn9k_ibex.py --build`. The
target sets the values that work on this board as its own defaults, so no build
flags are needed; each one replaces an upstream default that does not work here.
You can still override any of them on the command line, for example
`python3 tn9k_ibex.py --sys-clk-freq 27e6 --build`.

- `integrated_main_ram_size = 0x2000` puts 8 KB of main RAM in BRAM. This one is
  required: the upstream default brings up the on-board HyperRAM as main RAM, and
  that controller fails memtest badly (256/256 bus errors, ~99.6% data corruption).
- `uart_baudrate = 9600` is the serial baud that gives the least trouble. At 115200
  the BIOS receiver overran during a binary upload and every `serialboot` aborted
  with a frame or CRC error; at 9600 the upload completes. `make console` and
  `make run` read this baud from the `Makefile`'s `BAUD`, which must match it.
- `sys_clk_freq = 13.5e6` is what worked here. At the upstream 27 MHz default the
  design does not boot at all (the CPU is silent), not sure why.

Synthesis runs yosys, then nextpnr-himbaechel places and routes, then `gowin_pack`
writes the bitstream to `build/sipeed_tang_nano_9k/gateware/`.

## USB permissions (one-time host setup)

The board enumerates as two USB-serial ports: interface A is JTAG (used by
openFPGALoader, often `/dev/ttyUSB0`) and interface B is the UART console (often
`/dev/ttyUSB1`). Access is set by udev rules, and udev runs on the host, so this
is a host change even though flashing happens from the container.

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
