#!/usr/bin/env bash
# TinyTrust S1-D -- signoff checks on the routed chip.
#
#   sudo bash pd/designs/tinytrust_soc/run_signoff.sh [drc|lvs|both]
#
# Run as root: the toolchain was installed as root by pd/setup_wsl.sh, so the
# flow directory is not writable by anyone else.
#
# Logs go to /root rather than /tmp. /tmp is cleaned periodically on this
# machine, which already ate one signoff log mid-run.
#
# ---------------------------------------------------------------------------
# WHY LVS IS NOT JUST `make lvs`
#
# ORFS has an `lvs` target, and on this platform it does nothing:
#
#     echo "LVS not supported on this platform" > .../6_lvs.lvsdb
#
# It writes that string and exits 0, which is a false green of exactly the
# kind BUG-003 and BUG-006 were about -- a step that reports success without
# checking anything.
#
# The check itself is perfectly available: the platform ships KLayout rule
# decks at lvs/sg13g2.lvs with a runner, and all the cell netlists
# (standard cells, IO pads, SRAM macros) in cdl/. They are just not wired into
# the ORFS target. So this script builds the full netlist and calls the deck
# directly.
#
# That still leaves the project's whole path open-source, which is the point:
# the reference chip used Calibre for this step.
# ---------------------------------------------------------------------------
set -u

WHAT="${1:-both}"
ORFS=/opt/OpenROAD-flow-scripts/flow
PLAT=$ORFS/platforms/ihp-sg13g2
CFG=/mnt/e/tinytrust/pd/designs/tinytrust_soc/config.mk
RES=$ORFS/results/ihp-sg13g2/tinytrust_soc/base
RPT=$ORFS/reports/ihp-sg13g2/tinytrust_soc/base
LOGDIR=/root
TOP=soc_chip

cd "$ORFS" || exit 1

run_drc() {
    echo "=== signoff DRC ==="
    make DESIGN_CONFIG="$CFG" drc > "$LOGDIR/tt_drc.log" 2>&1
    echo "  exit $?"
    if [ -f "$RPT/6_drc.lyrdb" ]; then
        local n
        n=$(grep -c '<item>' "$RPT/6_drc.lyrdb" 2>/dev/null || echo 0)
        echo "  violations: $n"
        grep -oP "(?<=<category>).*?(?=</category>)" "$RPT/6_drc.lyrdb" \
            | sort | uniq -c | sort -rn
    else
        echo "  no report produced"
    fi
}

run_lvs() {
    echo "=== LVS ==="
    local netlist=$LOGDIR/tt_lvs_netlist.cdl

    # The design netlist alone has no cell definitions in it. LVS needs the
    # standard cells, the IO pads and the SRAM macro too, or every instance
    # reads as an unresolved black box.
    cat "$RES/6_final.cdl" \
        "$PLAT/cdl/sg13g2_stdcell.cdl" \
        "$PLAT/cdl/sg13g2_io.cdl" \
        "$PLAT/cdl/sg13g2_iocell.cdl" \
        "$PLAT/cdl/RM_IHPSG13_1P_512x64_c2_bm_bist.cdl" \
        > "$netlist" 2>/dev/null

    echo "  netlist: $(wc -l < "$netlist") lines"

    python3 "$PLAT/lvs/run_lvs.py" \
        --layout="$RES/6_final.gds" \
        --netlist="$netlist" \
        --topcell="$TOP" \
        --run_dir="$LOGDIR/tt_lvs_run" \
        > "$LOGDIR/tt_lvs.log" 2>&1
    echo "  exit $?, log $LOGDIR/tt_lvs.log"
    tail -15 "$LOGDIR/tt_lvs.log"
}

case "$WHAT" in
    drc)  run_drc ;;
    lvs)  run_lvs ;;
    both) run_drc ; run_lvs ;;
    *)    echo "usage: $0 [drc|lvs|both]" ; exit 2 ;;
esac
