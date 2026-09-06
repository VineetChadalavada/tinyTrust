#!/usr/bin/env bash
# TinyTrust S1-C/S1-D -- build the chip and check it.
#
#   sudo bash pd/designs/tinytrust_soc/run_chip.sh [flow|drc|lvs|all]
#
# Run as root: the toolchain was installed as root by pd/setup_wsl.sh, so the
# flow directory is not writable by anyone else.
#
# ---------------------------------------------------------------------------
# KEEP A SHELL ATTACHED TO WSL WHILE THIS RUNS
#
# WSL2 shuts the whole distribution down shortly after the last attached shell
# exits, and it does not care that something is still running inside. A job
# started with setsid/nohup dies with it, /tmp is wiped, and the only clue is
# that `ps -o etime 1` shows init a few seconds old.
#
# That killed a routing run and an hour-long LVS here before it was
# understood. If you launch this and then close every shell, expect it to
# vanish. Keep one open, or run it in the foreground.
# ---------------------------------------------------------------------------
set -u

WHAT="${1:-all}"
ORFS=/opt/OpenROAD-flow-scripts/flow
PLAT=$ORFS/platforms/ihp-sg13g2
CFG=/mnt/e/tinytrust/pd/designs/tinytrust_soc/config.mk
RES=$ORFS/results/ihp-sg13g2/tinytrust_soc/base
RPT=$ORFS/reports/ihp-sg13g2/tinytrust_soc/base
LOGDIR=/root
TOP=soc_chip

cd "$ORFS" || exit 1

# Wiping the tree is its own mode, never part of a build. ORFS is
# stage-based and resumes from whatever finished, which is the only thing
# that makes progress possible in this environment: a run that gets killed
# part way still leaves its completed stages behind, and the next
# invocation carries on. An unconditional rm -rf at the top of the build
# turns that into starting over every time -- which is exactly how a good
# routed result got thrown away once.
run_clean() {
    echo "=== wiping the result tree ==="
    rm -rf results/ihp-sg13g2/tinytrust_soc \
           objects/ihp-sg13g2/tinytrust_soc \
           logs/ihp-sg13g2/tinytrust_soc \
           reports/ihp-sg13g2/tinytrust_soc
}

run_flow() {
    echo "=== flow (resumes from whatever already completed) ==="
    make DESIGN_CONFIG="$CFG" >> "$LOGDIR/tt_flow.log" 2>&1
    echo "  exit $?"
    if [ -f "$RES/6_final.gds" ]; then
        echo "  GDS: $(ls -la "$RES/6_final.gds" | awk '{print $5}') bytes"
        grep -hE 'fmax|worst slack|Design area' "$RPT/6_finish.rpt" 2>/dev/null | head -4
        echo "  router DRC violations: $(wc -l < "$RPT/5_route_drc.rpt" 2>/dev/null)"
    else
        echo "  NO GDS -- last lines:"
        tail -12 "$LOGDIR/tt_flow.log"
    fi
}

run_drc() {
    echo "=== signoff DRC (full deck) ==="
    make DESIGN_CONFIG="$CFG" drc > "$LOGDIR/tt_drc.log" 2>&1
    echo "  exit $?"
    if [ -f "$RPT/6_drc.lyrdb" ]; then
        echo "  violations: $(grep -c '<item>' "$RPT/6_drc.lyrdb")"
        grep -oP "(?<=<category>).*?(?=</category>)" "$RPT/6_drc.lyrdb" \
            | sort | uniq -c | sort -rn | head -15
    else
        echo "  no report; last lines:"
        tail -8 "$LOGDIR/tt_drc.log"
    fi
}

run_lvs() {
    echo "=== LVS ==="
    local netlist=$LOGDIR/tt_lvs_netlist.cdl

    # The design netlist alone has no cell definitions in it. LVS needs the
    # standard cells, the IO pads and the SRAM macro too, or every instance
    # reads as an unresolved black box.
    #
    # sg13g2_iocell.cdl is deliberately NOT included. It overlaps
    # sg13g2_io.cdl and redefines the same pad circuits, which the deck
    # rejects outright:
    #
    #   ERROR: Redefinition of circuit SG13G2_IOPADINOUT30MA
    #
    # io.cdl alone has every cell this chip instantiates. This is the third
    # duplicate-definition problem in this flow, after the doubled Liberty
    # that killed ABC and the doubled LEF that only warned.
    cat "$RES/6_final.cdl" \
        "$PLAT/cdl/sg13g2_stdcell.cdl" \
        "$PLAT/cdl/sg13g2_io.cdl" \
        "$PLAT/cdl/RM_IHPSG13_1P_512x64_c2_bm_bist.cdl" \
        > "$netlist" 2>/dev/null
    echo "  netlist: $(wc -l < "$netlist") lines"
    echo "  (this takes a long while -- the six SRAM macros expand to a very"
    echo "   large transistor network and every one of them is compared)"

    # Driven through the klayout binary rather than the platform's run_lvs.py.
    # That wrapper needs the klayout *Python* module on top of the installed
    # binary, and pulling in a second full KLayout build just to parse
    # arguments is not worth it: the deck is a KLayout Ruby script and takes
    # its inputs as -rd variables directly.
    klayout -b -r "$PLAT/lvs/sg13g2.lvs" \
        -rd input="$RES/6_final.gds" \
        -rd schematic="$netlist" \
        -rd topcell="$TOP" \
        -rd report="$LOGDIR/tt_lvs.lvsdb" \
        -rd run_mode=deep \
        > "$LOGDIR/tt_lvs.log" 2>&1
    echo "  exit $?"
    tail -12 "$LOGDIR/tt_lvs.log"
}

case "$WHAT" in
    clean) run_clean ;;
    flow) run_flow ;;
    drc)  run_drc ;;
    lvs)  run_lvs ;;
    all)  run_flow ; run_drc ; run_lvs ;;
    *)    echo "usage: $0 [clean|flow|drc|lvs|all]" ; exit 2 ;;
esac
