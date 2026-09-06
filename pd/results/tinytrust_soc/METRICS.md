# S1-C — the whole chip, with pads

*Run 2026-09-05. Milestone S1-C of [TAPEOUT_PLAN.md](../../../docs/TAPEOUT_PLAN.md):
"Pad ring, floorplan with several memory blocks placed, power grid, clock tree,
routing. Timing met across the whole chip, zero routing violations."*

![die render](final_all.webp)

A KLayout render of `6_final.gds`. The ring around the edge is the 47 pads; the
six dark rectangles are the SRAM blocks — one per cache and four for main
memory. No silicon involved.

## What this is, and how it differs from P0

P0 hardened the bare processor: no pad ring, no memory blocks, no peripherals.
Its own notes said its 144 MHz was "closes comfortably" on a core-only harden
and not comparable to a finished chip. **This is the finished chip**, and its
numbers are chip numbers: every path here runs from a real input pad, through
the pad's own delay, into the logic, and back out through an output pad.

## Results

| Metric | Value |
|---|---|
| Die | 2500 × 2000 µm |
| Design area | 1,452,940 µm² @ **62% utilisation** |
| **Maximum frequency** | **107.72 MHz** (period_min 9.28 ns) |
| Worst setup slack | **+0.72 ns** against the 10 ns constraint |
| TNS / WNS | 0.00 / 0.00 |
| **Router DRC** | **0 violations** (`5_route_drc.rpt` empty) |
| **Signoff DRC** | **22 violations, all density/fill** — see below |
| Power grid | all VDD and VSS shapes connected; worst IR drop 0.294 mV (0.02%) |
| Power | 4.34 mW |
| GDS | `6_final.gds`, 99.2 MB |

### What is on the die

| | count | area µm² |
|---|---|---|
| SRAM blocks | 6 | 900,614 |
| Input pads | 21 | 302,400 |
| Output pads | 18 | 259,200 |
| Supply pads | 8 | 115,200 |
| Pad spacers | 171 | 612,000 |
| Sequential cells | 4,995 | 244,699 |
| Combinational cells | 20,701 | 223,814 |
| **Total instances** | **117,101** | |

21 input plus 18 output is the 39 signal pads the generator emits, and 8 supply
pads makes 47 — the count matches what `tools/gen_padring.py` wrote, which is
the cheapest possible check that the ring is the one that was designed.

## Against the reference

The project measures itself against
[noah-gigler/hft-chip](https://github.com/noah-gigler/hft-chip), which took a
design to this same process with open tools (TAPEOUT_PLAN.md §4a).

| | hft-chip | TinyTrust S1 |
|---|---|---|
| Process | IHP SG13G2 130 nm | same |
| Die | 2500 × 2000 µm, QFN-64 | same |
| Utilisation | 54% | 62% |
| Maximum frequency | 112 MHz (1.08 ns slack at 10 ns) | **107.7 MHz** (0.72 ns slack at 10 ns) |
| Power | 269 mW | 4.34 mW |
| DRC | clean | router clean; signoff pending |
| LVS | clean, with Calibre | pending, with **KLayout** |

Same process, same die, comparable density, and within 4% on frequency against
the same constraint. The power difference is not a win — theirs is a much
larger design doing arithmetic every cycle, while this one spends most of its
time waiting for a serial port.

The LVS row is the interesting one. hft-chip used Calibre, which is commercial.
The platform ships `lvs/sg13g2.lvs` and `run_lvs.py` driven by KLayout, so this
chip's whole path from source to signoff stays open-source.

It is not as simple as running the ORFS target, though. `make lvs` on this
platform writes the string "LVS not supported on this platform" into its own
output file and exits 0 — a step that reports success without checking
anything, which is precisely the false-green pattern of BUG-003 and BUG-006.
The deck is real; it is just not wired into the target.
`pd/designs/tinytrust_soc/run_signoff.sh` assembles the full netlist — the
design plus the standard cell, IO pad and SRAM macro netlists, without which
every instance reads as an unresolved black box — and calls the deck itself.

## What this does NOT establish

- **Signoff DRC is not clean: 22 violations.** This is exactly why the
  distinction matters. The router's own check reports zero, and KLayout's rule
  deck then finds 22 — because they check different things. Every one of the 22
  is a *density* rule, not connectivity or spacing:

  | count | rule | requirement |
  |---|---|---|
  | 19 | `M2Fil.h/k` | Metal2 plus filler coverage in any 800 × 800 µm window must be 25–75% |
  | 1 | `M2.j/k` | global Metal2 density 35–60% |
  | 1 | `GFil.g` | global GatPoly density at least 15% |
  | 1 | `AFil.g/g1` | Activ density |

  Foundries require a *minimum* metal density as well as a maximum, because
  chemical-mechanical polishing dishes out large empty regions and ruins
  planarity. A chip at 62% utilisation on a die this size has a lot of empty
  area, and the standard-cell filler that `USE_FILL` inserts is not the same
  thing as metal fill across the die.

  **Cause found, in ORFS's own fill step.** `scripts/density_fill.tcl` calls

  ```tcl
  density_fill -rules $::env(FILL_CONFIG)
  ```

  with no `-area` argument, and OpenROAD then defaults to the **core** area. On
  this chip the core box is inset 351 µm from the die edge on every side to
  make room for the pad ring, so that moat — roughly a third of the die — gets
  no fill at all. That is where the empty density windows are. It was a guess
  from the geometry first; reading the script turned it into a fact.

  The fix is `fill_moat.tcl`, hooked in through `POST_DENSITY_FILL_TCL`: run
  the same fill again over the full die area, additively, so the core keeps
  what it has and the moat gets the same treatment. Not yet re-run — the LVS
  pass currently reading `6_final.gds` has to finish first, since refilling
  regenerates it.

  Density fill is routine tape-out work rather than a design problem, but it is
  work, and the chip is not signoff-clean until it is done.

- **LVS has not returned a verdict yet.**
- **No gate-level simulation** of the routed netlist. The design is verified at
  RTL — 44/44 proofs, zero co-simulation disagreements, and a whole-chip test
  that boots and runs a program — but nothing has yet re-run those against
  `6_final.v`.
- **The output pads are underdriven.** Every output pad violates its slew limit:
  4 mA drivers against the 5 pF board load the constraints assume, giving
  4.68 ns against a 1.20 ns limit. The platform's own reference design uses
  16 mA pads for general I/O and that is the fix; 5 pF is a realistic load, so
  the answer is a stronger driver rather than a softer assumption. Numbers above
  are otherwise unaffected — this is an off-chip signal integrity problem, not a
  timing-closure one.
- **A hold path sits at exactly 0.00 slack** against a 0.48 ns library hold
  requirement. This is the risk the memory-block smoke test predicted in
  writing: "every flop feeding a cache array will start hold-critical and needs
  margin budgeted." It arrived exactly where that note said it would.
- **No package.** QFN-64 is the target footprint, and the bond diagram is not
  drawn.

## Reproducing

```bash
# once, to work around the memory-block Liberty defect
bash pd/designs/sram_smoke/patch_sram_lib.sh

# then, in WSL as root (the toolchain was installed as root)
source /opt/OpenROAD-flow-scripts/env.sh
cd /opt/OpenROAD-flow-scripts/flow
make DESIGN_CONFIG=/mnt/e/tinytrust/pd/designs/tinytrust_soc/config.mk
bash pd/designs/tinytrust_soc/run_signoff.sh both
```

Toolchain as P0: OpenROAD `26Q3-1278-g4421880472`, Yosys `0.68+`, KLayout
`0.30.7`.

### Three things that cost a run each

1. **A duplicated Liberty file.** Setting `FOOTPRINT_TCL` makes the platform add
   the IO libraries itself. Re-declaring the *typ* one gives ABC two cells of
   every name and it dies inside its own cell hash — `Abc_SclHashCells:
   Assertion '*pPlace == -1' failed`. Nothing in that message mentions
   libraries. Sibling of the `ADDITIONAL_LIBS` finding in the smoke test.
2. **`remove_from_collection` is not an OpenSTA command.** Rewriting the
   constraints against the platform's own pad-ring reference corrected
   something more important than the syntax: with a pad ring the clock must be
   created on the pad's *core-side output pin*, not the package port, and
   ordinary pins need a virtual clock because they really are asynchronous to
   the core.
3. **Supply pads get deleted by synthesis.** They have no ports and drive
   nothing, so they are dead logic by any reasonable measure. The failure
   appears two stages later, from a different tool, naming an instance that
   looks like it should exist: `[ERROR PAD-0102] Unable to find instance:
   sg13g2_IOPad_vdd1`. `(* keep *)` holds them.
