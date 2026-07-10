#!/usr/bin/env python3

# Tang Nano 9K / Ibex target.
#
# Board customisations that are plain configuration (an extra GPIO output, a
# BIOS constant) belong in a target script, not in a patch against the vendored
# litex-boards tree, so they live here. This subclasses the upstream Tang Nano
# 9K BaseSoC and adds:
#   - an external LED on J6 pin 25, driven by a dedicated GPIOOut (ext_led_out
#     CSR), so plain C can toggle it with ext_led_out_write();
#   - FLASH_BOOT_ADDRESS, so the BIOS auto-boots a flash-resident app (at SPI
#     flash offset app_flash_offset) into Main RAM once serialboot times out.
#
# The remaining deltas (Ibex-under-slang, the distributed-RAM register file, the
# clock-gate pass-through, the BIOS init-array section) are fixes to upstream
# source, not board config, so they stay as patches in the Containerfile. This
# subclasses the *patched* upstream BaseSoC, so it inherits the fpga register
# file automatically.
#
# Build (from the repo root inside the container), same options as before:
#   python3 tn9k_ibex.py --toolchain apicula --cpu-type ibex \
#     --sys-clk-freq 13.5e6 --integrated-main-ram-size 0x2000 \
#     --uart-baudrate 9600 --build

from litex.build.generic_platform import Pins, IOStandard
from litex.soc.cores.gpio import GPIOOut
from litex.soc.integration.builder import Builder
from litex.build.parser import LiteXArgumentParser

from litex_boards.platforms import sipeed_tang_nano_9k
from litex_boards.targets.sipeed_tang_nano_9k import BaseSoC as _BaseSoC


class BaseSoC(_BaseSoC):
    def __init__(self, app_flash_offset=0x100000, **kwargs):
        super().__init__(**kwargs)

        # External LED on J6 pin 25: FPGA pin 25 -> resistor -> LED -> GND.
        # A dedicated GPIO output rather than a 7th on-board LED; the CPU drives
        # it through the ext_led_out CSR (ext_led_out_write(1) / (0)).
        self.platform.add_extension([
            ("ext_led", 0, Pins("25"), IOStandard("LVCMOS33")),
        ])
        self.ext_led = GPIOOut(self.platform.request("ext_led"))

        # Auto-boot a flash-resident app. After serialboot times out, the BIOS
        # copies the FBI image at this flash offset into Main RAM and runs it
        # (boot priority: serial=0, flash=10). Constant-only, no gateware cost.
        self.add_constant("FLASH_BOOT_ADDRESS",
                          self.bus.regions["spiflash"].origin + app_flash_offset)


def main():
    parser = LiteXArgumentParser(platform=sipeed_tang_nano_9k.Platform,
                                 description="LiteX SoC on Tang Nano 9K (Ibex).")
    parser.add_target_argument("--flash",               action="store_true",      help="Flash bitstream.")
    parser.add_target_argument("--sys-clk-freq",        default=27e6, type=float, help="System clock frequency.")
    parser.add_target_argument("--bios-flash-offset",   default="0x0",            help="BIOS offset in SPI Flash.")
    parser.add_target_argument("--app-flash-offset",    default="0x100000",       help="Flash-boot app offset in SPI Flash.")
    parser.add_target_argument("--with-spi-sdcard",     action="store_true",      help="Enable SPI-mode SDCard support.")
    parser.add_target_argument("--with-video-terminal", action="store_true",      help="Enable Video Terminal (HDMI).")
    parser.add_target_argument("--prog-kit",            default="openfpgaloader", help="Programmer select from Gowin/openFPGALoader.")
    args = parser.parse_args()

    soc = BaseSoC(
        toolchain           = args.toolchain,
        sys_clk_freq        = args.sys_clk_freq,
        bios_flash_offset   = int(args.bios_flash_offset, 0),
        app_flash_offset    = int(args.app_flash_offset, 0),
        with_video_terminal = args.with_video_terminal,
        **parser.soc_argdict
    )

    if args.with_spi_sdcard:
        soc.add_spi_sdcard()

    builder = Builder(soc, **parser.builder_argdict)
    if args.build:
        builder.build(**parser.toolchain_argdict)

    if args.load:
        prog = soc.platform.create_programmer(kit=args.prog_kit)
        prog.load_bitstream(builder.get_bitstream_filename(mode="sram"))

    if args.flash:
        prog = soc.platform.create_programmer(kit=args.prog_kit)
        prog.flash(0, builder.get_bitstream_filename(mode="flash", ext=".fs"))
        if args.prog_kit == "openfpgaloader":
            prog.flash(int(args.bios_flash_offset, 0), builder.get_bios_filename(), external=True)


if __name__ == "__main__":
    main()
