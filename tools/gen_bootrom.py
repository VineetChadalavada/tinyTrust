#!/usr/bin/env python3
"""Generate rom/bootrom.v -- the S1 boot ROM.

WHAT IT DOES
The first chip has no flash (D28), so there has to be some way to get a
program into it. This ROM is a serial loader:

    1. send 'T' so a host knows the chip is alive and talking
    2. receive a 4-byte little-endian length
    3. receive that many bytes into main memory, writing through the
       *uncached* window at 0x40000000
    4. send 'G', wait for it to actually leave the wire, and jump to the
       cached view of the same memory at 0x20000000

Step 3 is the subtle one. Writing through the cached window would leave the
program sitting dirty in the write-back data cache while the instruction
cache fetched whatever main memory still held, and there is no flush
instruction to reconcile them -- D25 keeps the two caches deliberately out of
any coherence scheme. The uncached alias (D31) sidesteps it: the bytes are
really in memory before the jump, so the instruction cache misses and reads
the right thing.

That is the smallest thing that makes the chip useful. Without it a working
chip and a dead chip look identical.

WHY GENERATE IT RATHER THAN HAND-WRITE VERILOG
The instruction encoders already exist in dv/core_iss/rv32e.py, written from
the specification and used by every core test. Reusing them means the ROM is
assembled by the same code that the processor is verified against, so a
mistake in an encoding would already have shown up as a co-simulation
disagreement. Writing the hex by hand would have no such backstop.

    python tools/gen_bootrom.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "dv", "core_iss"))

from rv32e import (LUI, JAL, JALR, BEQ, BNE, LW, SB, ADDI, ANDI, ADD, OR, SLL)

# ---- register use ----
MMIO = 1     # 0x30000000
SCR  = 2     # scratch
STAT = 3     # status reads
LEN  = 4     # image length
BYTE = 5     # received byte
RAM  = 6     # 0x20000000
SH   = 7     # shift amount while assembling the length
LINK = 8     # return address for the receive helper
IDX  = 9     # copy index
WBAS = 10    # 0x40000000, the uncached view of main memory

UART_DATA = 0x00
UART_STAT = 0x04

TX_BUSY  = 0x1
RX_VALID = 0x2


def assemble(prog):
    """Two passes: place labels, then encode with real offsets."""
    labels, pc = {}, 0
    for item in prog:
        if isinstance(item, str):
            labels[item] = pc
        else:
            pc += 4
    words, pc = [], 0
    for item in prog:
        if isinstance(item, str):
            continue
        words.append(item(labels, pc))
        pc += 4
    return words


def const(word):
    return lambda labels, pc: word


def rel(fn, label):
    """An instruction whose immediate is a label offset from this address."""
    return lambda labels, pc: fn(labels[label] - pc)


PROG = [
    # ---- set up the base addresses ----
    const(LUI(MMIO, 0x30000)),
    const(LUI(RAM,  0x20000)),      # cached, for the jump
    const(LUI(WBAS, 0x40000)),      # uncached, for the stores

    # ---- say hello: 'T' ----
    const(ADDI(SCR, 0, 0x54)),
    const(SB(SCR, UART_DATA, MMIO)),

    # ---- receive a 4-byte little-endian length ----
    const(ADDI(LEN, 0, 0)),
    const(ADDI(SH,  0, 0)),
    "len_loop",
    rel(lambda off: JAL(LINK, off), "rx"),
    const(SLL(BYTE, BYTE, SH)),
    const(OR(LEN, LEN, BYTE)),
    const(ADDI(SH, SH, 8)),
    const(ADDI(SCR, 0, 32)),
    rel(lambda off: BNE(SH, SCR, off), "len_loop"),

    # ---- receive the image ----
    const(ADDI(IDX, 0, 0)),
    "copy_loop",
    rel(lambda off: BEQ(IDX, LEN, off), "done"),
    rel(lambda off: JAL(LINK, off), "rx"),
    const(ADD(SCR, WBAS, IDX)),     # store through the uncached window
    const(SB(BYTE, 0, SCR)),
    const(ADDI(IDX, IDX, 1)),
    rel(lambda off: JAL(0, off), "copy_loop"),

    # ---- say 'G' and hand over ----
    "done",
    "tx_idle1",
    const(LW(STAT, MMIO, UART_STAT)),
    const(ANDI(STAT, STAT, TX_BUSY)),
    rel(lambda off: BNE(STAT, 0, off), "tx_idle1"),
    const(ADDI(SCR, 0, 0x47)),
    const(SB(SCR, UART_DATA, MMIO)),
    # Wait for it to leave the wire before jumping. Without this the host can
    # still be mid-byte when the loaded program starts writing its own output,
    # and the two interleave into nonsense on the terminal.
    "tx_idle2",
    const(LW(STAT, MMIO, UART_STAT)),
    const(ANDI(STAT, STAT, TX_BUSY)),
    rel(lambda off: BNE(STAT, 0, off), "tx_idle2"),
    const(JALR(0, RAM, 0)),

    # ---- receive one byte into BYTE, return through LINK ----
    "rx",
    const(LW(STAT, MMIO, UART_STAT)),
    const(ANDI(STAT, STAT, RX_VALID)),
    rel(lambda off: BEQ(STAT, 0, off), "rx"),
    const(LW(BYTE, MMIO, UART_DATA)),
    const(ANDI(BYTE, BYTE, 0xFF)),
    const(JALR(0, LINK, 0)),
]

WORDS = 128           # 512 bytes


def main():
    words = assemble(PROG)
    if len(words) > WORDS:
        raise SystemExit("boot ROM is %d words, over the %d-word budget"
                         % (len(words), WORDS))

    out = os.path.join(ROOT, "rom", "bootrom.v")
    with open(out, "w", newline="\n") as f:
        f.write("// AUTO-GENERATED by tools/gen_bootrom.py -- do not edit.\n")
        f.write("//\n")
        f.write("// The S1 serial boot loader. Sends 'T', receives a 4-byte\n")
        f.write("// little-endian length then that many bytes into main memory\n")
        f.write("// at 0x20000000, sends 'G' and jumps there.\n")
        f.write("//\n")
        f.write("// Assembled with the same instruction encoders the processor\n")
        f.write("// is verified against (dv/core_iss/rv32e.py), so an encoding\n")
        f.write("// mistake here would already have shown up as a\n")
        f.write("// co-simulation disagreement.\n")
        f.write("//\n")
        f.write("// %d instructions of a %d-word budget.\n" % (len(words), WORDS))
        f.write("\n")
        f.write("module bootrom (\n")
        f.write("    input  wire [8:2]  addr,   // word address, %d words\n" % WORDS)
        f.write("    output reg  [31:0] rdata\n")
        f.write(");\n\n")
        f.write("    always @(*) begin\n")
        f.write("        case (addr)\n")
        for i, w in enumerate(words):
            f.write("            7'd%-3d: rdata = 32'h%08X;\n" % (i, w))
        f.write("            // Everything above the program reads as zero,\n")
        f.write("            // which decodes as an illegal instruction and\n")
        f.write("            // traps -- better than running into whatever\n")
        f.write("            // happens to be there.\n")
        f.write("            default: rdata = 32'h00000000;\n")
        f.write("        endcase\n")
        f.write("    end\n\n")
        f.write("endmodule\n")
    print("wrote %s (%d instructions, %d words free)"
          % (out, len(words), WORDS - len(words)))


if __name__ == "__main__":
    main()
