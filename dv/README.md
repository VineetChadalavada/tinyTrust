# TinyTrust DV

Verification strategy per REQUIREMENTS.md §6. Planned structure:

- `ascon_kat/` — **DONE (2026-07-14): ascon_p verified**, 66/66 KATs passing
  against the vendored pyascon reference (`third_party/ascon_ref.py`, CC0,
  by the Ascon team — independent of our RTL). Vectors: zero/all-ones/random
  states x {6,8,12} rounds. Run with `run.ps1` (needs OSS CAD Suite).
- `core_iss/` — **core lockstep co-sim (live since 2026-07-19)**:
  spec-written Python RV32E ISS + instruction encoders (`rv32e.py`),
  directed suites for vplan §3.1, constrained-random template generator,
  RVFI trace compare against `rtl/core/core.v` under randomized bus
  latency. 16 directed tests + 350k+ random instructions passing; found
  BUG-001 (see docs/BUGLOG.md) in its first random session.
  Run: `python cosim.py --directed --random 4` (or `run.ps1`).
- `cocotb/` — Python testbenches + regressions (Icarus/Verilator), for the
  core and SoC level.
- `formal/` — **riscv-formal harness (live since 2026-07-19)**: SBY bounded
  checks over the core's RVFI port (insn depth 25, shifts 60), with the
  RV32E space handled by a wrapper assumption (see `formal/README.md`).
  SVA property files for bus/PMP invariants come with M2.
- `uvm/` — UVM environment for the ascon_p block (agent, scoreboard vs.
  reference model, functional coverage), run on a free UVM-capable
  simulator. Exists specifically to demonstrate industry-standard DV.

Simulator note: OSS CAD Suite is installed at `E:\tools\oss-cad-suite`
(Icarus Verilog + native Yosys/ABC). Its binaries need `bin` and `lib` on
PATH — use the run scripts or `environment.bat`.

A full verification plan (vplan) document gates milestone M1.
