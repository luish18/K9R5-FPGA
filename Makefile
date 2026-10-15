# K9R5: Cheshire SoC (CVA6 + Ara) on FPGA.
#
# Includes Cheshire's build system with Bender rooted at this repo, so the
# overrides in Bender.local apply. Every Cheshire target is available, e.g.
# `make chs-hw-all` or `make chs-sw-all`. The k9r5-* targets below replace
# Ara's cheshire/Makefile, which assumes Ara is checked out inside Cheshire.

K9R5_ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

BENDER      ?= bender -d $(K9R5_ROOT)
BENDER_ROOT := $(K9R5_ROOT)/.bender
CHS_ROOT    := $(K9R5_ROOT)/cheshire
ARA_ROOT    := $(K9R5_ROOT)/ara
VIVADO      ?= vivado

# Fetch submodules, including the CVA6 submodule its Bender sources need.
# Usable on a fresh clone: the includes below are skipped for this goal.
.PHONY: k9r5-deps
k9r5-deps:
	git -C $(K9R5_ROOT) submodule update --init
	git -C $(K9R5_ROOT)/cva6 submodule update --init core/cache_subsystem/hpdcache

ifneq ($(MAKECMDGOALS),k9r5-deps)

# Ara configuration (see ara/config/); only 2_lanes is tested in Cheshire
ARA_CONFIGURATION ?= 2_lanes
include $(ARA_ROOT)/config/$(ARA_CONFIGURATION).mk

# CVA6 with the V extension and Ara attached to its accelerator port
CHS_BENDER_RTL_FLAGS := -t rtl -t cva6 -t cv64a6_imafdcv_sv39 -t exclude_first_pass_decoder \
                        --define ARA --define NR_LANES=$(nr_lanes) --define VLEN=$(vlen)

all: chs-hw-all

include $(CHS_ROOT)/cheshire.mk

# Cheshire only regenerates its source scripts when its own Bender.yml changes,
# so these targets force a rebuild to pick up ARA_CONFIGURATION and overrides.
K9R5_BOARD ?= vcu128

.PHONY: k9r5-sim-scripts k9r5-xilinx k9r5-xilinx-program k9r5-xilinx-flash
K9R5_SIM_SCRIPTS := $(CHS_ROOT)/target/sim/vsim/compile.cheshire_soc.tcl \
                    $(CHS_ROOT)/target/sim/vcs/compile.cheshire_soc.sh

# chs-sim-all also downloads Cheshire's (partly non-free) flash/EEPROM models;
# see cheshire/README.md for their terms.
k9r5-sim-scripts:
	rm -f $(K9R5_SIM_SCRIPTS)
	$(MAKE) chs-sim-all

k9r5-xilinx:
	rm -f $(CHS_XILINX_DIR)/scripts/add_sources.$(K9R5_BOARD).tcl
	$(MAKE) $(CHS_XILINX_DIR)/scripts/add_sources.$(K9R5_BOARD).tcl
	$(MAKE) chs-xilinx-$(K9R5_BOARD)

k9r5-xilinx-program:
	$(MAKE) chs-xilinx-program-$(K9R5_BOARD)

k9r5-xilinx-flash:
	$(MAKE) chs-xilinx-flash-$(K9R5_BOARD)

endif # k9r5-deps
