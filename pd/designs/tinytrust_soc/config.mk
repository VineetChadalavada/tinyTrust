# TinyTrust S1-C -- harden the whole chip, with pads.
#
# This is the real one. P0 hardened the bare processor with no pad ring, no
# memory blocks and no peripherals, purely to prove the tool flow; its 144 MHz
# and 0.41 mm2 were never comparable to a finished chip and its own notes say
# so. Everything reported out of *this* design is a chip number.
#
# Die and package match the reference the project measures itself against
# (docs/TAPEOUT_PLAN.md 4a): 2500 x 2000 um, QFN-64.
#
#   source /opt/OpenROAD-flow-scripts/env.sh
#   cd /opt/OpenROAD-flow-scripts/flow
#   make DESIGN_CONFIG=/mnt/e/tinytrust/pd/designs/tinytrust_soc/config.mk
#   make DESIGN_CONFIG=... gui_final

TT_PD   := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TT_ROOT := $(abspath $(TT_PD)../../..)

export DESIGN_NICKNAME = tinytrust_soc
export DESIGN_NAME     = soc_chip
export PLATFORM        = ihp-sg13g2

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
export VERILOG_FILES = \
    $(TT_ROOT)/rtl/soc/soc_chip.v \
    $(TT_ROOT)/rtl/soc/soc_top.v \
    $(TT_ROOT)/rtl/soc/soc_bus.v \
    $(TT_ROOT)/rtl/soc/soc_ram.v \
    $(TT_ROOT)/rtl/soc/soc_mmio.v \
    $(TT_ROOT)/rtl/periph/uart.v \
    $(TT_ROOT)/rtl/periph/gpio.v \
    $(TT_ROOT)/rtl/periph/timer.v \
    $(TT_ROOT)/rtl/core/core_p5.v \
    $(TT_ROOT)/rtl/core/regfile.v \
    $(TT_ROOT)/rtl/core/pmp.v \
    $(TT_ROOT)/rtl/cache/cache.v \
    $(TT_ROOT)/rtl/mem/sram_macro_bb.v \
    $(TT_ROOT)/rom/bootrom.v

# The IO pad cells have to be visible to synthesis as real modules, not
# blackboxes, or the ring cannot be elaborated.
export VERILOG_FILES += $(PLATFORM_DIR)/verilog/sg13g2_io.v

export SDC_FILE = $(TT_PD)constraint.sdc

# ---------------------------------------------------------------------------
# IO pads and bond pads
# ---------------------------------------------------------------------------
# Setting FOOTPRINT_TCL makes the platform add the IO LEFs, GDS and the
# slow/typ/fast IO libraries itself, so none of those are declared here.
# Re-declaring the LEF and GDS only produces "library already exists"
# warnings; the slow and fast corners are harmless duplicates.
#
# Re-declaring the *typ* library is NOT harmless, and cost a synthesis run to
# find. ABC reads only the typ corner, so a second copy hands it two cells of
# every name and it dies on an assertion inside its own cell hash:
#
#   Abc_SclHashCells: Assertion `*pPlace == -1' failed.
#   ERROR: ABC failed with status 86
#
# Nothing in that message points at a duplicated library. This is a sibling
# of the ADDITIONAL_LIBS finding in pd/results/sram_smoke/METRICS.md: which
# of these variables reaches which tool is not obvious, and getting it wrong
# fails somewhere unrelated.
export ADDITIONAL_LIBS      += $(PLATFORM_DIR)/lib/sg13g2_io_typ_1p2V_3p3V_25C.lib
export ADDITIONAL_SLOW_LIBS += $(PLATFORM_DIR)/lib/sg13g2_io_slow_1p08V_3p0V_125C.lib
export ADDITIONAL_FAST_LIBS += $(PLATFORM_DIR)/lib/sg13g2_io_fast_1p32V_3p6V_m40C.lib

export FOOTPRINT_TCL = $(PLATFORM_DIR)/pad.tcl
include $(TT_PD)pins.mk

# ---------------------------------------------------------------------------
# Memory blocks -- six of them: one per cache, four for main memory.
#
# The Liberty files shipped with the platform state max_capacitance in farads
# under a picofarad unit declaration, off by 1e12, which aborts placement.
# pd/designs/sram_smoke/patch_sram_lib.sh writes corrected copies; the PDK
# itself is left untouched. See pd/results/sram_smoke/METRICS.md.
# ---------------------------------------------------------------------------
SRAM_MACRO   = RM_IHPSG13_1P_512x64_c2_bm_bist
SRAM_LIB_DIR = $(TT_ROOT)/pd/designs/sram_smoke/lib

export ADDITIONAL_LEFS      += $(PLATFORM_DIR)/lef/$(SRAM_MACRO).lef
export ADDITIONAL_GDS       += $(PLATFORM_DIR)/gds/$(SRAM_MACRO).gds
export ADDITIONAL_LIBS      += $(SRAM_LIB_DIR)/$(SRAM_MACRO)_typ_1p20V_25C.lib
export ADDITIONAL_TYP_LIBS  += $(SRAM_LIB_DIR)/$(SRAM_MACRO)_typ_1p20V_25C.lib
export ADDITIONAL_SLOW_LIBS += $(SRAM_LIB_DIR)/$(SRAM_MACRO)_slow_1p08V_125C.lib
export ADDITIONAL_FAST_LIBS += $(SRAM_LIB_DIR)/$(SRAM_MACRO)_fast_1p32V_m55C.lib

ifeq ($(wildcard $(SRAM_LIB_DIR)/$(SRAM_MACRO)_typ_1p20V_25C.lib),)
  $(error Patched SRAM liberty missing. Run: bash $(TT_ROOT)/pd/designs/sram_smoke/patch_sram_lib.sh)
endif

# ---------------------------------------------------------------------------
# Floorplan
#
# The core box is inset by the pad ring: pad length 180, bond pad 70, seal ring
# offset 70, plus routing room. The resulting core is about 1798 x 1297 um =
# 2.33 mm2, against a design measured at 1.33 mm2, so utilisation lands near
# the mid-50s -- the same neighbourhood as the reference chip's 54%.
# ---------------------------------------------------------------------------
export DIE_AREA  = 0 0 2500 2000
export CORE_AREA = 351.36 351.54 2149.6 1648.46

export MAX_ROUTING_LAYER = TopMetal2

export MACRO_PLACE_HALO       = 20 20
export PLACE_DENSITY_LB_ADDON = 0.2
export TNS_END_PERCENT        = 100
export USE_FILL               = 1

# RVFI is compiled out unless RISCV_FORMAL is defined, which it is not here.
# Leaving it in costs 21% of the processor's area and 383 of its 492 port
# bits, for a port that only the proofs consume. See RETARGET.md 4.
