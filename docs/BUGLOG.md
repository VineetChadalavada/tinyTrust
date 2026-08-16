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
