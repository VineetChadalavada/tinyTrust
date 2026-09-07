# Test Plan

*Status: v1.0, written 2026-07-14. Living document — test status is tracked
here.*
*Related: [REQUIREMENTS.md](REQUIREMENTS.md) §6, [ARCHITECTURE.md](ARCHITECTURE.md).*

This document lists everything that has to be checked before the design can be
trusted, and how each thing gets checked. A **testpoint** is one specific claim
about the design that a test has to confirm — each one has an ID so it can be
tracked.

---

## 1. The approach

Testing happens at five levels, each using a different method, because
different methods catch different bugs. A feature is only "done" when its
testpoints pass **and** the coverage measurements say the tests actually
exercised it.

| Level | Method | Tools | When |
|---|---|---|---|
| L1 Block | Self-checking tests for one block at a time, compared against a separate model | Icarus, Python models | per block, before connecting anything |
| L2 Processor | Mathematical proof, plus random instruction streams compared against a reference model | riscv-formal/SBY; Python reference model | M1–M2 |
| L3 System | Whole-system tests: start-up, external memory, peripherals | cocotb + Icarus/Verilator | M3–M4 |
| L4 Layout | Simulation of the final wired-up design, plus timing analysis | layout tool flow | M5 |
| L5 Silicon | Run the system tests on a real manufactured chip | serial-port scripts | after manufacture |

**The reference-model rule:** every check compares the design against a model
that is *independent* of it — either a third-party implementation, or a model
written from the specification. Never a model written by reading our own design,
because then a misunderstanding would appear in both and cancel out.

### Honest notes on tools

- **Local machine (Windows):** Icarus for simulation, plus Yosys/ABC/SBY for
  proofs, via the OSS CAD Suite. Fast enough for quick checks.
- **CI (GitHub Actions, Linux):** the full test run, plus code-coverage
  measurement and comparison against Spike, the standard RISC-V reference
  simulator. Spike on Windows is not worth the fight, so Spike-dependent jobs
  are CI-only, with a small Python reference model as the local stand-in.
- **UVM** (a standard but heavyweight testing framework): tracked as an
  external dependency because it needs a commercial simulator. Not on the
  critical path.

## 2. What each testbench does

- **`dv/ascon_kat/`** (exists): feeds official test vectors to the crypto block
  and compares against pyascon, an independent Python implementation.
- **`dv/core_iss/`** (exists, 2026-07-19): builds test programs directly in
  Python, runs them on both the design and a reference model, and compares
  every instruction result. The design reports what it did through a standard
  interface called **RVFI**, which exists in the design from day one — it is a
  design requirement, not an afterthought. Random programs come from templates:
  arithmetic bursts, load/store storms, branch mazes, trap bombs. Memory speed
  is randomised between 2 and 5 cycles, or pinned to the minimum.
- **`dv/formal/`**: the riscv-formal proof setup. Bounded proofs per
  instruction type, plus custom properties for memory protection and the bus.
- **`dv/soc/`** (M3): whole-system tests with simulated external flash and RAM,
  a serial-port monitor, and alert-pin checking.
- **`dv/uvm/`** (parallel track): a UVM environment for the crypto block.

## 3. Testpoints: the processor

IDs are stable. "F" means the item is also covered by a mathematical proof.

### 3.1 The instruction set

*Status 2026-07-22: every item in this section passes on **both** methods.
Simulation: 16 directed programs plus a 1,207,930-instruction random soak (190
programs, two memory-speed settings), zero disagreements against the Python
reference model. The shift-timing claim in CPU-SHIFT-01 is asserted directly in
the testbench. This clears the M1 requirement of a million random instructions.
Proof: riscv-formal passes 44 of 44 bounded checks. Bring-up found BUG-001 (a
memory-protection bug, found in simulation) and two defects in the proof setup
itself — BUG-002 (the simulated memory could produce errors the instruction
specification cannot describe, so every counterexample was actually correct
behaviour) and BUG-003 (the result reporter turned failures into passes). The
`reg` check runs at cycle 30 using a SAT-based engine, because the depth-40
version using the default engine is intractable — see dv/formal/README.md.
Still open: cross-checking the Python reference model itself against Spike in
CI, which is a different check from the soak above — it guards against the same
specification misreading appearing in both model and design.*

| ID | What it checks | Method |
|---|---|---|
| CPU-ARITH-01 | Every arithmetic operation, with awkward operands: 0, ±1, the most negative value (INT_MIN), the largest positive value (0x7FFFFFFF), and sign boundaries | directed + F |
| CPU-ARITH-02 | Signed and unsigned comparison across the boundary where they differ | directed + F |
| CPU-SHIFT-01 | Shifts by 0, 1 and 31, and the shifter takes exactly as many cycles as the shift distance | directed + F |
| CPU-IMM-01 | Constants embedded in instructions: sign extension and alignment | random + F |
| CPU-BR-01 | Every branch type, taken and not taken, forwards and backwards | random + F |
| CPU-JMP-01 | Jumps, including discarding the return address, and misaligned targets causing a trap | directed + F |
| CPU-LS-01 | All load and store sizes, every byte position, sign and zero extension | directed + F |
| CPU-LS-02 | Misaligned access produces the right error and changes nothing | directed + F |
| CPU-RVE-01 | Instructions naming registers that do not exist cause an illegal-instruction trap | directed |
| CPU-ILL-01 | Illegal and unimplemented instructions trap correctly | random + F |
| CPU-X0-01 | Register x0 is never written and always reads as zero | F |

### 3.2 Privilege levels, traps and control registers

| ID | What it checks | Method |
|---|---|---|
| PRV-TRAP-01 | Every trap cause is reachable, and the saved state is correct | directed |
| PRV-TRAP-02 | Returning from a trap restores the previous privilege and interrupt state | directed + F |
| PRV-CSR-01 | Read/set/clear on every control register; fields that only accept legal values reject illegal ones (trap-vector alignment, and the saved-privilege field accepting only 00 or 11) | directed |
| PRV-CSR-02 | Accessing a register that does not exist traps | random |
| PRV-CSR-03 | User-mode code cannot touch machine-mode registers | directed |
| PRV-INT-01 | Timer and external interrupts are taken only when enabled, with the right priority against exceptions | directed |
| PRV-INT-02 | An interrupt arriving in any internal state is taken only at an instruction boundary | random injection |
| PRV-ECALL-01 | System calls from machine and user mode give different causes | directed |

### 3.3 Memory protection

The PMP is the hardware that decides which parts of memory a program may read,
write or execute.

| ID | What it checks | Method |
|---|---|---|
| PMP-MATCH-01 | Region decoding for every size from 1 KB to 4 GB, inside, outside and on the boundary | directed sweep |
| PMP-PERM-01 | Every combination of permission and access type, with the right error when denied | directed |
| PMP-PRIO-01 | When regions overlap, the lowest-numbered one wins | directed |
| PMP-MMODE-01 | Machine mode ignores unlocked regions but obeys locked ones | directed |
| PMP-LOCK-01 | A locked region cannot be changed until reset, and survives privilege changes | directed |
| PMP-WARL-01 | Unsupported region modes read back as "off" | directed |
| PMP-U-NOMATCH-01 | User-mode access matching no region is denied | directed + F |
| PMP-SIDE-01 | **A denied access produces no bus traffic at all** — so it cannot have a side effect on a peripheral | assertion, every simulation |

### 3.4 Internal invariants (proof-first)

| ID | What must always be true | Method |
|---|---|---|
| UAR-FSM-01 | The control logic never reaches an illegal state, or trips a fault if it does | F + fault injection |
| UAR-BUS-01 | Exactly one memory request outstanding, held steady until accepted | assertion |
| UAR-RVFI-01 | The instruction, register, PC and memory reports are all mutually consistent | F |
| UAR-TIME-01 | An instruction is never completed twice, and never lost on a trap | F |
| CPU-FWD-01 | In the pipelined processor, an operand is always the correct architectural value — **including while the pipeline is stalled waiting for memory** | F + directed test |
| CPU-SER-01 | System instructions finish alone and flush the pipeline, so nothing executes under stale privilege or protection settings | directed + proof environment |

**Note on having two processors.** The simple version and the pipelined version
implement the same architecture and are held to the same standard: both run all
of §3.1–§3.3 against the same reference model, and both must pass 44 of 44
proof checks. The pipeline adds CPU-FWD-01 and CPU-SER-01, which have no
equivalent in the simple version — nothing is ever in flight there to forward
or overtake.

## 4. Testpoints: blocks and system

### 4.1 Secure boot

Critical, because the start-up ROM cannot be patched after manufacture.

| ID | What it checks | Method |
|---|---|---|
| BOOT-OK-01 | A valid image boots, and the ROM locks itself away before handing over | system test |
| BOOT-TAMPER-01 | A single flipped bit anywhere in the image, its length or its checksum causes a refusal and an alert | system sweep |
| BOOT-TAMPER-02 | Truncated, empty or over-long images are cleanly rejected, with no hang and no overflow | system test |
| BOOT-DEV-01 | Development mode skips verification and signals it, and the mode pin is read only once | system test |
| BOOT-ROMLOCK-01 | After boot, the ROM cannot be read or executed | system test |
| BOOT-ROM-EXH-01 | Every branch in the ROM code is executed and compared against a Python model | dedicated test, 100% path coverage |
| BOOT-HASH-01 | The ROM's Ascon-Hash256 sequencing matches pyascon on three image sizes, including one that is not a whole number of hash blocks | system test + pyascon |

### 4.2 External flash controller

| ID | What it checks | Method |
|---|---|---|
| QSPI-READ-01 | Slow and fast read modes, and continuous-read entry and exit | system test |
| QSPI-SEQ-01 | Sequential fetching uses the fast continuous mode, within a cycle budget | system test |
| QSPI-PSRAM-01 | External RAM read and write; the two chips are never selected at once | system test + assertion |
| QSPI-DIRECT-01 | Manual mode can read the flash chip's ID and then resume normal operation | system test |
| QSPI-ABORT-01 | A trap or denied access mid-fetch leaves no stuck transaction | random |

### 4.3 Crypto block

| ID | What it checks | Method |
|---|---|---|
| ASC-KAT-01 | ☑ 66 of 66 official test vectors match pyascon (all-zeros, all-ones and random inputs × 6, 8 and 12 rounds) | done 2026-07-14 |
| ASC-IF-01 | Reads and writes while busy are safely ignored | directed |
| ASC-IF-02 | Round counts outside the legal set behave sanely: 0 does nothing, and 13 to 15 clamp down to 12 | directed |
| ASC-IF-03 | The block takes exactly as many cycles as rounds requested, back to back | directed |
| ASC-HASH-01 | Software-driven Ascon-Hash256 matches pyascon across the NIST message-length sweep, 0 to 1024 bytes | system level |
| ASC-UVM-01 | UVM environment: random transactions, scoreboard, coverage closed | UVM track |

### 4.4 Peripherals and fault hardening

| ID | What it checks | Method |
|---|---|---|
| UART-01 | Serial send and receive for every byte value, at slowest and fastest speeds, plus overflow reporting | system test |
| TIME-01 | Timer wrap-around and comparison behaviour | directed |
| SEC-01 | Status reporting, and the alert flag that can be set but never cleared except by reset | directed |
| FLT-01 | Deliberately corrupting the control state triggers a fault and a sticky alert | fault injection |
| GPIO-01 | Input and output pins behave as the pin map says | system test |

### 4.5 Caches

| ID | What it checks | Method |
|---|---|---|
| CACHE-HIT-01 | A hit is served with no memory traffic at all, and returns the stored data | `dv/cache` directed + traffic counting |
| CACHE-MISS-01 | A first-time miss fetches exactly one 64-byte line (16 transfers) and the line is then present | `dv/cache` directed |
| CACHE-WB-01 | Throwing out a modified line writes it back first (32 transfers) and the data is still recoverable | `dv/cache` directed + read-back sweep |
| CACHE-BM-01 | Byte and half-word writes go through the memory block's write mask without a read-modify-write | `dv/cache` directed |
| CACHE-UNC-01 | Addresses above the cacheable limit always bypass the cache and are never stored | `dv/cache` directed + traffic counting |
| CACHE-FLT-01 | A memory error during a fetch reaches the processor and leaves no valid line behind | `dv/cache` directed |
| CACHE-FV-01 | **The cache is invisible: a read returns the last value written to that address** | F (`dv/formal/cache`, one-address abstraction). **Instruction cache PASSES** out to 26 cycles. **Data cache PROVEN UNBOUNDED by k-induction** (2026-09-06) at depth 20 — the bounded method could never reach the eviction sequence, so the method was changed rather than the bound. Both have a matching non-vacuity run; the data cache's confirms the eviction sequence is reached at step 28 |
| CACHE-SYS-01 | The processor with caches runs an identical instruction stream to the processor without them | reference-model comparison, 4th test leg |

**Note on what the existing tests could not measure.** Every directed and random
program in `dv/core_iss` runs in a straight line, once. That is the worst
possible case for a cache: a 64-byte line pulls in 16 instructions that are each
used exactly once, so an instruction cache can only match a plain fetch, never
beat it. So `loop_bench` was added — a nested loop whose hot body sits in one
cache line and whose data fits comfortably in the data cache. It is the only
program in the suite that reuses anything, and it is the one the cache speed
figure is quoted on. Correctness was never the gap; the gap was that the
workload could not show the property being built.

**Note on where the proofs stop (D22).** The cache is *not* folded into the
processor's proof setup. The processor keeps its own 44/44 at its own edges, and
the cache is proven separately against CACHE-FV-01. The reasoning, with the
measured cost that justifies it, is in RETARGET.md D22 and §9.3.

**Note on proving something meaningful.** Every bounded-proof configuration in
`dv/formal/cache` has a matching `*_cover.sby`, and both are needed before a
result counts. This is not ceremony. The setup already contained a check for
exactly this and it had never run, because the tool only evaluates those checks
in a different mode. A proof under strong assumptions is only as good as the
evidence that those assumptions still leave the interesting behaviour possible
— and for the data cache, measuring that is what revealed the proof had been
set to look less far ahead than the behaviour it was meant to check.

## 5. Coverage

Coverage measures whether the tests actually exercised the design, as opposed
to merely passing.

**Code coverage** (in CI): at least 95% of lines and 90% of signal transitions
in `rtl/`. Anything excluded must have a written reason.

**Functional coverage** — the interesting combinations, not just individual
cases:
- instruction type × source equals destination × operand signs
- trap cause × privilege level × internal state at the time
- memory protection: region × permission × access type × privilege × locked
- crypto: round count × starting while busy × access pattern
- flash: mode × burst length × where it was aborted
- boot: image size × where the tampering was

**The closure rule:** a gap in coverage is either filled with a new test or
waived in writing here. Never quietly accepted.

## 6. Regression testing

- `dv/regress.ps1` (local): must pass before any commit that touches `rtl/` or
  `rom/`. The processor leg runs three configurations — simple, pipelined, and
  pipelined with fast instruction fetch — because the first two share a timing
  pattern that makes some pipeline states unreachable (this is BUG-005). With
  the timed memory model a fetch always takes at least three cycles, so
  consecutive instructions are never closer than three pipeline stages apart.
  Making instruction fetch instant reaches states the timed model cannot, and
  also previews the timing the instruction cache brings.
- GitHub Actions on push: the full matrix — directed suites, coverage build,
  proof jobs, random-stream comparison against Spike, and a nightly long random
  sweep.
- Every regression failure gets written up before it gets fixed.

## 7. Bug tracking

Every bug gets an entry in [BUGLOG.md](BUGLOG.md) before it gets a fix.
Required fields: symptom, root cause (asking "why" until it bottoms out), the
fix commit, **the regression test added** (an entry cannot close without one),
and found-by — which method caught it. That last field feeds the question worth
answering at the end: which techniques actually found bugs?

## 8. Milestone exit criteria

*These are the original v1 milestones. The current plan is one chip at a time —
see [TAPEOUT_PLAN.md](TAPEOUT_PLAN.md). The criteria below still describe what
"done" means for each area of functionality.*

| Milestone | Required to pass |
|---|---|
| **M1** processor complete | §3.1 and the invariants green; proofs clean to at least 20 cycles; a million random instructions with zero disagreements; reporting interface present |
| **M2** privilege and protection | §3.2 and §3.3 green; the protection coverage cube closed; protection invariants proven |
| **M3** secure boot | §4.1 and §4.3 green including 100% ROM path coverage; at least 1000 randomised tampering attempts, zero wrongly accepted |
| **M4** system and FPGA | §4.2 and §4.4 green; full boot demo in simulation **and** on an FPGA; coverage targets met |
| **M5** manufacturing gate | All testpoints passed or waived; nightly tests green for 14 days straight; simulation of the final wired design boots; layout checks clean; no open design bugs |

## 9. Known risks

| Risk | What we do about it |
|---|---|
| riscv-formal may not fully support our reduced register set | The reporting interface is standard; restrict checks to the registers we have, and raise issues upstream early |
| Open-source assertion support is partial | Keep assertions simple, and duplicate the critical ones as ordinary checks |
| Access to a UVM-capable simulator | Parallel track, never blocking manufacture |
| The Python reference model could itself be wrong | Validate it against Spike in CI before trusting it locally |
