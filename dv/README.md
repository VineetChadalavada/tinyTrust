# TinyTrust DV

Verification strategy per REQUIREMENTS.md §6. Planned structure:

- `ascon_kat/` — **DONE (2026-07-14): ascon_p verified**, 66/66 KATs passing
  against the vendored pyascon reference (`third_party/ascon_ref.py`, CC0,
  by the Ascon team — independent of our RTL). Vectors: zero/all-ones/random
  states x {6,8,12} rounds. Run with `run.ps1` (needs OSS CAD Suite).
- `core_iss/` — **core lockstep co-sim (live since 2026-07-19)**:
  spec-written Python RV32I ISS + instruction encoders (`rv32e.py`, name kept
  for import stability), directed suites for vplan §3.1, constrained-random
  template generator, RVFI trace compare under randomized bus latency.
  Found BUG-001 in its first random session and BUG-004 in the first session
  against the pipelined core (see docs/BUGLOG.md).
  Since P2 it drives **both** cores off one testbench and one memory model:
  `--core mc` (`rtl/core/core.v`), `--core p5` (`rtl/core/core_p5.v`), or
  `--core both`, which runs byte-identical stimulus through each and prints
  the CPI comparison. `--fastmem` makes the instruction port zero-wait-state
  while leaving the data port timed; that combination is what reaches the
  pipeline states the timed model structurally cannot (BUG-005), and it is
  a preview of I$ timing at P3. `run.ps1` runs all three legs.
  `--cache` inserts the P3 I$/D$ between the core and memory.
  Run: `python cosim.py --core both --directed --random 4` (or `run.ps1`,
  which runs all four legs).
- `cache/` — **block-level cache testbench (P3)**: drives `rtl/cache/cache.v`
  against a golden model of a coherent memory, and separately counts the
  memory-side beats. Both claims are needed — a cache that missed on every
  access would pass a data-only check — so hits are asserted to generate zero
  beats and a dirty eviction exactly 32 (16 writeback + 16 refill). Directed
  phase covers cold miss, read/write hit, partial writes through the macro's
  bit mask, dirty eviction, uncacheable pass-through and refill faults; then
  random traffic over a range that forces constant index conflicts; then a
  read-back sweep of every address ever written, which is what actually proves
  the writeback path. `-DDCACHE` selects the write-back data cache.
- `models/` — simulation model of the IHP SG13G2 SRAM macro. It exists
  because the ORFS platform references `SRAM_1P_behavioral_bm_bist` from all
  ten macro wrappers and never defines it, so the vendor `FUNCTIONAL` path is
  unusable as shipped. Simulation binds this; synthesis and P&R bind the LEF
  and Liberty with `rtl/mem/sram_macro_bb.v` supplying the declaration.
- `cocotb/` — Python testbenches + regressions (Icarus/Verilator), for the
  core and SoC level.
- `formal/` — **riscv-formal harness (live since 2026-07-19)**: SBY bounded
  checks over the core's RVFI port, 44 checks per core. Two configs since P2:
  `tinytrust/` (multicycle, insn depth 25 with shifts at 60 for the
  1-bit/cycle shifter) and `tinytrust_p5/` (5-stage, no shift overrides — the
  barrel shifter removed the need). Select with `run.ps1 -Core mc|p5`.
  The RV32E wrapper assumption is gone (D18); see `formal/README.md`.
  `reg_ch0` on the pipelined core is what found BUG-005, a forwarding defect
  no amount of co-simulation could have reached.
  `cache/` holds the P3 cache proof (D22): rather than fold cache state into
  the core's wrapper, the cache is proven separately against the property that
  it is *transparent* — a read returns the last value written to that address
  — using a one-address abstraction so the state space stays closable.
  SVA property files for bus/PMP invariants come with M2.
- `uvm/` — **empty; nothing here has been built.** The v1 plan was a UVM
  environment for `ascon_p`, which docs/RETARGET.md §5 retired as honestly
  redundant: the block is already closed by 66/66 KATs through a 40-line
  testbench. The replacement target is the coherent multi-master bus at P4
  (`COH-UVM-*`), where multiple active agents, a bus monitor and a protocol
  scoreboard are the right tool for engineering reasons rather than CV ones.

Simulator note: OSS CAD Suite is installed at `E:\tools\oss-cad-suite`
(Icarus Verilog + native Yosys/ABC). Its binaries need `bin` and `lib` on
PATH — use the run scripts or `environment.bat`.

A full verification plan (vplan) document gates milestone M1.
