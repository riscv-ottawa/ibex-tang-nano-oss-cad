# Ibex on Tang Nano 9K - build automation.
#
# Wraps the container flow from the README so the whole thing is a few `make`
# targets. Run these from the host; each one shells into the container, which
# holds the toolchain. Typical first run:
#
#   make image      # build the container image (once)
#   make up         # start the container (once per boot)
#   make soc        # build gateware + BIOS
#   make flash      # flash bitstream + BIOS to the board
#   make blink      # build + flash the external-LED blink app, runs on reset
#
# `make help` lists everything. Any variable below can be overridden, e.g.
# `make run APP=echo TTY=/dev/ttyUSB1`.

# ---- Configuration ---------------------------------------------------------

CONTAINER ?= ibex-tang-nano-oss-cad         # running container name
IMAGE     ?= ibex-tang-nano-oss-cad         # image tag built from the Containerfile
BOARD     ?= tangnano9k         # openFPGALoader board
TTY       ?= /dev/ttyUSB1       # UART console (interface B)

APP              ?= blink       # which app under apps/ to build/flash/run
APP_FLASH_OFFSET ?= 0x100000    # where a flash-boot app lives in SPI flash

# SoC build parameters (see README section 3 for why these values).
TOOLCHAIN     ?= apicula
CPU           ?= ibex
SYS_CLK_FREQ  ?= 13.5e6
MAIN_RAM_SIZE ?= 0x2000
BAUD          ?= 9600

# Build artifacts.
GATEWARE = build/sipeed_tang_nano_9k/gateware/sipeed_tang_nano_9k.fs
BIOS     = build/sipeed_tang_nano_9k/software/bios/bios.bin

# Apps are the subdirs of apps/ that contain a main.c (common/ is excluded).
APPS := $(notdir $(patsubst %/main.c,%,$(wildcard apps/*/main.c)))

# Run a command in the toolchain environment. From the host that means shelling
# into the container; inside the dev container (which has /opt/litex) we are
# already there, so the same soc/apps/flash targets work in both places.
ifneq ($(wildcard /opt/litex),)
EXEC    = bash -lc
EXEC_IT = bash -lc
else
EXEC    = podman exec $(CONTAINER) bash -lc
EXEC_IT = podman exec -it $(CONTAINER) bash -lc
endif

.DEFAULT_GOAL := help

# ---- Container -------------------------------------------------------------

image: ## Build the container image
	podman build -t $(IMAGE) .

up: ## Start (or create) the container
	podman start $(CONTAINER) 2>/dev/null || \
	podman run -dit --privileged --group-add=keep-groups --name $(CONTAINER) -v "$$PWD":/work $(IMAGE)

down: ## Stop and remove the container
	-podman rm -f $(CONTAINER)

shell: ## Open a shell in the container
	$(EXEC_IT) 'cd /work && exec bash'

# ---- Build -----------------------------------------------------------------

soc: ## Build the SoC gateware + BIOS
	$(EXEC) 'cd /work && python3 tn9k_ibex.py \
		--toolchain $(TOOLCHAIN) --cpu-type $(CPU) --sys-clk-freq $(SYS_CLK_FREQ) \
		--integrated-main-ram-size $(MAIN_RAM_SIZE) --uart-baudrate $(BAUD) --build'

app: ## Build one app (APP=blink)
	$(EXEC) 'cd /work && make -C apps APP=$(APP)'

apps: ## Build every app under apps/
	@for a in $(APPS); do \
		echo ">> building $$a"; \
		$(EXEC) "cd /work && make -C apps APP=$$a" || exit 1; \
	done

# ---- Flash / run -----------------------------------------------------------

detect: ## Detect the board over JTAG
	$(EXEC) 'openFPGALoader --detect -b $(BOARD)'

flash-bitstream: ## Flash the bitstream to FPGA config flash
	$(EXEC) 'cd /work && openFPGALoader -b $(BOARD) -f $(GATEWARE)'

flash-bios: ## Flash the BIOS to external SPI flash (offset 0)
	$(EXEC) 'cd /work && openFPGALoader -b $(BOARD) --external-flash -o 0 $(BIOS)'

flash: flash-bitstream flash-bios ## Flash bitstream + BIOS

flash-app: app ## Flash APP to SPI flash at APP_FLASH_OFFSET (for flash-boot)
	$(EXEC) 'cd /work && openFPGALoader -b $(BOARD) --external-flash \
		-o $(APP_FLASH_OFFSET) build/apps/$(APP)/$(APP).fbi'

reset: ## Reload the board from flash
	$(EXEC) 'openFPGALoader -b $(BOARD) -r'

console: ## Open the serial console
	$(EXEC_IT) 'litex_term $(TTY) --speed $(BAUD)'

run: app ## Serial-boot APP over the console (e.g. run APP=echo)
	$(EXEC_IT) 'cd /work && litex_term $(TTY) --speed $(BAUD) \
		--kernel=build/apps/$(APP)/$(APP).bin'

# ---- Housekeeping ----------------------------------------------------------

clean: ## Remove firmware build outputs
	rm -rf build/apps

help: ## List targets
	@echo "Ibex on Tang Nano 9K - make targets:"
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo "Apps: $(APPS)"

.PHONY: image up down shell soc app apps detect flash-bitstream flash-bios \
	flash flash-app blink reset console run clean help
