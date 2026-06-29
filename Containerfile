# Tang Nano 9K / Ibex toolchain image.
#
# Contains the full open FPGA flow plus everything LiteX needs to build, flash,
# and talk to the SoC:
#   - OSS CAD Suite: yosys, nextpnr-himbaechel, gowin_pack (apicula), openFPGALoader
#   - RISC-V GCC (riscv64-unknown-elf) for the BIOS and bare-metal apps
#   - LiteX (+ ibex core) installed into a venv, with litex_term / litex_bare_metal_demo
#
# BUILD:
#   podman build -t tn9k-ibex -f Containerfile .
#
# RUN:
# podman run -dit --privileged --name tn9k-ibex -v "$PWD":/work tn9k-ibex

# By default the newest OSS CAD Suite linux-x64 release is resolved and downloaded.
# Pin a specific build for reproducibility with:
#   --build-arg OSS_CAD_SUITE_URL=https://github.com/YosysHQ/oss-cad-suite-build/releases/download/<tag>/<asset>.tgz

FROM ubuntu:24.04

# Optional: pin an exact OSS CAD Suite .tgz URL. Empty = resolve the latest release.
ARG OSS_CAD_SUITE_URL=

# Non-interactive apt; the venv on PATH makes `python3`/`pip` resolve to LiteX's
# interpreter, and the OSS CAD Suite bin (appended) supplies yosys/nextpnr/etc.
# Ordering matters: the venv must precede the suite so its bundled python3 does
# not shadow the one that has LiteX installed.
ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/opt/litex-venv/bin:/opt/oss-cad-suite/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake ca-certificates git wget \
        python3 python3-pip python3-venv \
        meson ninja-build \
        libevent-dev libjson-c-dev \
        gcc-riscv64-unknown-elf \
    && rm -rf /var/lib/apt/lists/*

# Open FPGA flow, downloaded at build time. OSS CAD Suite binaries are relocatable
# (rpath-based), so adding the bin dir to PATH is enough; no `source environment`.
RUN set -eux; \
    url="${OSS_CAD_SUITE_URL}"; \
    if [ -z "$url" ]; then \
        url="$(wget -qO- https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest \
              | grep -oE 'https://[^\"]*oss-cad-suite-linux-x64-[0-9]+\.tgz' | head -n1)"; \
    fi; \
    echo "Fetching OSS CAD Suite: $url"; \
    wget -qO /tmp/oss-cad-suite.tgz "$url"; \
    mkdir -p /opt; \
    tar -xf /tmp/oss-cad-suite.tgz -C /opt; \
    rm /tmp/oss-cad-suite.tgz; \
    yosys --version && nextpnr-himbaechel --version && openFPGALoader --Version

# LiteX + CPU cores (full config pulls in ibex) into an isolated venv.
# LITEX_REF pins the litex repo to a known-good master commit. We depend on the
# upstreamed Ibex crt0 reset-vector fix (9b02b8e53) and the current-Ibex wrapper
# integration (4b97f01), so floating on master is not safe; bump this to re-pull.
ARG LITEX_REF=0806fefd2
RUN python3 -m venv /opt/litex-venv \
    && mkdir -p /opt/litex && cd /opt/litex \
    && wget -q https://raw.githubusercontent.com/enjoy-digital/litex/master/litex_setup.py \
    && python3 litex_setup.py --init --install --config=full \
    && git -C litex fetch --depth=300 origin master \
    && git -C litex checkout "${LITEX_REF}" \
    && rm -rf /root/.cache/pip

# Make the Ibex build under the open (apicula) flow. This patch (1) routes the
# lowRISC Ibex SystemVerilog through the yosys-slang frontend (stock read_verilog
# -sv cannot parse it) and adds the prim sources slang needs as a full elaborator,
# and (2) selects the small distributed-RAM register file (the default flip-flop
# file overflows the GW1NR-9 LUTs at 106%). Two earlier fixes are gone: the crt0
# reset-vector layout is now upstream (litex 9b02b8e53), and the BIOS UART no
# longer needs forcing to polling (interrupt-driven UART boots cleanly on the
# current Ibex integration). See README.md for the full story.
COPY litex-ibex-apicula.patch /tmp/litex-ibex-apicula.patch
RUN cd /opt/litex/litex && git apply --verbose /tmp/litex-ibex-apicula.patch \
    && rm /tmp/litex-ibex-apicula.patch

# Replace the lowRISC Ibex clock-gating cell with a pass-through. The latch-based
# gate does not route onto Gowin's global clock network through
# nextpnr-himbaechel, which can leave the core unclocked; pass-through keeps it
# permanently clocked (functionally correct, only loses the power optimisation).
COPY pythondata-cpu-ibex-clock-gating.patch /tmp/pythondata-cpu-ibex-clock-gating.patch
RUN cd /opt/litex/pythondata-cpu-ibex && git apply --verbose /tmp/pythondata-cpu-ibex-clock-gating.patch \
    && rm /tmp/pythondata-cpu-ibex-clock-gating.patch

# Mount your project here (build artifacts land in ./build).
WORKDIR /work

ENTRYPOINT ["/bin/bash"]
