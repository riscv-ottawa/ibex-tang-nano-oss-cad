# Tang Nano 9K / Ibex toolchain image.
#
# Contains the full open FPGA flow plus everything LiteX needs to build, flash,
# and talk to the SoC:
#   - OSS CAD Suite: yosys, nextpnr-himbaechel, gowin_pack (apicula), openFPGALoader
#   - RISC-V GCC (riscv64-unknown-elf) for the BIOS and bare-metal apps
#   - LiteX (+ ibex core) installed into a venv, with litex_term / litex_bare_metal_demo
#
# BUILD:
#   podman build -t ibex-tang-nano-oss-cad-f Containerfile .
#
# RUN:
# podman run -dit --privileged --name ibex-tang-nano-oss-cad-v "$PWD":/work ibex-tang-nano-oss-cad

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
        clangd neovim less \
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

# LiteX + CPU cores (full config pulls in ibex) into an isolated venv. Floats on
# whatever litex_setup checks out, i.e. the latest master of each repo. The Ibex
# crt0 reset-vector fix and the current-Ibex wrapper integration are upstream, so
# master builds as-is.
RUN python3 -m venv /opt/litex-venv \
    && mkdir -p /opt/litex && cd /opt/litex \
    && wget -q https://raw.githubusercontent.com/enjoy-digital/litex/master/litex_setup.py \
    && python3 litex_setup.py --init --install --config=full \
    && rm -rf /root/.cache/pip

# Test the upstream yosys-slang / Ibex integration from litex PR #2510
# (enjoy-digital/litex, branch fix-yosys-slang-ibex, resolves issue #2492). It
# supersedes our local litex-ibex-apicula.patch: the wrapper routes SystemVerilog
# through read_slang gated on platform.yosys_use_slang / yosys_slang_opts, and the
# Ibex core selects its register file via platform.ibex_regfile ("ff"/"fpga").
# litex is pip-installed editable, so checking out the branch is enough. The
# litex-boards regfile opt-in below still applies (same ibex_regfile attribute).
RUN cd /opt/litex/litex \
    && git fetch origin fix-yosys-slang-ibex \
    && git checkout fix-yosys-slang-ibex

# Pass the design's clock target to nextpnr on the open Apicula/Gowin flow. The
# apicula toolchain never emitted --freq, so nextpnr-himbaechel placed against
# its 12 MHz default with --timing-allow-fail on and silently shipped bitstreams
# that fail timing at the real sys_clk_freq (LiteX #1866, #1719). The patch adds
# build_timing_constraints, mirroring the Xilinx/CologneChip nextpnr flows.
COPY litex-apicula-nextpnr-freq.patch /tmp/litex-apicula-nextpnr-freq.patch
RUN cd /opt/litex/litex && git apply --verbose /tmp/litex-apicula-nextpnr-freq.patch \
    && rm /tmp/litex-apicula-nextpnr-freq.patch

# Opt the Tang Nano 9K target into the distributed-RAM register file so the SoC
# fits the GW1NR-9; the default flip-flop file overflows its LUTs (106%).
COPY litex-boards-tang-nano-regfile.patch /tmp/litex-boards-tang-nano-regfile.patch
RUN cd /opt/litex/litex-boards && git apply --verbose /tmp/litex-boards-tang-nano-regfile.patch \
    && rm /tmp/litex-boards-tang-nano-regfile.patch

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
