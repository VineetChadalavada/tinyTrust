#!/usr/bin/env bash
# TinyTrust — work around an IHP SG13G2 SRAM Liberty defect.
#
# THE DEFECT
# ----------
# Every RM_IHPSG13_* SRAM Liberty in the ORFS ihp-sg13g2 platform declares
#
#     capacitive_load_unit (1,pf) ;
#
# and then, on the A_DOUT output bus,
#
#     max_capacitance  : "6.4e-14" ;
#
# Read in the unit the file itself declares, that is 6.4e-14 pF = 6.4e-26 F,
# which is not a physical quantity. The value is plainly written in FARADS:
# 6.4e-14 F = 0.064 pF, which is a sensible max load for an SRAM output
# driver. For scale, the sg13g2 standard cells in the same platform declare
# max_capacitance 0.3-0.6 pF with default_max_capacitance 0.3.
#
# So the number is off by 1e12, and it is off by the same 1e12 in all ten
# macros (64x64, 256x48, 256x64, 512x64, 1024x8, 1024x16, 1024x64, 2048x64,
# 4096x8, 4096x16) — systematic, not a typo in one file.
#
# WHY IT MATTERS
# --------------
# OpenROAD's resizer refuses to drive a net whose driver has a max
# capacitance below the smallest available buffer input cap, and aborts
# global placement:
#
#   [ERROR RSZ-0169] Max cap for driver u_sram/A_DOUT[9] of type
#   RM_IHPSG13_1P_512x64_c2_bm_bist is unreasonably small 0.000pF.
#   Min buffer or inverter input cap is 0.001pF
#
# It is not reachable through SDC: OpenSTA takes the tightest of the liberty
# and SDC limits, so a looser `set_max_capacitance` cannot lift a library
# value. The library has to be corrected.
#
# WHAT THIS SCRIPT DOES
# ---------------------
# Copies the three corner Liberty files for one macro out of the platform and
# rewrites that single attribute to the value the PDK evidently meant. The
# PDK itself is left untouched — the patched copies land in ./lib/ next to
# this script and config.mk points at them. Nothing else in the file is
# changed, so a diff against the platform copy is one line per file.
#
# Usage (from WSL, where the PDK lives):
#   bash pd/designs/sram_smoke/patch_sram_lib.sh
#
# Upstream: worth reporting to the IHP PDK and to ORFS. No in-tree ORFS design
# instantiates these macros, which is consistent with nobody having driven
# them through the resizer before.
set -euo pipefail

ORFS=${ORFS:-/opt/OpenROAD-flow-scripts}
PLATFORM_LIB="$ORFS/flow/platforms/ihp-sg13g2/lib"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/lib"

MACRO=${MACRO:-RM_IHPSG13_1P_512x64_c2_bm_bist}
CORNERS=(typ_1p20V_25C slow_1p08V_125C fast_1p32V_m55C)

# 6.4e-14 F expressed in the picofarad unit the file declares.
GOOD_MAX_CAP="0.064"

if [ ! -d "$PLATFORM_LIB" ]; then
    echo "ERROR: platform lib dir not found: $PLATFORM_LIB" >&2
    echo "       set ORFS=<path to OpenROAD-flow-scripts> if it lives elsewhere" >&2
    exit 1
fi

mkdir -p "$OUT"

for corner in "${CORNERS[@]}"; do
    src="$PLATFORM_LIB/${MACRO}_${corner}.lib"
    dst="$OUT/${MACRO}_${corner}.lib"
    if [ ! -f "$src" ]; then
        echo "ERROR: missing source liberty: $src" >&2
        exit 1
    fi

    # Only rewrite the bogus value. If the PDK is ever fixed upstream, this
    # matches nothing and the copy is byte-identical — which is the signal to
    # delete this script rather than silently keep patching.
    sed -E 's/(max_capacitance[[:space:]]*:[[:space:]]*)"6\.4e-14"/\1'"$GOOD_MAX_CAP"'/' \
        "$src" > "$dst"

    if cmp -s "$src" "$dst"; then
        echo "NOTE  $corner: nothing patched — upstream may be fixed; re-check this script"
    else
        n=$(diff <(grep -c . "$src") <(grep -c . "$dst") >/dev/null 2>&1; \
            diff "$src" "$dst" | grep -c '^<' || true)
        echo "OK    $corner: patched $n attribute(s) -> $dst"
    fi
done

echo
echo "Patched libraries written to $OUT"
echo "config.mk points ADDITIONAL_*_LIBS at them."
