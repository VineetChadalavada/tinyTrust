# The Plan: One Chip At A Time

*Status: proposed 2026-09-03.*
*Changes the order of the milestones in [RETARGET.md](RETARGET.md) §7. Does not
change the architecture, the decisions already made, or the goal.*

---

## 1. What changes, and why

Some background first. **Tape-out** means sending a finished design to a
factory to be manufactured. Before that can happen, a design has to pass a set
of checks that have nothing to do with whether the logic is correct:

- **Pads** — the metal contacts around the edge of the chip that connect it to
  the outside world, plus the circuits that drive them.
- **Full-chip place and route** — arranging every gate on the die and drawing
  every wire between them.
- **DRC**, design rule checking — does the layout obey the factory's physical
  rules, like minimum wire spacing?
- **LVS**, layout versus schematic — does the layout actually match the circuit
  we designed, or did something get lost along the way?
- **Gate-level simulation** — re-running the tests on the final wired-up
  version, rather than on the original source code.

The old plan put all of this at the very end, after the two-core memory system
was finished. That means every one of these unknowns arrives at once, on the
most complicated version of the design.

That is exactly the mistake the first milestone was created to avoid. Its own
justification says so:

> **P0 is deliberately first.** The flow is the largest unknown and the thing
> that produces the render; growing the RTL before proving the backend risks
> discovering at P6 that the design cannot be hardened.

That reasoning does not stop at the tools. It applies to the chip. P0 proved
that a **processor core** can be turned into a layout. It did not prove that a
**chip** can — there were no pads, no LVS, no final DRC, no gate-level
simulation. Those are still the biggest unknowns in the project, and the old
plan met them last, on a two-core design.

**So the new plan is: build the simplest complete chip first, then improve it.**
Each version is a whole, working chip. Each one removes risk for the next.

### What is not changing

The goal. D16 settled it: not a coherence protocol, but a **comparison** of
two — MESI against MOESI, on the same hardware with the same test programs,
measuring memory traffic and delay.

**That comparison is a simulation measurement. It does not need a manufactured
chip.** So making the first chip single-core costs nothing against the main
result. The two-core work carries on in simulation alongside it, and arrives at
the second chip with its numbers already produced. This is the fact that makes
reordering free rather than a retreat.

---

## 2. The chips

| | What it is | What it settles |
|---|---|---|
| **S1** | Single-core system: processor, caches, on-chip memory, serial port, general-purpose pins, timer, crypto block | The whole manufacturing path — pads, full-chip layout, LVS, final DRC, gate-level simulation. Plus placing several memory blocks together, which the earlier memory test explicitly did not cover. |
| **S2** | Two cores with cache coherence, MESI and MOESI | The two-core memory design, on a path S1 has already proven |
| **S3** | External flash memory and secure boot | The security design from the original plan, which needs off-chip flash and its pin timing |

S2 comes before S3 because the two-core work is the stated point of the project.
If the security side matters more, the two swap without affecting S1 at all.

---

## 3. What goes in the first chip

The rule for S1 is **the smallest thing that is genuinely a chip** — it has to
start up, run a program, and tell you that it did.

### Included

| part | where it stands |
|---|---|
| The pipelined processor and its memory protection | **done**, 44/44 proof checks, zero simulation disagreements |
| 4 KB instruction cache and 4 KB data cache | **done**, tested at block and system level; instruction cache proven correct |
| On-chip main memory, 16 KB | **written and tested** 2026-09-05 — four blocks behind one bus slave |
| Start-up code in ROM | **written and tested** 2026-09-05 — a serial loader, `tools/gen_bootrom.py` |
| Serial port, send and receive | **written and tested** 2026-09-05 — checked by decoding the waveform, not by reading its own status register |
| General-purpose input/output pins | **written and tested** 2026-09-05 |
| Timer | **written and tested** 2026-09-05, and wired to the processor's interrupt input |
| ASCON crypto block | **done**, passes all 66 test vectors; still to be connected to the bus |
| A simple bus | **written and tested** 2026-09-05 — `rtl/soc/soc_bus.v` |
| Pads and package | **not started** |

### Deliberately left out

The second core, cache coherence, external flash memory, secure boot. All of it
belongs to S2 or S3, and none of it is needed to prove a chip works.

### Why the caches stay in

They are the one piece of "extra" in S1, and they earn their place. The earlier
memory test proved that **one** memory block survives the tool flow, and it was
explicit about what it did not prove:

> **One macro, not four.** Multi-macro placement, channel routing between
> macros and PDN across an array are not exercised.

S1 has an instruction cache, a data cache and main memory, so it places several
blocks together — exactly the gap. Finding out about that on a single-core chip
is much better than finding out when a two-core chip depends on it. And the
caches are already tested, so they cost integration time, not design time.

### Starting up and memory

S1 runs from **memory on the chip itself**, not external flash. The memory map
in ARCHITECTURE.md §4 assumes code lives in external flash and data in external
RAM. That needs a flash controller that has not been written, plus real
external parts and careful pin timing — and it puts something the chip depends
on outside the chip. For a first attempt that is the wrong trade. The memory
map keeps its layout so software still works later; S1 just uses the on-chip
regions.

### The S1 memory map (D30)

Decoded on the top address nibble only, as originally specified. S1 populates
the on-chip regions and leaves the external one faulting.

| Address | Region | Access | In S1 |
|---|---|---|---|
| `0x0000_0000` | Boot ROM | read, execute | populated |
| `0x1000_0000` | External flash | read, execute | **not populated — faults** |
| `0x2000_0000` | Main on-chip memory | read, write, execute | populated; code and data both live here |
| `0x3000_0000` | Peripherals | read, write | populated, and uncached |
| anything else | — | — | faults |

Setting the cache's cacheable limit to `0x3000_0000` makes the first three
regions cacheable and the peripherals uncached, using the single comparison the
cache already performs. Peripherals must not be cached — a write-back cache
would swallow a write to a device register — so this had to be right, and it
cost no hardware change.

### Does it fit? — now measured

The estimate was: processor with both caches 99.98 kGE (0.73 mm²), plus 16 KB
of main memory at 0.60 mm², plus small peripherals — roughly **1.4 mm²**.

**Measured 2026-09-05**, with the whole chip synthesised as one design:

| | |
|---|---|
| Standard cells | 433,495 µm² = **59.7 kGE** |
| Flip-flops | 4,958 |
| SRAM blocks | **6** — one per cache, four for main memory |
| Blocks at 150,102 µm² each | 900,612 µm² |
| **Total** | **1,334,107 µm² = 1.33 mm²** |

Against a 1.4 mm² estimate, on a 4 mm² die. The estimate held, and the die is
still limited by how many pads it needs rather than by what is inside it.

---

## 4. What makes S1 worth building on

This is the part that decides whether "we can extend it later" is real or
wishful.

1. **The bus is shaped the way the two-core bus will need, and it already
   arbitrates.** The caches speak a simple one-request-at-a-time interface, and
   D26 chose that same interface for the coherent bus. Better than expected:
   S1 is not single-master. The instruction cache and the data cache each have
   their own memory port, so there are two masters and a round-robin arbiter
   from the first chip — measured alternating strictly under sustained
   contention. Arbitration is therefore not something S2 introduces and has to
   debug on a two-core design; it is exercised from S1. S2 adds the snoop
   channel and a third and fourth master, without touching the caches or the
   processor.
2. **The cache line state is already in the right shape.** D24 replaced the old
   `valid`/`dirty` flags with a 2-bit state, and it measured identical in size.
   S1 ships lines that are only ever invalid, exclusive or modified; S2 makes
   "shared" reachable. No re-encoding, no area change, and it is already tested
   in hardware headed for manufacture.
3. **The memory map is fixed now**, so software, tests and the reference model
   carry across every chip version unchanged.
4. **Cache size is already adjustable** — line size and line count are real
   settings, not hard-coded numbers, so capacity can change between versions
   without rewriting anything.
5. **The pad ring is planned for S2 at S1 time.** Deciding the pins once, with
   room for the second core's debug signals and any extra I/O, avoids redoing
   the whole pad ring later. Pads are what set the die size.

Point 5 is the only one that has to be got right **now** rather than later. It
costs nothing to plan properly at S1 and a great deal to fix afterwards.

---

## 4a. The physical target, concretely

The finished chip is meant to stand next to
[noah-gigler/hft-chip](https://github.com/noah-gigler/hft-chip), which took a
design to this same process with open tools and reports a specific set of
numbers. Rather than "make it good", the target is that exact set, so it can be
checked rather than argued about.

| | hft-chip reports | S1 target | where we are (2026-09-05) |
|---|---|---|---|
| Process | IHP SG13G2, 130 nm | same | ✅ same |
| Die | 2500 × 2000 µm, QFN-64, 48 signal pads | same footprint | ❌ no pad ring yet; P0 was a 640 × 640 µm core-only harden |
| Utilisation | 54% | comparable | 42% core-only, not the same measurement |
| Maximum frequency | 112 MHz (1.08 ns slack at 10 ns) | reported for the **full chip with pads** | 144 MHz core-only — deliberately *not* comparable, see `pd/results/p0/METRICS.md` |
| Power | 269 mW | reported | 19.7 mW core-only. Ours should be far lower: theirs is a much larger design running every cycle |
| DRC | clean | clean, **signoff** | only the router's own check so far, which is not the same thing |
| LVS | clean (Calibre) | clean (**KLayout**) | never run |
| Die render | published | published | ✅ for the core and the memory test |
| Written report | `report/*.pdf` with sweeps | equivalent | docs, but no single report artifact |

### The one that looked hard is not

hft-chip used Calibre for layout-versus-schematic, which is a commercial tool.
Checking the installed platform, that is not needed here: it already ships
`lvs/sg13g2.lvs` with `run_lvs.py`, and signoff DRC decks
(`drc/sg13g2_minimal.lydrc`, `sg13g2_maximal.lydrc`), all driven by KLayout.
So the whole path stays open-source, which is a slightly better result than the
thing being matched.

The pad ring is there too: `sg13g2_io.lef` has the IO cells (input, output at
4/16/30 mA, tri-state, corner and filler), `bondpad_70x70.lef` has the bond
pads, and `pad.tcl` places a ring from four lists of pin names. hft-chip took
its pad ring from the Croc SoC; the same cells are in the platform we already
have installed.

### Pin budget

The chip currently needs 15 signal pins: clock, reset, serial in and out, four
general-purpose in, four out, the alert pin and two mode straps. A 64-pin
package has room for far more, so the spare pins are worth spending on
something — wider general-purpose I/O and a debug output — rather than leaving
them bonded to nothing. That is an S1-C decision and is taken there.

## 5. S1 milestones

| | Milestone | Done when |
|---|---|---|
| **S1-A** | Connect it all together | ✅ **done 2026-09-05.** Bus, serial port, I/O pins, timer, serial boot ROM, main memory and the top level, each tested on its own plus a whole-chip smoke test that loads a program over the serial port and runs it. Memory map per §3 above |
| **S1-B** | Whole-chip simulation and software | Start-up code runs, software prints over the serial port, the crypto test vectors run on-chip, a timer interrupt is taken. The reference-model comparison still shows zero disagreements at chip level |
| **S1-C** | Pads and full-chip layout | Pad ring, floorplan with several memory blocks placed, power grid, clock tree, routing. Timing met across the whole chip, zero routing violations |
| **S1-D** | Final checks | DRC clean, **LVS clean**, and gate-level simulation running the S1-B software |
| **S1-E** | Submit | Manufacturing agreement signed, slot booked, layout submitted |

**S1-D is the one that matters most**, because LVS and gate-level simulation are
the two things this project has never done and therefore cannot estimate.
Everything before it is work; S1-D is the unknown.

---

## 6. Open questions

1. **How often can we actually manufacture, and what does it really cost?**
   This decides whether "several chips, one after another" is a plan or a wish.
   The current price estimate of €2,400–3,500 is from public schedules and is
   **not confirmed** for a design this size, and missing a manufacturing slot
   costs months. **Settle this before committing to S1-E.** It is an email, not
   engineering, and it is the only genuinely blocking unknown here.
2. **How much main memory** — 16 KB (four blocks) or 32 KB (eight)? Depends on
   how ambitious the S1-B software is, and on how much memory-block placement is
   worth exercising.
3. **Does S1 include the formal-proof observation port?** No. It costs 21% of
   the processor's area and 383 of 492 signal pins. The proofs keep switching it
   on separately.
4. **Package and pin count.** This sets the die size directly, and needs
   answering together with question 1.

---

## 7. Decisions

| # | Decision | What else we considered | Why |
|---|---|---|---|
| **D27** | **Manufacturing checks move ahead of the two-core work.** The path from design to chip is proven on a single-core chip (S1) before the two-core design (S2). | Keep the old order: coherence first, manufacturing checks last | The P0 argument one level up. The path from design to finished chip is the biggest remaining unknown, and the old plan met it last, on the most complicated design. The comparison that D16 calls the goal is a simulation measurement, so nothing about the headline result depends on what is on the first chip. |
| **D28** | **The first chip runs from on-chip memory**, not external flash. | Run code directly from external flash, as ARCHITECTURE.md §4 assumes | Takes an unwritten controller, an external part and its pin timing off the critical path for a first attempt. The memory map keeps its layout so software carries forward; external flash arrives at S3 along with the secure-boot feature it exists to serve. |
| **D29** | **The first chip keeps the caches.** | A processor-only first chip, caches added at S2 | The earlier memory test proved one block works and explicitly not several placed together, wired together, or powered together. S1 settles that before a two-core chip depends on it — and the caches are already tested, so they cost integration time, not design time. |
