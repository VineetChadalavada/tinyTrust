"""TinyTrust RV32I instruction encoders + ISS golden model.

(Module name kept as rv32e.py for import stability; the ISA is RV32I as of
docs/RETARGET.md D18.)

The ISS is written from the RISC-V spec and ARCHITECTURE.md (never from the
RTL source): it models the exact architectural choices — 32 architectural
registers, trap causes, mtval absent, WARL rules (mtvec 16-byte base,
MPP in {00,11}, NAPOT-only PMP with 1 KiB grain), unimplemented counters
trapping, FENCE=NOP / FENCE.I=illegal, WFI=NOP.

It emits one RVFI-style record per retired instruction, in the same
conventions the core documents:
  - mem_addr is word-aligned, rmask/wmask are byte lanes, rdata/wdata are
    full bus words (stores carry the lane-replicated bus pattern);
  - a fetch access fault retires with trap=1 and insn=0;
  - trapped instructions report rs1/rs2 per decode class, rd=0, mem all 0.

Memory model (shared with tb_core.v): 64 KiB RAM at 0x0000_0000; TOHOST
word at 0x0001_0000 (any write ends the test after that store retires,
reads return 0); everything else bus-faults.
"""

M32 = 0xFFFFFFFF
RAM_SIZE = 0x10000
TOHOST = 0x00010000


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


# ----------------------------------------------------------------------
# Encoders
# ----------------------------------------------------------------------
def _r(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _i(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _s(imm, rs2, rs1, f3, op):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           ((imm & 0x1F) << 7) | op


def _b(imm, rs2, rs1, f3):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def _u(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def _j(imm, rd):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           (rd << 7) | 0x6F


def LUI(rd, imm20):     return _u(imm20, rd, 0x37)
def AUIPC(rd, imm20):   return _u(imm20, rd, 0x17)
def JAL(rd, off):       return _j(off, rd)
def JALR(rd, rs1, imm): return _i(imm, rs1, 0, rd, 0x67)

def BEQ(rs1, rs2, off):  return _b(off, rs2, rs1, 0)
def BNE(rs1, rs2, off):  return _b(off, rs2, rs1, 1)
def BLT(rs1, rs2, off):  return _b(off, rs2, rs1, 4)
def BGE(rs1, rs2, off):  return _b(off, rs2, rs1, 5)
def BLTU(rs1, rs2, off): return _b(off, rs2, rs1, 6)
def BGEU(rs1, rs2, off): return _b(off, rs2, rs1, 7)

def LB(rd, rs1, imm):   return _i(imm, rs1, 0, rd, 0x03)
def LH(rd, rs1, imm):   return _i(imm, rs1, 1, rd, 0x03)
def LW(rd, rs1, imm):   return _i(imm, rs1, 2, rd, 0x03)
def LBU(rd, rs1, imm):  return _i(imm, rs1, 4, rd, 0x03)
def LHU(rd, rs1, imm):  return _i(imm, rs1, 5, rd, 0x03)
def SB(src, off, base): return _s(off, src, base, 0, 0x23)
def SH(src, off, base): return _s(off, src, base, 1, 0x23)
def SW(src, off, base): return _s(off, src, base, 2, 0x23)

def ADDI(rd, rs1, imm):  return _i(imm, rs1, 0, rd, 0x13)
def SLTI(rd, rs1, imm):  return _i(imm, rs1, 2, rd, 0x13)
def SLTIU(rd, rs1, imm): return _i(imm, rs1, 3, rd, 0x13)
def XORI(rd, rs1, imm):  return _i(imm, rs1, 4, rd, 0x13)
def ORI(rd, rs1, imm):   return _i(imm, rs1, 6, rd, 0x13)
def ANDI(rd, rs1, imm):  return _i(imm, rs1, 7, rd, 0x13)
def SLLI(rd, rs1, sh):   return _r(0x00, sh, rs1, 1, rd, 0x13)
def SRLI(rd, rs1, sh):   return _r(0x00, sh, rs1, 5, rd, 0x13)
def SRAI(rd, rs1, sh):   return _r(0x20, sh, rs1, 5, rd, 0x13)

def ADD(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 0, rd, 0x33)
def SUB(rd, rs1, rs2):  return _r(0x20, rs2, rs1, 0, rd, 0x33)
def SLL(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 1, rd, 0x33)
def SLT(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 2, rd, 0x33)
def SLTU(rd, rs1, rs2): return _r(0x00, rs2, rs1, 3, rd, 0x33)
def XOR(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 4, rd, 0x33)
def SRL(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 5, rd, 0x33)
def SRA(rd, rs1, rs2):  return _r(0x20, rs2, rs1, 5, rd, 0x33)
def OR(rd, rs1, rs2):   return _r(0x00, rs2, rs1, 6, rd, 0x33)
def AND(rd, rs1, rs2):  return _r(0x00, rs2, rs1, 7, rd, 0x33)

def CSRRW(rd, csr, rs1):  return _i(csr, rs1, 1, rd, 0x73)
def CSRRS(rd, csr, rs1):  return _i(csr, rs1, 2, rd, 0x73)
def CSRRC(rd, csr, rs1):  return _i(csr, rs1, 3, rd, 0x73)
def CSRRWI(rd, csr, z):   return _i(csr, z, 5, rd, 0x73)
def CSRRSI(rd, csr, z):   return _i(csr, z, 6, rd, 0x73)
def CSRRCI(rd, csr, z):   return _i(csr, z, 7, rd, 0x73)

ECALL  = 0x00000073
EBREAK = 0x00100073
MRET   = 0x30200073
WFI    = 0x10500073
FENCE  = 0x0000000F
FENCEI = 0x0000100F
NOP    = ADDI(0, 0, 0)


def LI32(rd, val):
    """lui+addi pair loading an arbitrary 32-bit value."""
    val &= M32
    lo = sext(val & 0xFFF, 12)
    hi = ((val - lo) >> 12) & 0xFFFFF
    if hi == 0:
        return [ADDI(rd, 0, lo)]
    return [LUI(rd, hi), ADDI(rd, rd, lo)]


# ----------------------------------------------------------------------
# RVFI-style record
# ----------------------------------------------------------------------
REC_FMT = ("{order:016x} {pc:08x} {insn:08x} {trap:x} {mode:x} {intr:x} "
           "{rs1a:02x} {rs1d:08x} {rs2a:02x} {rs2d:08x} "
           "{rda:02x} {rdd:08x} {pcw:08x} "
           "{mema:08x} {rmask:x} {wmask:x} {memr:08x} {memw:08x}")


def blank_rec():
    return dict(order=0, pc=0, insn=0, trap=0, mode=3, intr=0,
                rs1a=0, rs1d=0, rs2a=0, rs2d=0, rda=0, rdd=0, pcw=0,
                mema=0, rmask=0, wmask=0, memr=0, memw=0)


# ----------------------------------------------------------------------
# ISS
# ----------------------------------------------------------------------
class ISS:
    def __init__(self, program_words, reset_pc=0):
        self.ram = bytearray(RAM_SIZE)
        for i, w in enumerate(program_words):
            self.ram[i * 4:i * 4 + 4] = (w & M32).to_bytes(4, "little")
        self.regs = [0] * 32
        self.pc = reset_pc
        self.priv_m = True
        self.mstatus_mie = False
        self.mstatus_mpie = False
        self.mpp_m = False
        self.mtvec_base = 0          # bits [31:4]
        self.mepc = 0                # bits [31:2]
        self.mcause_irq = 0
        self.mcause_code = 0
        self.mscratch = 0
        self.mie_mtie = False
        self.mie_meie = False
        self.pmp_cfg = [0] * 4       # 5-bit {L, A(napot), X, W, R}
        self.pmp_addr = [0] * 4      # 23-bit pmpaddr[29:7]
        self.order = 0
        self.intr_flag = False
        self.tohost = None           # set to written value when test ends

    # ------------------------------------------------------- memory bus
    def bus_read(self, addr):
        """Word read at aligned addr -> (data, fault)."""
        if addr < RAM_SIZE:
            return int.from_bytes(self.ram[addr:addr + 4], "little"), False
        if addr == TOHOST:
            return 0, False
        return 0, True

    def bus_write(self, addr, data, strb):
        """Word write -> fault. Sets self.tohost on the magic address."""
        if addr < RAM_SIZE:
            for i in range(4):
                if strb & (1 << i):
                    self.ram[addr + i] = (data >> (8 * i)) & 0xFF
            return False
        if addr == TOHOST:
            self.tohost = data
            return False
        return True

    # ------------------------------------------------------------- PMP
    def pmp_allow(self, addr, kind):
        """kind in 'rwx'; mirrors the lean PMP semantics (NAPOT, G=7)."""
        hit_i = None
        for i in range(4):
            if not (self.pmp_cfg[i] >> 3) & 1:          # A != NAPOT
                continue
            pa = ((self.pmp_addr[i] << 7) | 0x7F) & 0x3FFFFFFF
            mask = (pa ^ (pa + 1)) & 0x3FFFFFFF
            if (((addr >> 2) ^ pa) & ~mask & 0x3FFFFFFF) == 0:
                hit_i = i
                break
        if hit_i is None:
            return self.priv_m
        cfg = self.pmp_cfg[hit_i]
        perm = {"r": cfg & 1, "w": (cfg >> 1) & 1, "x": (cfg >> 2) & 1}[kind]
        if self.priv_m:
            return (not ((cfg >> 4) & 1)) or bool(perm)  # unlocked entries
        return bool(perm)                                # don't bind M-mode

    # ------------------------------------------------------------- CSRs
    CSR_IMPL = (0x300, 0x301, 0x304, 0x305, 0x340, 0x341, 0x342, 0x344,
                0x3A0, 0x3B0, 0x3B1, 0x3B2, 0x3B3,
                0xF11, 0xF12, 0xF13, 0xF14)

    def csr_read(self, a):
        if a == 0x300:
            return ((0b11 if self.mpp_m else 0) << 11) | \
                   (self.mstatus_mpie << 7) | (self.mstatus_mie << 3)
        if a == 0x304:
            return (self.mie_meie << 11) | (self.mie_mtie << 7)
        if a == 0x305:
            return self.mtvec_base << 4
        if a == 0x340:
            return self.mscratch
        if a == 0x341:
            return self.mepc << 2
        if a == 0x342:
            return (self.mcause_irq << 31) | self.mcause_code
        if a == 0x344:
            return 0                       # irq lines tied off in this TB
        if a == 0x3A0:
            v = 0
            for i in range(4):
                c = self.pmp_cfg[i]
                byte = ((c >> 4) << 7) | ((0b11 if (c >> 3) & 1 else 0) << 3) \
                       | (c & 0b111)
                v |= byte << (8 * i)
            return v
        if 0x3B0 <= a <= 0x3B3:
            i = a - 0x3B0
            g = 0x7F if (self.pmp_cfg[i] >> 3) & 1 else 0
            return (self.pmp_addr[i] << 7) | g
        return 0                           # misa / id registers

    def csr_write(self, a, v):
        if a == 0x300:
            self.mstatus_mie = bool(v & (1 << 3))
            self.mstatus_mpie = bool(v & (1 << 7))
            self.mpp_m = ((v >> 11) & 0b11) == 0b11
        elif a == 0x304:
            self.mie_mtie = bool(v & (1 << 7))
            self.mie_meie = bool(v & (1 << 11))
        elif a == 0x305:
            self.mtvec_base = (v >> 4) & 0xFFFFFFF
        elif a == 0x340:
            self.mscratch = v & M32
        elif a == 0x341:
            self.mepc = (v >> 2) & 0x3FFFFFFF
        elif a == 0x342:
            self.mcause_irq = (v >> 31) & 1
            self.mcause_code = v & 0x1F
        elif a == 0x3A0:
            for i in range(4):
                if (self.pmp_cfg[i] >> 4) & 1:            # locked
                    continue
                byte = (v >> (8 * i)) & 0xFF
                napot = ((byte >> 3) & 0b11) == 0b11
                self.pmp_cfg[i] = ((byte >> 7) << 4) | (napot << 3) | \
                                  (byte & 0b111)
        elif 0x3B0 <= a <= 0x3B3:
            i = a - 0x3B0
            if not (self.pmp_cfg[i] >> 4) & 1:
                self.pmp_addr[i] = (v >> 7) & 0x7FFFFF
        # 0x301 misa, 0x344 mip: writes ignored

    # ------------------------------------------------------------ traps
    def trap_enter(self, code, rec=None):
        """Common trap entry. rec is the (partial) retire record for a
        synchronous exception, or None for an interrupt."""
        if rec is not None:
            rec["trap"] = 1
            rec["pcw"] = self.mtvec_base << 4
            rec["rda"] = rec["rdd"] = 0
            rec["mema"] = rec["rmask"] = rec["wmask"] = 0
            rec["memr"] = rec["memw"] = 0
        self.mepc = (self.pc >> 2) & 0x3FFFFFFF
        self.mcause_irq = 0 if rec is not None else 1
        self.mcause_code = code
        self.mstatus_mpie = self.mstatus_mie
        self.mstatus_mie = False
        self.mpp_m = self.priv_m
        self.priv_m = True
        self.pc = self.mtvec_base << 4
        self.intr_flag = True

    # ------------------------------------------------------------- step
    def step(self):
        """Execute one instruction; return its RVFI record, or None if an
        interrupt was taken (no retire). Sets self.tohost to end the run."""
        rec = blank_rec()
        rec["order"] = self.order
        rec["pc"] = self.pc
        rec["mode"] = 3 if self.priv_m else 0
        rec["intr"] = int(self.intr_flag)

        # (interrupt lines are tied off in the core_iss TB; when they are
        # driven, the check goes here — before the fetch, at the boundary)

        # fetch (PMP execute check, then bus)
        insn, fault = (0, True) if not self.pmp_allow(self.pc, "x") \
            else self.bus_read(self.pc)
        if fault:
            rec["insn"] = 0
            self.trap_enter(1, rec)
            self.order += 1
            self.intr_flag = True
            return rec
        rec["insn"] = insn
        self.order += 1

        op = insn & 0x7F
        rd = (insn >> 7) & 0x1F
        f3 = (insn >> 12) & 0x7
        rs1 = (insn >> 15) & 0x1F
        rs2 = (insn >> 20) & 0x1F
        f7 = (insn >> 25) & 0x7F
        imm_i = sext(insn >> 20, 12)
        imm_s = sext(((insn >> 25) << 5) | ((insn >> 7) & 0x1F), 12)
        imm_b = sext((((insn >> 31) & 1) << 12) | (((insn >> 7) & 1) << 11) |
                     (((insn >> 25) & 0x3F) << 5) | (((insn >> 8) & 0xF) << 1), 13)
        imm_u = insn & 0xFFFFF000
        imm_j = sext((((insn >> 31) & 1) << 20) | (((insn >> 12) & 0xFF) << 12) |
                     (((insn >> 20) & 1) << 11) | (((insn >> 21) & 0x3FF) << 1), 21)

        opimm_legal = (f7 == 0) if f3 == 1 else \
                      (f7 in (0x00, 0x20)) if f3 == 5 else True
        op_legal = True if f7 == 0 else \
                   (f3 in (0, 5)) if f7 == 0x20 else False

        is_lui = op == 0x37
        is_auipc = op == 0x17
        is_jal = op == 0x6F
        is_jalr = op == 0x67 and f3 == 0
        is_branch = op == 0x63 and f3 not in (2, 3)
        is_load = op == 0x03 and f3 in (0, 1, 2, 4, 5)
        is_store = op == 0x23 and f3 in (0, 1, 2)
        is_opimm = op == 0x13 and opimm_legal
        is_op = op == 0x33 and op_legal
        is_fence = op == 0x0F and f3 == 0
        is_system = op == 0x73
        is_csr = is_system and f3 not in (0, 4)
        is_csri = is_csr and (f3 & 4) != 0
        is_ecall = insn == ECALL
        is_ebreak = insn == EBREAK
        is_mret = insn == MRET
        is_wfi = insn == WFI

        uses_rs1 = is_op or is_opimm or is_load or is_store or is_branch \
            or is_jalr or (is_csr and not is_csri)
        uses_rs2 = is_op or is_store or is_branch
        uses_rd = is_lui or is_auipc or is_jal or is_jalr or is_load \
            or is_op or is_opimm or is_csr
        rs1_val = self.regs[rs1] if uses_rs1 else 0
        rs2_val = self.regs[rs2] if uses_rs2 else 0
        rec["rs1a"], rec["rs1d"] = (rs1, rs1_val) if uses_rs1 else (0, 0)
        rec["rs2a"], rec["rs2d"] = (rs2, rs2_val) if uses_rs2 else (0, 0)

        csr_a = (insn >> 20) & 0xFFF
        csr_do_write = (f3 & 3) == 1 or rs1 != 0
        csr_illegal = is_csr and (csr_a not in self.CSR_IMPL
                                  or (csr_do_write and (csr_a >> 10) == 0b11)
                                  or not self.priv_m)
        sys_priv_ok = is_ecall or is_ebreak or is_wfi \
            or (is_mret and self.priv_m)
        decode_ok = (is_lui or is_auipc or is_jal or is_jalr or is_branch
                     or is_load or is_store or is_opimm or is_op or is_fence
                     or (is_csr and not csr_illegal)
                     or (is_system and f3 == 0 and sys_priv_ok))
        if not decode_ok:
            # illegal instructions report zero rs fields
            rec["rs1a"] = rec["rs1d"] = rec["rs2a"] = rec["rs2d"] = 0
            self.trap_enter(2, rec)
            return rec

        def retire(next_pc, wb=None):
            """wb = (rd, value); handles the jump-misalignment trap."""
            is_ct = is_jalr or is_jal or (is_branch and next_pc != (self.pc + 4) % (1 << 32))
            if is_ct and next_pc & 0b11:
                self.trap_enter(0, rec)
                return
            rec["pcw"] = next_pc
            if wb is not None and wb[0] != 0:
                self.regs[wb[0]] = wb[1] & M32
                rec["rda"], rec["rdd"] = wb[0], wb[1] & M32
            elif wb is not None:
                rec["rda"], rec["rdd"] = 0, 0
            self.pc = next_pc
            self.intr_flag = False

        pc4 = (self.pc + 4) & M32

        if is_lui:
            retire(pc4, (rd, imm_u))
        elif is_auipc:
            retire(pc4, (rd, (self.pc + imm_u) & M32))
        elif is_jal:
            retire((self.pc + imm_j) & M32, (rd, pc4))
        elif is_jalr:
            retire((rs1_val + imm_i) & M32 & ~1, (rd, pc4))
        elif is_branch:
            a, b = rs1_val, rs2_val
            sa, sb_ = sext(a, 32), sext(b, 32)
            taken = {0: a == b, 1: a != b, 4: sa < sb_, 5: sa >= sb_,
                     6: a < b, 7: a >= b}[f3]
            retire((self.pc + imm_b) & M32 if taken else pc4)
        elif is_load or is_store:
            imm = imm_i if is_load else imm_s
            addr = (rs1_val + imm) & M32
            size = f3 & 3
            if (size == 1 and addr & 1) or (size == 2 and addr & 3):
                self.trap_enter(6 if is_store else 4, rec)
                return rec
            aligned = addr & ~3
            lane = addr & 3
            if is_store:
                strb = {0: 1 << lane, 1: 0b1100 if addr & 2 else 0b0011,
                        2: 0b1111}[size]
                wdata = {0: (rs2_val & 0xFF) * 0x01010101,
                         1: ((rs2_val & 0xFFFF) << 16) | (rs2_val & 0xFFFF),
                         2: rs2_val}[size]
                if not self.pmp_allow(addr, "w") or \
                        self.bus_write(aligned, wdata, strb):
                    self.trap_enter(7, rec)
                    return rec
                rec["mema"], rec["wmask"], rec["memw"] = aligned, strb, wdata
                retire(pc4)
            else:
                if not self.pmp_allow(addr, "r"):
                    self.trap_enter(5, rec)
                    return rec
                word, fault = self.bus_read(aligned)
                if fault:
                    self.trap_enter(5, rec)
                    return rec
                sh = word >> (8 * lane)
                val = {0: sext(sh, 8) & M32, 4: sh & 0xFF,
                       1: sext(sh, 16) & M32, 5: sh & 0xFFFF,
                       2: word}[f3]
                rec["mema"] = aligned
                rec["rmask"] = {0: 1 << lane, 1: 0b1100 if addr & 2 else 0b0011,
                                2: 0b1111}[size]
                rec["memr"] = word
                retire(pc4, (rd, val))
        elif is_opimm or is_op:
            b = rs2_val if is_op else imm_i & M32
            a = rs1_val
            sa, sb_ = sext(a, 32), sext(b & M32, 32)
            sh = (rs2_val & 0x1F) if is_op else rs2
            res = {
                0: (a - b if (is_op and f7 == 0x20) else a + b),
                1: a << sh,
                2: int(sa < sb_),
                3: int(a < (b & M32)),
                4: a ^ b,
                5: (sa >> sh) if (insn >> 30) & 1 else (a >> sh),
                6: a | b,
                7: a & b,
            }[f3]
            retire(pc4, (rd, res & M32))
        elif is_csr:
            old = self.csr_read(csr_a) & M32
            src = rs1 if is_csri else rs1_val
            wval = {1: src, 2: old | src, 3: old & ~src}[f3 & 3] & M32
            if csr_do_write:
                self.csr_write(csr_a, wval)
            retire(pc4, (rd, old))
        elif is_ecall:
            self.trap_enter(11 if self.priv_m else 8, rec)
        elif is_ebreak:
            self.trap_enter(3, rec)
        elif is_mret:
            self.mstatus_mie = self.mstatus_mpie
            self.mstatus_mpie = True
            self.priv_m = self.mpp_m
            self.mpp_m = False
            rec["pcw"] = self.mepc << 2
            self.pc = self.mepc << 2
            self.intr_flag = False
        else:  # wfi / fence: NOP
            retire(pc4)
        return rec

    def run(self, max_steps):
        lines = []
        for _ in range(max_steps):
            rec = self.step()
            if rec is not None:
                lines.append(REC_FMT.format(**rec))
            if self.tohost is not None:
                return lines, self.tohost
        return lines, None
