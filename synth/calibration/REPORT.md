# Calibration Synthesis Report — 2026-07-14

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

## Reproduce

```
python synth/calibration/run_calibration.py
```
(needs `pip install yowasp-yosys` and `synth/lib/sky130_fd_sc_hd__tt_025C_1v80.lib`)
