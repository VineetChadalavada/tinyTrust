# Requirements (version 1)

**A security-focused RISC-V microcontroller chip for the Tiny Tapeout shared
shuttle**

*Status: draft v0.1, agreed requirements. Date: 2026-07-14.*

> ## ⚠ This is the original version 1 requirements document
>
> It is the most superseded document in the repository. The platform, the area
> budget, the register count and the entire schedule have all changed:
>
> | This document says | The project now |
> |---|---|
> | Tiny Tapeout, 8 tiles, about €560 | Full custom chip on IHP SG13G2 |
> | 16 registers, area-first | All 32 registers, one chip at a time |
> | Submit to a late-2027 run | Building the first chip now |
>
> It is kept because it records what was actually agreed at the start, and every
> later reversal is only meaningful against it. **For the current requirements,
> read [RETARGET.md](RETARGET.md) and [TAPEOUT_PLAN.md](TAPEOUT_PLAN.md).**

---

## 1. Purpose

Design, verify, physically build and manufacture a small RISC-V chip with a
hardware root of trust, then bring up the returned silicon. The project has to
produce concrete, defensible material for four kinds of role:

| Role | What this project has to demonstrate |
|---|---|
| Processor architecture | Instruction-set and microarchitecture trade-offs under a hard area budget; privilege levels and memory protection; decisions written down with their alternatives |
| Design verification | A coverage-driven test plan, random and directed testing plus formal proof and comparison against a reference model, and bug tracking with real root-cause write-ups |
| Embedded and firmware | Start-up firmware in assembly, a secure boot flow, and driver and bring-up code for real silicon |
| Hardware security | An explicit threat model, integrity-checked boot, fault-tolerant control logic, and modern lightweight cryptography |

**The single strongest deliverable is the whole arc: "I specified it, verified
it, manufactured it, and brought up the silicon." Every scope decision below
serves that.**

## 2. Agreed scope

| Decision | Choice | Reasoning |
|---|---|---|
| Where it gets made | Tiny Tapeout, a shared shuttle | Low cost (about €70 per tile), guaranteed silicon, and a proven path — someone had already fitted a full 32-bit RISC-V system into 4 tiles |
| Strategy | **One manufacturing run, features trimmed to fit** | Keeps the cost under about €600 and the scope focused |
| Security features kept | Two privilege levels with memory protection; secure boot that checks firmware integrity; lightweight hardening of the control logic against glitching | Together these make a coherent "minimal hardware root of trust". Memory protection is also the most interview-relevant architecture feature |
| Security features cut | A full AES engine, a random number generator, a physical fingerprint function, side-channel countermeasures | AES is the single largest area item, and ASCON below keeps a cryptography story at about a tenth of the area |
| Cryptography | **ASCON**, the NIST lightweight cryptography standard: one permutation provides both hashing and authenticated encryption | A few thousand gates; used by the start-up ROM to check firmware; and a modern, distinctive talking point |
| Verification | Aim high on rigour | |
| Timeline | 18+ months to submission, targeting a 2027 run | Runs happen every 3 to 4 months, so there is no schedule pressure |

## 3. Platform constraints

These are hard constraints, and they drive the architecture:

- **Area.** A tile is about 160 × 100 µm, roughly 1,000 logic gates. The budget
  is **8 tiles, about 8,000 gates, roughly €560**, with the trim ladder in §8 if
  it overflows.
- **Pins.** 8 inputs, 8 outputs and 8 that can be either. 24 in total.
- **No memory blocks on the chip.** Code runs directly out of **external
  flash**, and data lives in a second external chip or a tiny register-based
  scratchpad.
- **Open source is mandatory.** The whole design, including the ROM contents, is
  published. This means **there can be no secrets on the chip**, and the threat
  model must not assume any.
- **Clock.** At least 40 MHz after layout. Typical designs on this platform
  reach 50 MHz or more, but do not trade area for frequency.
- **Flow.** The platform's own hardening flow, and the design must pass its
  automated checks and gate-level tests.

### Preliminary pin budget

| Function | Pins | Notes |
|---|---|---|
| Flash and external RAM, sharing a bus | 6 bidirectional | 4 data, a clock, and 2 chip selects |
| Serial port | 2 | Console, and loading firmware during bring-up |
| Boot mode and security straps | 2 in | For example "enforce secure boot" and "halt on failure" |
| General pins, status LEDs, trap indicator | whatever is left | A security alert output pin is required (§5.4) |

## 4. Functional requirements

### 4.1 Processor

- **The 16-register variant of 32-bit RISC-V**, plus control registers. The
  32-register version's register file alone would blow the area budget.
  Compressed instructions are a stretch goal — they halve the fetch traffic
  from slow flash, but cost decoder area, so decide with real data.
- Machine and **user** privilege levels, with the minimum set of control
  registers needed.
- A full trap mechanism: system calls, illegal instructions, access faults from
  the protection unit, misalignment traps (there is no hardware support for
  misaligned access), and returning from traps.
- Interrupts: a machine timer, which may be narrower than the specification
  says, plus one external interrupt line.
- The microarchitecture — how deeply pipelined, if at all — is deliberately
  **left to the architecture document**. The requirement is only: area first,
  and correctness provable by riscv-formal.

### 4.2 Memory

- A controller that runs code directly from external flash and reads and writes
  external RAM.
- A small instruction prefetch buffer or line cache **only if area allows** — a
  candidate to cut.
- A fixed, documented memory map.

### 4.3 Memory protection

- **4 regions**, implementing a compliant subset: only "off" and
  power-of-two-sized regions. The general arbitrary-range mode is dropped for
  area, and that is documented as an explicit deviation with reasoning. A
  minimum region size of 1 KB is acceptable.
- The lock bit is supported, and is required for the secure boot story: machine
  mode locks the ROM region before dropping to user mode.
- Enforced on instruction fetches, loads and stores in user mode. Locked regions
  are enforced in machine mode too, as the specification requires.

### 4.4 Secure boot — integrity, not confidentiality

- A **start-up ROM** of 512 bytes or less of hand-written assembly. On reset it
  hashes the firmware image sitting in external flash and compares the result
  against a known-good value.
- Where that known-good value comes from, in order of preference: fixed in the
  ROM at manufacture for the demo image, or loaded from a separate section of
  flash whose *own* hash is in the ROM. There is no one-time-programmable
  storage available on this platform.
- On a mismatch: **refuse to boot** — raise the security alert pin and hold in a
  trap loop. A strap pin selects a warn-and-continue mode for development.
- A **crypto accelerator** as a memory-mapped peripheral implementing the ASCON
  permutation, one round at a time for area. The ROM drives it for hashing, and
  ordinary firmware can use it too.

### 4.5 Fault-hardened control

- The security-critical control logic uses redundant or checked state
  encodings, so that a detected corruption raises an unmaskable trap and
  asserts the alert pin.
- Kept only if the area cost stays trivial, under about 300 gates. Otherwise it
  is the first thing to cut.

### 4.6 Peripherals

The minimum needed to bring the chip up: a serial port, general-purpose pins, a
timer, the crypto block, and a security status register. Nothing else.

## 5. Threat model

1. **In scope:** someone modifying the contents of the external flash, which
   secure boot catches; software escaping the user privilege level, which the
   protection unit blocks; and opportunistic glitching of the supply or clock,
   which §4.5 detects — detects, not prevents.
2. **Explicitly out of scope, and documented as such:** confidentiality of
   anything on the chip, since the design is public and no key storage exists;
   side-channel attacks, since the countermeasures were cut; sophisticated
   physical attacks; and probing the wires between the chip and the flash.
3. The write-up must present these exclusions as *reasoned decisions under the
   constraints of an open-source platform with no secret storage*. That framing
   is itself part of the point.
4. **Observability requirement:** one output pin dedicated to security status,
   so the security behaviour can actually be demonstrated on a bench rather than
   only asserted.

## 6. Verification requirements

Verification is a first-class deliverable, not an afterthought.

- **A test plan document** before the hardware is feature-complete: features map
  to test items, test items map to coverage.
- **Processor correctness:** riscv-formal bounded proofs, plus random
  instruction streams checked against Spike, the standard RISC-V reference
  simulator.
- **System level:** a whole-system regression, which is also what the platform's
  own flow requires.
- **UVM exposure:** a proper UVM environment for at least the crypto block, with
  an agent, a scoreboard against a reference model, and functional coverage,
  run on a freely available simulator.
- **Directed security tests:** rejecting a tampered image, the full matrix of
  user-mode protection violations, locked-region behaviour, trap state, and
  fault injection into the hardened control logic.
- **Simulation of the final wired-up design**, as the platform requires.
- **Bug tracking from day one:** every bug found gets symptom, root cause, fix
  and regression test.
- **To be allowed to manufacture:** proofs clean, 100% of test items closed,
  coverage targets met, N clean nightly random runs, and gate-level smoke tests
  passing.

## 7. Deliverables beyond the chip itself

- A public repository: the hardware, the test environment, the ROM source, and
  the documentation.
- The architecture specification, threat model, test plan and bring-up report,
  all written like industry documents.
- An FPGA prototype running the full boot flow with real external flash
  **before** submission.
- After manufacture: a bring-up log and a demo video showing the boot-verified
  indicator, a serial shell, a protection-violation demo, and a tampered-flash
  rejection demo.

## 8. Area budget and trim ladder

Preliminary, against about 8,000 gates, to be refined with real synthesis data.

| Block | Rough estimate | What to cut if over budget |
|---|---|---|
| Processor with control registers and traps | ~3.5–4.5 kGE | Share the datapath harder; drop compressed instructions first |
| Memory protection, 4 regions | ~0.8–1.2 kGE | Drop to 2 regions |
| Crypto, one round per cycle | ~2.5–3.5 kGE | Fewer rounds per cycle, so more cycles; last resort, one bit at a time |
| Start-up ROM, 512 bytes | ~1–1.5 kGE | Shrink the ROM, move logic into a verified second stage in flash |
| Flash controller, serial, pins, timer | ~1.5–2 kGE | Narrower timer, fixed serial speed |
| Fault hardening | ~0.3 kGE | **First to cut** |

If the total demands it, growing to 12 or 16 tiles (about €840 to €1,120) is a
cost decision to bring back to the user, not a unilateral one.

## 9. Roadmap — targets, not promises

| Milestone | Target | Done when |
|---|---|---|
| M0 Setup and architecture spec | Aug 2026 | Specification reviewed; repository, CI and simulation running |
| M1 Processor complete | Nov 2026 | Proofs clean; random runs against Spike passing |
| M2 Privilege and protection | Jan 2027 | Full trap and protection test suite plus formal properties green |
| M3 Crypto and secure boot | Mar 2027 | Tampered-image rejection working in simulation |
| M4 System integration and FPGA | May 2027 | Full boot-from-flash demo on real FPGA hardware |
| M5 Test closure and hardening | Aug 2027 | §6 criteria met; passes the platform's checks and gate-level simulation |
| **Submission** | **A late-2027 run** | — |
| Silicon bring-up | around mid-2028 | Bring-up report and demo video |

## 10. Key risks

| Risk | What we do about it |
|---|---|
| Running out of area | The trim ladder in §8; synthesise early and track the size of each block weekly |
| Running from external flash makes demos sluggish | Compressed instructions or a prefetch buffer as data-driven options; choose demos that tolerate slow fetching |
| A bug in the ROM found after manufacture, since the ROM cannot be patched | Keep it to 512 bytes, verify it exhaustively, and provide a strap-selectable bypass |
| The standard test generator assumes 32 registers | Constrain it to the registers we have, or use a different generator |
| Competing time pressure | Milestones have slack, and the run cadence means slipping one costs 3 to 4 months, not the project |
