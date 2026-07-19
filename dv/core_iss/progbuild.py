"""Shared program layout for core_iss tests.

Memory map (matches tb_core.v / rv32e.ISS):
  0x0000  prologue: set mtvec, jump to body
  0x0100  trap handler (default: skip the faulting instruction)
  0x0200  test body
  0x8000  scratch data region (load/store target)
  0x10000 TOHOST
"""
from rv32e import *

MTVEC = 0x100
BODY = 0x200
SCRATCH = 0x8000

# default handler: mepc += 4, return (all TinyTrust instructions are 4 bytes)
HANDLER_SKIP = [CSRRS(5, 0x341, 0), ADDI(5, 5, 4), CSRRW(0, 0x341, 5), MRET]


def epilogue(value=0x600D):
    """Store `value` to TOHOST, ending the test at that store's retire."""
    return LI32(1, TOHOST) + LI32(2, value) + [SW(2, 0, 1), JAL(0, 0)]


def build_program(body, handler=None):
    handler = HANDLER_SKIP if handler is None else handler
    pro = [ADDI(5, 0, MTVEC), CSRRW(0, 0x305, 5)]
    pro.append(JAL(0, BODY - len(pro) * 4))
    assert len(pro) <= MTVEC // 4
    assert len(handler) <= (BODY - MTVEC) // 4
    words = pro + [NOP] * (MTVEC // 4 - len(pro))
    words += handler + [NOP] * ((BODY - MTVEC) // 4 - len(handler))
    words += body
    assert len(words) * 4 <= 0x7000, \
        f"program ({len(words)} words) overflows into scratch"
    return words
