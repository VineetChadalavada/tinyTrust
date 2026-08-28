# P0 — first GDS, ihp-sg13g2

*Run 2026-08-28. Milestone P0 of [docs/RETARGET.md](../../../docs/RETARGET.md) §7:
"ORFS + sg13g2 running; existing single core hardened to GDS; first die render
produced. Proves the flow before the RTL grows."*

![die render](final_all.webp)

The image is a KLayout render of `6_final.gds` — pink/cyan are the PDN straps,
the arrows around the border are IO pins. No silicon involved.

## What was hardened

The **v1 multicycle RV32I core** (`rtl/core/core.v` + `regfile.v` + `pmp.v`),
already closed by ISS lockstep co-sim and riscv-formal 44/44. Not the v2
design: no pipeline, no caches, no coherence, no second core.

The RVFI retire port is compiled out (`` `ifdef RISCV_FORMAL ``), so this is
the 109-pin netlist rather than the 492-pin one — see
[`../../designs/tinytrust_core/config.mk`](../../designs/tinytrust_core/config.mk)
for the measured justification.

## Results

| Metric | Value |
|---|---|
| Core area | 409,969 µm² (~640 × 640 µm) |
| Design area | 172,272 µm² @ 42% utilization |
| f_max | 144.11 MHz (period_min 6.94 ns) |
| WNS / TNS | 0.00 / 0.00 |
| Worst slack | +3.06 ns against the 10 ns constraint |
| Clock skew | −0.04 ns setup |
| Router DRC | 0 violations (`5_route_drc.rpt` empty) |
| Power | 19.7 mW total (42.6% sequential, 28.9% combinational, 28.5% clock) |
| Flow runtime | 481 s |
| GDS | `6_final.gds`, 15.2 MB |

Synthesis reports 144,328 µm² for `core`, above the 137,667 µm² measured with
a plain yosys script, because `SWAP_ARITH_OPERATORS` substitutes a Han-Carlson
adder — area traded for the timing result above.

## What this does NOT establish

- **No pad ring.** Core-only harden; pin count does not yet drive die size.
- **No SRAM macros.** The known OpenROAD/SG13G2 BITKIT GDS-merge risk
  (§8 of RETARGET.md) is therefore still untested.
- **No LVS, no sign-off DRC.** The clean DRC report is the *router's*, not
  KLayout's or Calibre's. Both are P6.
- **No gate-level simulation** of the resulting netlist.
- The 10 ns constraint is deliberately relaxed (see `constraint.sdc`), so
  144 MHz is "closes comfortably," not a tuned maximum.

hft-chip's 112 MHz is a **full chip with pads** and is not a like-for-like
comparison with a core-only harden.

## Reproducing

Toolchain built natively in WSL2 by [`pd/setup_wsl.sh`](../../setup_wsl.sh):
OpenROAD `26Q3-1278-g4421880472`, yosys `0.68+` (OpenROAD fork), KLayout
`0.30.7`.

```sh
source /opt/OpenROAD-flow-scripts/env.sh
cd /opt/OpenROAD-flow-scripts/flow
make DESIGN_CONFIG=/mnt/e/tinytrust/pd/designs/tinytrust_core/config.mk
```

Outputs land in `flow/results/ihp-sg13g2/tinytrust_core/base/` and
`flow/reports/ihp-sg13g2/tinytrust_core/base/`. The GDS is not tracked here —
only this summary and the render.

### Two failures worth not repeating

1. **An interrupted OpenROAD build leaves a zero-length `build/src/sta/sta`.**
   make considers the target current and never relinks it; `install` then dies
   with `RPATH_CHANGE could not write new RPATH ... file format is not
   recognized`, which aborts the *entire* install — so `openroad` never gets
   installed either, despite having compiled correctly. Delete the empty file
   and re-run. It presents as a compile failure and is not one.
2. **`SWAP_ARITH_OPERATORS` requires `OPENROAD_HIERARCHICAL = 1`** or
   `synth_odb.tcl` hard-errors at stage `1_synth`. The in-tree reference
   `flow/designs/ihp-sg13g2/riscv32i` sets both.
