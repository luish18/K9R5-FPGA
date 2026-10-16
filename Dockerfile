# K9R5-FPGA build environment: CVA6 + Ara (Cheshire) + Spatz cluster.
#
# Provides Bender, Verilator, Spike, a modern RV64 GCC for Cheshire/CVA6
# software, Ara's RV64 LLVM, and the RV32 GCC/LLVM toolchains used by the Spatz
# cluster. Ara's and Spatz's toolchains are built from the revisions pinned by
# the ara/ and spatz/ submodules, so bump ARA_COMMIT / SPATZ_COMMIT /
# CHESHIRE_COMMIT together with the submodules.
#
# Vivado is NOT included (license + size). Mount a host install instead:
#
#   docker build -t k9r5-fpga .
#   docker run -it --rm -v "$PWD":/work -v /tools/Xilinx:/tools/Xilinx k9r5-fpga
#
# A full build compiles two LLVMs and three GCCs: expect several hours and
# ~40 GB of free disk (build cache plus temporary build trees).

ARG UBUNTU_VERSION=24.04
ARG ARA_COMMIT=34bd3bc152421b4601a7bf3d6e8e91ffb545c99e
ARG SPATZ_COMMIT=d26ee74a9d29bb0df4117f9f3071698f5c65f7c0
ARG CHESHIRE_COMMIT=e040b7bbc7851a37faff3c4657ff8d656cc6e20a
ARG BENDER_VERSION=0.32.1
ARG RISCV_GNU_TOOLCHAIN_TAG=2026.08.27

########################################
#  Base: OS packages, Python, Bender   #
########################################
FROM ubuntu:${UBUNTU_VERSION} AS base

ARG ARA_COMMIT
ARG SPATZ_COMMIT
ARG CHESHIRE_COMMIT
ARG BENDER_VERSION
ENV DEBIAN_FRONTEND=noninteractive

# The libx*/libtinfo6/locales packages are runtime deps of a mounted Vivado.
RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf automake autotools-dev bc bison build-essential ca-certificates \
        ccache cmake curl device-tree-compiler flex g++ gawk gcc git gperf \
        help2man libelf-dev libexpat1-dev libfl-dev libfl2 libglib2.0-dev \
        libgmp-dev libmpc-dev libmpfr-dev libncurses-dev libslirp-dev libtool \
        ninja-build openocd patch patchutils perl pkg-config python3 \
        python3-dev python3-pip python3-venv rsync texinfo unzip wget xz-utils \
        zlib1g zlib1g-dev \
        libtinfo6 libx11-6 libxext6 libxrender1 libxtst6 locales \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Python deps of Ara, Spatz and Cheshire, in one venv on PATH
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv ${VIRTUAL_ENV}
ENV PATH=${VIRTUAL_ENV}/bin:${PATH}
RUN curl -fsSL -o /tmp/ara-req.txt \
        https://raw.githubusercontent.com/pulp-platform/ara/${ARA_COMMIT}/python-requirements.txt \
    && curl -fsSL -o /tmp/spatz-req.txt \
        https://raw.githubusercontent.com/pulp-platform/spatz/${SPATZ_COMMIT}/requirements.txt \
    && curl -fsSL -o /tmp/chs-req.txt \
        https://raw.githubusercontent.com/pulp-platform/cheshire/${CHESHIRE_COMMIT}/requirements.txt \
    && pip install --no-cache-dir -r /tmp/ara-req.txt -r /tmp/spatz-req.txt -r /tmp/chs-req.txt \
    && rm /tmp/*-req.txt

# Newer installers put the binary in ~/.cargo/bin, older ones in the cwd
RUN mkdir -p /tmp/bender && cd /tmp/bender \
    && curl --proto '=https' --tlsv1.2 -sSf https://pulp-platform.github.io/bender/init \
        | sh -s -- ${BENDER_VERSION} \
    && { [ -x /root/.cargo/bin/bender ] && mv /root/.cargo/bin/bender /usr/local/bin/ \
         || mv ./bender /usr/local/bin/; } \
    && rm -rf /tmp/bender && bender --version

# Some pinned submodules use SSH URLs (e.g. pulp-platform/llvm-project's
# riscv-opcodes); fetch them anonymously over HTTPS instead.
RUN git config --system url."https://github.com/".insteadOf "git@github.com:" \
    && git config --system --add url."https://github.com/".insteadOf "ssh://git@github.com/"

########################################
#  Ara toolchains (RV64 GCC + LLVM)    #
########################################
FROM base AS ara-toolchain

ARG ARA_COMMIT
# Fetch only the pinned commits (no history) and only the GCC submodules the
# newlib toolchain needs (not qemu/glibc/dejagnu): ~4 GB instead of ~26 GB.
# Ara marks these submodules `update = none`, hence --checkout.
RUN git init -q /src/ara && cd /src/ara \
    && git remote add origin https://github.com/pulp-platform/ara.git \
    && git fetch -q --depth 1 origin ${ARA_COMMIT} && git checkout -q FETCH_HEAD \
    && git submodule update --init --checkout --depth 1 \
        toolchain/riscv-gnu-toolchain toolchain/newlib toolchain/riscv-llvm \
    && git -C toolchain/riscv-gnu-toolchain submodule update --init --depth 1 \
        riscv-binutils riscv-gcc riscv-newlib riscv-gdb

# Each step deletes its build tree (and sources no later step needs) in the
# same RUN, so the build cache does not keep tens of GB of objects.
# `-o git-submodules` skips Ara's catch-all submodule update (which would
# also pull cva6-sdk/buildroot); only the toolchain submodules are needed here.
RUN cd /src/ara && make -o git-submodules toolchain-gcc INSTALL_DIR=/opt/ara/install \
    && rm -rf toolchain/riscv-gnu-toolchain
# LLVM is built in its three parts so a late failure keeps the compiler cached;
# `-o` skips the parts a target would otherwise rebuild as prerequisites.
# compiler-rt (last step) builds from riscv-llvm's sources, so only build/ goes.
RUN cd /src/ara && make -o git-submodules toolchain-llvm-main INSTALL_DIR=/opt/ara/install \
    && rm -rf toolchain/riscv-llvm/build
RUN cd /src/ara && make -o git-submodules -o toolchain-llvm-main \
        toolchain-llvm-newlib INSTALL_DIR=/opt/ara/install \
    && rm -rf toolchain/newlib
# LLVM 20's compiler-rt adds runtimes Ara's Makefile does not disable; the ctx
# profile runtime pulls in sanitizer_common, which rejects bare-metal targets.
RUN cd /src/ara \
    && sed -i 's/-DCOMPILER_RT_BUILD_XRAY=OFF/& -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_GWP_ASAN=OFF/' Makefile \
    && grep -q CTX_PROFILE=OFF Makefile \
    && make -o git-submodules -o toolchain-llvm-main -o toolchain-llvm-newlib \
        toolchain-llvm-rt INSTALL_DIR=/opt/ara/install \
    && rm -rf toolchain/riscv-llvm

########################################
#  Spatz toolchains (RV32 GCC + LLVM)  #
########################################
FROM base AS spatz-toolchain

ARG SPATZ_COMMIT
RUN git clone https://github.com/pulp-platform/spatz.git /src/spatz \
    && cd /src/spatz && git checkout ${SPATZ_COMMIT} \
    && make download

RUN cd /src/spatz && make tc-llvm INSTALL_DIR=/opt/spatz/install
RUN cd /src/spatz && make tc-riscv-gcc INSTALL_DIR=/opt/spatz/install
# The pinned Spike uses uint64_t in fesvr/device.h without <cstdint>, which
# GCC 13 no longer pulls in transitively
RUN cd /src/spatz && CXXFLAGS="-g -O2 -include cstdint" \
        make tc-riscv-isa-sim INSTALL_DIR=/opt/spatz/install
# Build Verilator from the source `make download` already fetched at Spatz's
# pinned version. Spatz's own `verilator` target also downloads and builds
# help2man from ftp.gnu.org, which is flaky; the base image has it from apt.
RUN cd /src/spatz/sw/toolchain/verilator && unset VERILATOR_ROOT \
    && autoconf && ./configure --prefix=/opt/spatz/install/verilator \
    && make -j$(nproc) && make install

########################################
#  RV64 GCC for Cheshire/CVA6 software #
########################################
# Cheshire needs GCC >= 11.2 (and its standard libexec layout for the LTO
# plugin); Ara's pinned GCC is 9.2 with draft RVV 0.9 encodings. Build upstream
# riscv-gnu-toolchain with newlib; medany because DRAM sits at 0x8000_0000.
# Its Makefile fetches only the submodules a newlib build needs, at depth 1.
FROM base AS cheshire-gcc

ARG RISCV_GNU_TOOLCHAIN_TAG
RUN git clone -q --depth 1 -b ${RISCV_GNU_TOOLCHAIN_TAG} \
        https://github.com/riscv-collab/riscv-gnu-toolchain.git /src/rgt \
    && cd /src/rgt \
    && ./configure --prefix=/opt/riscv --with-arch=rv64gc --with-abi=lp64d --with-cmodel=medany \
    && make -j$(nproc) newlib \
    && cd / && rm -rf /src/rgt

########################################
#  Final image                         #
########################################
FROM base

COPY --from=cheshire-gcc /opt/riscv /opt/riscv

# Ara's and Spatz's Makefiles pass INSTALL_DIR on the command line, which also
# overrides riscv-gnu-toolchain's own INSTALL_DIR, so their GCCs land in the
# install root instead of install/riscv-gcc. Copy them to where Ara's apps
# (GCC_INSTALL_DIR) and Spatz's bootrom/CMake flow look for them.
COPY --from=ara-toolchain /opt/ara/install/riscv-llvm          /opt/ara/install/riscv-llvm
COPY --from=ara-toolchain /opt/ara/install/bin                 /opt/ara/install/riscv-gcc/bin
COPY --from=ara-toolchain /opt/ara/install/include             /opt/ara/install/riscv-gcc/include
COPY --from=ara-toolchain /opt/ara/install/lib                 /opt/ara/install/riscv-gcc/lib
COPY --from=ara-toolchain /opt/ara/install/libexec             /opt/ara/install/riscv-gcc/libexec
COPY --from=ara-toolchain /opt/ara/install/share               /opt/ara/install/riscv-gcc/share
COPY --from=ara-toolchain /opt/ara/install/riscv64-unknown-elf /opt/ara/install/riscv-gcc/riscv64-unknown-elf

COPY --from=spatz-toolchain /opt/spatz/install/llvm                /opt/spatz/install/llvm
COPY --from=spatz-toolchain /opt/spatz/install/riscv-isa-sim       /opt/spatz/install/riscv-isa-sim
COPY --from=spatz-toolchain /opt/spatz/install/verilator           /opt/spatz/install/verilator
COPY --from=spatz-toolchain /opt/spatz/install/bin                 /opt/spatz/install/riscv-gcc/bin
COPY --from=spatz-toolchain /opt/spatz/install/include             /opt/spatz/install/riscv-gcc/include
COPY --from=spatz-toolchain /opt/spatz/install/lib                 /opt/spatz/install/riscv-gcc/lib
COPY --from=spatz-toolchain /opt/spatz/install/libexec             /opt/spatz/install/riscv-gcc/libexec
COPY --from=spatz-toolchain /opt/spatz/install/share               /opt/spatz/install/riscv-gcc/share
COPY --from=spatz-toolchain /opt/spatz/install/riscv32-unknown-elf /opt/spatz/install/riscv-gcc/riscv32-unknown-elf

# OpenTitan's regtool (used by Cheshire's register generation) still imports
# pkg_resources, which setuptools dropped in v81
RUN pip install --no-cache-dir 'setuptools<81'

# Only the RV64 GCC (Cheshire/CVA6 software), Spike and Verilator go on PATH.
# The two clang installs collide by name, so Ara and Spatz each find their
# own through <repo>/install, which the entrypoint links to /opt/*/install.
ENV PATH=/opt/riscv/bin:/opt/spatz/install/verilator/bin:/opt/spatz/install/riscv-isa-sim/bin:${PATH} \
    ARA_INSTALL_DIR=/opt/ara/install \
    SPATZ_INSTALL_DIR=/opt/spatz/install

COPY docker/k9r5-entrypoint.sh /usr/local/bin/k9r5-entrypoint
RUN chmod +x /usr/local/bin/k9r5-entrypoint

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/k9r5-entrypoint"]
CMD ["bash"]
