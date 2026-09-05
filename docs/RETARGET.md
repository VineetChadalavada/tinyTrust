# Version 2: Moving to a Full Custom Chip

*Status: adopted and in progress — proposed 2026-08-16, groundwork finished
2026-09-03.*
*Replaces the target and processor decisions in [ARCHITECTURE.md](ARCHITECTURE.md)
§2 and §10.*
*Parent: [REQUIREMENTS.md](REQUIREMENTS.md). Current build order:
[TAPEOUT_PLAN.md](TAPEOUT_PLAN.md).*

---

## 1. What changed and why

Version 1 was a **single-processor microcontroller squeezed into 16 tiles** of a
shared manufacturing run, where area was the binding constraint on every
decision.

Version 2 targets a **full custom chip**, and adds a **5-stage pipeline** and a
**two-core memory system with cache coherence** (both MESI and MOESI).

The reason is a deliberate change of goal. Version 1 optimised for *fitting*.
Version 2 optimises for *showing real processor design depth on real silicon*.
The reference point is [noah-gigler/hft-chip](https://github.com/noah-gigler/hft-chip)
(ETH Zürich), which used the same manufacturing process, the same open-source
tools, and a 2500 × 2000 µm die.

**This is not a small change.** It reverses the project's top design principle
and three entries in the decision log. Those reversals are recorded here rather
than quietly edited into ARCHITECTURE.md, so the version 1 reasoning stays
readable. "Here is what I optimised for, here is what changed, here is what that
cost" is a better story than a specification pretending it was always right.

### Design principles, re-ordered

| | version 1 | version 2 |
|---|---|---|
| 1 | **Area first** — every block judged by size | **Verifiability first** — cache coherence is where designs die |
| 2 | Verifiability second | **Design depth second** — the pipeline, caches and coherence are the point |
| 3 | Speed a distant third | Area third — a 2 × 2 mm chip is limited by its pins, not its logic |

---

## 2. Decisions reversed from ARCHITECTURE.md §2

| Old | Was | Now | Why it flipped |
|---|---|---|---|
| **D1** | One instruction at a time; a pipeline's speed is wasted waiting on 10–20 cycle flash fetches | **5-stage pipeline** | **The cache is what justifies the pipeline.** D1's reasoning was entirely a consequence of having no instruction cache. With one, a hit takes 1 cycle and the pipeline finally has something to work on. These are not two independent features — adding the pipeline *without* the cache would have been exactly the mistake D1 correctly identified. |
| **D3** | Flip-flop register file | unchanged, but the pressure is gone | With memory blocks available and a full chip, the latch-based fallback is dead. Keep flip-flops. |
| **D5** | Shifter moving 1 bit per cycle; "31 extra cycles is invisible next to fetch cost" | **Single-cycle barrel shifter** (pipelined core only) | D5 rested on the same premise as D1: fetch dominates, so execution time is free. It is not free once execution is a pipeline stage — a 31-cycle shift stalls every instruction behind it, and the whole point of a pipeline is that there *are* instructions behind it. The measured cost came in well under the 0.6–0.8 kGE D5 itself predicted, and it *reduces* proof cost: the old core's proof setup needs six checks raised to depth 60 purely so a 31-cycle shift can finish, and the pipelined one needs none. The old core keeps its iterative shifter. |
| **D10** | One bus transfer at a time | **Multiple masters on a shared bus, with a snoop channel** | Coherence needs at least two masters and a broadcast path by definition. This is the single largest increase in what has to be verified. |
| **§10** | Area budget in shuttle tiles (16 tiles = 0.256 mm²) | Area budget in mm² on a roughly 2 × 2 mm chip | Obsolete. The tile model and its trim ladder no longer apply. |

**D2 (16 registers) is reversed — the processor now has all 32** (signed off
2026-08-16). D2's entire justification was that a 32 × 32-bit flip-flop register
file "alone is larger than the rest of the core". On a 4 mm² chip that argument
is gone. See D18 for what the reversal bought.

Implemented and verified the same day: the register file widened to 32 entries,
the illegal-register trap deleted, the reference model widened to 32, the
matching assumption removed from the proof setup, the directed test for
"registers above 15 must trap" replaced by one confirming they are ordinary
registers exercised in every position, and the random generator widened. The
comparison run came back green: 16 of 16 directed tests, 12 of 12 random,
**45,612 instructions, 0 disagreements**.

---

## 3. New decisions

| # | Decision | What we rejected | Why |
|---|---|---|---|
| D11 | **Full custom chip (~2 × 2 mm), not the shared shuttle** | 16 tiles; more tiles | Our own measurements: 1 tile is 2,344 gate equivalents, so 16 tiles is 37.5 kGE. A single 256-byte flip-flop-based cache is 10.9 kGE, or 4.7 tiles. Two cores' caches alone would exceed the whole budget. Coherence simply cannot be expressed at that size. |
| D12 | **IHP SG13G2, 130 nm** | SKY130 through a commercial service | Three reasons: it costs €2,400–3,500 for an open-source run against $14,950; it **ships ready-made memory blocks** (widths of 8, 16, 48 and 64 bits, depths from 64 to 4096 — see the note in §4; the `x32` part named at proposal time does not exist), where the SKY130 open path is do-it-yourself; and hft-chip proved this exact tool flow, with an adaptable pin ring. The cost is re-running the area measurements against the new cell library. |
| D13 | **A classic 5-stage pipeline**, full forwarding, one-cycle stall on load-use | 3-stage; 2-stage; keep the old core | The classic 5-stage is the most-verified structure in existence, has a canonical reference implementation, and is what the reference model and proof setup already target. Going deeper buys nothing at 130 nm, where the critical path is memory access. |
| D14 | **2 cores**, identical | 4 cores; 1 core plus an accelerator | Two cores exercise every MESI and MOESI transition, including the cache-to-cache transfer that distinguishes them. Four multiply the verification effort and the area without adding a single new protocol situation. The arbiter stays written for any number. |
| D15 | **Snooping coherence on a shared bus** | A directory; the simpler MSI protocol | At two cores a directory is pure overhead. Snooping is the right engineering answer and the one that makes MOESI's Owned state meaningful — passing modified data cache to cache without writing it back. |
| D16 | **One controller with a switch, `COHERENCE = MESI \| MOESI`** | Pick one; write two separate blocks | Owned is a pure addition: MOESI is MESI plus one state and its transitions. One controller with a compile-time switch produces a *measurement* — memory traffic and shared-data latency, MESI against MOESI, on identical hardware with identical stimulus. **That comparison is the deliverable, not the protocol.** |
| D17 | **Write-back, write-allocate caches** | Write-through | MOESI's Owned state is meaningless with write-through. The entire point is deferring the write while still serving modified data cache to cache. |
| D18 | **All 32 registers** — signed off and implemented 2026-08-16 | Stay at 16 | Reverses D2, whose reasoning was an artefact of the tile budget. It also **removes the one environment restriction** in the 44/44 proof suite that shrank the verified space, so the checks now cover the whole register file with no shaping assumption. It removes toolchain friction too. Cost: 512 more flip-flops per core, about 2.7 kGE. |
| D19 | **Cache data in memory blocks, cache tags in flip-flops** | All flip-flops; all memory blocks | Data arrays are large and single-ported, a perfect fit for a memory block. Tags need a single-cycle comparison *and* a snoop lookup, which flip-flops give cheaply. |
| D20 | **Keep the version 1 security system** (crypto, memory protection, secure boot, alerts) | Drop it to reduce scope | It is verified, it is about 15 kGE, and it now fits trivially. A coherent multicore *with* a hardware root of trust is a distinctive project; a coherent multicore alone is a textbook exercise. Memory protection becomes per-core. |
| D21 | **4 KB instruction and data caches, 64-byte lines, direct-mapped** (signed off 2026-08-30) | 2 KB; 32-byte lines; two-way associative | Capacity fixes the memory block exactly: 4 KB is one `RM_IHPSG13_1P_512x64` with nothing wasted. Line size is the real lever on tag storage: at 64 bytes a cache has 64 lines and about 1,344 tag flip-flops (roughly 9.1 kGE at the 6.75 GE per flip-flop measured in P1); at 32 bytes it has 128 lines and about 18 kGE — roughly a whole processor in flip-flops, *per cache*. The cost is an 8-transfer refill instead of 4. Direct-mapped because a replacement policy is extra state, and state is exactly what the coherence proofs have to reason about. The protocol is the hard part and it should not arrive on top of a replacement policy. |
| D22 | **The proof boundary stays at the processor's edge; the cache is proven separately** (signed off 2026-08-30) | One proof wrapper covering processor and cache together | Two reasons, one of them measured. The processor's architecture does not change when caches are added, so its 44/44 is a standing result and should not be disturbed by cache proof cost. And that cost is real: the register check on the bare pipeline needed retuning to close at all (§9.3), and folding in tag state, data state and refill sequencing is the direction that made it intractable. The cache instead gets its own property — a read returns the last value written to that address, meaning the cache is *invisible* — which is both easier to prove and the right foundation for the coherence work, where the properties are stated over exactly that model. |
| D23 | **No second copy of the tags for snooping** (2026-09-03) | Duplicate tags, as D21 assumed; dual-ported memory tags | Tag duplication solves a single-ported-memory conflict this design does not have. D19 put the tags in flip-flops and only the *data* array is a memory block, so a snoop lookup is just extra read wiring — not a second copy of 1,344 flip-flops. Saves the roughly 9.1 kGE per data cache that D21 reserved, and removes a class of bug (two copies that can disagree). Tag *writes* still need arbitration; see COHERENCE.md §5.3. |
| D24 | **The coherence state replaces `valid` and `dirty` in place**, as one 2-bit value (2026-09-03) | A separate coherence-state array alongside them | The data cache already stores 2 bits per line and MESI has 4 states, so this is a rename rather than growth — the only thing MESI adds is splitting "valid and clean" into Exclusive and Shared. MOESI is five states and does need a third bit: 64 more flip-flops per data cache, about 0.43 kGE, which the S2 area budget must carry rather than inherit MESI's "free". Coherence is free in the tag array here, which inverts the usual intuition. A separate array would allow the contradiction "not valid, but modified", which would then have to be proven impossible. |
| D25 | **The instruction cache stays outside the coherence system** (2026-09-03) | Have it snoop invalidations too | The processor traps the cache-flush instruction and self-modifying code is already unsupported (§10.1), so instruction memory never changes while running and an out-of-date instruction cache cannot be observed. This halves the snoop logic and the situations to prove. It is a real restriction — a program writing code for the other core is outside the supported model — and it is recorded rather than hidden. |
| D26 | **One bus transfer at a time, round-robin arbiter** (2026-09-03) | Overlapping transfers with miss-tracking registers | It is the shape the caches already speak. Overlapping transfers are the more interesting problem but multiply the situations exactly where coherence bugs live — two requests for the same line at once — and §8 already lists the coherence work as the loosest estimate in the plan. Both protocols see the same bus, so the comparison stays controlled. |
| D27 | **Manufacturing checks move ahead of the coherence work** (2026-09-03) | Keep the §7 order: coherence, then manufacturing checks | The P0 argument one level up. The chip-level flow — pins, layout-versus-schematic, final rule checks, gate-level simulation — is the largest remaining unknown, and §7 meets it last, on the most complex design. The D16 deliverable is a simulation measurement, so nothing about the headline result depends on what is on the first chip. See [TAPEOUT_PLAN.md](TAPEOUT_PLAN.md). |
| D28 | **The first chip runs from on-chip memory** (2026-09-03) | Run from external flash, as ARCHITECTURE §4 assumes | Removes an unwritten controller, an external part and its pin timing from first silicon. The memory map keeps its layout so firmware carries forward; running from flash arrives with the secure-boot work it exists to serve. |
| D29 | **The first chip keeps the caches** (2026-09-03) | A processor-only first chip | The memory block test proved one block and explicitly *not* several placed together, wired between, or powered across. The first chip settles that before a two-core chip depends on it, and the caches are already verified — integration cost, not design cost. |
| D30 | **The S1 memory map keeps the version 1 regions, and the first chip populates the on-chip ones** (2026-09-05) | A fresh map for S1; putting main memory in the code window | Address decoding stays one nibble, as ARCHITECTURE.md §4 fixed it. The boot ROM stays at `0x0000_0000` and the peripherals at `0x3000_0000`. Main on-chip memory goes at `0x2000_0000`, the read-write-execute window, because in S1 code and data both live there — the `0x1000_0000` flash window is specified read-and-execute-only, so putting writable memory there would contradict the map. The flash window is simply not populated in S1 and faults, which is D28 made concrete. A useful consequence: a cacheable limit of `0x3000_0000` makes ROM, flash and main memory cacheable and the peripherals uncached, using the single comparator `cache.v` already has. No cache change was needed. |

---

## 4. Area budget v1.0 — estimate, later replaced by measurements

**Originally extrapolated from version 1 numbers. Treat everything in this
first table as ±30%.** The measured numbers follow.

| Block | Est. kGE | Notes |
|---|---|---|
| 2 × pipelined core (with control registers, traps, protection) | 20–28 | about 10–14 each |
| 4 × cache tag array and control (assuming duplicated tags) | 12–20 | line size is the main lever |
| 2 × coherence controller | 6–10 | |
| Shared bus, arbiter, snoop broadcast | 3–5 | |
| Version 1 security system (crypto 7.3 + protection + ROM + flash + peripherals) | ~15 | measured or projected in version 1 |
| **Total logic** | **56–78 kGE** | about **0.21–0.29 mm²** of standard cells |
| Memory blocks: 4 × 4 KB | — | **150,102 µm² = 20.68 kGE each; 4 of them is 0.60 mm²** (measured 2026-08-30) |

At 55% occupancy the logic lands around **0.4–0.55 mm² plus the memory blocks**
— comfortably inside a 2 × 2 mm chip. **The chip will be limited by its pin
count, not its logic**, exactly as hft-chip's was (54% occupancy at
2500 × 2000 µm). From here, pins drive the size, not gates.

The minimum area the manufacturing run sells is 0.8 mm², so there is no risk of
being too small either.

### Measured numbers — P1, 2026-08-28

`synth/calibration/calibrate_sg13g2.py` replaces the version 1 script: real
synthesis and technology mapping against the actual cell library, where one
gate equivalent is 7.2576 µm², rather than the old estimate-based pricing. The
version 1 script is kept for the record, but its numbers are both from the old
process and from before the 32-register change.

| block | area µm² | kGE | flip-flops | v1 estimate | change |
|---|---|---|---|---|---|
| **core** (including registers and protection) | 137,667 | **18.97** | 1,419 | — | — |
| ├ register file alone | 92,947 | 12.81 | 992 | 6.96 (16 regs) | +84% ¹ |
| └ protection alone | 10,877 | 1.50 | 112 | 2.54 | −41% |
| crypto block | 50,157 | 6.91 | 325 | 9.52 | −27% |
| start-up ROM | 6,793 | 0.94 | 0 | 2.15 | −56% |
| **top-level total** | **194,618** | **26.82** | | | |

¹ Not directly comparable: version 1 measured 16 registers, this is 32. The
register storage alone is 48,611 µm² = 6.7 kGE; the other 6.1 kGE is read
multiplexing, which partly merges into surrounding logic when synthesised
inside the core rather than on its own. Do not add the register-file and
protection rows to the core row — they are already inside it.

The three blocks that *are* comparable all came in 27–56% **below** the version
1 estimate, which is what the old script's own header predicted ("expect the
real flow to come in 10–30% lower"), plus the change of process.

### Measured numbers — P2, 2026-08-30

The pipelined core measured on the same flow and library. The two cores are
alternatives, not siblings — a chip takes one or the other, which is why the
script now prints two totals.

| block | area µm² | kGE | flip-flops | vs. the old core |
|---|---|---|---|---|
| **core** (one instruction at a time, P1 baseline) | 137,363 | **18.93** | 1,419 | — |
| **core_p5** (pipelined) | 180,652 | **24.89** | 1,787 | **+5.96 kGE (+31.5%), +368 flip-flops** |
| protection alone | 13,337 | 1.84 | 112 | +0.34 kGE against P1's 1.50 |
| total with the old core | 194,314 | 26.77 | | |
| total with the pipelined core | 237,603 | **32.74** | | |

*Corrected 2026-08-30.* The pipelined row first published read 179,684 µm² /
24.76 kGE / 1,786 flip-flops. Those were measured **before** the BUG-005 fix and
were stale by exactly one flip-flop: `w_fwd_live`, the register that keeps a
forwarded value alive across a memory stall, is one bit, and it plus the
multiplexer it feeds accounts for the extra 968 µm². Re-measured against the
committed design and confirmed reproducible — the tools give 180652.1346 µm² on
three consecutive runs, so this is a real difference, not tool variation. The
P2 commit message carries the stale figure; this table is the correct one.

Three notes on the differences:

1. **+31% for the pipeline is the honest price**, and it is dominated by
   storage, not logic. The extra 367 flip-flops are the four stage boundaries
   carrying the program counter, instruction, operands, control signals and the
   reporting payload. The barrel shifter and extra adders are the smaller half.
2. **Protection grew from 1.50 to 1.84 kGE** because it now has two check ports:
   the pipeline checks a data access and an instruction fetch in the same cycle,
   which one checker cannot do. The register state is shared and only the
   combinational matching is duplicated. The old core ties the second port off
   and the tools remove it — visible above, where the old core measures 18.93
   here against 18.97 at P1. That 0.04 kGE is drift from the hierarchy change,
   not a regression.
3. **This does not move the floorplan.** The revised estimate treated two cores
   as a floor of about 38 kGE; at 24.76 kGE each, two pipelined cores are about
   50 kGE. The first layout showed the version 1 core alone at 0.41 mm² with
   42% occupancy on a 2 × 2 mm chip. The chip is still pin-limited.

---

### Measured memory block numbers — before P3, 2026-08-30

From the memory block test (`pd/results/sram_smoke/METRICS.md`), which settles
the §8 risk that P0 deferred. Two corrections to the assumptions above, both
important for the cache design:

**The part named in D12 and in the table above does not exist.** There is no
`RM_IHPSG13_1P_1024x32`. The process ships ten single-port blocks with widths of
8, 16, 48 and 64 bits, and depths of 64, 256, 512, 1024, 2048 and 4096. A 4 KB
array is `RM_IHPSG13_1P_512x64`. Cache geometry has to be chosen from what
actually exists.

**Memory block area is no longer unknown, and it is the largest single item.**

| | value |
|---|---|
| `RM_IHPSG13_1P_512x64` (4 KB) | 784.48 × 191.34 µm = **150,102 µm² = 20.68 kGE** |
| 4 × 4 KB (the §4 budget) | **0.60 mm²** |
| for comparison, the pipelined core | 179,684 µm² = 24.76 kGE |

One 4 KB memory block is 0.83 times the area of the entire pipelined processor.
Four of them is 0.60 mm², against the 0.4–0.55 mm² projected for *all* the
logic. The chip stays comfortable — 0.6 plus about 0.55 is 1.15 mm² on a 4 mm²
chip, still pin-limited — but memory, not logic, now sets the area, and cache
capacity is the biggest area lever available.

Two more properties to design against:

- **Power.** The memory block is 66.6% of total power in a design that is one
  block plus a handful of registers (3.62 mW out of 5.43 mW).
- **Hold time.** The block requires its inputs to be held 0.39 ns after the
  clock edge, which is large next to a standard cell. Every flip-flop feeding a
  cache array starts out hold-critical and needs margin budgeted.

And one defect to carry forward: every memory block's timing file declares its
capacitance unit as picofarads and then gives a maximum load of `6.4e-14` —
a value written in farads, off by a factor of 10¹². This aborts the layout
tool's placement stage and cannot be overridden from the timing constraints
file. `pd/designs/sram_smoke/patch_sram_lib.sh` corrects a local copy; an
upstream report is still pending.

## 5. What this changes for verification

The existing testing survives and mostly still applies:

| Method | version 1 status | version 2 |
|---|---|---|
| Comparison against the reference model | green | **Per core.** The model already covers 32 registers. The pipeline changes reporting *timing*, not content. |
| riscv-formal proofs | 44/44 | **Per core.** 32 registers *removes* an assumption. The pipeline needs its depths retuned. |
| Crypto test vectors | 66/66 | unchanged |

**Two genuinely new problems:**

1. **Is the coherence protocol correct?** The properties are classic and
   provable: never two caches holding the same line as modified; a modified or
   owned line is the unique dirty copy; every request eventually completes, with
   no deadlock and no starvation at the arbiter. This is a *strong* target for
   proof — small state space, high-value properties — and should be proven
   rather than simulated.
2. **Is memory behaviour correct when both cores run at once?** Random
   two-core tests against a pair of reference models with a shared memory model.
   This is where directed testing stops scaling.

**Note on UVM.** In version 1, the proposed UVM environment for the crypto
block was honestly redundant — the block was already closed by 66 of 66 test
vectors through a 40-line testbench, and the environment existed for CV value.
A **coherent multi-master bus is the textbook application for UVM**: several
active agents, a bus monitor, a protocol scoreboard, and a coverage grid over
protocol state, request type, requester and responder. Here it is the right
tool for engineering reasons rather than CV reasons. The crypto UVM item should
be retired and replaced with coherence ones.

---

## 6. The real gap: turning the design into a chip

Verification is ahead of the reference project. **The path to a physical chip
was at zero** — `synth/` held area estimates and nothing else. No floorplan, no
placement, no layout file, no rule checks, no layout-versus-schematic.

The target flow:

```
Source code → Yosys → OpenROAD (floorplan · power · place · clock · route)
            → KLayout (layout file + rule checks) → LVS → picture of the chip
```

Every figure quoted in the reference project's README — maximum frequency,
occupancy, power, clean rule and equivalence checks, **and the picture of the
chip** — is an output of this flow. The picture is a screenshot of the finished
layout and needs no silicon at all. It becomes available the day the layout
first completes.

**Known risk:** the layout tool has reported failures merging in some of this
process's memory blocks. Hit this early with a memory-block-only test before
committing to a cache design.

---

## 7. Milestones

| # | Milestone | Done when | Status |
|---|---|---|---|
| **P0** | Get the tools working | The flow runs; **the existing processor is turned into a finished layout**; first picture produced. Proves the path before the design grows. | **done** 2026-08-28 |
| **P1** | Re-measure area | Calibration re-run against the new process; the §4 budget replaced with measurements; 32 registers signed off | **done** 2026-08-28 |
| **P2** | 5-stage pipeline | The pipelined core passes the reference comparison and the proofs at the version 1 standard; speed measured against the old core | **done** 2026-08-30 — §9. Zero disagreements over 19,326 instructions × 3 memory settings; 44/44 proofs on both cores; CPI 7.784 → 6.208, and 2.237 with fetch free |
| **P3** | Caches | Instruction and data caches on real memory blocks; hits and misses verified; still 44/44 | **done** 2026-09-03 — §10. Design and all verification green; both cores measured at 44/44; CPI 7.62 → 2.55; instruction cache proven. One criterion knowingly open: the data cache proof (§10.6) |
| **P4** | Coherence | 2 cores, shared bus, MESI; protocol properties proven; coherence test environment; directed concurrency tests | **design opened** 2026-09-03 — [COHERENCE.md](COHERENCE.md). D23–D26 signed off; two planned costs removed. The critical path is the proof technique P3 deferred, not the protocol hardware |
| **P5** | MOESI and the measurement | `COHERENCE=MOESI` closes the same suite; the traffic and latency comparison written up | |
| **P6** | Physical signoff | Pin ring, full-chip layout, timing closure, clean rule and equivalence checks, gate-level simulation | |
| **P7** | Submission | Manufacturing agreement signed, slot booked, layout submitted | |

**P0 is deliberately first.** The flow is the largest unknown and the thing that
produces the picture; growing the design before proving the tool path risks
discovering at the end that it cannot be built.

**The order below P3 is superseded by [TAPEOUT_PLAN.md](TAPEOUT_PLAN.md)
(2026-09-03, D27).** The plan is now one chip at a time: a smallest-complete
single-core chip is laid out, checked and submitted *before* the two-core
design. The reason is the sentence immediately above, applied one level up — P0
proved that a *processor* can be built, not that a *chip* can, and the table
above meets pins, equivalence checking, final rule checks and gate-level
simulation last, all at once, on the most complex version of the design.

P4 and P5 are not cancelled; they become the second chip, and the MESI/MOESI
comparison continues in simulation in parallel, because it is a measurement and
never needed silicon. The table is left as written rather than edited, for the
same reason §2 lists reversed version 1 decisions instead of quietly rewriting
them.

---

## 8. Open risks

| Risk | What we do about it |
|---|---|
| Manufacturing slot availability and true open-source pricing | Contact the foundry directly. The quoted €2,400–3,500 is from public schedules and unconfirmed for a design this size |
| Memory blocks failing in the layout tool | **Retired 2026-08-30** — the test P0 deferred was finally run (`pd/results/sram_smoke/METRICS.md`): a 4 KB block becomes a finished layout with zero routing violations. The missing-data cells are real but the current tool version already handles them. Three integration problems had to be solved first, one of them a genuine defect in the process's own timing files |
| Only 8 GB of memory allocated to the build environment | Full-chip layout may need more; raise the limit before the physical work |
| Underestimating the coherence verification effort | It always is. P4 and P5 have the loosest estimates in this plan |
| Solo project, and manufacturing has a hard deadline | Unlike version 1, a missed slot costs months. Book the slot *after* the design is proven, not before |
| Wasted version 1 calibration work | About an afternoon to redo; the method transfers unchanged |

---

## 9. Results: P2 — the 5-stage pipeline

*Completed 2026-08-30. Required: the pipelined core passes the reference
comparison and the proofs at the version 1 standard, with speed measured
against the old core.*

### 9.1 What was built

`rtl/core/core_p5.v` — five stages (fetch, decode, execute, memory, write
back), full operand forwarding, and a one-cycle stall when an instruction needs
a value still being loaded. It implements the *same architecture* as the old
core: same instructions, same control registers and rules, same trap causes,
same reporting conventions. That is deliberate, and it is what makes the rest of
this section possible — both cores are checked against the same reference model
and the same proof suite, so the speed comparison measures the microarchitecture
alone.

Both cores are kept. The old one is not dead code: it is the control in the
experiment, and it stays in the regression.

Three structural departures from version 1, each reversing a version 1 decision:

| | version 1 | P2 | why it had to change |
|---|---|---|---|
| Memory ports | one shared port, one transfer at a time (D10) | **separate instruction and data ports** | Fetch and memory both want memory in the same cycle; one port forces them to take turns. The testbench arbitrates for now; the caches then hang directly off these two ports. |
| Shifter | 1 bit per cycle (D5) | **single-cycle barrel** | A 31-cycle execute stalls every instruction behind it, and in a pipeline there *are* instructions behind it. |
| Adders | one shared (D1) | **one per stage** | Fetch needs the next address while execute computes a branch target while memory holds a load address. Sharing is not expressible once stages run at the same time. |

Two design choices worth stating, because they are where pipelines usually go
wrong:

- **The commit point is the memory stage, not write back.** Nothing
  architectural happens before it. The register file is written in write back,
  but the *decision* to write is made in memory, and the data bus is driven only
  once no older instruction can still fault. Exceptions are detected in fetch,
  decode, execute and memory — and all of them are *taken* in memory. That is
  what makes traps precise and in program order. Branches redirect from execute,
  costing two wasted slots, and a memory redirect always outranks an execute
  one.
- **System instructions run alone.** Control-register and privilege
  instructions wait in decode until the later stages are empty, and the pipeline
  is flushed behind them. This costs a handful of cycles on a rare instruction
  and buys three things outright: correct ordering of control-register reads
  after writes, a privilege change that cannot be overtaken by instructions
  fetched under the old rules, and a protection-register write that cannot be
  bypassed by a fetch already checked against the old settings. Version 2's
  first principle is "verifiability first", and this is what that looks like in
  practice — a stall instead of a bypass network.

### 9.2 Speed — the exit measurement

23 programs (17 directed, 6 random), **19,326 instructions**, the same program
words fed to both cores in the same run, three memory settings. Lower CPI is
faster.

| memory setting | old core CPI | pipelined CPI | speed-up |
|---|---|---|---|
| shared bus, 2–5 cycle latency (the default) | 7.784 | **6.208** | 1.254× |
| shared bus, minimum latency (3 cycles per access) | 6.153 | **4.142** | 1.485× |
| instant fetch, timed data | n/a ¹ | **2.237** | 3.48× vs. the old default |

¹ This setting separates fetch timing from data timing, which the old core has
no way to express — it has one port and one access in flight.

**The trend is the whole result, not the individual numbers.** As memory gets
faster, the pipeline's advantage grows: 1.25× → 1.49× → and with fetch free,
CPI 2.24 against the old core's 7.78. On straight-line arithmetic it reaches
**CPI 1.01** — one instruction per cycle, which is exactly what a correctly
forwarded 5-stage pipeline is supposed to do.

This is a direct measurement of the claim D1 was reversed on. Version 1 said a
pipeline's throughput is wasted waiting for slow fetch, and *at 2–5 cycles per
fetch it is mostly right* — 1.25× is a thin return for 31% more area. The
counter-argument was that the cache is what justifies the pipeline. The
instant-fetch row is that argument measured: hold everything else constant, make
only fetch free, and the same hardware goes from 1.25× to 3.5×. Neither half of
the pair is worth much alone. **P2 without P3 would not have been worth doing,
and now there is a number saying so rather than an assertion.**

### 9.3 Verification

**Reference comparison — 0 disagreements, three memory settings.** 23 programs,
19,326 instructions per setting: the default 2–5 cycle bus, the minimum-latency
bus, and instant fetch with timed data. The old core passes the same 23 programs
on the same stimulus, which is what licenses the table above as a comparison
rather than two unrelated numbers.

**riscv-formal — 44/44 on both cores.**

| | old core | pipelined core |
|---|---|---|
| checks | **44/44** | **44/44** |
| instruction check depth | 25, with **six raised to 60** for shifts | 25, **none raised** |
| register check cycle | 30 | 20 (see below) |
| register check solve time | 490 s | 36 s |

Two things in that table are results, not configuration trivia:

- **The six shift exceptions are gone.** Six shift checks needed depth 60 in the
  old configuration purely so a 31-cycle iterative shift could finish inside the
  bound. The barrel shifter makes shifts prove at the same depth as everything
  else. Reversing D5 bought speed *and* reduced proof cost.
- **The register check is retuned to cycle 20 for the pipeline, and that is not
  a weaker bar.** The quantity to hold constant across two cores is
  *instructions covered*, not cycles. Depth 30 leaves 20 working cycles, which
  at the old core's speed covers about 3 instructions but at the pipeline's
  covers 10 to 20 — several times the state space, on a design that also has a
  forwarding network. Measured: the old core closes at 30 in 490 s, and the
  pipelined one had not closed after more than 30 minutes. At 20 the pipeline
  still covers roughly 5 to 10 instructions — *more* than the old core gets at
  30 — and closes in 36 s. The reasoning is recorded at the setting itself
  rather than left as a bare number.

The old core's suite was re-run from scratch for this milestone, not quoted from
P1: the protection unit was split so its register state could feed two check
ports, and 44/44 on the unchanged core is the evidence that the split changed no
behaviour.

**Two bugs, and the second one is the point.**

- **BUG-004** (arithmetic right shift became logical) — caught by the reference
  comparison on the first run of the new core. A Verilog typing rule, not a
  design error: inside a conditional, one unsigned side makes the whole
  expression unsigned, and that propagates back into the operands, silently
  turning an arithmetic shift into a logical one. The signed cast was present
  and did nothing.
- **BUG-005** (a forwarded value was lost when a data access stalled) — caught
  by the register proof, and **simulation could not have caught it.** Not
  through unlucky stimulus: with the timed memory model a fetch costs at least
  three cycles, so consecutive instructions are never closer than three pipeline
  stages apart, and the failing state — a consumer stuck in execute across a
  data stall while its producer sits in write back — is *structurally
  unreachable* in that environment. The proof tool treats memory readiness as a
  free choice and explores schedules the model never produces.

  The fix to the hardware was small: separate "just finished" from "still
  available to forward". The fix to the *environment* mattered more. A directed
  test alone would have been vacuous — it passes on the broken hardware — so the
  testbench gained an instant-fetch mode, making instructions pack together
  while data accesses still stall. Verified in both directions: on the pre-fix
  hardware the new test passes with the timed model and fails at instruction 9
  with instant fetch. The test runner now runs three configurations so the state
  space stays reachable.

  The lesson is about coverage of the *environment*, not the design. A testbench
  whose timing is always the same shape hides state space, and no amount of
  extra random instructions finds what the timing forbids. It is also the timing
  an instruction cache produces — so left alone, this bug would have appeared at
  P3 as a regression in already-signed-off hardware.

### 9.4 What P2 changes for P3

- **The two ports are already there.** The pipelined core exposes independent
  instruction and data interfaces, which the testbench currently arbitrates onto
  one memory. P3 replaces the arbiter with two caches and the core does not
  change.
- **The speed target is set.** Instant fetch is a cache-hit emulator: it says
  the pipeline reaches CPI 2.24 overall and 1.01 on straight-line code when
  fetch is free. That is the number an instruction cache has to approach to
  justify itself, and it was measured before a line of cache code was written.
- **Instant-fetch mode is not throwaway.** It stays as the third regression
  configuration, and it is the closest thing available to cache timing until the
  caches exist.
- **Serialising system instructions is a known cost to revisit.** It is cheap
  now because those instructions are rare. If the coherence work makes them
  common, the serialisation becomes the thing to attack — and the bypass network
  it was traded against is written up here so the trade is visible rather than
  rediscovered.

---

## 10. Results: P3 — caches

*Completed 2026-09-03. Required: instruction and data caches on real memory
blocks; hits and misses verified; still 44/44.*

### 10.1 What was built

`rtl/cache/cache.v` — one adjustable module serving both caches. 4 KB, 64-byte
lines, direct-mapped (D21); write-back and write-allocate for the data cache
(D17); data in one memory block with tags in flip-flops (D19). The processor
side is exactly the interface the pipelined core already drove, and the memory
side is exactly the bus the system already spoke, so the caches dropped in
without either end changing.

Three things worth pulling out:

- **Write hits cost no waiting.** The memory block's per-bit write mask means a
  partial write needs no read-modify-write cycle: the byte enables expand onto
  the mask and the write completes in the cycle it arrives. This is the concrete
  reason a bit-masked block was worth having.
- **A miss retries rather than being served from the fill path.** After the line
  is fetched, the request simply tries again and hits. That costs one lookup
  cycle per miss and removes an entire class of bypass logic. The processor
  holds its request steady until accepted, so it is free to retry —
  verifiability first.
- **The uncached region is a correctness requirement, not an optimisation.** The
  test-completion register lives at address `0x0001_0000`, and a write-back
  cache would swallow the store that ends every test. Addresses at or above the
  cacheable limit bypass entirely, which is also what keeps the processor's
  precise fault behaviour intact.

**Deliberately not handled:** there is no coherence between the instruction and
data caches, and the processor traps the cache-flush instruction, so
self-modifying code is unsupported. Every test keeps code below `0x7000` and
data at `0x8000` and above, so no store can collide with a cached instruction
line. Coherence arrives with the snoop channel.

### 10.2 The first version made the machine slower

Worth recording, because the fix is the whole argument for the geometry choice.
The cache as first built gave **CPI 6.91 against 4.51 with no cache at all**. A
read hit cost one wait state — the tag comparison is immediate but the memory
read is not — so every fetch took two cycles where the uncached path took
roughly the same, and the misses were pure loss.

The fix is what D21 chose a 64-bit-wide block for: **one memory read returns two
instructions.** Keeping the second one in a single-entry buffer makes a
sequential fetch stream alternate between memory reads and buffer hits, so
fetching averages one cycle per instruction instead of two. Invalidating the
buffer is a single conservative clear whenever a line arrives, because a
read-only cache has nothing else that can make a buffered word stale.

### 10.3 Speed — and a benchmark that had to be written first

**The existing test suite structurally could not measure this milestone.** Every
directed and random program runs in a straight line, once. That is the worst
case for a cache: a 64-byte line pulls in 16 instructions used exactly once, so
an instruction cache can only match a plain fetch, never beat it. Measuring on
those programs measures refill bandwidth and nothing else. Nothing in the suite
had a loop.

So `loop_bench` was added: a nested loop whose 5-instruction hot body sits in a
single cache line and whose 512-byte working set fits the data cache several
times over. It is deliberately generous — an upper bound on what these caches
buy, not a typical program — and it is the only workload in the suite that
reuses anything.

| configuration (`loop_bench`, 5,164 instructions) | CPI | vs. the old core |
|---|---|---|
| old core, no cache | 7.62 | — |
| pipelined core, no cache | 6.29 | 1.21× |
| **pipelined core with both caches** | **2.55** | **2.99×** |

That completes the argument D1 was reversed on. The pipeline alone buys 1.21×;
the pipeline with caches buys 2.99×. "The cache is what justifies the pipeline"
is now a measured claim across three configurations rather than a rationale.

### 10.4 Area

Standard-cell area only — the data array is the memory block measured earlier at
150,102 µm² = 20.68 kGE each.

| block | area µm² | kGE | flip-flops | + block | total |
|---|---|---|---|---|---|
| instruction cache | 120,619 | 16.62 | 1,529 | 20.68 | **37.30 kGE** |
| data cache | 124,168 | 17.11 | 1,530 | 20.68 | **37.79 kGE** |

D21 estimated about 9.1 kGE for the tag flip-flops and that part holds — 1,529
flip-flops against the roughly 1,344 predicted for tags, with the rest being the
fetch buffer and the refill and write-back datapath. What D21 did *not* estimate
is that the control and datapath around the tags roughly doubles the
standard-cell area: the realised cache logic is 16.6 kGE, not 9.1. The
prediction was right about the part it named, and the part it did not name was
the larger half.

One core with both caches is now 24.89 + 37.30 + 37.79 = **99.98 kGE**, of which
41% is memory block. Two of those is about 200 kGE, roughly 1.45 mm² — still
comfortable on a 2 × 2 mm chip, but the coherence work should be sized knowing
that caches, not cores, dominate.

### 10.5 Verification

**Block level — 6 of 6 across three random seeds.** The testbench checks two
separate claims, because checking the data alone only proves the first: a cache
that missed on every single access would still return correct data. So
memory-side transfers are counted too, and a hit is required to generate
*none*, a first-time miss exactly 16, and throwing out a modified line exactly
32. The directed phase covers a cold miss, read and write hits, partial writes
through the block's write mask, eviction of modified data, uncached
pass-through, and a memory error during a fetch. Then random traffic over a
range chosen to force constant collisions, then a read-back sweep of every
address ever written. That sweep is what actually proves the write-back path,
since an evicted modified line is only readable again if its data really
reached memory.

**System level — all four regression configurations, 22 programs, 18,973
instructions, 0 disagreements.** The cached configuration executes an identical
instruction stream to the uncached one, which is the property that matters: the
caches are invisible to the software.

**Processor proofs — the pipelined core re-measured at 44/44.** Re-run against
the committed design after all cache work, with 44 passing status files on
disk. That is the core the caches actually connect to, and it is a fresh
observation rather than an argument.

The old core's suite was re-measured too, and is now a measurement rather than
an argument: **44/44 on 2026-09-03**, a full regenerate-and-run, with the
register check slowest at 410 s — consistent with the profile that made it the
one check needing a different engine. It had previously stood at 44/44 and been
carried forward by reasoning: the core was untouched and the cache sits outside
the proof boundary. The reasoning was sound; it is simply no longer what the
claim rests on.

**The cache property — instruction cache closed, data cache open for a stated
reason.** The property is that the cache is invisible: a read returns the last
value written to that address. It is proven for a single arbitrary address,
chosen by the solver rather than by the author, so a proof covers every address.

**Instruction cache — PASSES out to 26 cycles** (2026-09-03, 14m36s, every
cycle from 0 to 25 clean). Together with the non-emptiness check below, that
closes the property for the instruction cache.

**Why the non-emptiness check was not optional.** The setup always ended with a
`cover` statement whose own comment reads "the proof is worthless if the
environment cannot even complete a read of the tracked word" — but both
configurations run in one tool mode, and the tool evaluates cover statements
only in a different one. The check had never executed. Against assumptions as
strong as this setup carries — the processor holds requests steady, memory
answers within two cycles, the tracked address is cacheable — a proof that
passes by never reaching the interesting case was a live possibility, not a
theoretical one. Both caches now confirm a read really happens, at step 9, in
about a second.

**Data cache — does not close, for two independent measured reasons.**

| | |
|---|---|
| the cost | cumulative solve time at the reduced size: step 15 = 60 s, step 16 = 235 s, step 17 = 949 s — about **4x per step**. The instruction cache grew at about 1.4x over the same range and closed. The difference is the write path: a freely chosen 4-bit write mask every cycle, tracking which lines are modified, and the write-back sequencing. |
| the bound | the sequence the property actually turns on — writing back the tracked word, then reading it again — is **first reachable at step 28**. The configured bound was 26. |

The second reason is the important one. A pass at 26 would have been perfectly
sound and close to worthless: it would have covered refills and write hits and
never once an eviction, which is the behaviour the property exists to check.
Nothing in a passing result reveals this. It took stating the sequence as a
`cover` and measuring where it first becomes reachable. The configuration now
carries 28, the honest minimum, and is excluded from the default suite rather
than left looking green at a bound that asks the wrong question.

A shorter cache line was tried as a way in and **rejected as invalid**. At 8
bytes a refill is 2 transfers and the whole sequence fits by step 14 — but that
is not a legal setting for this design. One derived width becomes zero, so an
internal signal collapses to an impossible width and a bit-select comes out
reversed. Yosys accepts both silently and the structural check passes, so it
builds and then produces a counterexample at step 7 that says nothing about the
real design. 16 bytes is the floor, and **passing an elaboration check is not
the same as being a valid configuration**.

**What would close it is not a longer run.** A bounded proof replays the whole
write-evict-write-back sequence from reset at every step, which is what costs 4x
a step. The two ways past it are induction with hand-written invariants, or
splitting the property so write-back correctness is proven from an arbitrary
starting state rather than from reset. Both need the machinery the coherence
proofs need over the same state, which is where that work belongs.

Earlier attempts, kept because they are what led here:

| size | depth | reset cycles | reached | outcome |
|---|---|---|---|---|
| full (64-byte line, 64 lines) | 55 | 15 | step 40 | no result after **6h21m**; over an hour on a single query |
| reduced (16-byte line, 4 lines) | 40 | 15 | step 38 | clean, stopped at 39 min |
| reduced (16-byte line, 4 lines) | 32 | 3 | step 26 | clean, stopped at 28 min |
| reduced, different engine | 40 | 3 | step 33 | clean, stopped at 97 min |

The last row is what made the instruction cache result possible. Switching to a
SAT-based engine on a design where the memory array has been expanded into plain
flip-flops — the same trick the processor's register check already uses — is
dramatically faster at low depth (step 11 in 0.4 s against minutes per step),
because the memory array stops being an abstract array and becomes ordinary
logic.

Three lessons worth keeping:

1. **Proof cost is dominated by the memory array being part of the model.** This
   is what the earlier register-check retuning already hinted at: bounded proofs
   over designs with large arrays scale badly, and the fix is to shrink what is
   being unrolled rather than to wait longer.
2. **Time spent in reset is pure waste.** A third of the first reduced run's
   depth was spent sitting in reset — 15 cycles of a 40-cycle bound — and was
   cut to 3.
3. **A bound is not justified by arithmetic on paper.** State the sequence you
   believe the bound reaches as a `cover`, and measure it. Here the paper
   estimate was 21 and the measured answer was 28, which is the difference
   between a proof and a proof of the wrong thing.

### 10.6 P3 against its exit criteria

| criterion | status |
|---|---|
| Instruction and data caches on real memory blocks | **met** — 4 KB each, real `RM_IHPSG13_1P_512x64` blocks |
| Hits and misses verified | **met** — block-level transfer counting plus the system-level runs |
| Still 44/44 | **met, both cores, both measured** — pipelined core re-measured after all cache work; old core re-run 2026-09-03 |
| *(added by D22)* the cache proven separately | **met for the instruction cache** — passes at 26 cycles with a non-emptiness check. **Open for the data cache**, with the reason now measured rather than "no result": about 4x per step, and a bound of 28 needed to reach an eviction |

P3 is closed on three of four criteria and knowingly open on the fourth. The
change since 2026-08-31 is that the open item stopped being "the proof did not
return" and became a specific, measured statement: a bounded proof from reset
cannot reach the data cache's eviction sequence at any affordable cost, and the
way through is induction or a split property, which is coherence machinery. That
is a milestone exit, not a milestone stall — but it is an exit with one
criterion deliberately unmet, and the coherence work inherits it.

Two things were found while closing this out that were not part of the plan,
both recorded above: the non-emptiness check in the setup had never run because
of a tool-mode mismatch, and the data cache bound was below the depth at which
the behaviour it proves can happen. Neither would have shown up in a passing
result.
