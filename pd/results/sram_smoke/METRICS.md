# SRAM macro smoke test — ihp-sg13g2

*Run 2026-08-30. Retires the [RETARGET.md](../../../docs/RETARGET.md) §8 risk
"SG13G2 SRAM macros + OpenROAD GDS merge issues", whose mitigation was
assigned to P0 and not carried out — `pd/results/p0/METRICS.md` states so
explicitly. D19 ("cache data arrays in SRAM macros") rests on this working, so
it is answered **before** the P3 cache architecture is committed.*

![die render](final_all.webp)

## The question

Does an IHP SG13G2 single-port SRAM macro survive the ORFS flow end to end —
synthesis blackbox, floorplan, macro placement, PDN, CTS, route, and above all
the KLayout GDS merge?

**Yes.** `6_final.gds` (5.33 MB) is produced, with 0 router DRC violations.
Three things had to be fixed to get there, and none of them is a blocker.

## What was hardened

`sram_smoke.v` — one `RM_IHPSG13_1P_512x64_c2_bm_bist` (512 x 64 bit = 4 KiB)
wrapped in input and output registers, with an 8-bit byte-enable expanded onto
the macro's per-bit write mask. That is the shape a cache data array needs, and
the registers give the design real reg -> macro -> reg timing paths instead of
feedthroughs. 4 KiB is the per-cache-array capacity RETARGET.md §4 budgeted.

The BIST shadow port is tied off; wiring it is a production-test concern (P6)
and irrelevant to this question.

## Results

| Metric | Value |
|---|---|
| GDS | `6_final.gds`, 5.33 MB — **merge clean** |
| Router DRC | **0 violations** (`5_route_drc.rpt` empty) |
| Design area | 163,106 µm² @ 44% utilization |
| Macro area | 784.48 × 191.34 µm = **150,102 µm² = 20.68 kGE** for 4 KiB |
| Die | 1100 × 500 µm (explicit; see config.mk) |
| Setup | TNS 0.00, WNS 0.00, worst slack **+6.05 ns** at the 10 ns constraint |
| Hold | **−0.09 ns**, one path — see below |
| Power | 5.43 mW total, of which **macro 3.62 mW (66.6%)**, clock 0.96 mW (17.7%) |
| Wire length | 50,535 µm |

## Three things that had to be fixed

### 1. The macro needs an explicit blackbox stub

Synthesis stops at `hierarchy -check` with "Module
`\RM_IHPSG13_1P_512x64_c2_bm_bist' referenced ... is not part of the design".
ORFS's `SYNTH_BLACKBOXES` does **not** cover this: `scripts/synth_preamble.tcl`
runs `hierarchy -check -top` *before* applying `blackbox`, so that variable is
for modules that are defined but should be flattened out of a partition, not
for ones with no body. `sram_macro_bb.v` supplies the declaration.

### 2. `ADDITIONAL_LIBS` alone is not enough — and its documentation is wrong

ORFS documents `ADDITIONAL_LIBS` as "Hardened macro library files listed here.
The library information is immutable and **used throughout all stages**". It is
not: `scripts/read_liberty.tcl`, the only thing that feeds OpenROAD, reads
`LIB_FILES` and `<CORNER>_LIB_FILES` and nothing else. `ADDITIONAL_LIBS` is
consumed only by yosys.

The variables that work are `ADDITIONAL_TYP_LIBS` / `_SLOW_LIBS` / `_FAST_LIBS`,
which `platforms/ihp-sg13g2/config.mk` folds into the corner lists. Setting only
`ADDITIONAL_LIBS` gets through synthesis and placement and then fails twice:
`master ... has signal pins but no liberty cell` (no timing through the macro),
then a CTS-stage LEC abort that cannot find the module. Note also that the
macro's fast corner is `m55C` where the standard cells are `m40C` — the file
names are not symmetric.

### 3. A real defect in the IHP SRAM Liberty — max_capacitance off by 1e12

Every `RM_IHPSG13_*` Liberty declares

```
capacitive_load_unit (1,pf) ;
```

and then, on the `A_DOUT` output bus,

```
max_capacitance  : "6.4e-14" ;
```

Read in the unit the file itself declares, that is 6.4e-14 pF = 6.4e-26 F,
which is not a physical quantity. The value is plainly written in **farads**:
6.4e-14 F = 0.064 pF, a sensible max load for an SRAM output driver. For scale,
the sg13g2 standard cells in the same platform declare max_capacitance 0.3–0.6
pF with `default_max_capacitance : 0.3`.

OpenROAD's resizer aborts global placement on it:

```
[ERROR RSZ-0169] Max cap for driver u_sram/A_DOUT[9] of type
RM_IHPSG13_1P_512x64_c2_bm_bist is unreasonably small 0.000pF.
Min buffer or inverter input cap is 0.001pF
```

It is not reachable through SDC — OpenSTA takes the tightest of the liberty and
SDC limits, so a looser `set_max_capacitance` cannot lift a library value. The
library has to be corrected.

**All ten** macros in the platform (64x64, 256x48, 256x64, 512x64, 1024x8,
1024x16, 1024x64, 2048x64, 4096x8, 4096x16) carry the identical wrong value, so
this is systematic rather than a typo in one file. `patch_sram_lib.sh` writes
corrected copies next to the design and leaves the PDK untouched; the diff
against the platform file is exactly one line per corner. Worth reporting
upstream to both the IHP PDK and ORFS — no in-tree ORFS design instantiates
these macros, which is consistent with nobody having driven them through the
resizer before.

## The BITKIT risk itself: real, and already handled upstream

§8's specific concern — "missing GDS/OAS for LEF cells" — is real and visible
in the merge log:

```
[WARNING] LEF Cell 'RM_IHPSG13_1P_BITKIT_16x2_TAP' ignored. Matches GDS_ALLOW_EMPTY.
[WARNING] LEF Cell 'RM_IHPSG13_1P_BITKIT_16x2_CORNER' ignored. Matches GDS_ALLOW_EMPTY.
... 8 such cells
```

The platform's own `config.mk` already declares `GDS_ALLOW_EMPTY` for exactly
this set, so current ORFS absorbs it. **The risk is retired by upstream, not by
anything this project did** — but it needed confirming rather than assuming,
and it is the reason the milestone plan put a smoke test before the cache RTL.

## The hold finding — carry this into P3

The macro declares a **0.39 ns library hold time** on its data inputs, large
next to a standard cell, so almost every launch flop feeding it starts out
hold-critical. CTS finds 129 violating endpoints and inserts 80 hold buffers;
global route then reports "No hold violations found"; the post-route report
re-opens one path at **−0.09 ns** (`wstrb_q[0]` -> `u_sram/A_BM[0]`) once real
parasitics replace the estimate.

Repairing hold to a margin instead of to zero is the right answer and does not
work *in this design*: at both 0.1 and 0.2 ns, `repair_timing` inserts 105 hold
buffers and stops with `[ERROR RSZ-0060] Max buffer count reached`. The cap is
`-max_buffer_percent`, a percentage of instance count, and ORFS exposes no
variable for it (`flow/scripts/util.tcl:30`). This wrapper is ~92% macro by
area with only a few hundred standard cells, so 20% of instance count is ~105
buffers — the budget is small for the same reason the design is a good macro
test.

The −0.09 ns is therefore left visible rather than papered over. It should not
recur at P3, where a cache has orders of magnitude more standard cells and the
same 20% is a far larger absolute budget. What P3 must carry forward is the
0.39 ns macro hold requirement itself.

## What this does NOT establish

- **One macro, not four.** Multi-macro placement, channel routing between
  macros and PDN across an array are not exercised.
- **No LVS, no sign-off DRC.** The clean DRC report is the *router's*, not
  KLayout's or Calibre's. Both are P6.
- **No gate-level simulation**, and no functional check of the macro at all —
  this design is never simulated. The behavioural model in
  `flow/platforms/ihp-sg13g2/verilog/` is what P3 will bind for that.
- **No pad ring**, and the 10 ns constraint is deliberately relaxed, so none of
  the timing here is a frequency claim.
- **BIST untested** — tied off.

## Consequences for P3

1. **D19 stands.** Cache data arrays can go in SRAM macros.
2. **RETARGET.md §4's macro geometry is wrong and must be corrected.** It names
   `RM_IHPSG13_1P_1024x32`; there is no x32 macro. Available widths are 8, 16,
   48 and 64 bits, depths 64/256/512/1024/2048/4096. 4 KiB is `512x64`.
3. **SRAM area is now measured, not TBD:** 150,102 µm² (20.68 kGE) per 4 KiB.
   Four of them is 0.60 mm² — comparable to the entire logic estimate, and the
   single largest area line item in the design. Still comfortable on a 2×2 mm
   die, but it is no longer a placeholder.
4. **SRAM dominates power**: 66.6% of total in a design that is one macro plus
   a handful of registers.
5. **Budget hold margin** against the macro's 0.39 ns requirement.

## Reproducing

```bash
# once, to work around the Liberty defect (writes ./lib/, PDK untouched)
bash pd/designs/sram_smoke/patch_sram_lib.sh

# then, in WSL
source /opt/OpenROAD-flow-scripts/env.sh
cd /opt/OpenROAD-flow-scripts/flow
make DESIGN_CONFIG=/mnt/e/tinytrust/pd/designs/sram_smoke/config.mk
```

Toolchain as P0: OpenROAD `26Q3-1278-g4421880472`, yosys `0.68+` (OpenROAD
fork), KLayout `0.30.7`, built natively in WSL2 by
[`pd/setup_wsl.sh`](../../setup_wsl.sh).
