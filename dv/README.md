# TinyTrust DV

Verification strategy per REQUIREMENTS.md §6. Planned structure:

- `ascon_kat/` — **DONE (2026-07-14): ascon_p verified**, 66/66 KATs passing
  against the vendored pyascon reference (`third_party/ascon_ref.py`, CC0,
  by the Ascon team — independent of our RTL). Vectors: zero/all-ones/random
  states x {6,8,12} rounds. Run with `run.ps1` (needs OSS CAD Suite).
- `cocotb/` — Python testbenches + regressions (Icarus/Verilator), for the
  core and SoC level.
- `formal/` — riscv-formal harness for the core; SVA property files for
  bus/PMP invariants ("a denied access never reaches its target").
- `uvm/` — UVM environment for the ascon_p block (agent, scoreboard vs.
  reference model, functional coverage), run on a free UVM-capable
  simulator. Exists specifically to demonstrate industry-standard DV.

Simulator note: OSS CAD Suite is installed at `E:\tools\oss-cad-suite`
(Icarus Verilog + native Yosys/ABC). Its binaries need `bin` and `lib` on
PATH — use the run scripts or `environment.bat`.

A full verification plan (vplan) document gates milestone M1.
