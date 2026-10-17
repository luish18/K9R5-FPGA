# K9R5-FPGA
IP and code for building K9R5 for an FPGA

K9R5 is a CVA6 + Ara vector processor on the [Cheshire](https://github.com/pulp-platform/cheshire)
SoC, with a [Spatz](https://github.com/pulp-platform/spatz) vector cluster to be attached as an
AXI accelerator.

## Layout

| Path | What | Pinned at |
|---|---|---|
| `cheshire/` | Base SoC | `mp/ara-pulp-v2` branch (the Cheshire + Ara integration) |
| `cva6/` | `pulp-platform/cva6` fork | `pulp-v2.0.0` (Ara and Cheshire's Ara branch pin `alpha.1`, whose `mstatus.FS` never turns Dirty on scalar FP writes; fixed in upstream commit `ecb138010`) |
| `ara/` | Ara vector unit | Ara `main` (bug fixes ahead of Cheshire's pin) |
| `spatz/` | Spatz cluster | not yet wired into the SoC |

The repo root is a Bender package depending on Cheshire. `Bender.local` overrides Cheshire's `ara`
and `cva6` pins with the local submodules. Cheshire's own dependency tree only resolves through its
checked-in lock, so `Bender.lock` is generated from it; rerun `util/gen-bender-lock.py` after
bumping `cheshire/` (do not use `bender update`).

## Setup

```bash
make k9r5-deps
docker build -t k9r5-fpga .
```

Run the container with the repo mounted **at the same path as on the host**: generated scripts
contain absolute paths, and simulation runs on the host (see below).

```bash
docker run -it --rm -v "$PWD":"$PWD" -w "$PWD" -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v /tools/Xilinx:/tools/Xilinx k9r5-fpga
```

## Build (in the container)

```bash
make chs-hw-all                 # generate Cheshire's hardware (registers, peripherals)
make k9r5-sim-scripts           # QuestaSim/VCS compile scripts for CVA6 + Ara
make chs-sw-all                 # Cheshire's own tests, e.g. cheshire/sw/tests/helloworld.spm.elf
make k9r5-sw-ara                # Ara's vector tests for Cheshire, into sw/build/ara/
make k9r5-xilinx                # VCU128 bitstream (K9R5_BOARD=vcu128 by default)
make k9r5-xilinx-program        # program the board over the Vivado hardware server
```

`ARA_CONFIGURATION` selects a file from `ara/config/` (default `2_lanes`, the only configuration
tested in Cheshire). Every Cheshire `chs-*` target is also available.

## Simulate (on the host, QuestaSim)

QuestaSim runs on the host, not in the container. These targets need neither Bender nor the
RISC-V toolchains:

```bash
make k9r5-sim-compile                                        # compile the SoC (CVA6 + Ara)
make k9r5-sim BINARY=sw/build/ara/vector_helloworld.spm.elf  # run one program
```

`k9r5-sim` uses testbench config 3 (Cheshire with Ara), preloads `BINARY` over the serial link
(`PRELMODE=1`, much faster than JTAG for large binaries; `0` = JTAG, `2` = UART) and fails unless
the testbench reports `SUCCESS`. Each run stops after `K9R5_SIM_TIMEOUT` of simulated time
(default `100ms`, `-all` for no limit) and prints the CPU's `pc`/`mcause`/`mepc`/`mtval`, so a
program that traps fails instead of hanging. The optimized testbench is cached per `SELCFG`
(`make k9r5-sim-opt`, rerun automatically after `k9r5-sim-compile`). The log is
`cheshire/target/sim/vsim/k9r5-sim.<binary>.log`.

Notes for Questa Starter Edition (and other hosts):

- The testbench's VIP is patched (`target/sim/patches/`) so its serial-link AXI slave uses
  `axi_sim_mem` instead of `axi_rand_slave`: `std::randomize()` needs a verification license
  that the Starter Edition lacks.
- The DPI ELF loader is built with the system `g++`, and `vsim` runs with that compiler's
  `libstdc++` preloaded, because Questa's bundled `libstdc++` is older. Override the compiler
  with `K9R5_VSIM_CXX`.
- Starter Edition is slow: about 4 minutes per simulated millisecond. UART output at 115200 baud
  costs ~87 µs of simulated time per character, so `helloworld` takes about 9 minutes.
