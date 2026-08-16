# dv/formal — riscv-formal harness (vplan L2, M1 exit gate)

Bounded formal checks of the core's RVFI stream using
[riscv-formal](https://github.com/YosysHQ/riscv-formal) + SBY (smtbmc/boolector
from the OSS CAD Suite; the deep `reg` check uses `abc bmc3` — see below).

## Usage

```powershell
.\run.ps1                    # clone (first time), genchecks, run all 44
.\run.ps1 -Filter insn_*     # subset
python runchecks.py --list   # enumerate generated checks
```

The riscv-formal clone and generated `checks/` are not committed; only
`tinytrust/` (wrapper + checks.cfg) and the runners are.

## What is checked, and how RV32E is handled

- `insn_*` (depth 25; shifts 60 for the 1-bit/cycle shifter), `reg`,
  `pc_fwd`/`pc_bwd`, `unique`, `causal`, `liveness`, `cover` — stock
  riscv-formal, `RISCV_FORMAL_ALIGNED_MEM` matching the core's RVFI memory
  convention.
- **RV32E gap: CLOSED (2026-08-16, docs/RETARGET.md D18).** The core is now
  RV32I, so the checks run as `rv32i` against a matching DUT with **no
  ISA-shaping assumption at all**. The former `rv32e_ok` wrapper assumption —
  fetched instructions never name x16..x31 in a field that is architecturally
  a register — is deleted. riscv-formal has no first-class rv32e profile
  (`MISA_E` exists in `insns/generate.py` but no `isa_rv32e.txt` is
  generated), which is what forced that workaround; going RV32I removes the
  mismatch at the source rather than assuming around it. Net effect: the
  proofs now cover the full 32-register space, a strict increase in verified
  state. Sim coverage of the high registers is `dv/core_iss` test `rvi`
  (CPU-RVI-01) plus the widened random generator.
- UAR-FSM-01 formal half: `assert (!fsm_fault)` lives in the wrapper, so
  every check also proves the FSM one-hot/privilege-shadow invariant at
  its depth.
- `reg` (register-file read/write consistency) runs at **CHECK_CYCLE 30**
  via **`abc bmc3` on a `memory_map`'d netlist**, not the smtbmc/boolector
  default. It does one monolithic BMC query at CHECK_CYCLE with the register
  file as an array; every SMT/BTOR engine (boolector, bitwuzla, btormc,
  yices) drowns in read-over-write lemma refinement past ~depth 30 — none
  closes CHECK_CYCLE 40 in <30 min. Expanding the array to flops and using
  pure incremental SAT (`abc bmc3`) closes CHECK_CYCLE 30 in ~9 min. The
  invariant holds at every depth tried; the 30-cycle window (20 operating
  cycles after reset) covers ALU/load/short-shift write→read hazards, and
  the ISS co-sim's 353k random instructions cover long-latency-shift-writer
  forwarding beyond the window. The engine swap is applied automatically by
  `runchecks.py` (`HEAVY_ENGINE`), since genchecks only exposes a global
  solver and its `bmc3` mode needs a gates.il build this flow bypasses.
- Bus: unconstrained rdata, ready-within-2-cycles fairness assumption,
  `bus_fault` tied off. The base riscv-formal insn models have no notion of
  a bus access fault, so an injected fault produces a *correct* access-fault
  trap that the spec scores as a mismatch; tying it off restricts the proof
  to fault-free memory. The fault -> precise-trap path is a sim testpoint
  (`dv/core_iss` `ls_fault` + `fetch_fault`, ISS lockstep on cause 1/5/7).
  Interrupts tied off (PRV-INT-* are M2 sim testpoints).
- PMP + privilege kept permissive by construction (`mmode_safe` fetch
  assumption): the base insn models assume unrestricted memory, so a PMP- or
  U-mode-denied access is another *correct* trap the spec can't predict. The
  core boots M-mode/PMP-off (`pmp_allow==1` for all accesses) and only leaves
  that state via `mret` or a pmpcfg/pmpaddr write, so those two fetched
  instructions are forbidden. (Constrained on the fetch stream because yosys
  `read_verilog` has no hierarchical references to the internal `pmp_allow`.)
  PMP allow/deny + privilege faults are sim testpoints (vplan §3.2/§3.3).
- **Two `expect`/exit-code gotchas fixed (BUGLOG BUG-003):** the generated
  `.sby` carry `expect pass,fail`, so SBY exits 0 on a real counterexample —
  `runchecks.py` keys pass/fail on SBY's `DONE (STATUS, …)` line, never the
  exit code, or every FAIL reads as PASS.

## Windows quirks (upstream-issue candidates)

- `checks/genchecks.py` derives the core name via `os.getcwd().split("/")`
  — broken on Windows paths; our `checks.cfg` avoids `@core@` in
  `[verilog-files]` instead of patching the clone.
- The suite ships `yosys-smtbmc` as a setuptools launcher pair
  (`yosys-smtbmc.exe.exe`), unresolvable as a bare command from cmd;
  `runchecks.py` writes a `.bat` shim into `toolshim/` at runtime.
