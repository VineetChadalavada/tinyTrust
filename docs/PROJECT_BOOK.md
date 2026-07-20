# The TinyTrust Book

**A security-hardened RV32E microcontroller SoC, designed from a blank repo
toward silicon on a Tiny Tapeout SKY130 shuttle — and the engineering record
of how it was built and verified.**

*Snapshot date: 2026-07-19 (mid-M1). This is a living document; the
Results chapter carries exact numbers as of this date and is updated at
each milestone.*

---

## How to read this

This document serves two purposes:

1. **A self-contained manual** — everything about TinyTrust in one place:
   what it is, why every major decision went the way it did, how the
   verification machinery works, and how to run all of it.
2. **A portfolio piece** — the project exists to generate concrete,
   defensible material for roles in embedded/firmware engineering, RISC-V
   CPU architecture, design verification (DV), and hardware security.
   Chapter 8 maps the work directly onto those roles, interview-question
   by interview-question.

If you have ten minutes, read Chapter 1 and Chapter 7 (Results). If you're
preparing for an interview, Chapter 8 is the crib sheet, and Chapters 5–6
are the depth behind it.

**Companion documents** (this book summarizes them; they remain the
authoritative specs):

| Document | Role |
|---|---|
| [REQUIREMENTS.md](REQUIREMENTS.md) | Agreed scope, platform constraints, threat model, roadmap |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The full architecture spec, decision log D1–D10, memory/pin maps |
| [VPLAN.md](VPLAN.md) | Verification plan: layers, testpoint matrices, coverage model, exit criteria |
| [BUGLOG.md](BUGLOG.md) | Every bug found, with root cause and the test that now guards it |
| [../synth/calibration/REPORT.md](../synth/calibration/REPORT.md) | Area-calibration method and measured data |

---

## Chapter 1 — What we are building, in one page

TinyTrust is a **complete system-on-chip**: a 32-bit RISC-V CPU, a
security subsystem, and the peripherals needed to boot and talk to the
world — small enough to fit a hobby-budget silicon shuttle, serious enough
to demonstrate professional-grade architecture and verification practice.

The one-sentence pitch:

> A minimal **hardware root of trust**: the chip refuses to run firmware
> that fails cryptographic integrity verification, enforces a
> machine/user privilege boundary with physical memory protection, and
> detects glitch-style attacks on its control logic — all in roughly
> 25,000 logic gates.

Concretely, the SoC contains:

- **An RV32E CPU core** — the embedded profile of RISC-V (16 registers
  instead of 32), with machine (M) and user (U) privilege modes, full trap
  architecture, and a lean Physical Memory Protection (PMP) unit.
- **A secure boot ROM** (≤ 512 bytes of hand-written assembly): on reset it
  hashes the firmware image in external flash with **ASCON-Hash256** (the
  NIST SP 800-232 lightweight cryptography standard) and compares against a
  golden digest. Mismatch ⇒ the chip asserts a security-alert pin and
  refuses to boot. No retry, no software bypass — only reset.
- **An ASCON permutation accelerator** — hardware does only the expensive
  permutation rounds; software sequences it into hash/MAC/AEAD. One small
  block, three cryptographic services.
- **A QSPI execute-in-place (XIP) controller** — Tiny Tapeout provides no
  on-chip RAM or flash, so code executes directly from external QSPI flash
  and data lives in external QSPI PSRAM.
- **Fault-hardened control logic** — security-critical state machines use
  encoded states with validity checking; a corrupted state (e.g. from
  voltage glitching) forces a trap and latches a sticky alert.
- **Bring-up peripherals** — UART, GPIO, timer, security/status registers.

**The platform** is [Tiny Tapeout](https://tinytapeout.com): community
shuttles on the SkyWater SKY130 130 nm open-source PDK. It imposes the
constraints that shaped everything: ~1 kGE of logic per tile (we
signed off a 4×4 = 16-tile budget), 24 I/O pins, no on-chip memory macros,
and a fully public design — which means **no on-die secrets**, and a threat
model built honestly around that.

**The end goal** is the full arc: *specced it → verified it → taped it
out → brought up the silicon.* Target: a late-2027 SKY shuttle, bring-up
in 2028.

---

## Chapter 2 — The method: how this project is run

The process is deliberately the same one a professional silicon team
follows, scaled to one person. This is itself a showcase item: the
*artifacts* prove the discipline.

### 2.1 Documents before RTL

Nothing was coded until three documents existed and agreed with each
other:

1. **Requirements** (REQUIREMENTS.md) — scope decisions with rationale,
   platform constraints, threat model, roadmap with exit criteria.
2. **Architecture spec** (ARCHITECTURE.md) — every block, every interface,
   and a **decision log** (§2 there, D1–D10) recording each major choice,
   the alternatives *rejected*, and why. Example: D1 multicycle core, D2
   RV32E, D6 NAPOT-only PMP.
3. **Verification plan** (VPLAN.md) — written *before* the core RTL, per
   the requirement that DV is a first-class deliverable. Features map to
   numbered testpoints (CPU-ARITH-01, PMP-LOCK-01, …), testpoints map to
   methods (directed / random / formal / SVA), and milestones have
   mechanical exit criteria.

### 2.2 Calibrate before committing

Area was the project's scarcest resource, so before freezing the
architecture we wrote *real RTL for the four riskiest blocks* (ASCON,
register file, PMP, boot ROM stub) and synthesized them with Yosys against
SKY130 HD cell areas. The measured numbers (Chapter 7) replaced guesswork:
the original 4×2-tile hope was proven unrealistic *by data*, and the
16-tile plan was signed off with ~60 % headroom. Every architecture table
carries a "first trim action" column — the fallback is designed before
it's needed.

### 2.3 Independence of reference models

The cardinal DV rule in this project: **every checker compares the RTL
against a model that shares no code and no author's blind spots with the
RTL.**

- The ASCON block is checked against **pyascon**, the algorithm authors'
  own reference implementation, vendored unmodified.
- The CPU core is checked against a **Python instruction-set simulator
  (ISS) written from the RISC-V specification**, not from the RTL.
- The formal properties come from **riscv-formal**, a third-party,
  community-maintained property suite.

Chapter 6 tells the story of BUG-001, which is this rule earning its keep.

### 2.4 Bugs are records, not embarrassments

Per VPLAN §7, every regression failure gets a log entry *before* it gets a
fix: symptom, root cause (5-whys deep), fix commit, the regression test
that now guards it, and — crucially — **found-by**, i.e. which
verification technique caught it. At the end of the project this becomes a
retrospective: which techniques actually found bugs. That table is prime
interview material, and it only exists if the discipline starts at bug #1.

### 2.5 Regression gating

`dv/regress.ps1` runs the ASCON known-answer tests and the full core
directed + random co-sim suite. Rule: it must pass before any commit that
touches `rtl/` or `rom/`. CI (GitHub Actions, planned at M1 exit) extends
this with Verilator coverage builds, Spike co-simulation, and nightly
long-random sweeps.

---

## Chapter 3 — Architecture: the what and the why

This chapter walks the design top-down. For every choice, the pattern is
the same: *state the constraint, then the decision follows.*

### 3.1 The system

```
   ┌─────────────────────────── TinyTrust SoC ────────────────────────────┐
   │  RV32E core ──── internal bus ──┬── Boot ROM (512 B)                 │
   │  (multicycle FSM,               ├── QSPI controller ── ext. flash    │
   │   M/U modes, PMP,   valid/ready ├── (XIP + data)    └─ ext. PSRAM    │
   │   RVFI port)        1 in flight └── MMIO: UART·GPIO·timer·ASCON·SEC  │
   └──────────────────────────────────────────────────────────────────────┘
```

One clock domain (target 40 MHz post-layout), one bus master, one
transaction in flight at a time. Every simplification here is also a
verification multiplier: a single-outstanding valid/ready bus needs
exactly one assertion shape to police every access in the system.

**Memory map** (decode on `addr[31:28]` only — four regions, near-zero
decode logic):

| Base | Region | Access |
|---|---|---|
| `0x0000_0000` | Boot ROM (512 B) | RX in M-mode; self-locked via PMP before firmware handoff |
| `0x1000_0000` | QSPI flash, XIP (16 MiB) | RX — writes fault; flash programming is off-chip |
| `0x2000_0000` | QSPI PSRAM (8 MiB) | RWX |
| `0x3000_0000` | MMIO peripherals (4 KiB) | RW, PMP-controlled |

### 3.2 The core: why multicycle, and why that's the smart choice here

The counterintuitive headline decision (D1): the CPU is **deliberately not
pipelined**. A multicycle FSM executes one instruction completely —
FETCH → EXECUTE → (MEM) → WRITEBACK — before fetching the next.

The reasoning chain:

1. There is no on-chip code memory. Every instruction fetch goes over
   QSPI to external flash: **~10–20 cycles per 32-bit word** even with
   quad-mode continuous reads.
2. Therefore fetch latency dominates CPI regardless of the
   microarchitecture. A pipeline's throughput would be spent stalling,
   while its hazard logic, pipeline registers, and verification surface
   would all still cost area.
3. A multicycle core lets hardware be **radically shared**: TinyTrust has
   exactly *one* 32-bit adder. It computes PC+4 during the fetch wait,
   branch/jump targets, effective addresses, ADD/SUB, and all comparisons
   (SLT/branches, via subtraction flags) — in different FSM states of the
   same instruction.
4. Shifts use an iterative 1-bit/cycle shifter (D5) instead of a ~0.7 kGE
   barrel shifter; 31 extra cycles on a worst-case shift is invisible next
   to fetch cost.

This is the "area-first, and the performance analysis proves it costs
nothing here" story — an architecture trade-off argued from workload
numbers, not habit.

Other core-level decisions:

- **RV32E** (D2): a 32×32 flip-flop register file is ≈ 1,024 flops —
  alone bigger than the rest of the core. RV32E halves it. GCC and LLVM
  both support the `ilp32e` ABI.
- **Trap architecture**: all traps to M-mode, `mtvec` direct mode only
  (D9). Implemented causes: instruction/load/store access faults and
  misalignments, illegal instruction, breakpoint, ecall from U and M,
  plus timer and external interrupts. Interrupts are taken **only at the
  fetch boundary** — an instruction never half-executes.
- **Documented spec deviations, all WARL-legal** (WARL = "Write Any values,
  Read Legal values" — the RISC-V mechanism that makes restricted CSR
  fields spec-compliant): `mtval` hardwired to 0, `misa` reads 0, counter
  CSRs trap (emulable in firmware), `mstatus.MPP` constrained to {M, U},
  FENCE.I traps (no caches to synchronize; Zifencei not claimed),
  WFI executes as NOP. Every deviation has a directed test proving the
  *restricted* behavior — deviations are verified choices, not surprises.

### 3.3 The PMP: security per gate

PMP is the mechanism that makes U-mode mean something: user code can only
touch memory that machine mode has explicitly granted. Full RISC-V PMP is
expensive, so TinyTrust implements a **lean, spec-compliant subset** (D6):

- 4 entries, **NAPOT + OFF address modes only** (naturally-aligned
  power-of-two regions). TOR mode would need a ≥-comparator pair per
  entry; NAPOT needs one AND and one compare: `(addr & ~mask) == base`.
  The `A` field is WARL — TOR/NA4 writes legally read back as OFF.
- 1 KiB granularity (grain G=7): the low address bits read as ones under
  NAPOT, per spec.
- **Lock bits fully supported** — this is load-bearing for security: the
  boot ROM locks entry 0 over the ROM region with **no permissions**
  before jumping to firmware. After that, *nothing* — not even M-mode —
  can read or execute the ROM until reset. Defense in depth, and a
  bench-demonstrable property.
- Priority per spec: lowest-numbered matching entry wins; U-mode access
  with no matching entry faults.

The architectural placement matters as much as the logic: the PMP check
sits **between the core and the bus**, so a denied access is *never
presented* to its target. "A rejected store cannot tickle an MMIO
register" is enforced by construction and policed by an assertion
(vplan PMP-SIDE-01) — not by convention.

### 3.4 ASCON: one permutation, three services

AES was cut early (REQUIREMENTS §2): a full AES core is the single largest
area item on the original list. ASCON — NIST's 2023-selected lightweight
cryptography standard (SP 800-232) — provides hashing, MAC, and
authenticated encryption from **one 320-bit permutation**, at roughly a
tenth of the area.

The hardware/software split (D7) is the interesting decision: the
accelerator implements *only* the permutation (one round per cycle,
rounds ∈ {6, 8, 12}, 64 parallel 5-bit S-boxes + fixed-rotation linear
layer). All mode logic — absorb/squeeze sequencing, padding, IVs — is
software in the boot ROM and firmware. Hardware does the expensive part;
software does the flexible part. Hashing a 32 KiB firmware image costs
≈ 50 k cycles of permutation time — boot verification completes in well
under 100 ms even with QSPI reads dominating.

### 3.5 Secure boot: the ROM is the root of trust

```
reset → M-mode @ ROM:
 1. Sample & lock strap pins (8 cycles after reset — they cannot be
    toggled later to bypass a failed boot).
 2. Init QSPI, read image header: magic | length | entry_offset.
 3. DEV strap set? → skip verification, distinct BOOT_OK blink pattern.
 4. ASCON-Hash256 over the image.
 5. Compare to GOLDEN_DIGEST baked into ROM.
      mismatch → SEC_ALERT pin high, cause recorded, WFI loop.
      (No retry, no bypass — only reset exits.)
 6. PMP entry 0 ← ROM region, no permissions, LOCKED.
 7. QSPI to quad/continuous mode, BOOT_OK=1, jump to firmware.
```

Because Tiny Tapeout designs are fully public and have no fuses, this is
an **integrity** root of trust, not a confidentiality one — the threat
model says so explicitly, and the write-up treats that framing as a
feature: reasoned exclusions under platform constraints, not hand-waving.

The ROM is unpatchable after tape-out, so it gets the project's highest
verification bar: instruction-accurate co-simulation against a Python
golden model of the entire flow, 100 % branch-path coverage, ≥ 1000
randomized image-corruption trials with zero false accepts, and gate-level
simulation (vplan §4.1, milestone M3).

### 3.6 Fault hardening: detect the glitch

Opportunistic voltage/clock glitching is in scope (detection, not
prevention). The mechanisms (§5.5 of the architecture):

- Core FSM state is **one-hot with a validity check** — any two valid
  states differ in ≥ 2 bits, so a single-bit upset lands in an invalid
  state, which forces a trap with a reserved cause and latches a sticky
  `fsm_fault` alert that only reset clears.
- Privilege state is **duplicated and compared** — a mismatch between the
  two copies is treated identically to FSM corruption.
- Budget-capped at 300 GE; first item on the trim ladder if area demands.

A nice consequence discovered during formal setup: since the alarm signal
exists, *every* formal check can also carry `assert(!fsm_fault)` — so all
44 bounded proofs simultaneously prove the FSM invariant holds in normal
operation (vplan UAR-FSM-01's formal half) at zero extra cost.

---

## Chapter 4 — What has been built so far

Timeline of the five working sessions to date:

**2026-07-14 — Scaffold + calibration.** Repo structure, requirements,
architecture spec. Real RTL for the four riskiest blocks; calibration
synthesis flow (`synth/calibration/run_calibration.py`, Yosys +
SKY130 HD liberty pricing). Result: measured kGE data, 16-tile plan
signed off.

**2026-07-14 — ASCON verified.** Vector-driven Icarus testbench vs.
pyascon: 66/66 known-answer tests (zero/all-ones/random states ×
6/8/12 rounds).

**2026-07-14 — Verification plan v1.0.** The full vplan: five layers,
testpoint matrices for core/PMP/boot/peripherals, coverage model,
milestone exit criteria, bug-tracking discipline.

**2026-07-19 — The core, and the machinery to trust it.** In one session:

- `rtl/core/core.v` — the complete multicycle RV32E core: 7-state one-hot
  FSM with fault detection, the single shared adder, iterative shifter,
  full decode with illegal/RVE trapping, CSR file, M/U privilege, PMP-gated
  bus, and an **RVFI port from day one** (see Chapter 5 — this is a design
  requirement, not an afterthought).
- `dv/core_iss/` — the lockstep co-simulation environment: a spec-written
  Python RV32E ISS + instruction encoders, an Icarus testbench with
  randomized bus latency, 16 directed test programs covering every vplan
  §3.1 testpoint, and a constrained-random program generator.
- **Result: zero mismatches over 353,713 randomly generated instructions**
  (50 seeds, two bus-latency profiles) plus all directed suites — after
  fixing **BUG-001**, a real RTL bug the harness caught in its first
  random session (Chapter 6).
- A timing assertion closing the CPU-SHIFT-01 clause: the iterative
  shifter must spend *exactly* `shamt` cycles shifting, checked on every
  retired instruction.

**2026-07-19 (same day, second session) — Formal.** The riscv-formal
harness under `dv/formal/`: SBY bounded model checking with
smtbmc/boolector, instruction checks at depth 25 (the M1 gate is ≥ 20),
shift instructions at depth 60 to accommodate the iterative shifter,
consistency checks (`reg`, `pc_fwd`/`pc_bwd`, `unique`, `causal`,
`liveness`, `cover`). Status at snapshot: **43 of 44 checks complete, all
passing, zero counterexamples**; the last (`reg`, the deepest) still
solving. Two Windows-specific bugs in the upstream tooling were found and
worked around along the way (Chapter 6).

---

## Chapter 5 — The verification story (the DV chapter)

This is the project's center of gravity for DV roles. The strategy is
five layers, each with an independent reference (VPLAN §1):

| Layer | What | Reference | Status |
|---|---|---|---|
| L1 Block | Directed self-checking TBs | pyascon, Python golden models | ASCON done |
| L2 Core | ISS lockstep co-sim + riscv-formal | spec-written ISS; third-party properties | co-sim green; formal 43/44 |
| L3 SoC | cocotb system tests (boot, XIP, peripherals) | behavioral flash/PSRAM models | M3 |
| L4 Implementation | Gate-level sim + SDF, STA, TT precheck | — | M5 |
| L5 Silicon | Bring-up plan executes L3 demos on hardware | — | post-fab |

### 5.1 RVFI: design for verification, literally

The core exposes **RVFI** — the RISC-V Formal Interface. On every retired
instruction it reports: the instruction word, PC before/after, source
register indices and the values read, destination register and value
written, memory address/masks/data, privilege mode, and trap status.

One port, three consumers:

1. The **lockstep testbench** logs each retirement as a text record.
2. The **ISS** emits records in the identical format; verification is
   `diff`.
3. **riscv-formal** attaches its entire property suite to the same port.

Committing to RVFI *before* writing the core (it's in the vplan as a
design requirement) meant the core's internals were shaped by
observability from the first line — there was never a "now how do we see
what it did?" phase.

Edge-case conventions had to be pinned down and mirrored on both sides —
this is where co-sim rigs usually rot, so they're documented in the RTL
header and the ISS docstring: memory records use word-aligned addresses
with byte-lane masks and the lane-replicated store pattern actually driven
on the bus; a fetch access fault retires as `trap=1, insn=0`; illegal
instructions report zeroed source-register fields (an RV32E subtlety — the
4-bit register file index would otherwise alias x17 onto x1); interrupts
produce no retirement, and the handler's first instruction carries
`intr=1`.

### 5.2 The ISS: a second implementation of the spec

`dv/core_iss/rv32e.py` (~450 lines) is a complete RV32E ISS written from
the RISC-V privileged and unprivileged specs plus ARCHITECTURE.md — with
**every WARL choice and documented deviation modeled**: mtvec's 16-byte
alignment, MPP's two-value constraint, the NAPOT-only PMP with
grain-bits-read-as-ones, counter CSRs trapping, the works. It shares the
file with an instruction *encoder* library (`ADDI(rd, rs1, imm)` → 32-bit
word), which means test programs are Python data — no cross-toolchain
required on the development machine.

Honest caveat, tracked in the vplan risk table: a hand-written ISS can be
wrong. Mitigations: (a) it is validated against **Spike** (the RISC-V
golden simulator) in CI before being trusted locally — that job is part of
the M1 exit gate; (b) it was written from the spec documents, not by
reading the RTL, so shared-blind-spot bugs need the same misreading twice
in two different languages. BUG-001 is evidence the independence is real.

### 5.3 The lockstep testbench

`tb_core.v` wraps the core with a 64 KiB behavioral memory, a magic
**TOHOST** word (any store there ends the test after that store retires —
the same convention both sides implement), and a bus model with
**randomized ready latency (2–5 cycles)**. That last detail matters: the
multicycle FSM's wait-states get exercised under every timing alignment,
and a second soak profile pins latency to minimum to stress the fast
handshake path. The same testbench carries the shift cycle-count
assertion and an `fsm_fault` watchdog.

### 5.4 Constrained-random generation

`gen_program.py` builds programs from weighted templates, exactly the
menagerie the vplan calls for:

- arithmetic bursts (R/I forms, corner-value loads via LUI/ADDI pairs);
- load/store storms against a scratch region — mostly aligned, sometimes
  deliberately not (those trap; see below);
- branch mazes (forward skips over random filler) and bounded backward
  loops;
- JAL/JALR ladders, including targets with bit 0 set (must be silently
  cleared, per spec) and bit 1 set (must trap);
- **trap bombs**: illegal opcodes, M-extension instructions (no M here —
  must trap), FENCE.I, SRET, unimplemented CSRs, misaligned accesses,
  x16–x31 register references (the RV32E boundary);
- CSR pokes across the whole implemented set, with two safety rails —
  never write `mtvec` (the handler must stay reachable) and never set PMP
  lock bits (a random locked deny-all region would wedge both models
  identically, which *passes* but proves nothing).

The elegant property of full lockstep: **data-dependent control flow needs
no static resolution.** A trap handler that clobbers a register, a branch
whose direction depends on random data, a store that lands on previously
stored data — the ISS executes the identical program on the identical
memory model, so both sides agree or the diff catches it. The generated
programs run under a skip-handler (`mepc += 4; mret`) so every trap bomb
is also a trap-*return* test.

### 5.5 Directed suites

Sixteen programs pin down the corners randomness might visit rarely:
`arith_r` (every R-op × 11×11 corner operand pairs), `arith_i`,
`shift_imm` (shamt 0/1/17/31 × sign corners, plus shift-by-register with
amounts > 31 in the register), `lui_auipc`, `branch` (all six branches ×
taken/not × forward/backward), `jump` (link registers, lsb clearing,
misaligned targets), `ldst` (every byte lane, sign/zero extension,
negative offsets, loads to x0), `ls_misaligned`, `ls_fault` (unmapped
addresses), `fetch_fault` (wild jump, custom recovery handler), `rve`
(x16+ in every field position), `illegal` (22 encodings incl. the
legal read-only-CSR reads that must *not* trap), `csr_warl` (every WARL
field's readback rule, including the PMP A-field and grain bits),
`traps_sys` (ecall/ebreak/wfi/fence + mcause/mepc readback), `x0`
(never written, always zero), and `smoke`.

### 5.6 Formal: riscv-formal + SBY

Bounded model checking complements simulation with exhaustiveness-in-depth:
within N cycles of reset, *no possible* instruction sequence, bus timing,
or data pattern violates the checked property — the solver plays adversary.

Setup highlights (`dv/formal/`):

- The environment model gives the solver **full freedom over the bus**
  (unconstrained read data and fault signaling) with one fairness
  assumption — ready arrives within 2 cycles — so search depth is spent on
  instructions, not stalls.
- **The RV32E gap**: riscv-formal has no first-class RV32E profile (its
  generator defines the `MISA_E` bit but generates no rv32e instruction
  set). Rather than fork the suite, the wrapper adds a *sound environment
  assumption*: fetched instructions never name x16–x31 in a field that is
  architecturally a register — with shamt, CSR zimm, and FENCE fields
  deliberately left unconstrained, because those bit positions are not
  registers. Checks then run as stock rv32i over the restricted space,
  and the trap-on-x16+ behavior is verified in simulation instead. Knowing
  *which* tool gap to close with *which* technique — and documenting the
  soundness argument — is the point.
- Depths: instruction checks at 25 cycles (M1 gate: ≥ 20); shift
  instructions at 60, because a worst-case iterative shift takes 31+
  cycles to retire; consistency checks 30–60.
- Every check also proves `assert(!fsm_fault)` — the FSM/privilege-shadow
  invariant — at its full depth, for free.

### 5.7 Coverage and closure (the part that comes next)

The vplan's coverage model (§5) is the M1→M2 to-do: Verilator
line/toggle coverage in CI (≥ 95 %/90 % with written waivers),
functional covergroups (instruction × operand-sign crosses, trap cause ×
privilege × FSM-state, the full PMP entry × permission × access-type ×
privilege × lock cube), and the closure rule: every hole is either hit by
a new test or waived in writing — never silently accepted.

---

## Chapter 6 — Bugs found: the war stories

The whole point of the found-by discipline is that each bug becomes a
story with a moral. Three so far.

### BUG-001: the PMP A-field off-by-one-bit (bug/rtl, fixed)

**Symptom.** First random co-sim session, seed 2, retirement #454: a CSR
read of `pmpcfg0` returned `0x02` from the RTL, `0x1A` from the ISS. A
directed WARL test failed the same way minutes later: write
`0x1F` (NAPOT + RWX), read back `0x07` (OFF + RWX).

**Root cause.** `pmp.v` extracted the two-bit A field from
`csr_wdata[5:4]` instead of `[4:3]` — one bit position off. NAPOT could
only ever be enabled by values that happened to have bits [5:4] = 11. The
readback mux was correct, so inspecting either the write path or the read
path alone looked fine; only *disagreement with an independent model*
exposed it.

**The moral, and why this is the best interview story in the repo so
far:** `pmp.v` predates the core — it was written for the area
calibration and had only ever been *synthesized*, never simulated. It
passed Yosys, it made timing, it produced credible area numbers, and it
was broken. "Synthesizes ≠ works" is a thing everyone says; this is a
concrete, dated, logged instance of it — caught by the reference-model
rule within hours of the block first meeting a checker. Had this
survived to silicon, the secure-boot ROM-lock step (PMP entry 0, locked,
no permissions) would have silently not engaged.

### The riscv-formal Windows pair (bug/tooling, worked around, upstream candidates)

Setting up formal on Windows surfaced two upstream tool bugs, both now
documented in `dv/formal/README.md` for filing when the repo goes public:

1. `genchecks.py` derives the core name via `os.getcwd().split("/")` —
   which on Windows returns the entire backslashed path, corrupting every
   generated file reference. Worked around by not using the `@core@`
   substitution.
2. The OSS CAD Suite ships `yosys-smtbmc` as a setuptools launcher pair
   (`yosys-smtbmc.exe.exe` + `yosys-smtbmc.exe-script.py`) that the
   Windows shell cannot resolve as a bare command; SBY's engine invocation
   fails with COMMAND NOT FOUND. Worked around with a runtime-generated
   `.bat` shim — the suite install stays untouched.

Minor stories, but they demonstrate a real skill: diagnosing a four-layer
tool stack (sby → yosys → smtbmc → solver) from logs, and choosing
workarounds that don't fork upstream.

### The false FAIL (a lesson about process, not code)

One formal batch run reported `FAIL insn_sll` — alarming, since the
shifter is the core's most stateful datapath. Investigation showed the
batch had been killed externally mid-solve: no counterexample trace
existed, and the "failure" was the runner conflating *killed* with
*refuted*. Rerun to completion: proven at depth 60 (194 s). Two fixes:
the runner now reports SBY's own status word (PASS/FAIL/ERROR are
different things), and long solves get explicit time budgets. Moral:
**a checker that can't distinguish "wrong" from "interrupted" will
eventually cry wolf** — and the response to a surprising FAIL is to
demand the counterexample, not to start "fixing" the design.

---

## Chapter 7 — Results dashboard (as of 2026-07-19)

### Verification

| Metric | Value |
|---|---|
| ASCON permutation KATs vs. pyascon | **66 / 66** (zero/ones/random × 6/8/12 rounds) |
| Core directed co-sim suites | **16 / 16 green** (~4,900 retirements) |
| Random instructions vs. ISS, lockstep RVFI compare | **353,713 — zero mismatches** (50 seeds; latencies 2–5 cy and min) |
| Shift cycle-count assertion (CPU-SHIFT-01) | asserted on every retire, green |
| riscv-formal bounded checks | **43 / 44 complete, all passing** (insn depth 25, shifts 60); `reg` (depth 40) still solving at snapshot |
| FSM-fault invariant (UAR-FSM-01, formal half) | proven inside all completed checks |
| RTL bugs found → fixed → regression-guarded | 1 (BUG-001) |
| Upstream tool bugs found | 2 (documented, workarounds committed) |

Representative solver times (smtbmc/boolector, depth 25 unless noted):
ALU/branch/load/store checks 8–18 s each; iterative-shift checks at depth
60: 42–195 s; liveness 29 s.

### Area (calibration synthesis, Yosys + SKY130 HD; full method in synth/calibration/REPORT.md)

| Block | Measured / est. | Note |
|---|---|---|
| ASCON (round/cycle) | **9.5 kGE measured** | biggest block; slice-serial S-box fallback ≈ −1.5 |
| Register file (15×32 DFF) | **7.0 kGE measured** | latch-file fallback ≈ −2 |
| PMP ×4 | **2.5 kGE measured** | |
| Boot ROM 512 B (stub) | **2.2 kGE measured** | |
| Remaining blocks (est.) | ~8–10 kGE | core control, CSRs, QSPI, UART/GPIO/timer, glue |
| **Full SoC projection** | **~23–26 kGE ≈ 9–10 tiles** | ABC-mapped data came in 26 % under the pessimistic method |
| **Plan of record** | **4×4 = 16 tiles** | signed off 2026-07-14; ~60 % headroom; 4×3 revisit at M1 |

### Milestones

| Milestone | Exit criteria | Status |
|---|---|---|
| M1 core ISA-complete | vplan §3.1 + UAR green; formal depth ≥ 20; 1 M random vs. ISS; RVFI in RTL | **sim leg done; formal 43/44; Spike/CI leg open** |
| M2 privilege + PMP | §3.2 + §3.3; PMP coverage cube closed; formal PMP invariants | infrastructure largely in place |
| M3 secure boot | boot suite; ROM 100 % path cov; ≥ 1000 tamper trials, 0 false accepts | — |
| M4 SoC + FPGA | full boot demo in sim and on FPGA | — |
| M5 tape-out gate | all testpoints closed/waived; 14 days green nightlies; GL sim; TT precheck | — |

---

## Chapter 8 — The showcase: mapping the work to the roles

This chapter is the interview crib sheet. Each subsection: what the role
cares about → what in this project proves it → questions to be ready for.

### 8.1 Embedded / Firmware roles

**Evidence in the project:** the memory map and MMIO register design; the
boot ROM flow (hand-written assembly under a 512-byte budget, driving a
hardware accelerator via MMIO); the trap-and-emulate decision for counter
CSRs (a firmware-visible ABI choice); the `ilp32e` ABI awareness; the
TOHOST/bring-up conventions; the planned UART shell and flash-programming
escape hatch (`QSPI.DIRECT` bit-bang mode — day-one bring-up must not
depend on the XIP path working).

**Be ready for:**
- *Walk me through what happens from reset to `main()`.* (Chapter 3.5 —
  strap sampling, header parse, hash, compare, PMP lock, mode switch,
  jump. Know the failure branches cold.)
- *How does firmware use a memory-mapped accelerator?* (ASCON: 10 state
  registers, CTRL/STAT handshake, busy-wait vs. the cost model.)
- *What happens on a misaligned load on this chip, and what should
  firmware do about it?* (Trap, cause 4, `mtval`=0 — so the handler
  re-decodes from `mepc`; or firmware just never does that, per ABI.)
- *Why 32-bit `mtime` and what does firmware owe you because of it?*
  (Wrap handling every ~107 s at 40 MHz.)

### 8.2 RISC-V / CPU architecture roles

**Evidence:** the decision log D1–D10 — every entry is an architecture
interview answer with the alternatives and numbers attached; the
multicycle-because-XIP analysis; RV32E area arithmetic; the WARL
subsetting technique used five different ways (PMP A-field, MPP, mtvec,
misa, counters); interrupt-at-retire-boundary semantics; the
one-adder datapath schedule.

**Be ready for:**
- *Why not a 2-stage pipeline? Give me numbers.* (Fetch ~10–20 cy/word
  dominates CPI ⇒ pipeline throughput is wasted on stalls while hazard
  logic + registers + verification surface all cost; multicycle enables
  the shared adder. Estimated CPI 15–25 from flash either way.)
- *How can dropping TOR from PMP be spec-compliant?* (WARL: the A field
  legally reads back OFF for unsupported modes; software probes and
  adapts. Same argument for every deviation — know the list.)
- *Where exactly is an interrupt taken and why does that matter?* (Fetch
  boundary only ⇒ no partially-executed instruction state to unwind;
  trivial to verify; latency cost is bounded by the longest instruction.)
- *What did committing to RVFI early buy you microarchitecturally?*
  (Retire-centric state updates, one writeback point, no hidden
  architectural state — the core is shaped like its own specification.)

### 8.3 Design Verification roles

**Evidence:** the vplan-before-RTL workflow with numbered testpoints and
mechanical exit criteria; the reference-model independence rule and
BUG-001 as its payoff; lockstep co-sim architecture (353 k random
instructions, randomized bus timing, trap bombs through a real handler);
constrained-random generation with documented safety rails and *why* each
rail exists; formal setup including an explicit soundness argument for
every assumption; the found-by discipline; the false-FAIL process lesson.

**Be ready for:**
- *Tell me about a bug you found.* (BUG-001, Chapter 6 — symptom, root
  cause, why only co-sim could see it, the regression that now guards it.)
- *Your golden model is hand-written Python. Why should I trust it?*
  (Independence by construction + Spike cross-validation in CI before
  local trust + the vplan lists it as a tracked risk — the honest answer
  is a risk register, not a claim of perfection.)
- *When do you use formal vs. random vs. directed?* (Formal: unbounded
  input spaces at bounded depth — instruction semantics, invariants.
  Random: state-space breadth, timing interleavings, the bugs you didn't
  think to write. Directed: documented deviations and corner enumeration.
  Show the same testpoint IDs flowing to different methods in the vplan.)
- *How do you keep constrained-random from cheating?* (The two rails:
  mtvec preservation and PMP lock masking — and the meta-point that a
  constraint that makes both models wedge identically *passes while
  proving nothing*, so rails must be argued, not just added.)
- *What makes an assumption sound?* (It restricts the environment, not
  the design; the excluded space is verified elsewhere — cite the RV32E
  fetch constraint with sim coverage of the trap path.)

### 8.4 Hardware security roles

**Evidence:** a written threat model with *reasoned exclusions* (no on-die
secrets on an open-source shuttle ⇒ integrity, not confidentiality); the
unbypassable-by-design boot flow (strap sampled once and locked; no
retry path; alert pin observable on the bench); ROM self-lockout via
locked PMP; PMP-deny-has-no-bus-side-effect as an architectural property
with an assertion; fault-hardened FSMs with the detection→trap→sticky-alert
chain; ASCON as a modern lightweight-crypto story.

**Be ready for:**
- *What's your threat model and what did you consciously exclude?*
  (In: flash tampering, U-mode escape attempts, opportunistic glitching.
  Out, with reasons: confidentiality, side channels, invasive attacks,
  bus probing. The exclusion *rationale* is the demonstration of maturity.)
- *Why hash-and-compare instead of signatures?* (No on-die secret storage
  exists and the design is public — a signature's public key in ROM gives
  integrity equivalent to the digest at higher cost; the v2 manifest path
  is documented for updatable firmware.)
- *How do you demo security on a bench?* (SEC_ALERT and BOOT_OK pins;
  planned demos: tampered-flash rejection, U-mode "attack me" shell
  command → clean PMP trap. Observability was a requirement, §5.4.)

---

## Chapter 9 — Roadmap from here

1. **Finish M1**: `reg` formal check completes; GitHub remote + CI
   (Actions matrix: Icarus regression, Verilator coverage, Spike co-sim
   validating the ISS, nightly long-random); the 1 M-instruction run;
   upstream the two riscv-formal Windows issues; C-extension go/no-go
   decision with calibrated data (D4).
2. **M2 privilege + PMP**: the §3.2/§3.3 directed matrices (much of the
   infrastructure — CSR tests, U-mode entry via mret, PMP WARL — already
   exists), the PMP functional-coverage cube, formal PMP invariants, SVA
   for the bus.
3. **M3 secure boot**: QSPI controller + flash/PSRAM behavioral models,
   boot ROM assembly + Python golden model, the 1000-corruption tamper
   sweep, ASCON UVM environment on the parallel track.
4. **M4 FPGA**: full boot-from-real-flash demo before submission.
5. **M5 closure and tape-out**: coverage closure, 14 green nightlies,
   gate-level + SDF, TT precheck, submit to a late-2027 shuttle — then
   the bring-up log and demo video that complete the story.

---

## Appendix A — Repository map

```
docs/       REQUIREMENTS, ARCHITECTURE, VPLAN, BUGLOG, this book
rtl/core/   core.v (RV32E multicycle + RVFI), regfile.v, pmp.v
rtl/periph/ ascon_p.v (verified permutation)
rom/        boot ROM (calibration stub; real ROM lands at M3)
dv/ascon_kat/  KAT regression vs. pyascon          → run.ps1
dv/core_iss/   ISS lockstep co-sim                 → run.ps1 / cosim.py
dv/formal/     riscv-formal + SBY harness          → run.ps1 / runchecks.py
dv/regress.ps1 pre-commit gate (ascon + core)
synth/      calibration flow + REPORT.md
tools/      generators (boot ROM stub, etc.)
```

## Appendix B — Running everything

```powershell
# prerequisites: OSS CAD Suite at E:\tools\oss-cad-suite (or set
# $env:OSS_CAD_SUITE), Python 3.x. Scripts set PATH themselves.

.\dv\regress.ps1                          # the pre-commit gate
.\dv\ascon_kat\run.ps1                    # ASCON KATs alone
.\dv\core_iss\run.ps1                     # directed + 4 random seeds
python dv\core_iss\cosim.py --random 25 --n 4000 --seed0 100   # a soak
.\dv\formal\run.ps1                       # all 44 formal checks
.\dv\formal\run.ps1 -Filter "insn_s*"     # a subset
python synth\calibration\run_calibration.py    # area numbers (needs .lib)
```

## Appendix C — Glossary

| Term | Meaning |
|---|---|
| **RV32E** | RISC-V 32-bit embedded base ISA: 16 registers instead of 32 |
| **WARL** | "Write Any, Read Legal" — CSR fields may legally coerce written values into a supported subset; the mechanism behind every documented deviation here |
| **PMP / NAPOT** | Physical Memory Protection; Naturally-Aligned Power-Of-Two region encoding (one mask-and-compare per entry) |
| **XIP** | Execute-in-place: CPU fetches instructions directly from (Q)SPI flash |
| **RVFI** | RISC-V Formal Interface: a per-retirement report of everything an instruction did; consumed here by co-sim and formal alike |
| **ISS** | Instruction-set simulator; the project's spec-written golden model |
| **KAT** | Known-answer test: fixed input → published expected output |
| **BMC / SBY** | Bounded model checking; SymbiYosys, the open-source formal front-end driving it |
| **ASCON** | NIST SP 800-232 lightweight cryptography standard; one 320-bit permutation yields hash/MAC/AEAD |
| **kGE** | Thousand gate-equivalents (NAND2-normalized area) |
| **Tiny Tapeout** | Community silicon shuttle service on the open-source SKY130 PDK |
| **TOHOST** | Test convention: a store to a magic address ends simulation with a result code |
| **Lockstep co-sim** | RTL and reference model execute the same program; every retirement is compared field-by-field |
