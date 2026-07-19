"""Directed test programs for vplan §3.1 (core ISA, layer L2).

Each entry in TESTS returns (body_words, handler_or_None). The checker is
the lockstep RVFI compare against the ISS; these programs exist to hit the
directed corners the vplan calls out. Testpoint IDs are noted per test.
"""
from rv32e import *
from rv32e import _r, _i
from progbuild import SCRATCH, BODY, epilogue

CORNERS = [0, 1, 2, -1, -2, 0x7FFFFFFF, 0x80000000, 0x7FFFFFFE,
           0x80000001, 0x55555555, 0xAAAAAAAA]

R_OPS = [ADD, SUB, SLT, SLTU, XOR, OR, AND, SLL, SRL, SRA]
I_OPS = [ADDI, SLTI, SLTIU, XORI, ORI, ANDI]


def t_smoke():
    body = [ADDI(1, 0, 5), ADDI(2, 1, 7), SLLI(3, 2, 4), SUB(4, 3, 1)]
    return body + epilogue(), None


def t_arith_r():
    """CPU-ARITH-01/02, CPU-SHIFT-01(reg): all R-ops x corner operand pairs."""
    body = []
    rd = 3
    for a in CORNERS:
        for b in CORNERS:
            body += LI32(8, a) + LI32(9, b)
            for op in R_OPS:
                body.append(op(rd, 8, 9))
                rd = 3 if rd == 13 else rd + 1
    return body + epilogue(), None


def t_arith_i():
    """CPU-ARITH-01/02 (I-form), CPU-IMM-01: corner rs1 x corner imm."""
    body = []
    rd = 3
    for a in CORNERS:
        body += LI32(8, a)
        for imm in (-2048, -1, 0, 1, 7, 2047):
            for op in I_OPS:
                body.append(op(rd, 8, imm))
                rd = 3 if rd == 13 else rd + 1
    return body + epilogue(), None


def t_shift_imm():
    """CPU-SHIFT-01: SLLI/SRLI/SRAI x shamt {0,1,31,17} x corner operands."""
    body = []
    for a in (0x80000000, 0xFFFFFFFF, 1, 0xA5A5A5A5, 0x7FFFFFFF):
        body += LI32(8, a)
        for sh in (0, 1, 31, 17):
            body += [SLLI(3, 8, sh), SRLI(4, 8, sh), SRAI(6, 8, sh)]
    # shift-by-register with amounts > 31 in the register (only [4:0] count)
    body += LI32(8, 0x80000001) + LI32(9, 33) + \
        [SLL(3, 8, 9), SRL(4, 8, 9), SRA(6, 8, 9)]
    return body + epilogue(), None


def t_lui_auipc():
    """CPU-IMM-01: U-type corners."""
    body = []
    for imm20 in (0, 1, 0xFFFFF, 0x80000, 0x7FFFF, 0xABCDE):
        body += [LUI(3, imm20), AUIPC(4, imm20), LUI(0, imm20)]
    return body + epilogue(), None


def t_branch():
    """CPU-BR-01: all branches, taken/not-taken, forward and backward."""
    body = []
    pairs = [(0, 0), (0, 1), (1, 0), (-1, 1), (1, -1),
             (0x80000000, 0x7FFFFFFF), (0x7FFFFFFF, 0x80000000), (-1, -1)]
    for a, b in pairs:
        body += LI32(8, a) + LI32(9, b)
        for br in (BEQ, BNE, BLT, BGE, BLTU, BGEU):
            # forward: skip one marker instruction if taken
            body += [br(8, 9, 8), ADDI(7, 7, 1)]
            # backward: check jumps back to the marker if taken
            body += [ADDI(7, 0, 0),
                     JAL(0, 12),           # -> check
                     ADDI(7, 7, 1),        # back:
                     JAL(0, 8),            # -> done
                     br(8, 9, -8)]         # check: taken -> back
    return body + epilogue(), None


def t_jump():
    """CPU-JMP-01: JAL/JALR incl. rd=x0, lsb clearing, misaligned targets."""
    body = [
        JAL(1, 8), NOP,                    # forward, link in x1
        JAL(0, 8), NOP,                    # rd = x0
        JAL(6, 6),                         # imm[1]=1: misaligned -> trap 0
        # JALR: x6 = pc; jump to pc+16 (skips the NOP filler)
        AUIPC(6, 0), ADDI(6, 6, 16), JALR(1, 6, 0), NOP,
        # JALR with bit 0 set: cleared by hardware, lands on pc+16
        AUIPC(6, 0), ADDI(6, 6, 17), JALR(0, 6, 0), NOP,
        # JALR to pc+18: bit 1 set -> misaligned trap, handler skips jalr
        AUIPC(6, 0), ADDI(6, 6, 18), JALR(1, 6, 0), NOP,
    ]
    return body + epilogue(), None


def t_ldst():
    """CPU-LS-01: all sizes, all byte lanes, sign/zero extension."""
    body = LI32(14, SCRATCH)
    body += LI32(8, 0xDEADBEEF) + [SW(8, 0, 14)]
    body += LI32(8, 0x80808080) + [SW(8, 4, 14)]
    # byte stores into word 2, halfword stores into word 3
    body += LI32(8, 0x000000A5)
    body += [SB(8, 8, 14), SB(8, 9, 14), SB(8, 10, 14), SB(8, 11, 14)]
    body += LI32(8, 0x00008765) + [SH(8, 12, 14), SH(8, 14, 14)]
    # loads: every lane, sign and zero extension
    for off in (0, 1, 2, 3, 4, 5, 6, 7, 8):
        body += [LB(3, 14, off), LBU(4, 14, off)]
    for off in (0, 2, 4, 6, 12, 14):
        body += [LH(3, 14, off), LHU(4, 14, off)]
    body += [LW(3, 14, 0), LW(4, 14, 4), LW(0, 14, 0)]  # incl. rd = x0
    # negative offsets
    body += LI32(9, SCRATCH + 16) + [LW(3, 9, -16), SB(8, -12, 9)]
    return body + epilogue(), None


def t_ls_misaligned():
    """CPU-LS-02: misaligned load/store -> trap 4/6, no side effect."""
    body = LI32(14, SCRATCH)
    body += LI32(8, 0x11223344) + [SW(8, 0, 14), SW(8, 4, 14)]
    body += [LH(3, 14, 1), LHU(3, 14, 3),          # cause 4
             LW(3, 14, 1), LW(3, 14, 2), LW(3, 14, 3),
             SH(8, 1, 14), SH(8, 3, 14),           # cause 6
             SW(8, 1, 14), SW(8, 2, 14), SW(8, 3, 14),
             LW(3, 14, 0)]                         # word must be intact
    return body + epilogue(), None


def t_ls_fault():
    """Load/store access faults (cause 5/7) from unmapped addresses; reads
    of the TOHOST word return 0 without fault."""
    body = LI32(9, 0x00020000)
    body += [LW(3, 9, 0), LB(3, 9, 1), SW(9, 0, 9), SB(9, 2, 9)]
    body += LI32(9, 0x40000000) + [LW(3, 9, 0), SW(9, 0, 9)]
    body += LI32(9, TOHOST) + [LW(3, 9, 0)]        # reads as 0, no fault
    return body + epilogue(), None


def t_fetch_fault():
    """Instruction access fault (cause 1) via a wild JALR; custom handler
    redirects mepc to the resume point instead of skipping."""
    resume = BODY + 3 * 4
    handler = LI32(5, resume) + [CSRRW(0, 0x341, 5), MRET]
    assert len(handler) == 3
    body = [LUI(9, 0x20), JALR(1, 9, 0), NOP]      # jalr -> 0x20000: fault
    return body + epilogue(), handler


def t_rve():
    """CPU-RVE-01: any x16..x31 reference in a used field -> illegal."""
    body = [ADDI(3, 0, 7),
            ADD(17, 1, 2), ADD(3, 17, 2), ADD(3, 1, 18),
            ADDI(19, 0, 1), ADDI(3, 20, 1),
            LUI(22, 1), AUIPC(23, 1),
            LW(3, 20, 0), LW(21, 1, 0),
            SW(21, 0, 1), SB(1, 0, 21),
            JAL(24, 8), JALR(3, 25, 0), JALR(26, 1, 0),
            BEQ(27, 0, 8), BNE(0, 28, 8),
            CSRRW(3, 0x340, 29), CSRRW(30, 0x340, 1),
            CSRRWI(31, 0x340, 5),
            ADD(3, 3, 3)]                          # still alive afterwards
    return body + epilogue(), None


def t_illegal():
    """CPU-ILL-01: unknown opcodes, M-extension, FENCE.I, S-mode returns,
    unimplemented and read-only CSRs -> illegal instruction trap."""
    mul = _r(1, 2, 1, 0, 3, 0x33)
    div = _r(1, 2, 1, 4, 3, 0x33)
    body = [0x00000000, 0xFFFFFFFF, 0x00000001, 0x0000FFFF,
            mul, div,
            FENCEI,
            0x10200073,                            # sret
            0x00200073,                            # uret
            _i(0, 0, 0, 1, 0x73),                  # ecall with rd != 0
            _i(0x300, 0, 4, 3, 0x73),              # SYSTEM funct3=100
            CSRRW(3, 0xB00, 1),                    # mcycle: unimplemented
            CSRRW(3, 0xB02, 1),                    # minstret
            CSRRS(3, 0xC00, 1),                    # cycle (also read-only)
            CSRRW(3, 0x3A1, 1),                    # pmpcfg1: not present
            CSRRW(3, 0x3B4, 1),                    # pmpaddr4: not present
            CSRRW(3, 0x105, 1),                    # stvec: no S-mode
            CSRRW(3, 0xF14, 1),                    # write to read-only
            CSRRS(3, 0xF11, 1),                    # set with rs1 != 0
            CSRRCI(3, 0xF12, 1),                   # clear with zimm != 0
            CSRRS(3, 0xF11, 0),                    # LEGAL: read-only read
            CSRRSI(3, 0xF13, 0),                   # LEGAL
            ADD(3, 3, 3)]
    return body + epilogue(), None


def t_csr_warl():
    """PRV-CSR-01 subset runnable at M1: WARL fields on every implemented
    CSR; RW/RS/RC/immediates; PMP cfg A-field and grain readback."""
    body = LI32(8, 0xFFFFFFFF)
    body += [
        # mscratch: full RW + set/clear
        CSRRW(3, 0x340, 8), CSRRS(3, 0x340, 0),
        CSRRWI(3, 0x340, 0x15), CSRRS(3, 0x340, 0),
        CSRRSI(3, 0x340, 0x0A), CSRRCI(3, 0x340, 0x11), CSRRS(3, 0x340, 0),
        # mtvec: all-ones -> base 16-byte aligned; then restore handler base
        CSRRW(3, 0x305, 8), CSRRS(4, 0x305, 0),
        ADDI(5, 0, 0x100), CSRRW(0, 0x305, 5),
        # mepc / mcause WARL
        CSRRW(3, 0x341, 8), CSRRS(4, 0x341, 0),
        CSRRW(3, 0x342, 8), CSRRS(4, 0x342, 0),
        # mstatus: MPP pins to 00 or 11
        CSRRW(3, 0x300, 8), CSRRS(4, 0x300, 0),
        CSRRW(3, 0x300, 0), CSRRS(4, 0x300, 0)]
    body += LI32(9, 0x0800)
    body += [CSRRW(3, 0x300, 9), CSRRS(4, 0x300, 0)]   # MPP=01 -> 00
    body += [
        # misa / mip writes ignored; id registers read zero
        CSRRW(3, 0x301, 8), CSRRS(4, 0x301, 0),
        CSRRW(3, 0x344, 8), CSRRS(4, 0x344, 0),
        CSRRS(3, 0xF11, 0), CSRRS(3, 0xF12, 0),
        CSRRS(3, 0xF13, 0), CSRRS(3, 0xF14, 0),
        # mie: only MTIE/MEIE stick
        CSRRW(3, 0x304, 8), CSRRS(4, 0x304, 0), CSRRW(3, 0x304, 0)]
    body += [
        # PMP WARL (PMP-WARL-01 sim half): pmpaddr grain bits under OFF/NAPOT
        CSRRW(3, 0x3B0, 8), CSRRS(4, 0x3B0, 0),        # A=OFF: grain reads 0
        CSRRWI(3, 0x3A0, 0x1F), CSRRS(4, 0x3A0, 0),    # NAPOT+XWR sticks
        CSRRS(4, 0x3B0, 0),                            # grain reads ones
        CSRRWI(3, 0x3A0, 0x0F), CSRRS(4, 0x3A0, 0),    # TOR -> OFF
        CSRRWI(3, 0x3A0, 0x17), CSRRS(4, 0x3A0, 0),    # NA4 -> OFF
        CSRRWI(0, 0x3A0, 0)]                           # clean up
    return body + epilogue(), None


def t_traps_sys():
    """PRV-ECALL-01(M)/breakpoint/WFI/FENCE; mcause/mepc readback after."""
    body = [ECALL, CSRRS(3, 0x342, 0), CSRRS(4, 0x341, 0),
            EBREAK, CSRRS(3, 0x342, 0),
            WFI, FENCE,
            ADD(3, 3, 3)]
    return body + epilogue(), None


def t_x0():
    """CPU-X0-01 (sim half): x0 never written, reads as zero."""
    body = LI32(14, SCRATCH)
    body += LI32(8, 0x12345678) + [SW(8, 0, 14)]
    body += [ADDI(0, 0, 5), LUI(0, 0xFFFFF), AUIPC(0, 1),
             LW(0, 14, 0), CSRRW(0, 0x340, 8), CSRRS(0, 0x340, 0),
             JAL(0, 8), NOP,
             ADD(3, 0, 0), SLTIU(4, 0, 1)]         # x0==0 -> x4=1
    return body + epilogue(), None


TESTS = {
    "smoke": t_smoke,
    "arith_r": t_arith_r,
    "arith_i": t_arith_i,
    "shift_imm": t_shift_imm,
    "lui_auipc": t_lui_auipc,
    "branch": t_branch,
    "jump": t_jump,
    "ldst": t_ldst,
    "ls_misaligned": t_ls_misaligned,
    "ls_fault": t_ls_fault,
    "fetch_fault": t_fetch_fault,
    "rve": t_rve,
    "illegal": t_illegal,
    "csr_warl": t_csr_warl,
    "traps_sys": t_traps_sys,
    "x0": t_x0,
}
