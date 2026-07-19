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
