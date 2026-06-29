# Ibex RISC-V on the Tang Nano 9K

A complete RISC-V SoC (lowRISC **Ibex** CPU + UART + memory + Wishbone bus) for
the Sipeed Tang Nano 9K (Gowin GW1NR-9), built with LiteX and the fully open
FPGA flow (yosys + nextpnr-himbaechel + apicula).

## What you need

- A Sipeed Tang Nano 9K.
- Podman (or Docker, substitute `docker` for `podman` everywhere).

Everything else (the open FPGA toolchain, RISC-V GCC, LiteX) is in the container image.

## 1. Build the image

```bash
podman build -t tn9k-ibex .
```

The build pulls the newest OSS CAD Suite release on its own. To pin an exact
version for reproducibility, pass the asset URL from
<https://github.com/YosysHQ/oss-cad-suite-build/releases>:

```bash
podman build -t tn9k-ibex .
```

## 2. Start the container

Run it detached with your project mounted at `/work`. Build artifacts land in
`./build` on the host.

```bash
podman run -dit --privileged --name tn9k-ibex -v "$PWD":/work tn9k-ibex
```

## 3. Build the SoC

From inside the container, run:

```bash
cd /work && \
python3 -m litex_boards.targets.sipeed_tang_nano_9k \
--toolchain apicula --cpu-type ibex --sys-clk-freq 13.5e6 \
--integrated-main-ram-size 0x2000 --uart-baudrate 9600 --build
```

What the options mean:

- `--integrated-main-ram-size 0x2000` puts 8 KB of main RAM in BRAM. This one is
  required: dropping it brings up the on-board HyperRAM as main RAM, and that
  controller fails memtest badly for some reason (256/256 bus errors, ~99.6% data
  corruption).
- `--uart-baudrate 9600` is the baud for serial uploads (step 7) that gives the least trouble.
  At 115200 the BIOS receiver overran during the binary burst and every `serialboot`
  aborted with a frame or CRC error; at 9600 the upload completes.
- `--sys-clk-freq 13.5e6` is what worked for me. At 27 MHz the design does not
  boot at all (the CPU is silent), not sure why.

Synthesis runs yosys, then nextpnr-himbaechel places and routes, then
`gowin_pack` writes the bitstream to
`build/sipeed_tang_nano_9k/gateware/sipeed_tang_nano_9k.fs`.

The design lands around 80% of the GW1NR-9's LUT4s. nextpnr-himbaechel can fail
placement right at that utilisation ("Unable to find legal placement for all
cells"); it is seed-sensitive, so just re-run the build and it places on a later
attempt.

## 4. USB permissions (one-time host setup)

The board enumerates as two USB-serial ports: interface A is JTAG (used by
openFPGALoader, often `/dev/ttyUSB0`) and interface B is the UART console (often
`/dev/ttyUSB1`).

Install openFPGALoader's udev rules on the host (udev runs on the host, not in the
container, so this is a host change even when you flash from the container):

```bash
sudo wget -O /etc/udev/rules.d/70-openfpgaloader.rules \
  https://raw.githubusercontent.com/trabucayre/openFPGALoader/refs/heads/master/70-openfpgaloader.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Replug the board and restart the container so the new permissions apply.
Confirm with `podman exec tn9k-ibex openFPGALoader --detect -b tangnano9k`.

## 5. Flash the bitstream and BIOS

The bitstream and the BIOS live on two separate chips: the bitstream in the FPGA's
embedded configuration flash, the BIOS in the external W25Q32 SPI NOR. Flash both.

```bash
# bitstream -> embedded flash
podman exec tn9k-ibex bash -lc 'cd /work && \
  openFPGALoader -b tangnano9k -f build/sipeed_tang_nano_9k/gateware/sipeed_tang_nano_9k.fs'

# BIOS -> external SPI flash, offset 0
podman exec tn9k-ibex bash -lc 'cd /work && \
  openFPGALoader -b tangnano9k --external-flash -o 0 build/sipeed_tang_nano_9k/software/bios/bios.bin'
```

Both writes go through JTAG bitbanging, which is slow and occasionally fails its
post-write CRC (`CRC check : FAIL`). If that happens, just run the command again.
The BIOS at external offset 0 is on a different chip than the bitstream, so the two
never overwrite each other (this is also the stock target's `--bios-flash-offset`
default).

## 6. See the hello world (LiteX BIOS)


In one terminal, open the serial console:
```bash
podman exec -it tn9k-ibex bash -lc 'litex_term /dev/ttyUSB1 --speed 9600'
```

In another, reload from flash (or just press the reset button):
```bash
podman exec tn9k-ibex bash -lc 'openFPGALoader -b tangnano9k -r'
```

The banner appears in the console: the ASCII-art logo, `CPU: Ibex @ 13MHz`,
`BIOS CRC passed`, `Memtest OK`, and a `litex>` prompt that answers commands like
`help` and `ident`.

## 7. Run your own bare-metal app

The [`app/`](app/) directory is a minimal standalone program: a `main.c`, a small
`crt0.S`, a linker script, and a Makefile. It links against LiteX's libbase through
the build tree, so there is little boot plumbing to write. `main()` prints once on
boot, then echoes serial input and toggles the on-board LED on each keypress:

```c
#include <stdio.h>
#include <libbase/uart.h>
#include <libbase/console.h>
#include <generated/csr.h>

int main(void) {
    uart_init();
    puts("\nIbex on Tang Nano 9K - echo + blink\n");
    uint32_t led = 0;
    while (1) {
        if (readchar_nonblock()) {
            char c = getchar();
            putchar(c);            /* echo the byte back */
            led ^= 1;
            leds_out_write(led);   /* toggle LED on each keypress */
        }
    }
    return 0;
}
```

Build it, then upload over serial. The BIOS loads it into the 8 KB BRAM main RAM,
so keep the binary small (this one is about 600 bytes):
```bash
podman exec tn9k-ibex bash -lc 'cd /work && make -C app'
podman exec -it tn9k-ibex bash -lc \
  'litex_term /dev/ttyUSB1 --speed 9600 --kernel=app/app.bin'
```

The Makefile defaults `BUILD_DIR` to `../build/sipeed_tang_nano_9k/`, so `make -C app`
works as written; override it if you build the SoC somewhere else.

With the console open, get the board to a fresh `litex>` prompt by pressing the
reset button on the board (the reliable path; `openFPGALoader -r` often half-resets
the SoC here, hanging in memtest or coming up at the wrong baud). At the prompt, run
`serialboot`. The BIOS reaches "Booting from serial", litex_term sends `app.bin`,
and the CPU jumps to it. You will see the greeting, then typed characters echo back
and the LED toggles.

`app/crt0.S` is local rather than the shared Ibex crt0 on purpose. The shared one
places a 256-byte trap table at the start of the image with the reset entry at
offset 0x80, because the Ibex hardware reset vector is `boot_addr + 0x80`. A
serial-booted program is different: the BIOS jumps straight to the load address
(main RAM base), so the entry point has to be at offset 0. The local crt0 puts
`_start` there, which is all a polling, interrupt-free program needs.
