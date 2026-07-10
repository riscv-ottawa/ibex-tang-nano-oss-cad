# Bare-metal firmware for the Tang Nano 9K Ibex SoC.
#
# Runs inside the container (it needs the RISC-V toolchain and the SoC build
# tree). Builds one app, selected with APP=<name>, from apps/<name>/main.c plus
# the shared startup in apps/common/. Output goes to build/apps/<name>/.
#
#   make -C apps APP=blink      # -> build/apps/blink/blink.{elf,bin,fbi}
#
# The repo-root Makefile drives this for every app; you rarely call it directly.

APP       ?= blink
BUILD_DIR ?= ../build/sipeed_tang_nano_9k
OUT_DIR   ?= ../build/apps
OUT       := $(OUT_DIR)/$(APP)

# LiteX-provided toolchain flags, include paths, libraries, and the canned
# $(compile)/$(assemble) recipes. Paths inside are absolute, so building
# out-of-tree just works.
include $(BUILD_DIR)/software/include/generated/variables.mak
include $(SOC_DIRECTORY)/software/common.mak

# Prepends the [length][crc32] header the BIOS flashboot expects; -l writes it
# little-endian to match the Ibex (as LiteX's own bare-metal demo does).
CRCFBIGEN ?= /opt/litex/litex/litex/soc/software/crcfbigen.py

# Startup: an app may ship its own crt0.S (e.g. an interrupt handler); otherwise
# it uses the shared minimal one in common/.
CRT0 := $(firstword $(wildcard $(APP)/crt0.S) common/crt0.S)

OBJECTS = $(OUT)/crt0.o $(OUT)/main.o

all: $(OUT)/$(APP).bin $(OUT)/$(APP).fbi

$(OUT):
	mkdir -p $@

$(OUT)/crt0.o: $(CRT0) | $(OUT)
	$(assemble)

$(OUT)/main.o: $(APP)/main.c | $(OUT)
	$(compile)

$(OUT)/$(APP).elf: $(OBJECTS)
	$(CC) $(LDFLAGS) -T common/linker.ld -N -o $@ \
		$(OBJECTS) \
		$(PACKAGES:%=-L$(BUILD_DIR)/software/%) \
		-Wl,--start-group $(LIBS:lib%=-l%) -Wl,--end-group \
		-Wl,--gc-sections -Wl,-Map,$@.map

$(OUT)/$(APP).bin: $(OUT)/$(APP).elf
	$(OBJCOPY) -O binary $< $@

$(OUT)/$(APP).fbi: $(OUT)/$(APP).bin
	python3 $(CRCFBIGEN) $< -o $@ -f -l

clean:
	rm -rf $(OUT_DIR)

.PHONY: all clean
