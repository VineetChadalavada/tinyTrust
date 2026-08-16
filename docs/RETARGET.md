# TinyTrust v2 — Full-Die Retarget

*Status: PROPOSAL for review — 2026-08-16*
*Supersedes vehicle/microarchitecture decisions in [ARCHITECTURE.md](ARCHITECTURE.md) §2, §10*
*Parent: [REQUIREMENTS.md](REQUIREMENTS.md)*

---

## 1. What changed and why

TinyTrust v1 was scoped as a **single-core, area-first, 16-tile Tiny Tapeout**
security SoC. v2 retargets it to a **full custom die with a real MPW
submission**, and adds a **5-stage pipeline** and a **2-core cache-coherent
memory system (MESI and MOESI)**.

The driver is a deliberate change of goal: v1 optimized for *fitting*; v2
optimizes for *demonstrating microarchitecture depth on real silicon*. The
reference point is [noah-gigler/hft-chip](https://github.com/noah-gigler/hft-chip)
(ETH Zürich VLSI II) — IHP SG13G2, 2500×2000 µm, QFN-64, DRC + LVS clean,
Yosys → OpenROAD → KLayout → Calibre.

**This is not an incremental change.** It reverses the top design principle
and three decision-log entries. The reversals are recorded here rather than
edited silently into ARCHITECTURE.md, so the v1 reasoning stays legible —
"here is what I optimized for, here is what changed, here is what that cost"
is a better story than a spec that pretends it was always this way.

### Design principles, re-ordered

| | v1 | v2 |
|---|---|---|
| 1 | **Area first** — every block judged in GE | **Verifiability first** — coherence is where designs die |
| 2 | Verifiability second | **Microarchitecture depth second** — pipeline, caches, coherence are the point |
| 3 | Performance a distant third | Area third — a 2×2 mm die is pad-limited, not core-limited |

---

## 2. Decisions reversed from ARCHITECTURE.md §2

| Old | Was | Now | Why it flipped |
|---|---|---|---|
| **D1** | Multicycle core; a pipeline's throughput is wasted stalling on ~10–20 cycle XIP fetch | **5-stage pipeline** | **The cache is what justifies the pipeline.** D1's rationale was entirely a consequence of having no instruction cache — with an I$, a hit is 1 cycle and the pipeline finally has something to pipeline. These are not two independent features; adding the pipeline without the cache would have been the mistake D1 correctly identified. |
| **D3** | DFF register file | unchanged, but pressure removed | With SRAM macros and a full die, the latch-file fallback is dead. Keep DFFs. |
| **D10** | Single outstanding bus transaction | **Multi-master shared bus with snoop channel** | Coherence requires ≥2 masters and a broadcast snoop path by definition. This is the single largest verification-surface increase in v2. |
| **§10** | Area budget in Tiny Tapeout tiles (16 tiles = 0.256 mm²) | Area budget in mm² on a ~2×2 mm die | Obsolete. The tile-capacity model and trim ladder no longer apply. |

**D2 (RV32E) is REVERSED — the core is now RV32I** (signed off 2026-08-16).
D2's entire justification was that a 32×32 DFF register file "alone [is]
larger than the rest of the core." On a 4 mm² die that argument is gone.
See D18 for what it bought.

Implemented and verified the same day: `regfile.v` widened to 32 entries,
the `rve_viol` illegal-instruction path deleted from `core.v`, the ISS
widened to 32 registers, the `rv32e_ok` assumption removed from the formal
wrapper, directed test `CPU-RVE-01` (x16+ traps) replaced by `CPU-RVI-01`
(x16+ are ordinary registers, exercised in every field position), and the
random generator widened to all 32. Lockstep co-sim re-run green: 16/16
directed + 12/12 random, 45,612 instructions, 0 mismatches.

---

## 3. New decision log

| # | Decision | Alternatives rejected | Rationale |
|---|---|---|---|
| D11 | **Full custom die (~2×2 mm), not Tiny Tapeout** | 16-tile TT; larger TT tile counts | Own calibration numbers: 1 tile = 2,344 GE, 16 tiles = 37.5 kGE. A single 256 B flop-based cache = 10.9 kGE = 4.7 tiles. Two cores' caches alone exceed the entire budget. Coherence is not expressible in TT. |
| D12 | **IHP SG13G2 130 nm** | SKY130 via ChipFoundry chipIgnite | (a) €2,400–3,500 open-source MPW vs. $14,950; (b) **ships single-port SRAM macros** (`RM_IHPSG13_1P_1024x8/32/64`, `4096x8`) — SKY130's open SRAM path is DIY; (c) hft-chip proved the exact flow, and the Croc SoC pad ring is adaptable. Cost: re-run area calibration against sg13g2 std cells. |
| D13 | **5-stage pipeline** (IF/ID/EX/MEM/WB), full forwarding, 1-cycle load-use stall | 3-stage; 2-stage; keep multicycle | Classic 5-stage is the most-verified structure in existence, has a canonical reference implementation, and is what the ISS/riscv-formal setup already targets via RVFI. Depth beyond 5 buys nothing at 130 nm where the critical path is SRAM access. |
| D14 | **2 cores**, symmetric | 4 cores; 1 core + accelerator | 2 cores exercise every MESI/MOESI transition including the O-state transfer that distinguishes them. 4 cores multiply verification cost and pad/area without adding a single new protocol state. Bus arbiter stays parameterizable to N. |
| D15 | **Snooping coherence on a shared bus** | Directory-based; MSI only | At 2 cores a directory is pure overhead — snooping is the correct engineering answer and the one that makes MOESI's Owned state meaningful (cache-to-cache dirty transfer without writeback). |
| D16 | **One parameterizable coherence controller, `COHERENCE = MESI \| MOESI`** | Pick one; two separate RTL blocks | The Owned state is a superset addition: MOESI = MESI + O + dirty-sharing transitions. One controller with a compile-time parameter yields a *measurement* — writeback traffic and shared-line latency, MESI vs. MOESI, on identical RTL and identical stimulus. That comparison is the deliverable, not the protocol. |
| D17 | **Write-back, write-allocate caches** | Write-through | MOESI's Owned state is meaningless under write-through — the entire point is deferring the writeback while serving dirty data cache-to-cache. |
| D18 | **RV32I** — signed off and implemented 2026-08-16 | Stay RV32E | Reverses D2, whose rationale ("a 32×32 DFF file is larger than the rest of the core") was an artefact of the tile budget. RV32I **deletes the `rv32e_ok` fetch assumption from the formal wrapper** — the one environment restriction in the 44/44 suite that shrank the verified space — so the checks now run over the full register file with no ISA-shaping assumption. Also removes ilp32e toolchain friction. Cost: +512 flops/core ≈ +2.7 kGE. |
| D19 | **Cache data arrays in SRAM macros; tag arrays in flops** | All-flop caches; all-SRAM | Data arrays are large and single-ported — a perfect macro fit. Tags need single-cycle compare *and* a snoop port; duplicating a small flop tag array per cache lets snoops proceed without stalling the core pipeline. |
| D20 | **Keep the v1 security SoC** (ASCON, PMP, secure boot, SEC/ALERT) | Drop it to reduce scope | It is verified, it is ~15 kGE, and it fits trivially now. A coherent multicore *with* a hardware root of trust is a differentiated project; a coherent multicore alone is a textbook exercise. PMP becomes per-core. |

---

## 4. Area budget v1.0 (full die) — ESTIMATE, needs recalibration

**Basis: SKY130 GE numbers extrapolated (NAND2 = 3.7536 µm² = 1 GE).
These are placeholders until `run_calibration.py` is re-run against the
sg13g2 liberty file.** Treat every number below as ±30%.

| Block | Est. kGE | Notes |
|---|---|---|
| 2 × 5-stage core (RV32I + CSR + traps + PMP) | 20–28 | ~10–14 kGE each |
| 4 × cache tag array + control (dup. tags for snoop) | 12–20 | 32 lines × 64 B assumed; line size is the main lever |
| 2 × coherence controller (MESI/MOESI FSM + MSHR) | 6–10 | |
| Shared bus, arbiter, snoop broadcast | 3–5 | |
| v1 security SoC (ASCON 7.3 + PMP + ROM + QSPI + UART/GPIO/timer) | ~15 | measured or projected in v1 |
| **Total logic** | **56–78 kGE** | ≈ **0.21–0.29 mm²** of standard cells |
| SRAM macros: 4 × `RM_IHPSG13_1P_1024x32` (4 KiB each) | — | macro area from PDK; **TBD** |

At 55% utilization the core lands around **0.4–0.55 mm² plus macros** —
comfortably inside a 2×2 mm die. **The die will be pad-limited, not
core-limited**, exactly as hft-chip's was (54% utilization at 2500×2000 µm).
Pin count, not gates, drives die size from here.

Minimum MPW area is 0.8 mm², so there is no "too small" risk either.

---

## 5. Verification impact

The existing verification stack survives and mostly still applies:

| Leg | v1 status | v2 |
|---|---|---|
| ISS lockstep co-sim (RVFI) | green | **Per core.** ISS already widened to RV32I (D18). Pipeline changes RVFI timing, not content. |
| riscv-formal | 44/44 | **Per core.** RV32I would *delete* the `rv32e_ok` wrapper assumption. Pipeline needs depth re-tuning. |
| ASCON KAT | 66/66 | unchanged |

**Two genuinely new verification problems:**

1. **Coherence protocol correctness.** The invariants are classic and
   formally checkable: never two caches in M for one line; a line in O/M is
   the unique dirty copy; every request eventually completes (no deadlock,
   no livelock on the arbiter). This is a *strong* formal target — small
   state space, high-value properties — and should be proven, not simulated.

2. **Memory consistency under concurrency.** Random multi-core litmus tests
   against an ISS pair with a reference memory model. This is where directed
   testing stops scaling.

**Note on UVM (closes ASC-UVM-01).** In v1, the proposed UVM environment for
`ascon_p` was honestly redundant — the block was already closed by 66/66 KATs
through a 40-line Icarus testbench, and the env existed for résumé value.
A **coherent multi-master bus is the canonical UVM application**: multiple
active agents, a bus monitor, a protocol scoreboard, and a coverage cube over
(protocol state × request type × requester × responder). Here UVM is the
right tool for engineering reasons rather than CV reasons. `ASC-UVM-01`
should be retired and replaced with `COH-UVM-*` testpoints in VPLAN §4.

---

## 6. The actual gap: backend

Verification is ahead of hft-chip. **Backend is at zero** — `synth/` contains
area estimates, nothing more. No floorplan, no P&R, no GDS, no DRC, no LVS.

Target flow (mirrors hft-chip):

```
SystemVerilog → Yosys → OpenROAD (floorplan · PDN · place · CTS · route)
              → KLayout (GDS + DRC) → LVS → die render
```

Every metric quoted in the hft-chip README — max frequency, utilization,
power, DRC/LVS clean, **and the die render** — is an output of this flow.
The render is a KLayout screenshot of the finished GDS; it requires no
silicon. It becomes available the day P&R first closes.

**Known risk:** OpenROAD has reported GDS-merge failures with some SG13G2
SRAM BITKIT cells (missing GDS/OAS for LEF cells). Hit this early with a
macro-only smoke test before committing the cache architecture.

---

## 7. Milestones (v2)

| # | Milestone | Exit criteria |
|---|---|---|
| **P0** | Backend bring-up | ORFS + sg13g2 running; **existing single core hardened to GDS**; first die render produced. Proves the flow before the RTL grows. |
| **P1** | Recalibrate | `run_calibration.py` re-run against sg13g2; area budget §4 replaced with measured numbers; D18 (RV32I) signed off |
| **P2** | 5-stage pipeline | Pipelined core passes ISS lockstep + riscv-formal at the v1 bar; CPI measured vs. multicycle |
| **P3** | Caches, single core | I$/D$ with SRAM macros; hit/miss verified; still 44/44 formal |
| **P4** | Coherence | 2 cores, shared bus, MESI; protocol invariants formally proven; UVM coherence env; litmus tests |
| **P5** | MOESI + measurement | `COHERENCE=MOESI` closes the same suite; writeback-traffic and latency comparison written up |
| **P6** | Physical signoff | Pad ring, full-chip P&R, timing closure, DRC + LVS clean, GL sim |
| **P7** | Submission | IHP Open Silicon MPW agreement signed, slot booked, GDS submitted |

**P0 is deliberately first.** The flow is the largest unknown and the thing
that produces the render; growing the RTL before proving the backend risks
discovering at P6 that the design cannot be hardened.

---

## 8. Open risks

| Risk | Mitigation |
|---|---|
| IHP MPW slot availability and true open-source pricing | Contact IHP directly with the Open Source Request before P2; pricing quoted (€2,400–3,500) is from public schedules and unconfirmed for this design size |
| SG13G2 SRAM macros + OpenROAD GDS merge issues | Macro-only smoke test at P0, before cache architecture is committed |
| Docker allocated only 8 GB RAM | Full-chip P&R may need more; raise WSL2 memory limit before P6 |
| Coherence verification scope underestimated | It always is. P4/P5 have the loosest estimates in this plan. |
| Solo project, tape-out has a hard deadline | Unlike v1, a missed shuttle slot costs months. Book the slot *after* P5, not before. |
| Sunk SKY130 calibration work | ~1 afternoon to redo; the methodology transfers unchanged |
