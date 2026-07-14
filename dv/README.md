# TinyTrust DV

Verification strategy per REQUIREMENTS.md §6. Planned structure:

- `cocotb/` — Python testbenches + regressions (Icarus/Verilator).
  First target: `ascon_p` against the official NIST SP 800-232 KATs and a
  Python golden model of the permutation. **This is the immediate next DV
  task — the ascon_p RTL is currently unverified (area-calibrated only).**
- `formal/` — riscv-formal harness for the core; SVA property files for
  bus/PMP invariants ("a denied access never reaches its target").
- `uvm/` — UVM environment for the ascon_p block (agent, scoreboard vs.
  reference model, functional coverage), run on a free UVM-capable
  simulator. Exists specifically to demonstrate industry-standard DV.

Simulator note: cocotb needs a native simulator (Icarus via OSS CAD Suite,
or Verilator). Not yet installed on this machine.

A full verification plan (vplan) document gates milestone M1.
