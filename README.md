# K9R5-FPGA
IP and code for building K9R5 for an FPGA

K9R5 is a CVA6 + Ara vector processor on the [Cheshire](https://github.com/pulp-platform/cheshire)
SoC, with a [Spatz](https://github.com/pulp-platform/spatz) vector cluster to be attached as an
AXI accelerator.

## Layout

| Path | What | Pinned at |
|---|---|---|
| `cheshire/` | Base SoC | `mp/ara-pulp-v2` branch (the Cheshire + Ara integration) |
| `cva6/` | `pulp-platform/cva6` fork | `pulp-v2.0.0-alpha.1`, the revision Ara and Cheshire require |
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
docker run -it --rm -v "$PWD":/work -v /tools/Xilinx:/tools/Xilinx k9r5-fpga
```

## Build

Inside the container, from the repo root:

```bash
make chs-hw-all                 # generate Cheshire's hardware (registers, peripherals)
make k9r5-sim-scripts           # QuestaSim/VCS compile scripts for CVA6 + Ara
make k9r5-xilinx                # VCU128 bitstream (K9R5_BOARD=vcu128 by default)
make k9r5-xilinx-program        # program the board over the Vivado hardware server
```

`ARA_CONFIGURATION` selects a file from `ara/config/` (default `2_lanes`, the only configuration
tested in Cheshire). Every Cheshire `chs-*` target is also available.
