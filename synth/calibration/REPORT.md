# Calibration Synthesis Report — 2026-07-14

> **SUPERSEDED for v2 (2026-08-28).** This report answers a Tiny Tapeout tile
> question that no longer applies (see `docs/RETARGET.md` D11/D12), on SKY130,
> using ABC-free primitive pricing, against an RV32E register file from before
> D18. It is kept because it is the basis of the tile budget in
> ARCHITECTURE.md §10 and the reasoning still stands on its own terms.
> For current numbers use `calibrate_sg13g2.py` → `results_sg13g2.json`
> (real ABC liberty mapping against ihp-sg13g2), summarised in RETARGET.md §4.

**Question:** how many Tiny Tapeout tiles does TinyTrust actually need?
(Requirements hoped 4×2 = 8 tiles; architecture spec §10 predicted overflow.)

## Method

Yosys 0.67 (YoWASP), `synth -noabc` + `simplemap` to generic gate primitives,
each primitive priced with its SKY130 HD cell area from
`sky130_fd_sc_hd__tt_025C_1v80.lib` (NAND2 = 3.7536 µm² = 1 GE).
Tile capacity model: 160×100 µm × 55 % placement density = 8,800 µm²/tile.

**Bias: pessimistic.** No ABC optimization (no gate sharing, no complex
cells: AOI/OAI etc.), and enable-flops priced as DFF+mux where SKY130 has
cheaper native enable/reset flops. Expect a real OpenLane flow to land
**10–30 % lower** on combinational-heavy blocks (ROM especially).

## Measured (the four riskiest blocks, real RTL)

| Block | Area µm² | Flops | kGE | Tiles | Sanity check |
|---|---|---|---|---|---|
| ascon_p (round/cycle) | 35,726 | 325 | 9.52 | 4.06 | flops = 320 state + 5 ctrl ✓; XORs 1358 ≈ analytic 1352 ✓ |
| regfile (15×32 DFF) | 26,140 | 480 | 6.96 | 2.97 | flops = 15×32 ✓ |
| pmp (4 × NAPOT) | 9,548 | 112 | 2.54 | 1.08 | flops = 4×(5 cfg + 23 addr) ✓ |
| bootrom (512 B stub) | 8,063 | 0 | 2.15 | 0.92 | random contents = worst case |
| **Measured subtotal** | **79,476** | | **21.2** | **9.0** | |

## Projection for unbuilt blocks (same pessimistic basis)

| Block | Est. kGE | Basis |
|---|---|---|
| Core control + datapath (shared adder, iterative shifter) | 3.5–4.5 | ~150 control flops + 32-bit adder/logic/muxes |
| CSR file (mstatus/mtvec/mepc/mcause/mie/mip/mscratch) | 1.5–2.0 | ~180 flops + read mux |
| QSPI controller (quad + continuous read + direct mode) | 1.2–1.8 | shift regs + FSM |
| UART + GPIO + timer + SEC | 0.8–1.2 | ~120 flops |
| Bus/decode/top glue + fault hardening | 0.6–0.9 | |
| **Projected remainder** | **7.6–10.4** | |

## Bottom line

| Scenario | kGE | Tiles |
|---|---|---|
| Total, pessimistic mapping | 29–32 | 12.3–13.5 |
| Total, expected after real ABC/OpenLane flow (−20 %) | 23–26 | ~10–11 |

**Recommendation: plan for 4×4 = 16 tiles (~€1,120).** It fits with healthy
margin (~30 %) for routing congestion, timing fixes, and the inevitable
"one more CSR". A 4×3 = 12-tile (~€840) target is reachable only by
committing now to the trim ladder: latch-based register file (−~2 kGE),
slice-serial ASCON S-boxes (−~1.5 kGE), 384 B ROM, and 2 PMP entries —
tighter margin, more risk, saves €280.

Per requirements §8, **tile count is a user decision** — flagged for sign-off.
Next calibration checkpoint: rerun with the full core RTL at milestone M1,
ideally with native Yosys+ABC for a true liberty-mapped figure.

## Addendum (2026-07-14, later): TRUE ABC-mapped areas

Native Yosys+ABC (OSS CAD Suite) with full liberty mapping, same RTL:

| Block | ABC-mapped µm² | kGE | Tiles | vs. pessimistic |
|---|---|---|---|---|
| ascon_p | 27,291 | 7.27 | 3.10 | −24 % |
| regfile | 21,592 | 5.75 | 2.45 | −17 % |
| pmp | 5,912 | 1.57 | 0.67 | −38 % |
| bootrom | 3,729 | 0.99 | 0.42 | −54 % |
| **Subtotal** | **58,524** | **15.6** | **6.65** | **−26 %** |

With the projected remainder scaled by the same ~25 % gain (~5.7–7.8 kGE),
the full SoC lands around **9–10 tiles**. Implications:

- The signed-off **4×4 = 16 tiles stays plan of record** (~60 % headroom —
  cheap insurance against routing congestion and feature growth).
- A **down-size to 4×3 = 12 tiles (~20 % margin) is a realistic call to
  revisit at M1** when the full core RTL exists; TT tile count is only
  committed at submission.
- Note: OpenLane final placement will differ somewhat from raw Yosys/ABC
  numbers; the M1 checkpoint should use the actual TT hardening flow.

## Reproduce

```
python synth/calibration/run_calibration.py
```
(needs `pip install yowasp-yosys` and `synth/lib/sky130_fd_sc_hd__tt_025C_1v80.lib`)
