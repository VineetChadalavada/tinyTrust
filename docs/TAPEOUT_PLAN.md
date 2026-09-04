# TinyTrust — Incremental Silicon Plan

*Status: PROPOSED 2026-09-03.*
*Re-orders the milestones in [RETARGET.md](RETARGET.md) §7. Does not change
the architecture, the decision log, or the deliverable.*

---

## 1. What changes, and why

RETARGET.md §7 puts physical signoff at **P6, after coherence**. That means
every chip-level unknown — pad ring, full-chip P&R, chip-level timing closure,
LVS, signoff DRC, gate-level simulation — arrives at the very end, on the most
complex version of the design, all at once.

That is the mistake P0 exists to prevent. P0's own justification:

> **P0 is deliberately first.** The flow is the largest unknown and the thing
> that produces the render; growing the RTL before proving the backend risks
> discovering at P6 that the design cannot be hardened.

That argument does not stop at the flow. It applies to the chip. P0 proved
*a core* hardens; it did not prove a *chip* does — no pads, no LVS, no signoff
DRC, no gate-level sim. Those remain the largest unknowns in the project, and
the current plan meets them last, on a dual-core coherent design.

**The new plan is therefore: smallest complete chip first, then iterate.**
Each silicon version is a whole chip. Each one retires risk for the next.

### What does *not* change

The deliverable. D16 fixed it: not a coherence protocol but a *comparison* of
two, `COHERENCE = MESI | MOESI` on identical RTL, measured for writeback
traffic and shared-line latency.

**That comparison is a measurement over RTL. It does not need silicon.** So
taping out a single-core chip first costs nothing against the headline result —
the coherence work continues in simulation in parallel, and lands on silicon at
S2 having already produced its number. This is the fact that makes the
re-ordering free rather than a retreat.

---

## 2. Silicon versions

| | Chip | Retires |
|---|---|---|
| **S1** | Single-core RV32I SoC — core, caches, on-chip memory, UART, GPIO, timer, ASCON | The entire chip-level flow: pads, full-chip P&R, LVS, signoff DRC, GL sim. Plus multi-macro placement, which the SRAM smoke test explicitly did not establish. |
| **S2** | Dual-core, MESI/MOESI coherent | The coherence design (current P4/P5), on a flow already proven by S1 |
| **S3** | Security completion — QSPI XIP, ASCON secure boot from external flash | The v1 threat model, which needs off-chip flash and its pad timing |

S2 before S3 because coherence is the project's stated goal (RETARGET §1:
"microarchitecture depth demonstrated on real silicon"). If the security story
matters more, the two swap without affecting S1.

---

## 3. S1 scope

The rule for S1 is **smallest thing that is genuinely a chip** — it must boot,
run a program, and tell you it did.

### In

| block | state today |
|---|---|
| `core_p5` — 5-stage RV32I + PMP | **done**, 44/44 formal, 0 lockstep mismatches |
| 4 KiB I$ + 4 KiB D$ | **done**, block + system verified; I$ transparency proven |
| On-chip main memory, 16–32 KiB SRAM macros | macro flow **proven** (smoke test); instancing is new |
| Boot ROM | `bootrom_stub.v` is a calibration stub — needs a real one |
| UART (TX + RX) | **not written** |
| GPIO | **not written** |
| Timer (`MTIME`/`MTIMECMP`) | **not written**; core already has `irq_timer` |
| ASCON-P as MMIO block | **done**, 66/66 KATs; needs a bus wrapper |
| Simple single-master bus | **not written** (`rtl/soc/` is empty) |
| Pad ring, QFN | **not started** |

### Out, deliberately

Second core, coherence, QSPI/XIP, external flash, secure boot, PSRAM. All of
it is S2 or S3, and none of it is needed to prove a chip works.

### Why the caches stay in

They are the one piece of "extra" in S1, and they earn it. The SRAM smoke test
proved *one* macro hardens and said so explicitly about its limits:

> **One macro, not four.** Multi-macro placement, channel routing between
> macros and PDN across an array are not exercised.

S1 with I$, D$ and main memory instantiates several macros, which is exactly
the gap. Doing that on a single-core chip is how you find out about macro
placement before a dual-core chip depends on it. The caches are also already
verified, so they cost integration time, not design time.

### Boot and memory

S1 boots and runs from **on-chip SRAM**, not QSPI XIP. The memory map in
ARCHITECTURE.md §4 assumes external flash for code and PSRAM for data; that
needs the QSPI controller (unwritten) plus external parts and pad timing, and
it puts a bring-up dependency outside the die. For first silicon that is the
wrong trade. The map's regions stay as specified so firmware carries forward —
S1 simply populates the on-chip ones.

### Fit

Core with both caches measured 99.98 kGE ≈ 0.73 mm² (RETARGET §10.4). Add
16 KiB of main memory (4 × 4 KiB macros, 150,102 µm² each) ≈ 0.60 mm², plus
small peripherals. **~1.4 mm² of core area** — comfortable on a 2×2 mm die,
which RETARGET §4 already expects to be pad-limited rather than area-limited.

---

## 4. What makes S1 a foundation rather than a throwaway

This is the part that decides whether "build on it later" is real.

1. **The bus takes the shape the coherent bus needs.** The caches already speak
   single-outstanding valid/ready, and D26 already chose that for the coherence
   bus. If S1's bus is that interface with one master, S2 replaces the arbiter
   and adds the snoop channel without touching the caches or the core.
2. **The D$ tag state is already MESI-shaped.** D24 landed the 2-bit `state_q`
   and it is flop-identical to the old `{valid, dirty}`. S1 ships lines that
   are only ever I, E or M; S2 makes S reachable. No re-encoding, no area
   change, and it is already verified in silicon-bound RTL.
3. **The memory map is fixed now** (ARCHITECTURE §4), so firmware, tests and
   the ISS carry forward unchanged across versions.
4. **The cache geometry is already parameterized** — D21 plus the formal work
   made `LINE_BYTES`/`LINES` real parameters, so capacity can change between
   silicon versions without an RTL rewrite.
5. **Pin budget planned for S2 at S1 time.** Deciding the pad ring once, with
   room for the second core's debug and any extra GPIO, avoids a full pad-ring
   redesign at S2. Pads are the thing that sets die size here.

Point 5 is the only one that requires acting *now* rather than later, and it
costs nothing to get right at S1 and a lot to get wrong.

---

## 5. S1 milestones

| | Milestone | Exit criteria |
|---|---|---|
| **S1-A** | SoC integration RTL | Bus, UART, GPIO, timer, boot ROM, memory controller, top level. Each block unit-tested; memory map matches ARCHITECTURE §4 |
| **S1-B** | Full-chip simulation + firmware | Boot ROM runs, firmware prints over UART, ASCON KAT executes on-chip, timer interrupt taken. ISS lockstep still 0 mismatches at the SoC level |
| **S1-C** | Physical: pads + full-chip P&R | Pad ring, chip-level floorplan with multi-macro placement, PDN, CTS, route. Timing closed at chip level, 0 router DRC |
| **S1-D** | Signoff | KLayout DRC clean, **LVS clean**, gate-level simulation of the routed netlist passing the S1-B firmware |
| **S1-E** | Submission | MPW agreement signed, slot booked, GDS submitted |

S1-D is the milestone that matters most, because LVS and GL sim are the two
things this project has never done and cannot estimate. Everything before it
is work; S1-D is the unknown.

---

## 6. Open questions

1. **IHP shuttle cadence and real pricing.** This decides whether "iterate
   across several tape-outs" is a plan or a wish. RETARGET §8 already flags
   pricing (€2,400–3,500) as unconfirmed for this design size, and says a
   missed slot costs months. **Resolve before committing to S1-E.** It is an
   email, not engineering, and it is the only genuinely blocking unknown here.
2. **Main memory size.** 16 KiB (4 macros) or 32 KiB (8)? Depends on firmware
   ambition at S1-B and on how much macro placement is worth exercising.
3. **Does S1 carry RVFI?** No — it costs 21% of core area and 383 of 492 port
   bits (RETARGET §4). Formal runs keep using the `ifdef`.
4. **Package and pin count.** Drives die size directly. Needs answering with
   question 1.

---

## 7. Decisions

| # | Decision | Alternatives | Why |
|---|---|---|---|
| **D27** | **Physical signoff moves ahead of coherence.** Chip-level flow is proven on a single-core chip (S1) before the dual-core coherent design (S2). | Keep RETARGET §7 order (coherence, then P6 signoff) | The P0 argument applied one level up: the chip-level flow is the largest remaining unknown and meeting it last, on the most complex design, is the risk P0 was created to avoid. The comparison D16 calls the deliverable is a simulation measurement, so nothing about the headline result depends on what is on the first die. |
| **D28** | **S1 boots and runs from on-chip SRAM**, not QSPI XIP. | XIP from external flash, as ARCHITECTURE §4 assumes | Removes the unwritten QSPI controller, the external part and its pad timing from first silicon. The memory map keeps its regions so firmware carries forward; S1 populates the on-chip ones. XIP arrives at S3 with the rest of the secure-boot story it exists to serve. |
| **D29** | **S1 keeps the caches.** | Core-only chip, caches at S2 | The SRAM smoke test proved one macro and explicitly not multi-macro placement, channel routing or PDN across an array. S1 with I$, D$ and main memory is how that gap gets retired before a dual-core chip depends on it — and the caches are already verified, so they cost integration, not design. |
