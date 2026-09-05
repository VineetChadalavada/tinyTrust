#!/usr/bin/env python3
"""Generate dv/soc/hello.hex -- the program the S1 smoke test loads.

Deliberately tiny, and it proves the whole path in one go: it runs from main
memory (so the loader worked and the instruction cache fetched what the
loader wrote), it drives the output pins (so the bus reaches the peripherals),
and it sends a byte (so the serial port works from software as well as from
the ROM).

    python tools/gen_soc_demo.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "dv", "core_iss"))

from rv32e import LUI, ADDI, SW, SB, JAL

MMIO = 1
SCR  = 2

GPIO_OUT  = 0x10
UART_DATA = 0x00

PROG = [
    LUI(MMIO, 0x30000),
    ADDI(SCR, 0, 0xA),
    SW(SCR, GPIO_OUT, MMIO),      # show a pattern on the pins
    ADDI(SCR, 0, 0x4B),           # 'K'
    SB(SCR, UART_DATA, MMIO),     # and say so on the wire
    JAL(0, 0),                    # spin here forever
]


def main():
    out = os.path.join(ROOT, "dv", "soc", "hello.hex")
    with open(out, "w", newline="\n") as f:
        for w in PROG:
            f.write("%08X\n" % w)
    print("wrote %s (%d instructions)" % (out, len(PROG)))


if __name__ == "__main__":
    main()
