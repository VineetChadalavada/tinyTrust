# The TinyTrust Book

**A security-focused RISC-V microcontroller chip, taken from an empty
repository toward manufacture — and the engineering record of how it was built
and tested.**

> ## ⚠ This is a historical snapshot
>
> **Everything below describes version 1, as it stood on 2026-07-22.** Almost
> all of it has since been superseded:
>
> | This document says | The project now |
> |---|---|
> | 16 registers (RV32E) | All 32 registers |
> | One instruction at a time | 5-stage pipeline, with caches |
> | Tiny Tapeout, 16 tiles, SKY130 | Full custom chip on IHP SG13G2 |
> | Code runs from external flash | First chip runs from on-chip memory |
> | Manufacture in late 2027 | One chip at a time, first one being built now |
>
> It is kept because the reasoning is worth reading and because the reversals
> only make sense if the original argument is still on record. **For the
> current state, read [RETARGET.md](RETARGET.md) and
> [TAPEOUT_PLAN.md](TAPEOUT_PLAN.md), or the README.**

---

## How to read this

This document does two jobs:

1. **A manual** — everything about version 1 in one place: what it is, why each
   major decision went the way it did, how the testing works, and how to run it.
2. **A portfolio piece** — the project exists to produce concrete, defensible
   material for embedded, processor architecture, verification and hardware
   security roles. Chapter 8 maps the work onto those roles.

With ten minutes, read Chapter 1 and Chapter 7. Preparing for an interview,
Chapter 8 is the summary and Chapters 5 and 6 are the depth behind it.

**Companion documents** — this book summarises them; they are the authoritative
versions:

| Document | What it covers |
|---|---|
| [REQUIREMENTS.md](REQUIREMENTS.md) | Scope, platform constraints, threat model, roadmap |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The full specification and the decision log |
| [VPLAN.md](VPLAN.md) | The test plan: methods, test lists, coverage, exit criteria |
| [BUGLOG.md](BUGLOG.md) | Every bug found, its cause, and the test now guarding it |
| [../synth/calibration/REPORT.md](../synth/calibration/REPORT.md) | How area was measured, and the measurements |

---

## Chapter 1 — What we are building, in one page

TinyTrust is a **complete system on a chip**: a 32-bit RISC-V processor, a
security subsystem, and the peripherals needed to start up and talk to the
outside world. Small enough to fit a hobby budget, serious enough to
demonstrate professional design and verification practice.

The one-sentence version:

> A minimal **hardware root of trust**: the chip refuses to run firmware that
> fails a cryptographic integrity check, enforces a privilege boundary between
> trusted and untrusted code, and detects glitch-style attacks on its own
> control logic — in roughly 25,000 logic gates.

The chip contains:

- **A RISC-V processor** using the embedded variant of the instruction set (16
  registers instead of 32), with two privilege levels, a full trap mechanism,
  and a small memory protection unit.
- **A secure start-up ROM** — 512 bytes or less of hand-written assembly. On
  reset it hashes the firmware sitting in external flash using
  **Ascon-Hash256** (the NIST lightweight cryptography standard) and compares
  the result against a known-good value stored in the ROM. A mismatch raises a
  security alert pin and refuses to start. No retry, no software bypass. Only a
  reset gets out.
- **A crypto accelerator** — the hardware does only the expensive inner
  permutation, and software wraps it into hashing, authentication or
  encryption. One small block, three services.
- **A flash controller** that lets the processor run code directly out of
  external flash, because the chosen platform provides no on-chip memory at
  all. Data lives in a second external chip.
- **Hardened control logic** — the security-critical state machines use
  encodings that make a corrupted state detectable. A corrupted state, for
  example from deliberate voltage glitching, forces a trap and latches an alert
  that only a reset can clear.
- **Bring-up peripherals** — serial port, general-purpose pins, timer, and
  status registers.

**The platform** is [Tiny Tapeout](https://tinytapeout.com), a community
service that puts small designs onto shared silicon. It imposed the constraints
that shaped everything: roughly 1,000 gates per tile (16 tiles were signed
off), 24 pins, no on-chip memory, and a fully public design. That last point
matters most — **there can be no secrets on the chip**, so the threat model is
built honestly around integrity rather than confidentiality.

**The goal** is the full arc: specify it, verify it, manufacture it, bring it
up. Target at the time: a late-2027 run, with bring-up in 2028.

---

## Chapter 2 — How this project is run

The process is deliberately the one a professional silicon team follows, scaled
to one person. That is itself part of the point: the *artifacts* are what
demonstrate the discipline.

### 2.1 Documents before hardware

Nothing was written as hardware until three documents existed and agreed with
each other:

1. **Requirements** — scope with reasoning, platform constraints, threat model,
   and a roadmap with mechanical exit criteria.
2. **Architecture specification** — every block, every interface, and a
   **decision log** recording each major choice, the alternatives *rejected*,
   and why.
3. **Test plan** — written *before* the processor, because testing is treated
   as a first-class deliverable rather than something that happens afterwards.
   Features map to numbered test items, test items map to methods, and
   milestones have criteria that can be checked mechanically.

### 2.2 Measure before committing

Area was the scarcest resource, so before freezing the architecture we wrote
*real hardware for the four riskiest blocks* — the crypto accelerator, register
file, protection unit and start-up ROM — and synthesised them to get real
numbers. Those measurements (Chapter 7) replaced guesswork: the original hope
of fitting in 8 tiles was disproved *by data*, and the 16-tile plan was signed
off with about 60% headroom. Every architecture table carries a "first thing to
cut" column, so the fallback is designed before it is needed.

### 2.3 Reference models must be independent

The cardinal rule here: **every check compares the design against a model that
shares no code, and no author's blind spots, with the design.**

- The crypto block is checked against **pyascon**, the algorithm authors' own
  implementation, used unmodified.
- The processor is checked against a **Python model written from the RISC-V
  specification**, not by reading our own hardware.
- The formal properties come from **riscv-formal**, a third-party
  community-maintained suite.

Chapter 6 tells the story of BUG-001, which is this rule earning its keep.

### 2.4 Bugs are records, not embarrassments

Every test failure gets a log entry *before* it gets a fix: symptom, root cause
dug down to the bottom, the fix, the regression test that now guards it, and —
crucially — **found-by**, meaning which technique caught it. At the end that
becomes a retrospective on which techniques actually found bugs. That table only
exists if the discipline starts at bug number one.

### 2.5 Regression gating

`dv/regress.ps1` runs the crypto test vectors and the full processor comparison
suite. The rule: it must pass before any commit touching the hardware. CI
extends this with coverage builds, comparison against the standard RISC-V
simulator, and nightly long random runs.

---

## Chapter 3 — Architecture: the what and the why

This chapter walks the design from the top down. For every choice the pattern is
the same: state the constraint, and the decision follows.

### 3.1 The system

```
   ┌─────────────────────────── TinyTrust SoC ────────────────────────────┐
   │  processor ───── internal bus ──┬── Boot ROM (512 B)                 │
   │  (one instruction               ├── flash controller ── ext. flash   │
   │   at a time, two      one       │                    └─ ext. RAM     │
   │   privilege levels)  transfer   └── peripherals: serial·pins·timer   │
   │                      at a time      ·crypto·security                 │
   └──────────────────────────────────────────────────────────────────────┘
```

One clock domain, targeting 40 MHz after layout. One thing can start a transfer
on the bus, and only one transfer is in flight at a time. Every simplification
here is also a verification multiplier: a bus with one transfer shape needs
exactly one assertion to police every access in the system.

**Memory map.** Addresses are decoded on their top four bits only — four
regions, and almost no decoding logic:

| Address | Region | Access |
|---|---|---|
| `0x0000_0000` | Boot ROM, 512 B | read and execute; locks itself away before handing over to firmware |
| `0x1000_0000` | External flash, 16 MB | read and execute; writes fault, because programming happens off-chip |
| `0x2000_0000` | External RAM, 8 MB | read, write and execute |
| `0x3000_0000` | Peripherals, 4 KB | read and write, under protection control |

### 3.2 The processor: why one instruction at a time is the smart choice here

The counterintuitive headline decision: the processor is **deliberately not
pipelined**. It executes one instruction completely — fetch, execute, memory,
write back — before fetching the next.

The reasoning chain:

1. There is no code memory on the chip. Every instruction fetch goes out to
   external flash: **10 to 20 cycles per instruction**, even in the fastest
   mode.
2. So fetch latency dominates regardless of how clever the processor is. A
   pipeline's throughput would be spent waiting, while its hazard logic, extra
   registers and larger verification surface would all still cost area.
3. Handling one instruction at a time allows hardware to be **radically
   shared**. This chip has exactly *one* 32-bit adder. It computes the next
   instruction address during the fetch wait, then branch and jump targets, then
   load and store addresses, then arithmetic and every comparison — all in
   different states of the same instruction.
4. Shifts use a shifter that moves one bit per cycle instead of a barrel
   shifter costing about 0.7 kGE. Thirty-one extra cycles on a worst-case shift
   is invisible next to the fetch cost.

This is the "area first, and the performance analysis proves it costs nothing
here" story — a trade-off argued from workload numbers rather than habit.

*Both points 2 and 4 were later reversed, once caches made fetch fast. The
measurement that justified reversing them is in RETARGET.md §9.2 and §10.3 — and
the original reasoning above is exactly why the reversal had to wait for the
caches.*

Other processor-level decisions:

- **16 registers instead of 32.** A 32 × 32-bit flip-flop register file is about
  1,024 storage elements, on its own bigger than the rest of the processor.
  Halving it was the largest single saving available, and both major compilers
  support the reduced variant.
- **Traps.** Everything traps to machine mode, through a single entry point.
  The causes implemented are instruction, load and store access faults and
  misalignments, illegal instruction, breakpoint, system calls from either
  privilege level, plus timer and external interrupts. Interrupts are taken
  **only at an instruction boundary**, so an instruction never half-executes.
- **Documented deviations from the specification, all legal.** The mechanism
  that makes them legal is called WARL — "write any value, read a legal one" —
  which allows a control register field to force a written value into the subset
  the hardware supports. Using it: the trap-value register is hardwired to zero,
  the ISA description register reads zero, the counter registers trap so
  firmware can emulate them, the saved-privilege field accepts only two of its
  four values, the cache-flush instruction traps because there are no caches to
  flush, and the wait-for-interrupt instruction does nothing. Every deviation has
  a directed test proving the *restricted* behaviour, so each is a verified
  choice rather than a surprise.

### 3.3 Memory protection: security per gate

Memory protection is what makes the user privilege level mean anything: user
code can only touch memory that machine mode has explicitly granted it. The full
RISC-V mechanism is expensive, so this chip implements a **lean but compliant
subset**:

- 4 regions, and only two address modes — off, or a power-of-two sized region
  aligned to its own size. The general arbitrary-range mode would need a pair of
  comparators per region; the power-of-two form needs one AND and one comparison.
  Writing an unsupported mode legally reads back as "off".
- Regions are at least 1 KB, so the low address bits read back as ones.
- **Lock bits are fully supported**, and this is load-bearing for security. The
  boot ROM locks region 0 over itself with **no permissions at all** before
  jumping to firmware. After that, *nothing* — not even machine mode — can read
  or execute the ROM until the next reset. Defence in depth, and a property that
  can be demonstrated on a bench.
- Priority follows the specification: the lowest-numbered matching region wins,
  and a user-mode access matching no region is denied.

Where the check sits matters as much as the logic. It is placed **between the
processor and the bus**, so a denied access is *never presented* to its target.
"A rejected store cannot disturb a peripheral register" is enforced by
construction and policed by an assertion, not left to convention.

### 3.4 The crypto block: one permutation, three services

AES was cut early: a full AES engine is the single largest area item on the
original list. ASCON — the standard NIST selected for lightweight cryptography —
provides hashing, authentication and authenticated encryption from **one 320-bit
permutation**, at roughly a tenth of the area.

The split between hardware and software is the interesting decision. The
accelerator implements *only* the permutation: one round per cycle, with 6, 8 or
12 rounds selectable, built from 64 parallel 5-bit substitution boxes and a
fixed-rotation mixing layer. All the surrounding logic — sequencing, padding,
initial values — is software in the ROM and firmware. Hardware does the
expensive part; software does the flexible part.

Hashing a 32 KB firmware image costs about 50,000 cycles of permutation time, so
boot verification finishes well under 100 ms even with flash reads dominating.

### 3.5 Secure boot: the ROM is the root of trust

```
reset → machine mode, running from ROM:
 1. Sample and lock the mode pins, 8 cycles after reset. They cannot be
    changed afterwards to get around a failed boot.
 2. Set up the flash controller, read the image header: magic number,
    length, entry point.
 3. Development mode set? Skip verification, with a distinct blink pattern.
 4. Hash the image with Ascon-Hash256.
 5. Compare against the expected value built into the ROM.
      Mismatch → raise the alert pin, record why, and spin forever.
      No retry, no bypass. Only a reset gets out.
 6. Lock protection region 0 over the ROM, with no permissions.
 7. Switch the flash to fast mode, signal success, jump to firmware.
```

Because the design is fully public and has no secret storage, this is an
**integrity** root of trust, not a confidentiality one. The threat model says so
explicitly, and treats that framing as a feature: reasoned exclusions under real
platform constraints, rather than hand-waving.

The ROM cannot be patched after manufacture, so it gets the project's highest
verification standard: instruction-by-instruction comparison against a Python
model of the entire flow, 100% branch coverage, at least 1,000 randomised
image-corruption trials with zero wrongly accepted, and simulation of the final
wired-up version.

### 3.6 Fault hardening: detect the glitch

Opportunistic attacks that glitch the supply voltage or clock are in scope — for
*detection*, not prevention. The mechanisms:

- The processor's control state uses an encoding where **any two valid states
  differ in at least 2 bits**, so a single flipped bit always lands on an
  invalid state. That forces a trap with a reserved cause and latches a sticky
  alert that only a reset clears.
- The privilege state is **stored twice and compared**. A mismatch between the
  two copies is treated exactly like a corrupted control state.
- The whole mechanism is capped at 300 gate equivalents, and is first on the
  list to cut if area runs short.

A nice consequence discovered while setting up the proofs: because the alarm
signal exists, *every* proof can also assert that it never fires. So all 44
bounded proofs simultaneously prove the control-state invariant holds in normal
operation, at no extra cost.

---

## Chapter 4 — What had been built by the snapshot date

Five working sessions:

**2026-07-14 — Scaffolding and area measurement.** Repository structure,
requirements, architecture specification. Real hardware for the four riskiest
blocks, plus the synthesis flow to measure them. Result: real area data, and
the 16-tile plan signed off.

**2026-07-14 — Crypto block verified.** A vector-driven testbench against
pyascon: **66 of 66 known-answer tests** pass, covering all-zero, all-ones and
random inputs across 6, 8 and 12 rounds.

**2026-07-14 — Test plan version 1.0.** Five testing levels, test lists for the
processor, protection unit, boot and peripherals, a coverage model, milestone
criteria and the bug-tracking discipline.

**2026-07-19 — The processor, and the machinery to trust it.** In one session:

- The complete processor: a 7-state control machine with fault detection, the
  single shared adder, the iterative shifter, full instruction decoding with
  illegal-instruction trapping, the control registers, two privilege levels, a
  protection-gated bus, and a **reporting interface from day one** — a design
  requirement, not an afterthought.
- The comparison environment: a Python model written from the specification,
  instruction encoders, a testbench with randomised memory timing, 16 directed
  test programs covering every item in the test plan, and a random program
  generator.
- **Result: zero disagreements over 353,713 randomly generated instructions**
  across 50 seeds and two memory-timing profiles, plus all directed tests —
  after fixing **BUG-001**, a real hardware bug the environment caught in its
  very first random session.
- A timing assertion: the iterative shifter must spend *exactly* as many cycles
  as the shift distance, checked on every completed instruction.

**2026-07-19, second session — Formal proofs brought up.** The riscv-formal
setup: bounded proofs with instruction checks at 25 cycles (the milestone
requires at least 20), shift instructions at 60 to accommodate the slow
shifter, plus consistency checks. Two Windows-specific tool bugs found and
worked around (Chapter 6). Left at 43 of 44 with one check still solving.

**2026-07-22 — Proofs closed, and the simulation soak to a million.** Getting
from 43 to a genuine **44 of 44** exposed that the memory-instruction checks had
never actually been passing — two defects in the setup were hiding it.
**BUG-002**: the environment allowed traps the instruction model cannot
describe, so every counterexample was *correct* processor behaviour.
**BUG-003**: the reporter turned those failures into passes, because the tool
exits successfully on an expected failure and the reporter keyed on the exit
code. The deep register check proved intractable for five different solvers at
40 cycles, so it now runs at 30 using a different engine on a transformed
netlist. Same session: the comparison soak extended to **1,207,930 random
instructions across two timing profiles, zero disagreements**, clearing the
milestone's million-instruction target.

---

## Chapter 5 — The verification story

This is the project's centre of gravity. The strategy is five levels, each with
an independent reference:

| Level | What | Reference | Status |
|---|---|---|---|
| L1 Block | Self-checking directed tests | pyascon, Python models | crypto done |
| L2 Processor | Comparison against a model, plus proofs | model written from the spec; third-party properties | comparison green over 1.2 M random; proofs 44/44 |
| L3 System | Whole-system tests | simulated flash and RAM | later |
| L4 Layout | Simulation of the final wired design, timing analysis | — | later |
| L5 Silicon | Run the system tests on a real chip | — | after manufacture |

### 5.1 The reporting interface: designed for verification, literally

The processor exposes **RVFI**, a standard interface that reports, for every
completed instruction: the instruction itself, the program counter before and
after, which registers were read and what they held, which register was written
and with what, any memory address and data, the privilege level, and whether it
trapped.

One interface, three consumers:

1. The **comparison testbench** logs each completed instruction as a text
   record.
2. The **reference model** emits records in exactly the same format, so
   verification is a file comparison.
3. **riscv-formal** attaches its entire property suite to the same interface.

Committing to this *before* writing the processor meant its internals were
shaped by observability from the first line. There was never a "now how do we
see what it did?" phase.

The edge cases had to be pinned down and mirrored on both sides, because this is
where comparison setups usually rot. They are documented in both the hardware
and the model: memory records use word-aligned addresses with byte masks
matching what is actually driven on the bus; a failed instruction fetch is
reported as a trap with a zero instruction; illegal instructions report zeroed
register fields, which is a subtlety of the reduced register set, since a 4-bit
register index would otherwise make register 17 look like register 1; and
interrupts produce no completion record, with the handler's first instruction
carrying the interrupt flag instead.

### 5.2 The reference model: a second implementation of the specification

`dv/core_iss/rv32e.py` is about 450 lines and is a complete processor model
written from the RISC-V specifications and our own architecture document — with
**every deviation and restriction modelled**: the trap vector's alignment
requirement, the privilege field's two legal values, the protection unit's
restricted region modes and its read-back rules, the counter registers that
trap. It shares a file with an instruction *encoder* library, which means test
programs are ordinary Python data and no cross-compiler is needed on the
development machine.

Honest caveat, tracked as a risk: a hand-written model can be wrong. Two
mitigations. It is validated against **Spike**, the standard RISC-V simulator,
in CI before being trusted locally. And it was written from the specification
rather than by reading our hardware, so a shared blind spot would require the
same misreading twice, in two languages. BUG-001 is evidence that the
independence is real.

### 5.3 The comparison testbench

The testbench wraps the processor with 64 KB of simulated memory, a magic
address where any store ends the test, and a memory model with **randomised
response delay of 2 to 5 cycles**. That last detail matters: it exercises the
processor's waiting states under every timing alignment, and a second profile
pins the delay to its minimum to stress the fast path instead. The same
testbench carries the shifter timing assertion and a watchdog on the
fault-detection signal.

### 5.4 Random program generation

Programs are built from weighted templates:

- arithmetic bursts, including awkward operand values;
- load and store storms against a scratch area — mostly aligned, sometimes
  deliberately not, since those must trap;
- branch mazes and bounded backward loops;
- jump ladders, including targets with the low bit set, which must be silently
  cleared, and the next bit set, which must trap;
- **trap bombs**: illegal instructions, multiply and divide instructions that
  this chip does not implement, cache-flush instructions, unimplemented control
  registers, misaligned accesses, and references to registers above 15;
- control-register pokes across the whole implemented set, with two safety
  rails: never overwrite the trap vector, since the handler has to stay
  reachable, and never set a protection lock bit, because a randomly locked
  deny-everything region would wedge both the hardware and the model
  identically — which *passes* while proving nothing.

The elegant property of full comparison: **data-dependent control flow needs no
special handling.** A trap handler that clobbers a register, a branch whose
direction depends on random data, a store landing on previously stored data —
the model executes the identical program on an identical memory, so either both
sides agree or the comparison catches it. Generated programs run under a handler
that skips the faulting instruction and returns, so every trap bomb is also a
test of returning from a trap.

### 5.5 Directed tests

Sixteen programs pin down corners that randomness would visit rarely: every
arithmetic operation against an 11 × 11 grid of awkward operand pairs; shifts by
0, 1, 17 and 31 plus sign corners and shift amounts greater than 31 held in a
register; constant-building instructions; all six branch types taken and not
taken, forwards and backwards; jumps including link registers, low-bit clearing
and misaligned targets; loads and stores across every byte position with sign
and zero extension, negative offsets, and loads discarding their result;
misaligned accesses; accesses to unmapped addresses; a wild jump with a custom
recovery handler; references to registers above 15 in every field position; 22
illegal encodings including read-only register reads that must *not* trap;
every control register's read-back rule; system instructions with their cause
and saved-address read-back; the always-zero register; and a smoke test.

### 5.6 Formal proofs

Bounded proof complements simulation with exhaustiveness in depth: within N
cycles of reset, *no possible* instruction sequence, memory timing or data
pattern violates the property. The solver plays adversary.

Setup highlights:

- The environment gives the solver free rein over returned data, with a fairness
  assumption that memory answers within two cycles, so the depth is spent on
  instructions rather than on stalls. But the standard instruction models assume
  an *ideal, unrestricted memory*, so the sources of a *correct* trap that the
  specification cannot predict have to be switched off, each verified in
  simulation instead: memory errors, and protection or privilege denials. Each
  is a sound restriction on the *environment*, with the excluded behaviour
  covered elsewhere. Getting there taught two lessons the hard way (BUG-002 and
  BUG-003): a correct trap reads as a specification mismatch, and yosys cannot
  reach inside a module, so you constrain the instruction stream rather than an
  internal signal.
- **The reduced-register-set gap**: riscv-formal has no first-class support for
  the 16-register variant. Rather than fork the suite, the setup adds a sound
  environment assumption — fetched instructions never name registers above 15 in
  a field that is architecturally a register, with shift amounts and other
  non-register fields deliberately left unconstrained. The checks then run as
  standard 32-register checks over the restricted space, and the trap-on-high-
  register behaviour is verified in simulation. Knowing *which* tool gap to
  close with *which* technique, and writing down the argument for why it is
  sound, is the point.
- Depths: instruction checks at 25 cycles; shift instructions at 60, because a
  worst-case iterative shift takes over 31 cycles to finish; consistency checks
  between 30 and 60. The register check is the outlier — its single large query
  with the register file modelled as an abstract array is intractable past about
  30 cycles for every solver tried, so it runs at 30 using a SAT-based engine on
  a netlist where the array has been expanded into plain logic.
- Every check also proves the fault-detection invariant at its full depth, for
  free.

### 5.7 Coverage, which comes next

The coverage model is the next milestone's work: line and transition coverage in
CI at 95% and 90% with written waivers, functional coverage of the interesting
combinations, and the closure rule — every gap is either filled by a new test or
waived in writing, never quietly accepted.

---

## Chapter 6 — Bugs found: the war stories

The point of recording *how* each bug was found is that every bug becomes a
story with a moral. Three by the snapshot date.

### BUG-001: the protection unit read the mode field one bit off

**Symptom.** First random comparison session, seed 2, instruction number 454: a
read of the protection config register returned `0x02` from the hardware and
`0x1A` from the model. A directed test failed the same way minutes later: write
`0x1F`, read back `0x07`.

**Root cause.** The protection unit extracted the two-bit mode field from bits
[5:4] instead of bits [4:3] — one position off. The power-of-two region mode
could only ever be switched on by values that happened to have bits [5:4] set
to 11. The read-back path was correct, so inspecting either the write path or
the read path on its own looked fine. Only *disagreement with an independent
model* exposed it.

**The moral, and why this is the best story in the repository so far.** The
protection unit predates the processor — it was written for the area
measurements and had only ever been *synthesised*, never simulated. It passed
synthesis, it met timing, it produced credible area numbers, and it was broken.
"It synthesises" is not "it works" — everyone says this, and here is a
concrete, dated, logged instance, caught by the independent-model rule within
hours of the block first meeting a checker.

Had it survived to silicon, the secure boot's ROM lock-out step — protection
region 0, locked, no permissions — would have silently failed to engage. The
security property would have been absent while every test still passed.

### The two Windows tool bugs

Setting up the proof tools on Windows surfaced two upstream bugs, both
documented for filing:

1. The check generator works out the design name by splitting a path on forward
   slashes, which on Windows returns the whole backslashed path and corrupts
   every generated file reference. Worked around by not using that substitution.
2. The tool suite ships one of its helper programs as a launcher pair that the
   Windows shell cannot resolve as a bare command, so the proof engine fails
   with "command not found". Worked around with a small generated shim, leaving
   the installed suite untouched.

Minor stories, but they demonstrate a real skill: diagnosing a four-layer tool
stack from its logs, and choosing workarounds that do not fork upstream.

### The false failure — a lesson about process, not code

One batch run reported a failing shift check. Alarming, since the shifter is the
most stateful part of the datapath. Investigation showed the batch had been
killed from outside mid-solve: no counterexample existed, and the "failure" was
the runner confusing *killed* with *disproved*. Re-run to completion, it proved
cleanly at depth 60 in 194 seconds.

Two fixes: the runner now reports the tool's own status word, because passed,
failed and errored are three different things; and long solves get explicit time
budgets. The moral: **a checker that cannot tell "wrong" from "interrupted"
will eventually cry wolf** — and the right response to a surprising failure is
to demand the counterexample, not to start "fixing" the design.

---

## Chapter 7 — Results, as of 2026-07-22

### Verification

| Measure | Value |
|---|---|
| Crypto test vectors against pyascon | **66 / 66** (zero, ones and random inputs × 6, 8 and 12 rounds) |
| Directed comparison suites | **16 / 16 green**, about 4,900 instructions |
| Random instructions compared against the model | **1,207,930 — zero disagreements** (190 programs, two timing profiles), clearing the million-instruction target |
| Shifter timing assertion | checked on every instruction, green |
| Formal bounded checks | **44 / 44 passing** (instructions at 25 cycles, shifts at 60, the register check at 30 using a different engine) |
| Fault-detection invariant | proven inside all 44 checks |
| Hardware bugs found, fixed and guarded | 1 (BUG-001) |
| Test-setup bugs found and fixed | 2 (BUG-002, BUG-003) — the hardware was correct in both |
| Upstream tool bugs found | 2, documented with workarounds committed |

Representative solve times at depth 25: arithmetic, branch and memory checks 8
to 18 seconds each; the shift checks at depth 60 take 42 to 195 seconds;
liveness 29 seconds.

### Area

| Block | Measured or estimated | Note |
|---|---|---|
| Crypto, one round per cycle | **9.5 kGE measured** | biggest block; a slower fallback saves about 1.5 |
| Register file, 15 × 32 bits | **7.0 kGE measured** | a latch-based fallback saves about 2 |
| Memory protection, 4 regions | **2.5 kGE measured** | |
| Start-up ROM, 512 bytes | **2.2 kGE measured** | |
| Everything else, estimated | ~8–10 kGE | processor control, registers, flash, peripherals, glue |
| **Full chip projection** | **~23–26 kGE, about 9–10 tiles** | properly mapped data came in 26% under the pessimistic method |
| **Plan of record** | **16 tiles** | signed off 2026-07-14, about 60% headroom |

### Milestones

| Milestone | Required to pass | Status at snapshot |
|---|---|---|
| M1 processor complete | instruction tests and invariants green; proofs to at least 20 cycles; a million random instructions; reporting interface present | **simulation done (1.2 M, zero disagreements); proofs 44/44; only the model-versus-Spike check outstanding** |
| M2 privilege and protection | the privilege and protection test matrices; coverage cube closed; protection invariants proven | infrastructure largely in place |
| M3 secure boot | boot suite; 100% ROM path coverage; at least 1000 tampering trials with zero wrongly accepted | — |
| M4 system and FPGA | full boot demo in simulation and on an FPGA | — |
| M5 manufacturing gate | all tests closed or waived; 14 days of green nightly runs; simulation of the final wired design; platform checks | — |

---

## Chapter 8 — Mapping the work to roles

Each section: what the role cares about, what in this project demonstrates it,
and the questions to be ready for.

### 8.1 Embedded and firmware

**Evidence:** the memory map and peripheral register design; the boot ROM flow,
hand-written assembly under a 512-byte budget driving a hardware accelerator;
the decision to make counter registers trap rather than read zero, which is a
choice firmware can see; the bring-up conventions; the planned serial shell and
the manual flash-access escape hatch, because day-one bring-up must not depend
on the normal path already working.

**Be ready for:**
- *Walk me through what happens from reset to running firmware.* Mode pins
  sampled and locked, header parsed, image hashed, compared, ROM locked away,
  jump. Know the failure branches cold.
- *How does firmware drive a memory-mapped accelerator?* Ten state registers, a
  control and status handshake, and the cost model that decides whether to wait
  or do something else.
- *What happens on a misaligned load, and what does firmware owe you?* It
  traps, and because the trap-value register is hardwired to zero the handler
  has to re-decode the instruction from the saved address.
- *Why is the timer 32-bit and what does that cost firmware?* It wraps about
  every 107 seconds at 40 MHz, so firmware has to handle the wrap.

### 8.2 Processor architecture

**Evidence:** the decision log, where every entry is an architecture interview
answer with the alternatives and numbers attached; the analysis that fetch
latency justified handling one instruction at a time; the register-count area
arithmetic; the technique of legally implementing a subset of a specification
field, used five different ways; interrupt timing semantics; the shared-adder
schedule.

**Be ready for:**
- *Why not a pipeline? Give me numbers.* Fetch takes 10 to 20 cycles and
  dominates, so a pipeline's throughput would be wasted while its hazard logic,
  registers and verification surface all cost area. Note that this was later
  reversed once caches made fetch fast, and there is now a measurement.
- *How can dropping a protection region mode still be specification-compliant?*
  The field legally reads back as "off" for unsupported modes, so software
  probes and adapts. The same argument covers every deviation.
- *Where exactly is an interrupt taken, and why does that matter?* Only at an
  instruction boundary, so there is no partially executed instruction to unwind.
  Trivial to verify, and the latency cost is bounded by the longest instruction.
- *What did committing to the reporting interface early buy you?* Completion-
  centric state updates, one write-back point, and no hidden architectural
  state. The processor ends up shaped like its own specification.

### 8.3 Design verification

**Evidence:** the test-plan-before-hardware workflow with numbered items and
mechanical criteria; the independent-model rule and BUG-001 as its payoff; the
comparison architecture with randomised timing and trap bombs through a real
handler; random generation with documented safety rails and *why* each rail
exists; the formal setup with an explicit soundness argument for every
assumption; the found-by discipline; the false-failure lesson.

**Be ready for:**
- *Tell me about a bug you found.* BUG-001 — symptom, root cause, why only the
  comparison could see it, and the test that now guards it.
- *Your reference model is hand-written. Why should I trust it?* Independence by
  construction, cross-validation against the standard simulator before it is
  trusted locally, and it is listed as a tracked risk. The honest answer is a
  risk register, not a claim of perfection.
- *When do you use formal, random and directed testing?* Formal for unbounded
  input spaces at bounded depth. Random for breadth and timing interleavings —
  the bugs you did not think to write. Directed for documented deviations and
  corner enumeration. The same test item flows to different methods in the plan.
- *How do you stop random testing from cheating?* The two rails, and the
  meta-point behind them: a constraint that makes both the hardware and the
  model wedge identically *passes while proving nothing*, so rails have to be
  argued rather than just added.
- *What makes an assumption sound?* It restricts the environment, not the
  design, and the excluded space is verified elsewhere.

### 8.4 Hardware security

**Evidence:** a written threat model with *reasoned exclusions* — no secrets can
exist on a public chip, so the goal is integrity rather than confidentiality; a
boot flow that cannot be bypassed by design, with the mode pin sampled once and
locked and no retry path; the ROM locking itself away using its own protection
hardware; "a denied access produces no bus traffic" as an architectural property
backed by an assertion; hardened state machines with a detection, trap and
sticky-alert chain; a modern lightweight-cryptography story.

**Be ready for:**
- *What is your threat model and what did you consciously exclude?* In scope:
  tampering with the external flash, attempts to escape the privilege boundary,
  opportunistic glitching. Out of scope, with reasons: confidentiality, side
  channels, invasive attacks, bus probing. The *reasoning behind the exclusions*
  is what demonstrates maturity.
- *Why hash-and-compare rather than signatures?* There is no secret storage and
  the design is public, so a signature's public key sitting in ROM gives
  integrity equivalent to storing the hash, at higher cost. An updatable scheme
  is documented as a later path.
- *How would you demonstrate the security on a bench?* The alert and boot-status
  pins, a tampered-flash rejection demo, and a shell command that deliberately
  attempts a forbidden access and gets a clean trap. Observability was a
  requirement, not an afterthought.

---

## Chapter 9 — Roadmap from here

*This was the version 1 roadmap as of the snapshot. It has been replaced — see
[TAPEOUT_PLAN.md](TAPEOUT_PLAN.md).*

1. **Finish M1:** the register proof completes; a git remote and CI; the
   million-instruction run; file the two upstream tool bugs; decide on
   compressed instructions with real data.
2. **M2, privilege and protection:** the directed matrices, much of whose
   infrastructure already exists; the protection coverage cube; protection
   invariants proven; bus assertions.
3. **M3, secure boot:** the flash controller and simulated external parts, the
   boot ROM and its Python model, the thousand-corruption tampering sweep.
4. **M4, FPGA:** a full boot from real flash before submission.
5. **M5, closure and manufacture:** coverage closure, 14 green nightly runs,
   simulation of the final wired design, platform checks, submission — then the
   bring-up log and demo that complete the story.

---

## Appendix A — Repository map

*As of the snapshot. The current layout is in the README.*

```
docs/          requirements, architecture, test plan, bug log, this book
rtl/core/      the processor, register file, memory protection
rtl/periph/    the crypto accelerator
rom/           start-up ROM (a stub at this point)
dv/ascon_kat/  crypto test vectors           → run.ps1
dv/core_iss/   comparison against the model  → run.ps1 / cosim.py
dv/formal/     the proof setup               → run.ps1 / runchecks.py
dv/regress.ps1 the pre-commit gate
synth/         area measurement
tools/         generators
```

## Appendix B — Running everything

```powershell
# needs the OSS CAD Suite and Python 3. The scripts set up their own paths.

.\dv\regress.ps1                          # the pre-commit gate
.\dv\ascon_kat\run.ps1                    # crypto vectors alone
.\dv\core_iss\run.ps1                     # directed tests plus 4 random seeds
python dv\core_iss\cosim.py --random 25 --n 4000 --seed0 100   # a longer soak
.\dv\formal\run.ps1                       # all 44 proof checks
.\dv\formal\run.ps1 -Filter "insn_s*"     # a subset
```

## Appendix C — Glossary

| Term | Meaning |
|---|---|
| **RV32E / RV32I** | The 32-bit RISC-V instruction set. The E variant has 16 registers, the I variant 32. Version 1 used E; the project now uses I |
| **WARL** | "Write Any, Read Legal" — a control register field may legally force a written value into the subset it supports. This is the mechanism behind every documented deviation here |
| **PMP** | Physical Memory Protection: the hardware deciding which parts of memory code may read, write or execute |
| **NAPOT** | A region encoding where regions are a power of two in size and aligned to their size, so a match is one mask and one comparison |
| **XIP** | Execute in place: the processor fetches instructions directly from external flash rather than copying them to RAM first |
| **RVFI** | RISC-V Formal Interface: a per-instruction report of everything an instruction did. Used here by both the comparison and the proofs |
| **ISS** | Instruction set simulator — the reference model written from the specification |
| **KAT** | Known-answer test: a fixed input with a published expected output |
| **BMC** | Bounded model checking: proving no input can break a property within N cycles of reset |
| **SBY / SymbiYosys** | The open-source front-end that drives the proof engines |
| **ASCON** | The NIST lightweight cryptography standard. One 320-bit permutation provides hashing, authentication and encryption |
| **kGE** | Thousands of gate equivalents — chip area measured in multiples of one basic logic gate |
| **Tiny Tapeout** | A community service putting small designs onto shared silicon. The version 1 target |
| **TOHOST** | A test convention: a store to a magic address ends the simulation with a result code |
| **Lockstep comparison** | The hardware and the reference model execute the same program, and every completed instruction is compared field by field |
| **Cache coherence** | Keeping two processors' private copies of the same memory in agreement. Not in version 1; it is the point of version 2 |
