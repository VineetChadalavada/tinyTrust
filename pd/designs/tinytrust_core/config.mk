# TinyTrust P0 — harden the EXISTING v1 multicycle core on ihp-sg13g2.
#
# Purpose is to prove the backend flow end to end and produce the first GDS +
# KLayout render BEFORE the RTL grows (see docs/RETARGET.md, milestone P0).
# This is NOT the v2 design and NOT a timing target — it is a flow smoke test
# against RTL that is already verified (ISS lockstep + riscv-formal 44/44).
#
# Run from the ORFS flow directory:
#   source /opt/OpenROAD-flow-scripts/env.sh
#   cd /opt/OpenROAD-flow-scripts/flow
#   make DESIGN_CONFIG=/mnt/e/tinytrust/pd/designs/tinytrust_core/config.mk
#   make DESIGN_CONFIG=... gui_final          # interactive
#   make DESIGN_CONFIG=... final_report

# Resolve the repo root from this file's own location (no hardcoded abs paths).
TT_PD   := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TT_ROOT := $(abspath $(TT_PD)../../..)

export DESIGN_NICKNAME = tinytrust_core
export DESIGN_NAME     = core
export PLATFORM        = ihp-sg13g2

export VERILOG_FILES = $(TT_ROOT)/rtl/core/core.v \
                       $(TT_ROOT)/rtl/core/regfile.v \
                       $(TT_ROOT)/rtl/core/pmp.v

export SDC_FILE = $(TT_PD)constraint.sdc

# Mirrors flow/designs/ihp-sg13g2/riscv32i, which is the closest reference
# point in-tree (a RISC-V core already hardened on this exact platform).
export USE_FILL               = 1
export CORE_UTILIZATION       = 35
export PLACE_DENSITY_LB_ADDON = 0.2
export TNS_END_PERCENT        = 100
export CTS_BUF_DISTANCE       = 60
export SWAP_ARITH_OPERATORS   = 1
# Required by SWAP_ARITH_OPERATORS — synth_odb.tcl hard-errors without it.
# The reference riscv32i config sets both; omitting this one killed the first
# P0 flow attempt at stage 1_synth (2026-08-28).
export OPENROAD_HIERARCHICAL   = 1

# RVFI: core.v's retire port is wrapped in `ifdef RISCV_FORMAL (2026-08-28),
# so this flow — which does not define it — synthesises the lean core. The
# guard was moved ahead of P0 rather than left to P2 because the cost was
# measured, not guessed (yosys + sg13g2_stdcell_typ_1p20V_25C):
#
#              area           flops   ports  port bits
#   RVFI in    174,960 um^2   1,963      34        492
#   RVFI out   137,667 um^2   1,419      13        109
#              -21.3%          -544     -21       -383
#
# 383 of 492 pin bits is the part that mattered: hardening with the port left
# in produces a die sized by verification-only pins, so neither the area
# numbers nor the render would describe anything that could tape out.
