"""Constrained-random instruction stream generator (vplan §2, dv/core_iss).

Templates: arith bursts, load/store storms, branch mazes, bounded loops,
jump ladders, trap bombs, CSR pokes — all with the RV32E register
constraint. Register conventions:
  x14 : scratch base pointer (never a random rd)
  x13 : bounded-loop counter (only written inside the loop template)
  x5  : trap-handler scratch (clobbering it is fine — lockstep)
  x6  : jalr-ladder scratch (loaded fresh inside the template)
Everything is deterministic given the seed; the ISS executes the identical
stream, so data-dependent control flow needs no static resolution.
"""
import random
from rv32e import *
from rv32e import _r
from progbuild import SCRATCH, epilogue

R_OPS = [ADD, SUB, SLT, SLTU, XOR, OR, AND, SLL, SRL, SRA]
I_OPS = [ADDI, SLTI, SLTIU, XORI, ORI, ANDI]
CORNERS = [0, 1, 2, 0xFFFFFFFF, 0xFFFFFFFE, 0x7FFFFFFF, 0x80000000,
           0x80000001, 0x55555555, 0xAAAAAAAA]
# RV32I: all 32 architectural registers (D18). x14 is the scratch base and
# x5 is reserved by the epilogue, so neither is a random destination.
RD_POOL = [r for r in range(32) if r not in (5, 14)]


def rnd_rd(rng):
    return rng.choice(RD_POOL)


def rnd_rs(rng):
    return rng.randrange(32)


def t_r(rng):
    return [rng.choice(R_OPS)(rnd_rd(rng), rnd_rs(rng), rnd_rs(rng))]


def t_i(rng):
    return [rng.choice(I_OPS)(rnd_rd(rng), rnd_rs(rng),
                              rng.randrange(-2048, 2048))]


def t_shift_imm(rng):
    sh = rng.choice([0, 1, 31, rng.randrange(32)])
    return [rng.choice([SLLI, SRLI, SRAI])(rnd_rd(rng), rnd_rs(rng), sh)]


def t_u(rng):
    return [rng.choice([LUI, AUIPC])(rnd_rd(rng), rng.getrandbits(20))]


def t_li(rng):
    val = rng.choice(CORNERS) if rng.random() < 0.5 else rng.getrandbits(32)
    rd = rng.choice([r for r in RD_POOL if r != 0])
    return LI32(rd, val)


def t_ldst(rng):
    size = rng.randrange(3)
    align = 1 << size
    off = rng.randrange(0, 0x800)
    if rng.random() < 0.85:
        off &= ~(align - 1)                     # mostly aligned
    if rng.random() < 0.5:
        return [[SB, SH, SW][size](rnd_rs(rng), off, 14)]
    op = rng.choice([[LB, LBU], [LH, LHU], [LW]][size])
    return [op(rnd_rd(rng), 14, off)]


def t_branch(rng):
    k = rng.randrange(1, 5)                     # skip k fillers if taken
    br = rng.choice([BEQ, BNE, BLT, BGE, BLTU, BGEU])
    ins = [br(rnd_rs(rng), rnd_rs(rng), 4 * (k + 1))]
    ins += [rng.choice(R_OPS)(rnd_rd(rng), rnd_rs(rng), rnd_rs(rng))
            for _ in range(k)]
    return ins


def t_loop(rng):
    k = rng.randrange(1, 5)
    return [ADDI(13, 0, k), ADDI(13, 13, -1), BNE(13, 0, -4)]


def t_jal(rng):
    k = rng.randrange(1, 4)
    ins = [JAL(rng.choice([0, 1, 7]), 4 * (k + 1))]
    ins += [NOP] * k
    return ins


def t_jalr(rng):
    # x6 = pc; land on pc+16 (delta 16), pc+17 (bit0 cleared -> pc+16),
    # or pc+18 (misaligned -> trap 0, handler resumes at the filler)
    delta = rng.choice([16, 16, 16, 17, 18])
    return [AUIPC(6, 0), ADDI(6, 6, delta),
            JALR(rng.choice([0, 1]), 6, 0), NOP]


def t_trap(rng):
    off = rng.randrange(0, 0x7FE)
    bombs = [
        0x00000000, 0xFFFFFFFF,
        ECALL, EBREAK, FENCEI,
        0x10200073,                                    # sret
        _r(1, rnd_rs(rng), rnd_rs(rng), 0, rnd_rd(rng), 0x33),  # mul
        CSRRW(rnd_rd(rng), 0xB00, rnd_rs(rng)),        # mcycle
        CSRRW(rnd_rd(rng), 0xC01, 0),                  # time
        LW(rnd_rd(rng), 14, off | 1),                  # misaligned load
        SH(rnd_rs(rng), off | 1, 14),                  # misaligned store
    ]                          # (the old RVE-violation bomb is a legal ADD
                               #  under RV32I and was removed — see D18)
    return [rng.choice(bombs)]


CSR_READS = [0x300, 0x301, 0x304, 0x305, 0x340, 0x341, 0x342, 0x344,
             0x3A0, 0x3B0, 0x3B1, 0x3B2, 0x3B3, 0xF11, 0xF12, 0xF13, 0xF14]


def t_csr(rng):
    c = rng.random()
    if c < 0.5:
        return [CSRRS(rnd_rd(rng), rng.choice(CSR_READS), 0)]
    if c < 0.8:  # scratch-class CSRs take arbitrary writes safely
        op = rng.choice([CSRRW, CSRRS, CSRRC])
        return [op(rnd_rd(rng), rng.choice([0x340, 0x341, 0x342]),
                   rnd_rs(rng))]
    if c < 0.9:  # pmpaddr: harmless while cfg stays unlocked/immediate-only
        return [CSRRW(rnd_rd(rng), 0x3B0 + rng.randrange(4), rnd_rs(rng))]
    # immediate forms; pmpcfg0 via zimm only (L bit unreachable: zimm<=31)
    op = rng.choice([CSRRWI, CSRRSI, CSRRCI])
    return [op(rnd_rd(rng), rng.choice([0x300, 0x340, 0x3A0]),
               rng.randrange(32))]


TEMPLATES = [
    (t_r, 15), (t_i, 15), (t_shift_imm, 6), (t_u, 6), (t_li, 6),
    (t_ldst, 20), (t_branch, 10), (t_loop, 4), (t_jal, 5), (t_jalr, 4),
    (t_trap, 6), (t_csr, 6),
]


def gen_body(seed, n_templates):
    rng = random.Random(seed)
    body = LI32(14, SCRATCH)
    for r in range(1, 32):
        if r not in (5, 14):
            body += LI32(r, rng.getrandbits(32))
    fns = [t for t, _ in TEMPLATES]
    wts = [w for _, w in TEMPLATES]
    for _ in range(n_templates):
        body += rng.choices(fns, weights=wts)[0](rng)
    return body + epilogue()
