# TinyTrust v2 — Full-Die Retarget

*Status: ADOPTED and in execution — proposed 2026-08-16, P0–P2 complete 2026-08-30 (see §7 and §9)*
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
| **D5** | Iterative 1-bit/cycle shifter; "worst-case 31 extra cycles per shift is invisible next to fetch cost" | **32-bit barrel shifter** (in the 5-stage core only) | D5's premise was the same one D1 rested on: fetch dominates, so EX latency is free. It is not free once EX is a pipeline stage — a 31-cycle shift stalls every instruction behind it, and the whole point of the pipeline is that they are there. Measured cost is well under the 0.6–0.8 kGE D5 itself predicted for a barrel shifter, and it *removes* proof cost: the multicycle riscv-formal config needs six depth-60 overrides (`insn_sll/srl/sra/slli/srli/srai`) purely to let a 31-cycle shift finish inside the bound, and the 5-stage config needs none. The multicycle core keeps the iterative shifter. |
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

### Measured sg13g2 numbers — P1, 2026-08-28

`synth/calibration/calibrate_sg13g2.py` replaces `run_calibration.py` for v2:
real Yosys + ABC liberty mapping against `sg13g2_stdcell_typ_1p20V_25C.lib`
(1 GE = `sg13g2_nand2_1` = 7.2576 µm²), not the old ABC-free primitive
pricing. The v1 script is kept for the v1 record but its numbers are both
SKY130 and pre-D18 (it reports `regfile = 480 flops`, i.e. RV32E).

| block | area µm² | kGE | flops | v1 SKY130 estimate | delta |
|---|---|---|---|---|---|
| **core** (incl. regfile + pmp) | 137,667 | **18.97** | 1,419 | — | — |
| ├ regfile, standalone | 92,947 | 12.81 | 992 | 6.96 (RV32E) | +84% ¹ |
| └ pmp, standalone | 10,877 | 1.50 | 112 | 2.54 | −41% |
| ascon_p | 50,157 | 6.91 | 325 | 9.52 | −27% |
| bootrom | 6,793 | 0.94 | 0 | 2.15 | −56% |
| **top-level total** | **194,618** | **26.82** | | | |

¹ Not comparable directly: v1 measured RV32E (15 registers), this is RV32I
(31). The register file *flops* alone are 48,611 µm² = 6.7 kGE; the other
6.1 kGE is read multiplexing, which partly folds into surrounding logic when
synthesised inside `core` rather than standalone. Do not add the regfile and
pmp rows to `core` — they are already inside it.

The three blocks that *are* comparable all came in 27–56% **below** the v1
estimate, which is what `run_calibration.py`'s own header predicted ("expect
the real flow to come in ~10–30% lower"), plus the sky130 → sg13g2 change.

**What this changes in the table above:**

1. **The 10–14 kGE per-core budget is too low.** The *multicycle* core
   measures **18.97 kGE**; whatever the 5-stage pipeline adds, it adds on top.
   Treat "2 × core = 20–28 kGE" as a floor of ~38 kGE, not a range.
2. **The ~15 kGE security-SoC row is optimistic but not yet disproven.**
   Measured so far: ascon_p 6.91 + bootrom 0.94 = 7.85 kGE. QSPI, UART, GPIO
   and the timer are still unwritten RTL, so the rest of that row remains an
   estimate.
3. **Everything still fits comfortably.** Even at ~40 kGE of cores plus caches
   and coherence, the P0 harden shows the v1 core alone occupying 0.41 mm² of
   core area at 42% utilization — the die stays pad-limited, exactly as §4
   assumed. No architectural consequence; the numbers just stop being guesses.

RVFI is excluded from every figure here (`` `ifdef RISCV_FORMAL ``): leaving
the retire port in costs 21% of core area (174,960 → 137,667 µm²), 544 flops,
and 383 of 492 port bits. See `pd/designs/tinytrust_core/config.mk`.

Still outstanding for P1: nothing above covers the SRAM macros, whose area
comes from the PDK and is measured when the cache architecture is committed
(P3).

### Measured sg13g2 numbers — P2, 2026-08-30

The 5-stage core added by P2 measured on the same flow and the same liberty.
`core` and `core_p5` are alternatives, not siblings — a top-level total takes
one or the other, which is why `calibrate_sg13g2.py` now prints two TOTAL rows.

| block | area µm² | kGE | flops | vs. multicycle |
|---|---|---|---|---|
| **core** (multicycle, P1 baseline) | 137,363 | **18.93** | 1,419 | — |
| **core_p5** (5-stage) | 179,684 | **24.76** | 1,786 | **+5.83 kGE (+31%), +367 flops** |
| pmp, standalone | 13,337 | 1.84 | 112 | +0.34 kGE vs. P1's 1.50 |
| top-level total, with `core` | 194,314 | 26.77 | | |
| top-level total, with `core_p5` | 236,635 | **32.61** | | |

Three notes on the deltas:

1. **+31% for the pipeline is the honest price of P2**, and it is dominated by
   state, not logic: +367 flops is the four stage boundaries (IF/ID, ID/EX,
   EX/MEM, MEM/WB) carrying PC, instruction, operands, control and the RVFI
   payload. The barrel shifter and the extra adders are the smaller half.
2. **pmp grew 1.50 → 1.84 kGE** because it now has two concurrent check ports:
   the pipeline checks a data access in MEM and an instruction fetch in IF in
   the same cycle, which one checker cannot do. The CSR state is shared and
   only the combinational match/permission chain is duplicated. The multicycle
   core ties the second port off and yosys trims it — which is visible in the
   row above: `core` measures 18.93 kGE here against 18.97 at P1, a 0.04 kGE
   drift from the hierarchy change, not a regression.
3. **This does not move the floorplan.** §4's revised estimate treated
   "2 × core" as a floor of ~38 kGE; at 24.76 kGE each the two 5-stage cores
   are ~50 kGE, and the P0 harden showed the v1 core alone at 0.41 mm² core
   area with 42% utilization on a 2×2 mm die. The die is still pad-limited.

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

| # | Milestone | Exit criteria | Status |
|---|---|---|---|
| **P0** | Backend bring-up | ORFS + sg13g2 running; **existing single core hardened to GDS**; first die render produced. Proves the flow before the RTL grows. | **done** 2026-08-28 |
| **P1** | Recalibrate | `run_calibration.py` re-run against sg13g2; area budget §4 replaced with measured numbers; D18 (RV32I) signed off | **done** 2026-08-28 |
| **P2** | 5-stage pipeline | Pipelined core passes ISS lockstep + riscv-formal at the v1 bar; CPI measured vs. multicycle | **done** 2026-08-30 — §9. Lockstep 0 mismatches over 19,326 instructions × 3 memory configs; riscv-formal 44/44 (both cores); CPI 7.784 → 6.208, and 2.237 with fetch free |
| **P3** | Caches, single core | I$/D$ with SRAM macros; hit/miss verified; still 44/44 formal | next |
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

---

## 9. Milestone results: P2 — the 5-stage pipeline

*Completed 2026-08-30. Exit criteria from §7: "Pipelined core passes ISS
lockstep + riscv-formal at the v1 bar; CPI measured vs. multicycle."*

### 9.1 What was built

`rtl/core/core_p5.v` — IF/ID/EX/MEM/WB, full EX-operand forwarding, one-cycle
load-use stall. It implements the *same architecture* as `rtl/core/core.v`:
same ISA subset, same CSR set and WARL rules, same trap causes, same RVFI
conventions. That is deliberate and it is what makes the rest of this section
possible — the two cores are checked against the same ISS and the same formal
suite, so the CPI comparison is a measurement of microarchitecture alone.

Both cores are kept. The multicycle core is not dead code: it is the control
in the experiment, and it stays in the regression.

Three structural departures from the v1 datapath, each reversing a v1
decision (§2):

| | v1 (`core.v`) | P2 (`core_p5.v`) | why it had to change |
|---|---|---|---|
| Memory ports | one unified, single outstanding (D10) | **split instruction + data** | IF and MEM both want memory in the same cycle; one port serializes them. The TB now arbitrates (data over fetch, grant locked per transaction); P3 hangs the I$ and D$ directly on these two ports. |
| Shifter | iterative, 1 bit/cycle (D5) | **single-cycle barrel** | A 31-cycle EX stalls every instruction behind it, and in a pipeline there *are* instructions behind it. |
| Adders | one shared 32-bit adder (D1) | **one per stage** | IF needs PC+4 while EX computes a branch target while MEM holds an effective address. Sharing is not expressible once stages run concurrently. |

Two design choices worth stating because they are where a pipeline usually
goes wrong:

- **The commit point is MEM, not WB.** Nothing architectural happens before
  it. The register file is written in WB, but the *decision* to write is made
  in MEM, and the data bus is driven in MEM only once no older instruction can
  still fault. Exceptions are raised in IF (instruction access fault), ID
  (illegal, ECALL, EBREAK), EX (address misaligned, including the
  instruction-address-misaligned that the spec reports on the branch itself)
  and MEM (load/store access fault) — and all of them are *taken* in MEM. That
  is what makes traps precise and in program order. Branches redirect from EX
  (a two-bubble penalty); a MEM redirect always outranks an EX one.
- **SYSTEM is serializing.** CSR/MRET/ECALL/EBREAK/WFI wait in ID until EX and
  MEM are empty, and the pipeline is flushed behind them on commit. This costs
  a handful of cycles on a rare instruction and buys three things outright:
  CSR read-after-write ordering, a privilege change (MRET) that cannot be
  overtaken by instructions fetched under the old mode, and a pmpcfg/pmpaddr
  write that cannot be bypassed by an in-flight fetch checked against the old
  configuration. Design principle 1 for v2 is "verifiability first"; this is
  what that looks like in practice — a stall instead of a bypass network.

### 9.2 CPI — the exit measurement

23 programs (17 directed + 6 random), **19,326 retired instructions**, the same
program words fed to both cores in the same run, three memory configurations:

| memory configuration | mc CPI | p5 CPI | speedup |
|---|---|---|---|
| shared bus, 2–5 cycle latency (`--maxlat 3`, the default) | 7.784 | **6.208** | 1.254× |
| shared bus, minimum latency (`--maxlat 0`, 3 cycles/access) | 6.153 | **4.142** | 1.485× |
| zero-wait-state fetch, timed data (`--fastmem`) | n/a ¹ | **2.237** | 3.48× vs. mc default |

¹ `--fastmem` splits fetch timing from data timing, which the multicycle core
has no way to express — it has one port and one access in flight.

**The trend is the whole result, not the individual numbers.** As memory gets
faster the pipeline's advantage grows: 1.25× → 1.49× → and with fetch free,
CPI 2.24 against the multicycle core's 7.78. On the straight-line arithmetic
tests it reaches **CPI 1.01** — one instruction per cycle, which is what a
correctly-forwarded 5-stage pipeline is supposed to do.

This is a direct measurement of the claim D1 was reversed on. v1's D1 said a
pipeline's throughput is wasted stalling on slow fetch, and *at 2–5 cycles per
fetch it is mostly right* — 1.25× is a thin return for +31% area. The v2
counter-argument was that the cache is what justifies the pipeline. The
`--fastmem` row is that argument measured: hold everything else constant, make
only instruction fetch free, and the same RTL goes from 1.25× to 3.5×. Neither
half of the pair is worth much alone. **P2 without P3 would not have been worth
doing, and now there is a number saying so rather than an assertion.**

### 9.3 Verification

**ISS lockstep — 0 mismatches, three memory configurations.** 23 programs
(17 directed + 6 random), 19,326 retired instructions per configuration:
default 2–5 cycle shared bus, minimum-latency shared bus, and zero-wait-state
fetch with timed data. The multicycle core passes the same 23 programs on the
same stimulus, which is what licenses the CPI table above as a comparison
rather than two unrelated numbers.

**riscv-formal — 44/44 on both cores.**

| | multicycle (`tinytrust`) | 5-stage (`tinytrust_p5`) |
|---|---|---|
| checks | **44/44** | **44/44** |
| `insn_*` depth | 25, with **six depth-60 overrides** for the shifts | 25, **no overrides** |
| `reg` CHECK_CYCLE | 30 | 20 (see below) |
| `reg` solve time (abc-bmc3) | 490 s | 36 s |

Two things in that table are results, not configuration trivia:

- **The six shift overrides are gone.** `insn_sll/srl/sra/slli/srli/srai`
  needed depth 60 in the multicycle config purely so a 31-cycle iterative
  shift could finish inside the bound. The barrel shifter (D5 reversed) makes
  shifts prove at the same depth as everything else. Reversing D5 bought
  throughput *and* reduced proof cost.
- **The `reg` check is retuned to CHECK_CYCLE 20 for the pipeline, and that is
  not a weaker bar.** The quantity to hold constant across two cores is
  instructions covered, not cycles. Depth 30 leaves 20 operating cycles, which
  at the multicycle core's CPI unrolls ~3 instructions but at the pipeline's
  unrolls 10–20 — several times the state space, on a design that also has a
  forwarding network. Measured: abc-bmc3 closes the multicycle check at 30 in
  490 s and had not closed the pipelined one after 30+ minutes. At 20 the
  pipeline still unrolls ~5–10 instructions — *more* than the multicycle core
  gets at 30 — and closes in 36 s. The reasoning is recorded at the setting in
  `checks.cfg` rather than left as a bare number.

The multicycle suite was re-run from scratch for this milestone, not quoted
from P1: `pmp.v` was refactored into `pmp` + `pmp_chk` so the CSR state could
feed two concurrent check ports, and 44/44 on the unchanged core is the
evidence that the refactor is behaviour-preserving.

**Two bugs, and the second one is the point.**

- **BUG-004** (SRA/SRAI shifted logically) — caught by ISS lockstep on the
  first run of the new core. A Verilog typing rule, not a design error: inside
  a ternary, one unsigned arm makes the whole expression unsigned, and that
  propagates back into the operands, silently turning `>>>` into a logical
  shift. The `$signed` cast was present and did nothing.
- **BUG-005** (the WB forward was lost when a data access stalled MEM) —
  caught by `reg_ch0`, and **co-simulation could not have caught it.** Not
  through unlucky stimulus: through the timed memory model a fetch costs at
  least three cycles, so consecutive instructions are never closer than three
  pipeline stages apart, and the state — a consumer pinned in EX across a data
  stall while its producer sits in WB — is *structurally unreachable* in that
  environment. riscv-formal drives `ready` as a free variable and explores bus
  schedules the model never produces.

  The fix to the RTL was small (split retire from forwardability: `w_valid`
  stays a one-cycle pulse, a new `w_fwd_live` holds until the next instruction
  reaches WB). The fix to the *environment* mattered more. A directed
  regression test alone would have been vacuous — it passes on the broken RTL
  — so `tb_core.v` gained `+fastmem`, which makes the instruction port
  zero-wait-state while leaving the data port timed: fast fetch so instructions
  pack back to back, slow data so MEM still stalls. Verified in both
  directions: on the pre-fix RTL the new `fwd_stall` test passes with the timed
  model and fails at retire 9 with `+fastmem`. `dv/core_iss/run.ps1` now runs
  three legs so the state space stays reachable.

  The lesson is about coverage of the *environment*, not the design. A
  testbench whose timing is always the same shape hides state space, and no
  amount of extra random instructions finds what the timing forbids. It is
  also the timing an I$ produces — so left alone, this bug would have surfaced
  at P3 as a regression in already-signed-off RTL.

### 9.4 What P2 changes for P3

- **The two ports are already there.** `core_p5` exposes independent
  instruction and data interfaces; the TB arbitrates them onto one memory
  today. P3 replaces the arbiter with an I$ and a D$, one per port, and the
  core does not change.
- **The CPI target is set.** `--fastmem` is a cache-hit emulator: it says the
  pipeline reaches CPI 2.24 overall and 1.01 on straight-line code when fetch
  is free. That is the number an I$ has to approach to justify itself, and it
  was measured before a line of cache RTL was written.
- **`+fastmem` is not throwaway.** It stays as the third regression leg, and
  it is the closest thing available to P3's timing until the caches exist.
- **Serialized SYSTEM is a known cost to revisit.** It is cheap now because
  CSR instructions are rare. If the coherence work at P4/P5 makes CSR or fence
  traffic common, the serialization becomes the thing to attack — and the
  bypass network it was traded against is written up here so the trade is
  legible rather than rediscovered.
