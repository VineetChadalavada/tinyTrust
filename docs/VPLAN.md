# TinyTrust — Verification Plan (vplan)

*Status: v1.0 — 2026-07-14. Gates milestone M1; living document — testpoint
status is tracked here, bugs in the issue tracker.*
*References: [REQUIREMENTS.md](REQUIREMENTS.md) §6, [ARCHITECTURE.md](ARCHITECTURE.md).*

---

## 1. Strategy overview

Five verification layers, each with a distinct owner-method. A feature is
"done" only when its testpoints pass **and** its coverage items are hit.

| Layer | Method | Tools | When |
|---|---|---|---|
| L1 Block | Self-checking directed TBs + reference models | Icarus, Python golden models | per block, before integration |
| L2 Core ISA | Formal (bounded) + random instruction streams vs. ISS | riscv-formal/SBY; Python RV32E ISS co-sim | M1–M2 |
| L3 SoC | cocotb system tests (boot flows, XIP, peripherals) | cocotb + Icarus/Verilator | M3–M4 |
| L4 Implementation | Gate-level sim w/ SDF, STA, TT precheck | TT OpenLane flow | M5 |
| L5 Silicon | Bring-up plan executes L3 demos on hardware | UART host scripts | post-fab |

**Reference-model rule:** every checker compares against a model that is
*independent* of the RTL (vendored third-party where possible — e.g. pyascon
— or a Python model written from the spec, never from the RTL).

### Tool/platform notes (honest constraints)

- Local (Windows): Icarus + native Yosys/ABC/SBY via OSS CAD Suite; quick
  regressions.
- CI (GitHub Actions, Linux): full regression + **Verilator code coverage**
  (line/toggle) + Spike co-sim for random streams. Spike on Windows is not
  worth the fight; the ISS-dependent jobs are CI-only, with a small Python
  RV32E ISS as the local fallback.
- UVM (ascon block, résumé deliverable): free UVM-capable simulator
  (Questa free edition or DVT/Xcelium academic access) — tracked as an
  external dependency, not on the critical path to tape-out.

## 2. Testbench architectures

- **`dv/ascon_kat/`** (exists): vector-driven Icarus TB vs. pyascon. Extend
  with interface-corner tests (§4.3).
- **`dv/core_iss/`** (exists, 2026-07-19): instruction-stream runner with
  encoder-built programs (no external toolchain needed locally). RTL retire
  interface (RVFI) logged and compared instruction-by-instruction against
  the ISS (Spike in CI, Python ISS locally — `rv32e.py`, written from the
  spec per the reference-model rule). Random generator: constrained
  templates (arith bursts, load/store storms, branch mazes, trap bombs)
  with RV32E register constraint. Bus latency randomized (2–5 cycles) or
  pinned minimum.
- **`dv/formal/`** (M1): riscv-formal harness — core exposes an **RVFI
  port** from day one (this is a design requirement on the core RTL, not an
  afterthought). SBY bounded proofs per instruction class + custom SVA for
  PMP/bus invariants.
- **`dv/soc/`** (M3): cocotb TB with behavioral QSPI flash + PSRAM models
  (W25Q-style command set incl. continuous-read; PSRAM quad R/W), UART
  monitor/driver, strap control, alert-pin monitor.
- **`dv/uvm/`** (parallel track): UVM env for ascon_p — sequence items =
  (state, rounds) transactions, scoreboard vs. pyascon via DPI or file
  exchange, functional covergroups (§5).

## 3. Feature → testpoint matrix: core (L2)

IDs are stable; ☐/☑ tracked here. "F" = also covered by riscv-formal proof.

### 3.1 ISA — RV32E base

*Status 2026-07-22: every §3.1 testpoint is green on **both** legs. Sim: 16
directed programs + a 1,207,930-instruction random soak (190 programs, two
bus-latency profiles — maxlat=3 and min-latency), zero mismatches vs. the
Python ISS; the CPU-SHIFT-01 cycle-count clause is asserted directly in
tb_core.v (S_SHIFT occupancy == shamt, per retire). This clears the M1
"1 M random instructions vs. ISS" criterion on the RTL-vs-ISS lockstep leg.
Formal ("F"): riscv-formal 44/44 bounded checks pass (dv/formal —
insn/reg/pc_fwd/pc_bwd/unique/causal/liveness/cover). Bring-up found BUG-001
(pmpcfg A-field, sim) and the two formal-harness defects BUG-002 (the memory
environment could take bus-fault and PMP/privilege traps the base insn spec
can't model — every counterexample was correct DUT behavior) and BUG-003 (a
false-green in the check reporter). The `reg` check runs at CHECK_CYCLE 30 via
abc-bmc3 (see dv/formal/README.md — the depth-40 SMT query is intractable).
Still open before M1 exit: cross-validating the ISS itself against Spike in
CI (a distinct check from the RTL-vs-ISS soak above — it guards against a
shared spec-misread in the golden model), plus the CI wiring (no git remote
yet).*

| ID | Testpoint | Method |
|---|---|---|
| CPU-ARITH-01 | All ALU ops, directed corner operands (0, ±1, INT_MIN, 0x7FFFFFFF, sign boundaries) | directed + F |
| CPU-ARITH-02 | SLT/SLTU signed/unsigned boundary matrix | directed + F |
| CPU-SHIFT-01 | Shifts by 0, 1, 31; iterative-shifter cycle count == shamt | directed + F |
| CPU-IMM-01 | LUI/AUIPC/immediates: sign extension, U-type alignment | random + F |
| CPU-BR-01 | All branches taken/not-taken × forward/backward targets | random + F |
| CPU-JMP-01 | JAL/JALR incl. rd=x0, target misalignment → trap | directed + F |
| CPU-LS-01 | LB/LBU/LH/LHU/LW/SB/SH/SW all byte lanes, sign/zero extension | directed + F |
| CPU-LS-02 | Misaligned load/store/fetch → correct trap cause, no side effect | directed + F |
| CPU-RVE-01 | Opcodes referencing x16–x31 → illegal-instruction trap | directed |
| CPU-ILL-01 | Illegal/unimplemented opcodes (incl. MUL/DIV, FENCE.I handling as specced) → trap | random-illegal + F |
| CPU-X0-01 | x0 never written, reads as 0 (all instruction classes) | F |

### 3.2 Privilege, traps, CSRs

| ID | Testpoint | Method |
|---|---|---|
| PRV-TRAP-01 | Every mcause in ARCHITECTURE §5.3 reachable; mepc/mcause/mstatus stack correct | directed |
| PRV-TRAP-02 | mret: MPP/MPIE/MIE restore semantics, return to U and to M | directed + F |
| PRV-CSR-01 | CSR RW/RS/RC ops on every implemented CSR; WARL fields hold legal values only (mtvec alignment, MPP∈{00,11}) | directed |
| PRV-CSR-02 | Unimplemented CSR access → illegal-instruction trap | random |
| PRV-CSR-03 | CSR access from U-mode → trap (machine CSRs) | directed |
| PRV-INT-01 | Timer + external interrupt: taken only when MIE/mie allow; mip reflects lines; priority vs. sync exceptions | directed |
| PRV-INT-02 | Interrupt arrival in every core FSM state (fetch-wait, exec, mem-wait) — taken at retire boundary only | random-irq injection |
| PRV-ECALL-01 | ecall from M and from U → distinct causes | directed |

### 3.3 PMP

| ID | Testpoint | Method |
|---|---|---|
| PMP-MATCH-01 | NAPOT decode: region sizes 1 KiB → 4 GiB, address inside/outside/boundary ±4 | directed sweep |
| PMP-PERM-01 | Full R/W/X × U-mode access-type matrix per entry (deny → correct fault cause) | directed |
| PMP-PRIO-01 | Overlapping entries: lowest-numbered wins (incl. deny-over-allow both orders) | directed |
| PMP-MMODE-01 | M-mode ignores unlocked entries; locked entry enforces on M-mode | directed |
| PMP-LOCK-01 | Locked cfg/addr writes ignored until reset; lock survives U↔M transitions | directed |
| PMP-WARL-01 | TOR/NA4 writes read back as OFF; grain bits read-as-ones under NAPOT | directed |
| PMP-U-NOMATCH-01 | U-mode access with no matching entry → fault | directed + F |
| PMP-SIDE-01 | **Denied access produces no bus transaction** (no MMIO side effect) | SVA assertion, all sims |

### 3.4 Core microarchitecture invariants (formal-first)

| ID | Invariant | Method |
|---|---|---|
| UAR-FSM-01 | Core FSM: no unreachable/illegal state; encoded-state parity holds or fault trap fires | F + fault-injection sim |
| UAR-BUS-01 | Exactly one outstanding transaction; valid stable until ready | SVA |
| UAR-RVFI-01 | riscv-formal insn/reg/PC/mem channel consistency (catches whole bug classes) | F |
| UAR-TIME-01 | Instruction never retires twice / lost on trap | F |
| CPU-FWD-01 | 5-stage core: an EX operand is the architectural value under every forwarding path, **including while EX is held across a data-bus stall** | F (`reg_ch0`) + directed `fwd_stall` with `+fastmem` |
| CPU-SER-01 | 5-stage core: SYSTEM (CSR/MRET/ECALL/EBREAK/WFI) is serialized and the pipeline is flushed behind it, so no instruction executes under a stale privilege or PMP configuration | directed `csr_warl` / `traps_sys` + `mmode_safe` formal env |

**Note on the two cores (P2).** `rtl/core/core.v` (multicycle) and
`rtl/core/core_p5.v` (5-stage) implement the same architecture and are held to
the same bar: both run the whole of §3.1–§3.3 against the same ISS, and both
have a riscv-formal config (`dv/formal/tinytrust`, `dv/formal/tinytrust_p5`)
that must close 44/44. The pipeline adds CPU-FWD-01 and CPU-SER-01, which have
no multicycle equivalent — nothing is ever in flight there to forward to or
overtake.

## 4. Feature → testpoint matrix: blocks & SoC (L1/L3)

### 4.1 Secure boot (SoC-critical; ROM is unpatchable)

| ID | Testpoint | Method |
|---|---|---|
| BOOT-OK-01 | Golden image boots: BOOT_OK pin, PMP entry 0 locked over ROM, entry at correct flash offset | cocotb |
| BOOT-TAMPER-01 | Each of: 1-bit flip in image body / header length / stored digest → refuse boot, ALERT high, WFI loop | cocotb sweep |
| BOOT-TAMPER-02 | Truncated image, length = 0, length > flash window → clean rejection (no hang, no overflow) | cocotb |
| BOOT-DEV-01 | DEV strap: verification skipped, distinct BOOT_OK blink pattern; strap sampled once — toggling after sample has no effect | cocotb |
| BOOT-ROMLOCK-01 | Post-boot: fetch/load from ROM region faults (M and U) | cocotb |
| BOOT-ROM-EXH-01 | ROM code: every branch path executed; instruction-level co-sim vs. Python model of boot flow | dedicated TB, 100 % path cov |
| BOOT-HASH-01 | ROM's ASCON sequencing computes Ascon-Hash256 == pyascon on 3 image sizes (incl. non-multiple-of-rate) | cocotb + pyascon |

### 4.2 QSPI XIP controller

| ID | Testpoint | Method |
|---|---|---|
| QSPI-READ-01 | 1-bit SPI read + quad fast-read + continuous-read entry/exit vs. flash model | cocotb |
| QSPI-SEQ-01 | Sequential fetch burst uses continuous mode (cycle-count budget assertion) | cocotb |
| QSPI-PSRAM-01 | PSRAM word R/W all byte strobes; flash/PSRAM CS never both active | cocotb + SVA |
| QSPI-DIRECT-01 | Bit-bang mode: JEDEC-ID read sequence; regains XIP after | cocotb |
| QSPI-ABORT-01 | Trap/PMP-deny during fetch: no wedged transaction | random |

### 4.3 ASCON block (extends passing KAT suite)

| ID | Testpoint | Method |
|---|---|---|
| ASC-KAT-01 | ☑ 66/66 permutation KATs vs. pyascon (zero/ones/random × 6/8/12 rounds) | done 2026-07-14 |
| ASC-IF-01 | Write/read while busy: ignored/safe; state unchanged by reads | directed |
| ASC-IF-02 | rounds ∈ {0 (no-op), 13–15 (clamp to 12)} WARL behavior | directed |
| ASC-IF-03 | busy cycle count == effective rounds, back-to-back starts | directed |
| ASC-HASH-01 | Software-sequenced Ascon-Hash256 (firmware C) matches pyascon on NIST message-length sweep 0–1024 B | SoC-level |
| ASC-UVM-01 | UVM env: constrained-random transactions, scoreboard vs. reference, covergroups closed | UVM track |

### 4.4 Peripherals, SEC, fault hardening

| ID | Testpoint | Method |
|---|---|---|
| UART-01 | TX/RX loopback all byte values, baud divisor min/max, RX overflow flag | cocotb |
| TIME-01 | mtime wrap, mtimecmp equality/past-value semantics, MTIP set/clear | directed |
| SEC-01 | STATUS reflects boot stage + straps; ALERT is W1S and never clears except reset | directed |
| FLT-01 | Forced FSM-state corruption (sim force) → fault trap + sticky ALERT within N cycles | fault-injection sim |
| GPIO-01 | OUT/IN paths, pin-map conformance to ARCHITECTURE §3 | cocotb |

### 4.5 Caches (P3)

| ID | Testpoint | Method |
|---|---|---|
| CACHE-HIT-01 | A hit is served without any memory-side transfer; a read hit returns the resident data | `dv/cache` directed + beat counting |
| CACHE-MISS-01 | A cold miss refills exactly one 64 B line (16 beats) and the line is then resident | `dv/cache` directed |
| CACHE-WB-01 | Evicting a dirty line writes it back before the refill (32 beats), and the data is recoverable afterwards | `dv/cache` directed + phase-3 read-back sweep |
| CACHE-BM-01 | Partial writes (SB/SH) go through the macro's per-bit mask with no read-modify-write | `dv/cache` directed |
| CACHE-UNC-01 | Addresses at or above CACHEABLE_LIMIT bypass the cache every time and are never cached | `dv/cache` directed + beat counting |
| CACHE-FLT-01 | A bus fault during refill propagates to the core and leaves no valid line behind | `dv/cache` directed |
| CACHE-FV-01 | **The cache is transparent: a read returns the last value written to that address** | F (`dv/formal/cache`, one-address abstraction) |
| CACHE-SYS-01 | Core + I$ + D$ retire an identical instruction stream to the no-cache configuration | ISS lockstep, 4th regression leg |

**Note on what the existing suites could not measure.** Every directed and
random program in `dv/core_iss` is straight-line code executed once, which is
the worst case for a cache: a 64 B line pulls in 16 instructions used exactly
once, so an I$ can only match a plain fetch stream, never beat it. P3 therefore
added `loop_bench`, a nested loop whose hot body is one cache line and whose
working set fits the D$ — the only program in the suite with temporal locality,
and the one the P3 CPI figure is quoted on. Correctness was never the gap here;
the gap was that the workload could not exhibit the property being built.

**Note on the formal boundary (D22).** The cache is *not* folded into the
core's riscv-formal wrapper. The core keeps its own 44/44 at its own ports, and
the cache is proven separately against CACHE-FV-01. Rationale and the measured
proof-cost argument are in RETARGET.md D22 and §9.3.

## 5. Coverage model

**Code coverage** (Verilator, CI): line ≥ 95 %, toggle ≥ 90 % on rtl/ —
waivers documented per line with rationale (e.g. defensive defaults).

**Functional coverage** (cocotb-coverage / UVM covergroups):
- Instruction class × source-register-equal-destination × operand-sign cross
- Trap cause × privilege × core-FSM-state-at-trap cross
- PMP: entry × permission × access-type × M/U × locked cross (the full cube)
- ASCON: rounds value × start-while-busy × word-access pattern
- QSPI: mode × burst length × abort-point
- Boot: image size mod rate × tamper location bins

**Closure rule:** a coverage hole is either hit by a new test or waived in
writing here — never silently accepted.

## 6. Regression & CI

- `dv/regress.ps1` (local): ascon_kat + core directed + smoke SoC test; must
  pass before every commit touching rtl/ or rom/. The core leg runs three
  configurations — multicycle, 5-stage, and 5-stage with `+fastmem` — because
  the first two share a timing shape that makes some pipeline states
  unreachable (BUG-005): through the timed memory model a fetch costs at least
  three cycles, so consecutive instructions are never closer than three
  pipeline stages apart. `+fastmem` makes the instruction port zero-wait-state
  while leaving the data port timed, which is both the state space the timed
  model cannot reach and a preview of the I$ timing arriving at P3.
- GitHub Actions (on push): full matrix — Icarus directed suites, Verilator
  coverage build, riscv-formal SBY jobs, random-stream co-sim (Spike),
  nightly long-random seed sweep. Badge in README.
- Every regression failure gets an issue before it gets a fix.

## 7. Bug tracking discipline

GitHub issues, label `bug/rtl`, `bug/tb`, `bug/spec`. Mandatory fields:
symptom, root cause (5-whys depth), fix commit, **regression test added**
(issue may not close without one), found-by (which method — feeds the
"which techniques actually caught bugs" retrospective, prime interview
material).

## 8. Milestone exit criteria

| Milestone | Exit criteria (all mandatory) |
|---|---|
| **M1** core ISA-complete | §3.1 + UAR-* green; riscv-formal clean at depth ≥ 20; 1 M random instructions vs. ISS zero-mismatch; RVFI port in RTL |
| **M2** privilege+PMP | §3.2 + §3.3 green; PMP functional-coverage cube closed; formal PMP invariants proven |
| **M3** secure boot | §4.1 + §4.3 green incl. ROM 100 % path coverage; tamper sweep ≥ 1000 randomized corruptions, zero false-accepts |
| **M4** SoC/FPGA | §4.2 + §4.4 green; full boot demo in sim **and** on FPGA; code coverage targets met |
| **M5** tape-out gate | All testpoints ☑ or waived; nightly regression green 14 consecutive days; GL sim (SDF) boot smoke passes; TT precheck clean; zero open `bug/rtl` issues |

## 9. Open risks

| Risk | Mitigation |
|---|---|
| riscv-formal RV32E support gaps | RVFI is standard; constrain checks to x0–x15; upstream issues early at M1 start |
| Icarus/Verilator SVA support is partial | Keep SVA simple (immediate + bounded); duplicate critical invariants as cocotb checks |
| UVM simulator access | Parallel track, not tape-out-gating |
| Python ISS correctness (local co-sim) | ISS itself validated against Spike in CI before trusted locally |
