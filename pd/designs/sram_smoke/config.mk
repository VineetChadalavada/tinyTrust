# TinyTrust — SRAM macro smoke test on ihp-sg13g2.
#
# Retires the RETARGET.md §8 risk that P0 deferred: "OpenROAD has reported
# GDS-merge failures with some SG13G2 SRAM BITKIT cells (missing GDS/OAS for
# LEF cells)". D19 (cache data arrays in SRAM macros) rests on this working,
# so it is checked BEFORE the P3 cache architecture is committed.
#
# Run from the ORFS flow directory:
#   source /opt/OpenROAD-flow-scripts/env.sh
#   cd /opt/OpenROAD-flow-scripts/flow
#   make DESIGN_CONFIG=/mnt/e/tinytrust/pd/designs/sram_smoke/config.mk
#   make DESIGN_CONFIG=... gui_final          # interactive
#   make DESIGN_CONFIG=... final_report

TT_PD   := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TT_ROOT := $(abspath $(TT_PD)../../..)

export DESIGN_NICKNAME = sram_smoke
export DESIGN_NAME     = sram_smoke
export PLATFORM        = ihp-sg13g2

# sram_macro_bb.v must be listed: synthesis needs the macro module to exist
# but must not descend into it. See the file header for why ORFS's
# SYNTH_BLACKBOXES does not cover this case.
export VERILOG_FILES = $(TT_PD)sram_smoke.v \
                       $(TT_PD)sram_macro_bb.v
export SDC_FILE      = $(TT_PD)constraint.sdc

# ---------------------------------------------------------------------------
# The macro. All three views must be supplied by the design: the platform's
# own config.mk adds only the IO cells to ADDITIONAL_*, not the SRAMs, and no
# in-tree ORFS design uses these macros — so there is no reference wiring to
# copy and this is the part most likely to be wrong.
#   LIB -> synthesis blackboxes it and STA times through it
#   LEF -> floorplan/place/route see its outline and pins
#   GDS -> KLayout merges its layout at the end.  <-- the risk under test
# ---------------------------------------------------------------------------
SRAM_MACRO = RM_IHPSG13_1P_512x64_c2_bm_bist

export ADDITIONAL_LEFS += $(PLATFORM_DIR)/lef/$(SRAM_MACRO).lef
export ADDITIONAL_GDS  += $(PLATFORM_DIR)/gds/$(SRAM_MACRO).gds

# Liberty needs BOTH of the following, and this is the one genuinely
# non-obvious part of macro integration on this platform:
#
#   ADDITIONAL_LIBS       is read only by yosys (scripts/synth_preamble.tcl).
#                         Its ORFS documentation says "used throughout all
#                         stages", but scripts/read_liberty.tcl — the only
#                         thing that feeds OpenROAD — reads LIB_FILES and
#                         <CORNER>_LIB_FILES and nothing else.
#   ADDITIONAL_*_LIBS     is what the platform folds into the corner lists:
#                         ihp-sg13g2/config.mk defines
#                         TYP_LIB_FILES ?= <stdcell> $(ADDITIONAL_TYP_LIBS)
#                         and LIB_FILES ?= $(TYP_LIB_FILES).
#
# Setting only ADDITIONAL_LIBS gets you through synthesis and placement and
# then fails twice: "master ... has signal pins but no liberty cell" (no
# timing through the macro) and a CTS-stage LEC abort that cannot find the
# module. Note the macro's fast corner is m55C where the standard cells are
# m40C — the file names are not symmetric with the stdcell ones.
#
# The libraries come from $(TT_PD)lib/, NOT from the platform: every
# RM_IHPSG13_* Liberty declares capacitive_load_unit (1,pf) and then sets
# max_capacitance to 6.4e-14 — the value written in farads under a picofarad
# unit, off by 1e12 — which aborts global placement with RSZ-0169. SDC cannot
# lift it (OpenSTA takes the tightest of liberty and SDC). patch_sram_lib.sh
# writes corrected copies; run it once before the flow. See that script for
# the full analysis.
SRAM_LIB_DIR = $(TT_PD)lib

export ADDITIONAL_LIBS      += $(SRAM_LIB_DIR)/$(SRAM_MACRO)_typ_1p20V_25C.lib
export ADDITIONAL_TYP_LIBS  += $(SRAM_LIB_DIR)/$(SRAM_MACRO)_typ_1p20V_25C.lib
export ADDITIONAL_SLOW_LIBS += $(SRAM_LIB_DIR)/$(SRAM_MACRO)_slow_1p08V_125C.lib
export ADDITIONAL_FAST_LIBS += $(SRAM_LIB_DIR)/$(SRAM_MACRO)_fast_1p32V_m55C.lib

ifeq ($(wildcard $(SRAM_LIB_DIR)/$(SRAM_MACRO)_typ_1p20V_25C.lib),)
  $(error Patched SRAM liberty missing. Run: bash $(TT_PD)patch_sram_lib.sh)
endif

# ---------------------------------------------------------------------------
# Floorplan. Explicit rather than utilization-driven: the macro is
# 784.48 x 191.34 um, so an auto-sized core can easily come out smaller than
# the thing it has to contain. The platform sets MACRO_PLACE_HALO = 40 40, so
# the macro needs 864 x 271 um of clearance; the core below is 980 x 380,
# leaving room for the wrapper's standard cells and the PDN straps.
# ---------------------------------------------------------------------------
export DIE_AREA  = 0 0 1100 500
export CORE_AREA = 60 60 1040 440

export PLACE_DENSITY_LB_ADDON = 0.2
export TNS_END_PERCENT        = 100
export USE_FILL               = 1

# Hold margin: left at the default 0 deliberately, see below.
#
# The macro declares a 0.39 ns library hold time on its data inputs — large
# next to a standard cell — so almost every launch flop feeding it starts out
# hold-critical. CTS finds 129 violating endpoints and inserts 80 hold
# buffers, global route then reports "No hold violations found", and the
# post-route report re-opens one path at -0.09 ns
# (wstrb_q[0] -> u_sram/A_BM[0]) once real parasitics replace the estimate.
#
# The obvious fix — repair hold to a margin instead of to zero — does not work
# *in this design*. At both 0.1 and 0.2 ns, repair_timing inserts 105 hold
# buffers and stops with "[ERROR RSZ-0060] Max buffer count reached". The cap
# is repair_timing's -max_buffer_percent, a percentage of instance count, and
# ORFS exposes no variable for it (flow/scripts/util.tcl:30). This wrapper is
# ~95% macro by area with only a few hundred standard cells, so 20% of the
# instance count is ~105 buffers in absolute terms — the budget is tiny for
# the same reason the design is a good macro test.
#
# So the residual -0.09 ns is left visible rather than papered over. It is not
# a blocker for the question this design exists to answer, and it should not
# recur at P3: a cache has orders of magnitude more standard cells, so the
# same 20% is a far larger absolute budget. What P3 must carry forward is the
# 0.39 ns macro hold requirement itself, which is real and needs margin.

# 10 ns matches the P0 constraint: this is a flow check, and a relaxed clock
# keeps a timing failure from masking the GDS-merge question being asked.
