# Bug log

Every test failure gets written up here before it gets fixed
([VPLAN.md](VPLAN.md) §7). Each entry records the symptom, the root cause, the
fix, the test added to stop it coming back, and **found-by** — which method
actually caught it, because that is the question worth answering at the end.

---

## BUG-001 — memory protection read the mode field from the wrong bits

- **Status:** fixed
- **Type:** design bug
- **Symptom:** writing `0x1F` to the protection config register read back as
  `0x07`. The mode had been silently changed from "region of a given size" to
  "off", while the read/write/execute permission bits came back correctly. The
  only values that could switch the mode on were ones that happened to have
  bits [5:4] set to 11. Found as a disagreement against the reference model in
  the directed test `csr_warl` and again in the random stream `rand2`, both
  times on the value read back.
- **Root cause:** `pmp.v` pulled the mode field out with
  `csr_wdata[i*8+4 +: 2]` — bits [5:4] of the config byte — when the RISC-V
  specification puts it at bits [4:3], which is `csr_wdata[i*8+3 +: 2]`. Why it
  survived until then: `pmp.v` had only ever been run through synthesis for an
  area estimate, never simulated. That is exactly the gap the block-level
  testing layer exists to close. The read-back path was correct, so looking at
  either side on its own showed nothing wrong.
- **Fix:** correct the bit positions.
- **Test added:** `csr_warl` in `dv/core_iss` — write and read back every mode,
  check that unsupported modes read as "off" and that the size bits read as
  ones — plus a random template that exercises the control registers.
- **Found-by:** running against the reference model, in the very first random
  session. A point for the rule that the reference model is written from the
  specification and never from our own design — a model built by reading
  `pmp.v` would have made the same mistake and agreed with it.

---

## BUG-002 — the proof setup allowed memory errors the instruction spec cannot describe

- **Status:** fixed
- **Type:** proof-setup bug. The design was correct in every counterexample —
  the environment was under-constrained, not the hardware.
- **Symptom:** on the first riscv-formal run, all 8 memory-instruction checks
  out of 44 failed at 25 cycles, while arithmetic, branch and jump checks all
  passed. Each counterexample was an ordinary, properly aligned load or store
  which the specification says should not trap, while the processor reported a
  trap with cause 5 or 7 (load or store access fault). That one disagreement
  then dragged down every dependent check with it.
- **Root cause — two separate sources of surprising-but-correct traps.** Both
  are legal processor behaviour that the standard instruction models cannot
  predict, because those models assume an ideal memory with no restrictions.
  1. **Bus errors.** The setup left the "memory returned an error" signal free
     for the solver to choose, so it set it during a data transfer, and the
     processor correctly took an access fault. Counterexample: `lw x0,-16(x0)`
     in machine mode with the error signal set, giving cause 5.
  2. **Protection denial.** Even with bus errors switched off, the checks were
     *still* failing — and this is where the reporting bug in BUG-003 hid the
     truth for several rounds. The solver would write a locked, denying
     protection entry, or return to user mode where nothing granted access, and
     the processor would correctly refuse. Counterexample: `csrrw x2,pmpcfg0,x2`
     and later `lb x14,947(x0)` in machine mode with permission denied, cause 5.
     riscv-formal has no model of memory protection, so once again a correct
     trap looked like a disagreement.
- **Fix — two assumptions in `dv/formal/tinytrust/wrapper.sv`:**
  - Assume the memory never returns an error, confining the proof to
    fault-free memory.
  - Assume the instruction stream never contains a return-from-trap
    (`32'h30200073`) or a write to the protection registers `pmpcfg0` or
    `pmpaddr0` through `pmpaddr3`. Out of reset the processor is in machine
    mode with protection off, where every access is permitted, and those two
    instruction types are the *only* ways to leave that state. Blocking them
    keeps every access permitted **by construction**.

  A first attempt assumed the internal permission signal directly, and that was
  a dead end: yosys does not support reaching into a module from outside, and
  silently turned the reference into a wire with nothing driving it, so the
  assumption constrained nothing at all. The lesson is to constrain the
  instruction stream, which the setup really does drive, rather than an
  internal signal.
- **Result:** all 8 memory checks genuinely pass, and the full suite is 44/44.
  Solve times actually dropped, because the extra assumptions shrink the space
  the solver has to search.
- **Test added:** the memory checks themselves. The behaviour deliberately kept
  in simulation rather than proof: errors producing precise traps (`ls_fault`
  for causes 5 and 7, `fetch_fault` for cause 1) and the protection allow/deny
  matrix, all compared against the reference model.
- **Found-by:** the first riscv-formal session. These gaps were invisible to
  inspection precisely because every behaviour they flagged was itself correct.
  You only see them by running the tool and reading the counterexample.

---

## BUG-003 — the proof reporter turned failures into passes

- **Status:** fixed
- **Type:** tooling bug, and the worst kind — a **false green**, which hides
  real failures.
- **Symptom:** `runchecks.py` printed `PASS` for checks that had written
  `FAIL` and a counterexample to disk at the same moment. This masked the
  protection half of BUG-002 for several rounds: the bus-error fix was believed
  complete when the checks were in fact still failing.
- **Root cause:** the check generator writes every configuration with
  `expect pass,fail`, which tells the tool that a counterexample is an
  *acceptable* outcome, so it exits with status 0. `run_check()` read the real
  verdict correctly from the tool's `DONE (FAIL, rc=0)` line, and then threw it
  away: `if r.returncode == 0: status = "PASS"`. **The exit code is not the
  verdict here.**
- **Fix — `dv/formal/runchecks.py`:** drop the exit-code override and trust the
  `DONE (STATUS, …)` line. A missing `DONE` line, meaning the tool crashed or
  was killed, stays an error rather than becoming a pass.
- **Test added:** re-ran the suite against a known-failing check and confirmed
  the reporter now prints `FAIL`, matching the per-check status files on disk,
  which had been correct all along. 44/44 is now only reported when every check
  genuinely passes.
- **Found-by:** comparing the printed summary against the status files on disk
  after a killed run left both visible. The lesson: a pass/fail reporter must
  key on the tool's own verdict, never its exit code, whenever a setting can
  make failure a zero-exit outcome.

---

## BUG-004 — arithmetic right shift became a logical shift in the pipelined core

- **Status:** fixed
- **Type:** design bug, but caused by language rules rather than a mistake in
  the intent. The idea was right and the operator was right; Verilog's typing
  rules quietly changed what the operator meant.
- **Symptom:** on the first comparison run of the pipelined core, 3 of 16
  directed tests failed (`arith_r`, `shift_imm`, `rvi`), and every disagreement
  was an arithmetic right shift on a negative number. `SRAI x6, x8, 1` with
  `x8 = 0x80000000` produced `0x40000000` where the reference model said
  `0xC0000000` — the sign bit was not being copied down. Everything else
  passed, including logical shifts and the signed comparisons.
- **Root cause:** the arithmetic unit wrote the shift as one expression:

  ```verilog
  alu_res = e_insn[30] ? ($signed(ex_rs1) >>> shamt) : (ex_rs1 >> shamt);
  ```

  In Verilog, the two branches of a conditional are brought to a common type,
  and if *either* side is unsigned the whole expression becomes unsigned — and
  that unsignedness then propagates **back down into the operands**. So the
  unsigned logical shift on the right forced the `$signed()` on the left back
  to unsigned, and `>>>` applied to an unsigned value is defined as a *logical*
  shift. The `$signed()` cast was still sitting there, still perfectly
  readable, and doing nothing at all.

  Why the signed comparisons in the same file survived: they sit inside a
  concatenation, `{31'd0, ($signed(a) < $signed(b))}`, where each operand is
  evaluated on its own, so there was no unsigned neighbour to demote them.

  Why the simple core never had it: it shifts one bit per cycle with the sign
  bit spliced in by hand, `{instr[30] & result[31], result[31:1]}`. No `>>>`,
  so no typing rule to fall foul of. The bug arrived with the pipelined core's
  barrel shifter.
- **Fix — `rtl/core/core_p5.v`:** compute the arithmetic shift in its own
  signed wire, `wire signed [31:0] sra_res = $signed(ex_rs1) >>> shamt;`, where
  the assignment context is signed and nothing can demote it, then select that
  wire in the conditional. A comment at the site records why the obvious inline
  version is wrong.
- **Test added:** the directed tests that caught it, plus the riscv-formal
  shift checks, which prove it for *all* operands rather than the sampled ones.
- **Found-by:** the reference-model comparison, on the very first run of the
  pipelined core, before it had seen a single proof. Same lesson as BUG-001:
  the reference model was written from the specification, so it had no reason
  to make the same mistake. Worth noting that a directed test using only
  positive numbers would have passed — `arith_r` covers negative operands
  because the test generators build from value classes that include
  sign-bit-set patterns.

---

## BUG-005 — the pipelined core lost a forwarded value when memory stalled

- **Status:** fixed
- **Type:** real design bug, and also a testing-environment finding, because
  the simulation could not reach the failing state at all.
- **Symptom:** the `reg_ch0` proof failed for the pipelined core at cycle 30
  (42/44 passing). The counterexample: instruction `0xb` writes `x15` with
  `0x40000490`; instruction `0xc` is a store; instruction `0xd` reads `x15` and
  reports `0x40000090`, while the check's own copy holds `0x40000490`. Every
  directed and random comparison test passed, before and after, across more
  than 40,000 instructions.
- **Root cause.** When one instruction needs a value another has just produced,
  the pipeline "forwards" it directly instead of waiting for it to reach the
  register file. The forwarding logic took its signal from `w_valid`, a pulse
  that lasts exactly one cycle. That is only correct if an instruction spends
  exactly one cycle in the execute stage. It does not:
  1. A consumer enters execute on the same cycle its producer is in write-back.
     The consumer read the register file one cycle before the producer wrote
     it, so it *must* take the forwarded value.
  2. If the instruction between them is a load or a store, the memory stage
     stalls for the whole length of the memory transaction, and nothing
     advances.
  3. The consumer is therefore stuck in execute for the whole transaction, but
     `w_valid` is cleared on the very next cycle regardless.
  4. The consumer captures its operands at the *end* of the stall, by which
     time the forwarded value is long gone, so it captures the stale value it
     originally read.

  Why the register file's write-through did not save it: write-through covers a
  producer three slots ahead — one writing on the cycle the consumer reads —
  not one writing the cycle after.
- **Fix — `rtl/core/core_p5.v`:** separate "an instruction just finished" from
  "this value is still available to forward". `w_valid` stays a one-cycle
  pulse, since it drives the reporting interface and the register write. A new
  signal, `w_fwd_live`, is updated only when the memory stage advances, so it
  holds the last completed result for exactly as long as the pipeline is
  stalled. Nothing can reach write-back while memory is stalled, so
  `w_fwd_live` always names the most recent register write — which is what
  makes forwarding from it correct at any point during the hold.
- **Test added — two parts, and the second is the important one.**
  1. The directed test `fwd_stall`: a producer, then one memory instruction,
     then a consumer — for every kind of consumer that captures an operand, and
     with the middle instruction as both a load and a store.
  2. A fast-fetch mode, and a third configuration in the test runner. **The
     directed test alone is not enough, because it passes on the broken
     design.** With the timed memory model a fetch always takes at least three
     cycles, so consecutive instructions are never closer than three pipeline
     stages apart, and the failing arrangement is *structurally unreachable* in
     simulation. Fast-fetch mode makes instruction fetch instant while leaving
     data accesses timed — instructions pack together, memory still stalls.
     Verified in both directions: on the pre-fix design, `fwd_stall` passes
     with the timed model and fails at instruction 9 with fast fetch.
- **Found-by:** the `reg_ch0` proof, on the first full run of the pipelined
  core. This is the strongest argument for formal proof in the project so far.
  More than 40,000 co-simulated instructions could not have found it — not
  because the tests were unlucky, but because the testbench's own timing made
  the state impossible to reach. The proof tool treats memory timing as a free
  choice and so explores schedules the simulation never produces.

  The second lesson is about coverage of the *environment* rather than the
  design: a testbench whose timing is always the same shape hides part of the
  state space. The fix was to let the environment reach it — which is also
  exactly the timing an instruction cache produces, so this bug would otherwise
  have appeared later as a regression in already-signed-off hardware.

---

## BUG-006 — the cache proof runner would have reported a counterexample as success

- **Status:** fixed
- **Type:** tooling bug. The same **false green** as BUG-003, reintroduced in a
  different runner.
- **Symptom:** none observed, because the caches were in fact correct. That is
  the problem. `dv/formal/cache/run.ps1` decides pass or fail from the exit
  code, and both cache configurations carried `expect pass,fail`. The tool
  treats an expected failure as a clean exit, so a genuine counterexample would
  have exited 0 and been reported as a passing suite.
- **Root cause:** BUG-003 recorded exactly this lesson — "exit code is not the
  verdict" — and fixed it in `runchecks.py` by reading the tool's own verdict
  line. The cache runner was written later, for the cache milestone, and worked
  out pass/fail from the exit code again, bringing the same trap back by a
  different route. **A buglog entry does not protect the next file someone
  writes.** That is the real failure here.
- **Fix — `icache.sby`, `dcache.sby`:** change `expect pass,fail` to
  `expect pass`, so a failure becomes an *unexpected* outcome and the tool
  exits non-zero. Each file carries a comment pointing back at the
  `runchecks.py` note, so the reasoning sits next to the setting rather than
  only in this log.
- **Test added:** the default suite runs green with the corrected settings, and
  the mechanism was seen working during later work — a run with `expect pass`
  that hit a genuine counterexample exited 2, not 0.
- **Found-by:** reading `runchecks.py`'s own comment while picking up the open
  cache proof. Not by any failing test, which is consistent with the type.

---

## BUG-007 — the check that catches meaningless proofs had never run

- **Status:** fixed
- **Type:** testing-environment bug. A proof that could have been empty and
  would still have looked green.
- **Symptom:** none observed; the proofs reported normally.
- **Root cause:** `cache_fv.sv` ends with a `cover` statement whose own comment
  says the proof is worthless if the test cannot even complete a read of the
  address being tracked. Both configurations run in `mode bmc`, and the tool
  evaluates `cover` statements **only** in `mode cover`. So that safeguard was
  dead code from the day it was written.

  This matters rather than being a formality. The setup assumes the processor
  holds requests steady, that memory answers within two cycles, and that the
  tracked address is cacheable. If those assumptions were too strong, they
  could make the proof vacuously true — it would pass by never reaching the
  interesting case at all, and nothing in the result would say so.
- **Fix — new `icache_cover.sby` and `dcache_cover.sby`:** run the same design
  in `mode cover`, using a different engine because `abc` rejects cover mode
  outright. `run.ps1` runs both parts by default, and VPLAN §4.5 now states
  that a bounded proof without a matching cover run is not a result.
- **Test added:** both reach the read at step 9, in about a second, and the
  cover runs are part of the default suite, so the safeguard cannot silently
  stop running again.
- **Found-by:** reading the setup while picking up the open cache proof.

---

## BUG-008 — the data cache proof looked less far ahead than the behaviour it was checking

- **Status:** the bound is fixed; the proof itself is still open — see
  RETARGET.md §10.5
- **Type:** testing-environment bug. A proof that would have been perfectly
  sound and very nearly meaningless.
- **Symptom:** `dcache.sby` was set to look 26 cycles ahead and was understood
  to cover the cache's write-back behaviour. It cannot. The sequence the
  property actually turns on — write to a line, push it out, write it back to
  memory, then read it again — is first reachable at **step 28**.
- **Root cause:** the bound was chosen by working it out on paper. At the
  reduced size used for proofs a line fetch takes 4 transfers, so the whole
  sequence was estimated to fit in about 25 cycles. The estimate was 21. The
  measured answer is 28. Nothing in a passing result would ever reveal the gap:
  a pass at 26 cycles would have been entirely valid, and would have covered
  ordinary fetches and write hits while never once reaching an eviction, which
  is the behaviour the property exists to check.
- **Fix — `cache_fv.sv`, `dcache.sby`, `dcache_cover.sby`:** state the sequence
  as a `cover` statement, so the bound is justified by measurement rather than
  by estimate. `dcache.sby` now carries 28, the measured minimum, and is
  excluded from the default suite rather than left looking green at a bound
  that asks the wrong question.
- **Test added:** `dcache_cover.sby` runs to 32 cycles and reaches both cover
  points. If the eviction one ever stops being reachable, the bound is wrong
  again and the suite says so instead of passing quietly.
- **Found-by:** adding the cover from BUG-007 and then asking the same question
  of the data cache — does the bound actually reach the thing being proven? —
  which had not been asked of either cache.
