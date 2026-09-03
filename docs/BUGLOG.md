# TinyTrust bug log

Per VPLAN §7: every regression failure gets an entry before it gets a fix.
Mandatory fields: symptom, root cause, fix commit, regression test, found-by.
(Local mirror of the issue-tracker discipline until the repo has a remote.)

---

## BUG-001 — pmpcfg A-field written from the wrong bit positions

- **Status:** fixed
- **Label:** bug/rtl
- **Symptom:** writing `pmpcfg0 = 0x1F` (NAPOT + XWR) reads back `0x07`
  (OFF + XWR); NAPOT entries can only be enabled by values that happen to
  have bits [5:4] = 11. Found as a co-sim mismatch in `csr_warl` (directed)
  and `rand2` (random stream), first mismatch on the CSR read-back value.
- **Root cause (5 whys):** `pmp.v` extracted the A field with
  `csr_wdata[i*8+4 +: 2]` (bits [5:4] of the cfg byte) instead of
  `csr_wdata[i*8+3 +: 2]` (bits [4:3], where the privileged spec puts A).
  Why not caught earlier: pmp.v had only been *synthesized* (area
  calibration) and never simulated — exactly the gap the vplan's
  block-level layer exists to close. The read-back mux was correct, so the
  bug was invisible to inspection of either side alone.
- **Fix commit:** (this commit)
- **Regression test:** `dv/core_iss` `csr_warl` (NAPOT write/read-back,
  TOR/NA4-write-as-OFF, grain-bits-read-as-ones) + random CSR template.
- **Found-by:** ISS lockstep co-sim (L2), first random-stream session.
  Score one for the reference-model rule (ISS written from spec, not RTL).

---

## BUG-002 — formal wrapper let the memory environment take faults the base spec can't model; all load/store insn checks red

- **Status:** fixed
- **Label:** bug/formal-harness (DUT was correct on every counterexample —
  this is an environment under-constraint, not an RTL defect)
- **Symptom:** on first riscv-formal run, every memory instruction check
  (`insn_lb/lbu/lh/lhu/lw/sb/sh/sw`, 8 of 44) failed at BMC depth 25 while
  the ALU/branch/jump checks passed. Each counterexample is a legal aligned
  load/store that the spec scores `spec_trap=0`, while the core retires
  `rvfi_trap=1` with `mcause=5/7` (load/store access fault) — the mismatch
  `spec_trap != trap` drags the dependent pc_wdata/mem_addr/mask asserts down
  with it.
- **Root cause — TWO independent surprising-trap sources, both legal core
  behavior the base `insn_*` models cannot predict (they assume an ideal,
  unrestricted memory):**
  1. **Bus fault.** The wrapper declared `` `rvformal_rand_reg bus_fault ``
     free, so the solver injects `bus_fault=1` on the data beat; the core
     correctly takes a precise access fault. Counterexample: `lw x0,-16(x0)`,
     M-mode, `bus_fault=1`, `mcause=5`.
  2. **PMP / privilege deny.** Even with bus faults tied off, the checks were
     *still* red (this is where the reporting bug in BUG-003 first hid the
     truth). The solver drives a `csrrw pmpcfg0` to install a locked, denying
     PMP entry — or an `mret` into U-mode where no entry grants access — and
     the core correctly access-faults. Counterexample: `csrrw x2,pmpcfg0,x2`
     … later `lb x14,947(x0)`, M-mode, `pmp_allow=0` during `S_MEM`,
     `mcause=5`. riscv-formal has no PMP/privilege model, so again a correct
     trap reads as a spec mismatch.
- **Fix (this commit) — `dv/formal/tinytrust/wrapper.sv`, two assumptions:**
  - `always @* assume (!bus_fault);` — confines the proof to fault-free
    memory.
  - a `mmode_safe` **fetch** assumption forbidding `mret` (`32'h30200073`)
    and any CSR write to `pmpcfg0`/`pmpaddr0..3`. From reset the core is
    M-mode with PMP OFF, where `pmp_allow==1` for every access; those two
    instruction classes are the *only* ways to leave that state, so blocking
    them at fetch keeps every access permitted **by construction**. (First
    attempt `assume (uut.pmp_allow)` was a dead end: yosys `read_verilog` has
    no hierarchical references and silently turned `uut.pmp_allow` into an
    undriven wire — "Identifier implicitly declared / used but has no driver"
    — so the assume constrained nothing. Constrain the fetch stream, which the
    wrapper actually drives, not an internal net.)
- **Result:** all 8 load/store checks now genuinely PASS; full suite 44/44
  green (verified with the BUG-003 reporting fix in place — solve times even
  dropped, the extra assumptions shrink the state space).
- **Regression test:** the riscv-formal `insn_l*`/`insn_s*` checks themselves
  (now PASS). The complementary behaviors deliberately kept in *sim*, not
  formal: fault→precise-trap (`dv/core_iss` `ls_fault` cause 5/7 +
  `fetch_fault` cause 1) and PMP/privilege allow-deny (vplan §3.2/§3.3
  PMP-*/PRV-* directed tests + co-sim), all ISS lockstep.
- **Found-by:** first riscv-formal bring-up session (L2 formal leg). The
  harness gaps were invisible to inspection because every DUT behavior they
  flagged was itself correct — you only see them by running the tool and
  reading the counterexample.

---

## BUG-003 — runchecks.py reported failing formal checks as PASS

- **Status:** fixed
- **Label:** bug/tooling (verification infrastructure — a *false green*, the
  worst kind: it hides real red)
- **Symptom:** `runchecks.py` printed `PASS insn_lb_ch0` etc. while the same
  checks had written `FAIL` and a counterexample trace to disk. Masked the
  BUG-002 PMP/privilege half for several iterations — the bus_fault fix was
  believed complete when the checks were in fact still failing.
- **Root cause:** genchecks emits every check with `expect pass,fail` in the
  `.sby` `[options]`, so SBY treats a real counterexample as an *expected*
  outcome and exits **0**. `run_check()` parsed the true verdict from SBY's
  `DONE (FAIL, rc=0)` line but then overwrote it: `if r.returncode == 0:
  status = "PASS"`. Exit code is not the verdict here.
- **Fix (this commit) — `dv/formal/runchecks.py`:** drop the returncode
  override; trust the `DONE (STATUS, …)` line (PASS/FAIL/UNKNOWN/ERROR), with
  a missing DONE line (tool crash/kill) staying ERROR.
- **Regression test:** re-ran the suite pre-fix-verification — the fixed
  reporter now prints `FAIL` for a known-red check (confirmed against the
  on-disk `FAIL`/`PASS` status files, which were always correct) and 44/44
  only when every check truly passes.
- **Found-by:** cross-checking the printed summary against the on-disk
  per-check `status` files after a killed run left both visible. Lesson: a
  pass/fail reporter must key on the tool's semantic verdict, never its exit
  code, whenever `expect` can make failure a zero-exit outcome.

---

## BUG-004 — SRA/SRAI in the 5-stage core shifted logically, not arithmetically

- **Status:** fixed
- **Label:** bug/rtl (language semantics, not a design mistake — the intent
  was right and the operator was right; Verilog's typing rules quietly
  changed what the operator meant)
- **Symptom:** on the first lockstep run of `core_p5`, 3 of 16 directed tests
  failed (`arith_r`, `shift_imm`, `rvi`) and every mismatch was an SRA or
  SRAI on a negative operand. `SRAI x6, x8, 1` with `x8 = 0x80000000` retired
  `rd = 0x40000000` where the ISS said `0xC0000000`; the sign bit was not
  replicated. Every other instruction class passed, including SRL/SRLI and
  the signed compares SLT/SLTI/BLT/BGE.
- **Root cause (5 whys):** the ALU wrote the shift as
  `alu_res = e_insn[30] ? ($signed(ex_rs1) >>> shamt) : (ex_rs1 >> shamt);`
  In Verilog, a conditional expression's two arms are brought to a *common*
  type, and if either operand is unsigned the whole expression is unsigned —
  and that signedness then propagates **back down into the operands**. So
  `ex_rs1 >> shamt` (unsigned) forced `$signed(ex_rs1)` back to unsigned, and
  `>>>` on an unsigned operand is defined as a *logical* shift. The `$signed`
  cast was still there, still readable, and did nothing. Why the signed
  compares survived the same file: they sit inside a concatenation
  (`{31'd0, ($signed(a) < $signed(b))}`), where each operand is
  self-determined, so no unsigned sibling was there to demote them.
  Why it did not appear in the multicycle core: `core.v` shifts iteratively,
  one bit per cycle, with the sign bit spliced in explicitly
  (`{instr[30] & result[31], result[31:1]}`) — no `>>>`, so no typing rule to
  fall foul of. The bug was created by the P2 barrel shifter (D5 reversed).
- **Fix (this commit) — `rtl/core/core_p5.v`:** compute the arithmetic shift
  in its own signed wire, `wire signed [31:0] sra_res = $signed(ex_rs1) >>>
  shamt;`, where the assignment context is signed and nothing can demote it,
  and select it in the ternary. Comment at the site records why the obvious
  inline form is wrong.
- **Regression test:** existing `dv/core_iss` `arith_r` / `shift_imm` / `rvi`
  directed tests (which caught it), plus `insn_sra_ch0` / `insn_srai_ch0` in
  the riscv-formal suite, which prove it over all operands rather than the
  sampled ones.
- **Found-by:** ISS lockstep co-sim (L2) on the very first `core_p5` run —
  before the pipeline had seen a single formal check. Reinforces the same
  lesson as BUG-001: the golden model was written from the spec, so it had no
  reason to make the same mistake. Worth noting that a directed test that
  only shifted *positive* values would have passed; `arith_r` covers negative
  operands because the random/directed generators build from value classes
  that include sign-bit-set patterns.

---

## BUG-005 — 5-stage core lost the WB forward when a data access stalled MEM

- **Status:** fixed
- **Label:** bug/rtl (real design defect; also a verification-environment
  finding, because the simulation environment could not reach the state at
  all — see "found-by")
- **Symptom:** `reg_ch0` failed in the riscv-formal suite for `core_p5` at
  CHECK_CYCLE 30 (42/44 green). The counterexample: instruction order `0xb`
  writes **x15** = `0x40000490`; order `0xc` is `SH` (a store); order `0xd` is
  `BGEU` reading **x15** and reporting `rvfi_rs1_rdata = 0x40000090` while the
  check's shadow copy holds `0x40000490`. Every directed and random co-sim
  test passed, before and after, with 40k+ instructions.
- **Root cause (5 whys):** the EX forwarding network took its WB source from
  `w_valid`, the single-cycle retire pulse. That is correct only if an
  instruction spends exactly one cycle in EX. It does not:
  1. A consumer C enters EX on the same cycle its producer P is in WB — C read
     the register file in ID one cycle before P wrote it, so C *must* forward
     from WB.
  2. If the instruction between them is a load or store, MEM stalls for the
     length of the bus transaction, and `ex_advance = mem_advance = 0`.
  3. C is therefore pinned in EX for the whole transaction, but `w_valid` is
     cleared on the very next cycle (`else w_valid <= 1'b0`).
  4. C captures its operands into the EX/MEM register at the *end* of the
     stall, by which time the forward is long gone, so it captures the stale
     register-file read.
  Why the register file's write-through did not save it: write-through covers
  a producer three slots ahead (writing on the cycle C reads in ID), not one
  that writes the cycle after.
- **Fix (this commit) — `rtl/core/core_p5.v`:** split retire from
  forwardability. `w_valid` stays a one-cycle pulse (it drives RVFI and the
  register-file write enable); a new `w_fwd_live` is written only when MEM
  advances, so it holds the last committed result for exactly as long as the
  pipeline is stalled behind a data access. Because nothing can reach WB while
  MEM is stalled, `w_fwd_live` always names the most recent architectural
  register write, which is what makes forwarding from it correct at any point
  during the hold.
- **Regression test:** two parts, and the second is the important one.
  1. `dv/core_iss` directed test `fwd_stall` (CPU-FWD-01): producer, then one
     memory instruction, then a consumer of the producer — for every consumer
     form that captures an operand (ALU rs1/rs2, load base, store data, branch
     comparator, JALR target), with the middle instruction as both a load and
     a store.
  2. `+fastmem` in `tb_core.v`, plus a third leg in `run.ps1`. **The directed
     test alone is not enough: it passes on the broken RTL.** Through the
     timed memory model a fetch costs at least three cycles, so consecutive
     instructions are never closer than three pipeline stages apart, and the
     "producer in WB while consumer is pinned in EX" state is *structurally
     unreachable* in simulation. `+fastmem` makes the instruction port
     zero-wait-state while leaving the data port timed — fast fetch so
     instructions pack back to back, slow data so MEM still stalls. Verified
     both directions: on the pre-fix RTL `fwd_stall` passes with the timed
     model and fails at retire 9 with `+fastmem`.
- **Found-by:** riscv-formal `reg_ch0`, on the first full run of the 5-stage
  core. This is the clearest argument for the formal leg in the whole project
  so far: 40,000+ co-simulated instructions could not have found it, not
  because the stimulus was unlucky but because the testbench's own timing made
  the state unreachable. riscv-formal drives `ready` as a free variable and so
  explores bus schedules the model never produces. The second lesson is about
  coverage of the *environment*, not the design: a testbench whose timing is
  always the same shape hides state space, and the fix was to make the
  environment able to reach it — which is also exactly the timing an I$ will
  produce at P3, so the bug would otherwise have surfaced there as a
  regression in already-signed-off RTL.

---

## BUG-006 — cache formal suite would have reported a counterexample as PASS (recurrence of BUG-003)

- **Status:** fixed
- **Label:** bug/tooling (false green — the same class as BUG-003, reintroduced
  in a different runner)
- **Symptom:** none observed, because the caches were in fact correct. That is
  the problem: `dv/formal/cache/run.ps1` decides pass/fail from
  `$LASTEXITCODE`, and both cache `.sby` files carried `expect pass,fail`. SBY
  treats an *expected* FAIL as a clean exit, so a genuine cache counterexample
  would have exited 0 and been reported as a passing suite.
- **Root cause:** BUG-003 recorded exactly this lesson — "Exit code is not the
  verdict here" — and fixed it in `runchecks.py` by parsing the
  `DONE (STATUS, …)` line instead. `dv/formal/cache/run.ps1` was written later,
  for P3, and re-derived its own pass/fail from the exit code, reintroducing
  the trap by a different route. The lesson was recorded in this log but not in
  the code the next runner was copied from, which is the actual failure: a
  buglog entry does not defend the next file anyone writes.
- **Fix (`21c451e`) — `icache.sby`, `dcache.sby`:** `expect pass,fail` →
  `expect pass`, so a FAIL becomes an *unexpected* outcome and SBY exits
  nonzero. Each file carries a comment pointing at the `runchecks.py` note, so
  the reasoning is at the site of the setting rather than only in the log.
- **Regression test:** the default suite runs green (exit 0) with the corrected
  configs, and the mechanism was observed working during P4 groundwork: a
  `mode bmc` run with `expect pass` that hit a real counterexample exited 2,
  not 0.
- **Found-by:** reading `runchecks.py`'s own comment while picking up the open
  CACHE-FV-01 item — not by any failing test, which is consistent with the
  defect class.

---

## BUG-007 — the cache proofs' non-vacuity guard had never executed

- **Status:** fixed
- **Label:** bug/verification-environment (a proof that could have been vacuous
  and would have looked green)
- **Symptom:** none observed; the proofs reported normally.
- **Root cause:** `cache_fv.sv` ends with `cover (core_read)` under a comment
  stating that "the proof is worthless if the environment cannot even complete
  a read of the tracked word". Both `.sby` files are `mode bmc`, and SBY
  evaluates cover statements **only** in `mode cover` — so that guard was dead
  code from the day it was written. It matters here rather than being a
  formality: the harness assumes request stability, two-cycle bus fairness and
  a cacheable `chk_word`, and an over-constrained environment yielding a
  vacuous pass was a live possibility, not a theoretical one.
- **Fix (`21c451e`) — new `icache_cover.sby` / `dcache_cover.sby`:**
  `mode cover`, engine `smtbmc` (abc rejects cover mode outright:
  "Invalid engine 'abc' for cover mode"). `run.ps1` runs both legs by default,
  and VPLAN §4.5 now states that a bmc config without a matching cover run is
  not a result.
- **Regression test:** both reach `core_read` at step 9 in about a second, and
  the cover legs are in the default suite, so the guard cannot silently stop
  running again.
- **Found-by:** reading the harness while picking up the open CACHE-FV-01 item.

---

## BUG-008 — the D$ proof bound was below the depth at which the proven behaviour can occur

- **Status:** fixed as to the bound; the D$ proof itself remains open (see
  RETARGET.md §10.5)
- **Label:** bug/verification-environment (a proof that would have been sound
  and nearly meaningless)
- **Symptom:** `dcache.sby` was configured at depth 26 and understood to cover
  the cache's write-back behaviour. It cannot: the sequence the D$ property
  actually turns on — a writeback of the tracked word, then a core read of it —
  is first reachable at **step 28**.
- **Root cause:** the bound was chosen by arithmetic on paper. At the reduced
  geometry a refill is 4 beats, so the write-evict-writeback-refill-reread
  sequence was estimated to "fit in ~25 cycles"; the estimate was 21 and the
  measured answer is 28. Nothing in an assertion result exposes the gap — a
  PASS at 26 would have been perfectly sound, and would have covered refills
  and write hits and *never an eviction*, which is the behaviour the property
  exists to check.
- **Fix (`21c451e`) — `cache_fv.sv`, `dcache.sby`, `dcache_cover.sby`:** the
  sequence is stated as a cover (`wb_seen && core_read`, D$ only) so the bound
  is justified by measurement rather than by estimate; `dcache.sby` carries
  depth 28, the measured minimum, and is excluded from the default suite rather
  than left looking green at a bound that asks the wrong question.
- **Regression test:** `dcache_cover.sby` runs at depth 32 and reaches both
  covers. If the eviction cover ever stops being reachable, the bound is wrong
  again and the suite says so instead of passing quietly.
- **Found-by:** adding the cover from BUG-007 and then asking the same question
  of the D$ — "does the bound reach the thing being proven?" — which had not
  been asked of either cache.
