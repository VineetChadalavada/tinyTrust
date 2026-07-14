# TinyTrust — Requirements Specification

**A security-hardened RV32E microcontroller SoC for Tiny Tapeout (SKY130)**

*Working name "TinyTrust" — rename freely.*
*Status: DRAFT v0.1 — agreed requirements; architecture spec is the next document.*
*Date: 2026-07-14*

---

## 1. Purpose and career goals

Design, verify, physically implement, and tape out a small RISC-V SoC with a
hardware root-of-trust flavor, then bring up the returned silicon. The project
must generate concrete, defensible interview material for:

| Target role | What this project must demonstrate |
|---|---|
| CPU/GPU/NPU Architect | ISA/microarchitecture trade-offs under a hard area budget; privilege architecture (M/U modes, PMP); documented design decisions |
| Design Verification | Coverage-driven DV plan, constrained-random + formal + co-simulation, bug tracking with root-cause writeups |
| Embedded/Firmware | Boot ROM firmware in C/asm, secure boot flow, driver + bring-up code for real silicon |
| Hardware Security | Explicit threat model, integrity-verified boot, fault-tolerant control logic, lightweight crypto (ASCON) |

**The single strongest deliverable is the story: "I specced it, verified it,
taped it out, and brought up the silicon." Every scope decision below serves
that story.**

## 2. Agreed scope decisions (from requirements discussion)

| Decision | Choice | Rationale |
|---|---|---|
| Tape-out platform | Tiny Tapeout, SKY130 shuttle | Low cost (€70/tile), guaranteed silicon, proven path (TinyQV precedent: full RV32 SoC in 2×2 tiles) |
| Strategy | **One tape-out, features trimmed to fit** | User decision; keeps cost ≤ ~€600 and scope focused |
| Security features KEPT | M/U privilege modes + lean PMP; secure boot (integrity-verified XIP); lightweight fault-hardening of control FSMs | Coherent "minimal hardware root of trust" narrative; PMP is the most architecture-interview-relevant feature |
| Security features CUT | Full AES accelerator (Zkne), TRNG, PUF, side-channel masking | AES is the largest area item; ASCON (below) preserves a crypto story at ~1/10 the area |
| Crypto primitive | **ASCON** (NIST SP 800-232 lightweight crypto standard): one permutation gives hash + AEAD | Few-kGE footprint; used by boot ROM for firmware integrity; modern/differentiating talking point |
| Verification background | Solid RTL + DV — aim high on verification rigor | |
| Timeline | 18+ months to submission → target a **2027 SKY shuttle** | Shuttles run ~every 3–4 months; no schedule pressure |

## 3. Platform constraints (Tiny Tapeout, SKY130)

These are hard constraints that drive the architecture:

- **Tile**: ~160×100 µm ≈ ~1,000 digital gates per tile. **Area budget: 4×2 tiles (8 tiles, ≈ 8 kGE, ~€560)**, with the trim ladder in §8 if we overflow.
- **I/O**: 8 dedicated inputs, 8 dedicated outputs, 8 bidirectional pins. Total 24.
- **No on-chip SRAM macros.** Code executes in place (XIP) from **external QSPI flash**; data RAM is external QSPI PSRAM or a tiny internal register-based scratchpad.
- **Open source mandatory.** The full design, including any ROM contents, is published. → **No on-die secrets.** Threat model (§5) must not assume key confidentiality on-chip.
- **Clock**: target ≥ 40 MHz post-layout on SKY130 (typical TT designs achieve 50 MHz+; do not sacrifice area for frequency).
- **Flow**: TT-provided OpenLane/LibreLane hardening flow; design must pass TT's automated precheck and cocotb-based gate-level tests.

### Pin budget (preliminary)

| Function | Pins | Notes |
|---|---|---|
| QSPI (flash + PSRAM, shared bus) | 6 bidir | 4 data + SCK + 2 CS (CS2 may steal a bidir or output) |
| UART TX/RX | 2 | Console + firmware loading during bring-up |
| Boot-mode / security straps | 2 in | e.g. "secure boot enforce" strap, halt-on-fail |
| GPIO / status LEDs / trap indicator | remainder | Security-alert output pin is required (§5.4) |

## 4. Functional requirements

### 4.1 CPU core

- **ISA: RV32E + Zicsr** (16 registers — the 32×32 RV32I register file alone would blow the area budget). **C extension is a stretch goal** (halves fetch bandwidth from slow QSPI flash, but costs decoder area — decide with data during architecture phase).
- Machine mode + **User mode**, with the minimal CSR set required: `mstatus`, `mtvec`, `mepc`, `mcause`, `mie`/`mip`, `mscratch`, plus PMP CSRs.
- Full trap architecture: `ecall`, illegal-instruction, instruction/load/store access faults (from PMP), misaligned traps (no hardware misaligned support), `mret`.
- Interrupts: machine timer (`mtime`/`mtimecmp`, may be width-reduced) + one external interrupt line.
- Microarchitecture (pipeline depth, multicycle vs. 2-stage, serialization choices) is deliberately **deferred to the architecture spec** — requirements only say: area-first, correctness provable by riscv-formal.

### 4.2 Memory system

- QSPI XIP controller: execute from external flash, read/write external PSRAM.
- Small direct-mapped instruction prefetch buffer / line cache **only if area allows** (trim candidate).
- Memory map fixed and documented (ROM / XIP flash / PSRAM / MMIO regions).

### 4.3 Physical Memory Protection (lean)

- **4 PMP entries**, spec-compliant subset: **NAPOT + OFF modes only** (TOR dropped for area — document this as an explicit deviation with rationale). Granularity ≥ 1 KiB is acceptable.
- Lock bit (`L`) supported — required for the secure-boot story (M-mode locks the boot ROM region before dropping to U-mode).
- Enforced on instruction fetch, loads, and stores in U-mode; locked entries enforce in M-mode too (per spec).

### 4.4 Secure boot (integrity, not confidentiality)

- **Boot ROM** (synthesized mask ROM, ≤ 512 bytes of machine code — hand-written assembly): on reset, hash the firmware image in external flash with **ASCON-Hash256** and compare against a **golden digest**.
- Golden digest source, in priority order (decide in architecture phase): (a) fixed in ROM at tape-out for the demo image, (b) loaded from a flash "manifest" sector whose *own* digest is in ROM. No fuses/OTP exist on TT.
- On digest mismatch: **refuse to boot** — assert the security-alert pin, hold in a trap loop; strap pin selects "warn-and-continue" mode for development.
- **ASCON accelerator**: memory-mapped peripheral implementing the ASCON permutation (round-serial for area); ROM drives it for hashing; runtime firmware may also use it (hash/MAC/AEAD via software sequencing of the same permutation).

### 4.5 Fault-hardened control (lightweight)

- Security-critical FSMs (boot sequencer, PMP check, trap entry) use **redundant/encoded states** (parity or one-hot-with-check); a detected corruption raises a non-maskable trap and asserts the alert pin.
- Kept only if the area cost stays trivial (< ~300 GE); first item on the trim ladder otherwise.

### 4.6 Peripherals (minimum viable bring-up set)

- UART (fixed or simply-divided baud), GPIO, machine timer, ASCON, security-alert/status register. Nothing else.

## 5. Threat model (summary — full doc later)

1. **In scope**: modification of external flash contents (integrity) → caught by secure boot; software escape from U-mode → blocked by PMP + privilege architecture; opportunistic voltage/clock glitching of control FSMs → detection (not prevention) by §4.5.
2. **Explicitly out of scope, and documented as such**: confidentiality of anything on-die (design is public, no key storage exists); side-channel attacks (masking was cut); sophisticated invasive/physical attacks; bus probing between chip and flash.
3. The write-up must present these exclusions as *reasoned decisions under the open-source, no-NVM constraints of the platform* — this framing is itself interview material.
4. **Observability requirement**: one output pin dedicated to security status (boot-verified / alert), so security behavior is demonstrable on the bench and in the TT demo video.

## 6. Verification requirements (DV is a first-class deliverable)

- **Verification plan document** (vplan) before RTL is feature-complete: features → testpoints → coverage items.
- **Core correctness**: `riscv-formal` bounded proofs on the core (RV32E profile); **riscv-dv** (or equivalent generator adapted for RV32E) constrained-random instruction streams with **Spike co-simulation** as reference.
- **SoC/bench**: cocotb + Verilator/Icarus regression (also what TT's flow requires for gate-level sims).
- **UVM exposure** (for DV-role résumé value): a proper UVM environment for at least the **ASCON block** — agent, scoreboard vs. reference model, functional coverage, run on a free UVM-capable simulator (e.g. Questa free edition). Documented coverage-closure results.
- **Directed security tests**: tampered-image boot rejection, U-mode PMP violation matrix (R/W/X × regions), locked-entry behavior, trap CSR state, fault-injection simulation on encoded FSMs.
- **Gate-level simulation** post-hardening with SDF, as required by TT.
- **Bug tracking from day one** (GitHub issues): every RTL bug found gets symptom → root cause → fix → regression test. This log is interview gold.
- Exit criteria for tape-out: riscv-formal clean, 100 % of vplan testpoints closed, functional coverage targets met, N nightly random regressions clean, gate-level smoke tests pass.

## 7. Deliverables beyond the chip

- Public GitHub repo: RTL (SystemVerilog), DV environment, boot ROM source, docs.
- Architecture spec, threat model, vplan, bring-up report — written like industry documents.
- FPGA prototype (any small board, e.g. iCE40/ECP5/Arty) running the full boot flow with real QSPI flash **before** submission.
- Post-silicon: bring-up log + demo video (boot-verify LED, UART shell, PMP violation demo, tampered-flash rejection demo).

## 8. Area budget and trim ladder

Preliminary budget against ~8 kGE (4×2 tiles) — to be refined with synthesis data in the architecture phase:

| Block | Rough estimate | Trim action if over budget |
|---|---|---|
| RV32E core + CSRs + traps | ~3.5–4.5 kGE | Serialize datapath (multicycle); drop C extension first |
| PMP (4 × NAPOT) | ~0.8–1.2 kGE | 4 → 2 entries |
| ASCON (round-serial) | ~2.5–3.5 kGE | Fewer rounds/cycle → more cycles; last resort: bit-serial |
| Boot ROM (≤ 512 B) | ~1–1.5 kGE | Shrink ROM, move logic to verified flash stage-1 |
| QSPI + UART + GPIO + timer | ~1.5–2 kGE | Reduce timer width, fixed baud |
| Fault-hardened FSMs | ~0.3 kGE | **First cut** |

If the total demands it, growing to 4×3 or 4×4 tiles (~€840–1,120) is a cost
decision to bring back to the user — not a unilateral one.

## 9. Roadmap (targets, not promises)

| Milestone | Target | Exit criterion |
|---|---|---|
| M0 Setup + architecture spec | Aug 2026 | Arch spec reviewed; repo, CI, sim flow running |
| M1 Core ISA-complete | Nov 2026 | riscv-formal clean; random regressions vs Spike passing |
| M2 Privilege + PMP | Jan 2027 | Full trap/PMP directed suite + formal props green |
| M3 ASCON + secure boot | Mar 2027 | Tampered-image rejection working in simulation |
| M4 SoC integration + FPGA | May 2027 | Full boot-from-flash demo on FPGA hardware |
| M5 DV closure + hardening | Aug 2027 | §6 exit criteria met; passes TT precheck + GL sim |
| **Submission** | **A late-2027 SKY shuttle** | — |
| Silicon bring-up | ~mid-2028 (shuttle-dependent) | Bring-up report + demo video |

## 10. Key risks

| Risk | Mitigation |
|---|---|
| Area overflow | Trim ladder (§8); synthesize early and track kGE per block weekly |
| QSPI XIP performance makes demos sluggish | C extension / prefetch buffer as data-driven options; demos chosen to tolerate slow fetch |
| ROM bug discovered after tape-out (ROM is unpatchable) | Keep ROM ≤ 512 B, formally/exhaustively verify it, strap-selectable bypass mode |
| riscv-dv assumes RV32I | Constrain generator to E-compatible registers, or use an alternative generator; spike supports RV32E |
| PhD time pressure | Milestones have slack; shuttle cadence means slipping one shuttle costs ~3–4 months, not the project |
