// TinyTrust — RV32I multicycle core (ARCHITECTURE.md §5; RV32E->RV32I per
// docs/RETARGET.md D18)
//
// One instruction fully retires before the next fetch. Shared-everything
// datapath (D1): a single adder/subtractor serves PC+4, branch/jump targets,
// effective addresses, ADD/SUB and all compares; shifts are iterative,
// 1 bit/cycle (D5). Privilege = M/U with the lean PMP (D6); bus is
// single-outstanding valid/ready (D10).
//
// Decisions fixed at RTL time (recorded in ARCHITECTURE.md):
//   - mcycle/minstret and all other counter CSRs are unimplemented: access
//     traps as illegal instruction (trap-and-emulate path).
//   - FENCE is a NOP; FENCE.I traps (Zifencei not claimed; no caches).
//   - WFI is a NOP (spec-legal).
//   - mstatus.MPP WARL: writes of 01/10 map to 00 (U).
//   - FSM fault forced trap uses mcause = 0x8000_0018 (platform interrupt
//     code 24); it does not produce an RVFI retire.
//
// RVFI port is always present (vplan: a design requirement, not an
// afterthought); synthesis trims it when unconnected. Conventions:
//   - rvfi_mem_addr is the word-aligned address; rmask/wmask are byte lanes
//     within that word; rdata/wdata are the full bus words (stores carry the
//     lane-replicated pattern actually driven on the bus).
//   - A fetch access fault retires with rvfi_trap=1 and rvfi_insn=0.
//   - Interrupt entry produces no retire; the handler's first retired
//     instruction carries rvfi_intr=1.

module core #(
    parameter [31:0] RESET_PC = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst_n,

    // internal bus (ARCHITECTURE.md §6): single outstanding transaction
    output wire        bus_valid,
    output wire [31:0] bus_addr,
    output wire [31:0] bus_wdata,
    output wire [3:0]  bus_wstrb,     // nonzero = store
    output wire        bus_is_fetch,
    input  wire        bus_ready,
    input  wire [31:0] bus_rdata,
    input  wire        bus_fault,     // decode error / target fault

    // interrupt lines (already synchronized at SoC level)
    input  wire        irq_timer,
    input  wire        irq_external,

    // fault hardening (§5.5): sticky until reset
    output wire        fsm_fault

    // RVFI retire interface. Verification-only, so it is compiled out of
    // synthesis and P&R builds: left in, it costs ~5.2 kGE (21% of core
    // area) and 383 of 492 port bits on sg13g2 typ. riscv-formal defines
    // RISCV_FORMAL in its generated defines.sv; the ISS co-sim passes
    // -DRISCV_FORMAL to iverilog. See docs/RETARGET.md milestone P0.
`ifdef RISCV_FORMAL
    ,
    output reg         rvfi_valid,
    output reg  [63:0] rvfi_order,
    output reg  [31:0] rvfi_insn,
    output reg         rvfi_trap,
    output wire        rvfi_halt,
    output reg         rvfi_intr,
    output reg  [1:0]  rvfi_mode,
    output wire [1:0]  rvfi_ixl,
    output reg  [4:0]  rvfi_rs1_addr,
    output reg  [4:0]  rvfi_rs2_addr,
    output reg  [31:0] rvfi_rs1_rdata,
    output reg  [31:0] rvfi_rs2_rdata,
    output reg  [4:0]  rvfi_rd_addr,
    output reg  [31:0] rvfi_rd_wdata,
    output reg  [31:0] rvfi_pc_rdata,
    output reg  [31:0] rvfi_pc_wdata,
    output reg  [31:0] rvfi_mem_addr,
    output reg  [3:0]  rvfi_mem_rmask,
    output reg  [3:0]  rvfi_mem_wmask,
    output reg  [31:0] rvfi_mem_rdata,
    output reg  [31:0] rvfi_mem_wdata
`endif
);

`ifdef RISCV_FORMAL
    assign rvfi_halt = 1'b0;
    assign rvfi_ixl  = 2'b01;
`endif

    // ------------------------------------------------------------------
    // FSM: one-hot with validity check (§5.5 / UAR-FSM-01). Any non-one-hot
    // state or privilege-shadow mismatch forces a trap with a reserved cause.
    // ------------------------------------------------------------------
    localparam S_FETCH = 0, S_EX = 1, S_EX2 = 2, S_SHIFT = 3,
               S_MEM   = 4, S_WB = 5, S_TRAP = 6;
    localparam [6:0] ST_FETCH = 7'b0000001, ST_EX  = 7'b0000010,
                     ST_EX2   = 7'b0000100, ST_SHF = 7'b0001000,
                     ST_MEM   = 7'b0010000, ST_WB  = 7'b0100000,
                     ST_TRAP  = 7'b1000000;

    reg [6:0] state;

    // exception cause codes (mcause[4:0])
    localparam [4:0] EXC_IALIGN = 5'd0,  EXC_IFAULT = 5'd1,
                     EXC_ILL    = 5'd2,  EXC_BREAK  = 5'd3,
                     EXC_LALIGN = 5'd4,  EXC_LFAULT = 5'd5,
                     EXC_SALIGN = 5'd6,  EXC_SFAULT = 5'd7,
                     EXC_ECALLU = 5'd8,  EXC_ECALLM = 5'd11,
                     EXC_FSM    = 5'd24;   // reserved/platform: FSM fault

    // ------------------------------------------------------------------
    // Architectural + working state
    // ------------------------------------------------------------------
    reg [31:0] pc;
    reg [31:0] instr;
    reg [31:0] pc_plus4;
    reg [31:0] result;        // ALU out / CSR old value / LUI imm / shift work
    reg [31:0] addr_r;        // effective address / jump target
    reg        br_taken;
    reg [4:0]  shcnt;
    reg [31:0] mem_rdata_r;
    reg        fetch_issued;  // a fetch transaction is on the bus

    reg        priv_m_q;      // 1 = M-mode
    reg        priv_m_shadow; // duplicated privilege state (§5.5)

    // CSR state
    reg        mstatus_mie, mstatus_mpie, mpp_m;   // MPP stored as one bit
    reg [27:0] mtvec_base;                          // mtvec[31:4]
    reg [29:0] mepc_r;                              // mepc[31:2]
    reg        mcause_irq;
    reg [4:0]  mcause_code;
    reg [31:0] mscratch;
    reg        mie_mtie, mie_meie;

    reg [4:0]  trap_code;     // latched cause for S_TRAP
    reg        trap_irq;

    reg        intr_flag;     // next retire is first instruction of a handler
    reg [63:0] order_cnt;
    reg        fsm_fault_sticky;

    // per-instruction RVFI memory-access capture
    reg [31:0] cap_mem_addr, cap_mem_rdata, cap_mem_wdata;
    reg [3:0]  cap_mem_rmask, cap_mem_wmask;

    // ------------------------------------------------------------------
    // Decode
    // ------------------------------------------------------------------
    wire [6:0] opcode = instr[6:0];
    wire [4:0] rd     = instr[11:7];
    wire [2:0] funct3 = instr[14:12];
    wire [4:0] rs1    = instr[19:15];
    wire [4:0] rs2    = instr[24:20];
    wire [6:0] funct7 = instr[31:25];

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7],
                         instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12],
                         instr[20], instr[30:21], 1'b0};

    wire opimm_legal = (funct3 == 3'b001) ? (funct7 == 7'b0000000) :
                       (funct3 == 3'b101) ? (funct7 == 7'b0000000 ||
                                             funct7 == 7'b0100000) : 1'b1;
    wire op_legal = (funct7 == 7'b0000000) ? 1'b1 :
                    (funct7 == 7'b0100000) ? (funct3 == 3'b000 ||
                                              funct3 == 3'b101) : 1'b0;

    wire is_lui    = (opcode == 7'b0110111);
    wire is_auipc  = (opcode == 7'b0010111);
    wire is_jal    = (opcode == 7'b1101111);
    wire is_jalr   = (opcode == 7'b1100111) && (funct3 == 3'b000);
    wire is_branch = (opcode == 7'b1100011) && (funct3 != 3'b010)
                                            && (funct3 != 3'b011);
    wire is_load   = (opcode == 7'b0000011) && (funct3 != 3'b011)
                     && (funct3 != 3'b110) && (funct3 != 3'b111);
    wire is_store  = (opcode == 7'b0100011) && (funct3[2] == 1'b0)
                                            && (funct3 != 3'b011);
    wire is_opimm  = (opcode == 7'b0010011) && opimm_legal;
    wire is_op     = (opcode == 7'b0110011) && op_legal;
    wire is_fence  = (opcode == 7'b0001111) && (funct3 == 3'b000); // FENCE=NOP

    wire is_system = (opcode == 7'b1110011);
    wire is_csr    = is_system && (funct3 != 3'b000) && (funct3 != 3'b100);
    wire is_csri   = is_csr && funct3[2];
    wire is_ecall  = (instr == 32'h0000_0073);
    wire is_ebreak = (instr == 32'h0010_0073);
    wire is_mret   = (instr == 32'h3020_0073);
    wire is_wfi    = (instr == 32'h1050_0073);                     // WFI=NOP
    wire sys_priv_ok = is_ecall | is_ebreak | is_wfi | (is_mret && priv_m_q);

    // Which register fields this instruction actually reads/writes. Drives the
    // regfile write enable and the RVFI report. (Under RV32E this also gated
    // an x16..x31 illegal-instruction check; RV32I has no such restriction —
    // docs/RETARGET.md D18.)
    wire uses_rs1 = is_op | is_opimm | is_load | is_store | is_branch
                  | is_jalr | (is_csr && !is_csri);
    wire uses_rs2 = is_op | is_store | is_branch;
    wire uses_rd  = is_lui | is_auipc | is_jal | is_jalr | is_load
                  | is_op | is_opimm | is_csr;

    // ------------------------------------------------------------------
    // Register file
    // ------------------------------------------------------------------
    wire [31:0] rs1_val, rs2_val, rd_wdata;
    wire target_misaligned;
    wire rf_we = state[S_WB] && !target_misaligned && uses_rd;

    regfile u_regfile (
        .clk    (clk),
        .we     (rf_we),
        .waddr  (rd),
        .wdata  (rd_wdata),
        .raddr1 (rs1),
        .rdata1 (rs1_val),
        .raddr2 (rs2),
        .rdata2 (rs2_val)
    );

    // ------------------------------------------------------------------
    // Shared adder/subtractor (the only 32-bit adder in the core)
    // ------------------------------------------------------------------
    reg  [31:0] add_a, add_b;
    reg         add_sub;
    wire [32:0] add_y   = {1'b0, add_a}
                        + {1'b0, add_sub ? ~add_b : add_b}
                        + {32'b0, add_sub};
    wire [31:0] add_res = add_y[31:0];
    wire        lt_u    = ~add_y[32];                       // when subtracting
    wire        lt_s    = (add_a[31] != add_b[31]) ? add_a[31] : add_res[31];
    wire        cmp_eq  = (add_res == 32'd0);

    wire cmp_op    = (funct3 == 3'b010) || (funct3 == 3'b011); // SLT/SLTU
    wire op_sub    = ((funct3 == 3'b000) && funct7[5]) || cmp_op;

    always @* begin
        add_a = pc; add_b = 32'd4; add_sub = 1'b0;   // FETCH default: PC+4
        if (state[S_EX]) begin
            case (1'b1)
                is_op:     begin add_a = rs1_val; add_b = rs2_val; add_sub = op_sub; end
                is_opimm:  begin add_a = rs1_val; add_b = imm_i;   add_sub = cmp_op; end
                is_branch: begin add_a = rs1_val; add_b = rs2_val; add_sub = 1'b1;  end
                is_load:   begin add_a = rs1_val; add_b = imm_i; end
                is_store:  begin add_a = rs1_val; add_b = imm_s; end
                is_jal:    begin add_a = pc;      add_b = imm_j; end
                is_jalr:   begin add_a = rs1_val; add_b = imm_i; end
                is_auipc:  begin add_a = pc;      add_b = imm_u; end
                default: ;
            endcase
        end else if (state[S_EX2]) begin
            add_a = pc; add_b = imm_b;               // taken-branch target
        end
    end

    // Logic unit + ALU result mux (shifts handled in S_SHIFT)
    wire [31:0] op2 = is_op ? rs2_val : imm_i;
    reg  [31:0] alu_res;
    always @* begin
        case (funct3)
            3'b010:  alu_res = {31'd0, lt_s};
            3'b011:  alu_res = {31'd0, lt_u};
            3'b100:  alu_res = rs1_val ^ op2;
            3'b110:  alu_res = rs1_val | op2;
            3'b111:  alu_res = rs1_val & op2;
            default: alu_res = add_res;              // ADD/SUB/ADDI
        endcase
    end

    wire is_shift = (is_op | is_opimm)
                  && (funct3 == 3'b001 || funct3 == 3'b101);
    wire [4:0] shamt = is_op ? rs2_val[4:0] : rs2;
    wire shift_left  = (funct3 == 3'b001);
    wire [31:0] shift_next = shift_left
                           ? {result[30:0], 1'b0}
                           : {instr[30] & result[31], result[31:1]};

    reg br_cond;
    always @* begin
        case (funct3)
            3'b000:  br_cond = cmp_eq;
            3'b001:  br_cond = !cmp_eq;
            3'b100:  br_cond = lt_s;
            3'b101:  br_cond = !lt_s;
            3'b110:  br_cond = lt_u;
            default: br_cond = !lt_u;                // 111 = BGEU
        endcase
    end

    // ------------------------------------------------------------------
    // Load/store lanes
    // ------------------------------------------------------------------
    wire ls_misaligned = (funct3[1:0] == 2'b01 && add_res[0])
                       | (funct3[1:0] == 2'b10 && add_res[1:0] != 2'b00);

    reg [3:0]  lane_mask;
    reg [31:0] store_wdata;
    always @* begin
        case (funct3[1:0])
            2'b00: begin
                lane_mask   = 4'b0001 << addr_r[1:0];
                store_wdata = {4{rs2_val[7:0]}};
            end
            2'b01: begin
                lane_mask   = addr_r[1] ? 4'b1100 : 4'b0011;
                store_wdata = {2{rs2_val[15:0]}};
            end
            default: begin
                lane_mask   = 4'b1111;
                store_wdata = rs2_val;
            end
        endcase
    end

    wire [31:0] lw_shifted = mem_rdata_r >> {addr_r[1:0], 3'b000};
    reg  [31:0] load_val;
    always @* begin
        case (funct3)
            3'b000:  load_val = {{24{lw_shifted[7]}},  lw_shifted[7:0]};
            3'b100:  load_val = {24'd0,                lw_shifted[7:0]};
            3'b001:  load_val = {{16{lw_shifted[15]}}, lw_shifted[15:0]};
            3'b101:  load_val = {16'd0,                lw_shifted[15:0]};
            default: load_val = mem_rdata_r;
        endcase
    end

    // ------------------------------------------------------------------
    // PMP (CSR state lives in pmp.v; check port is shared fetch/data —
    // only one access exists at a time in a multicycle core)
    // ------------------------------------------------------------------
    wire [31:0] pmp_cfg_rd, pmp_a0_rd, pmp_a1_rd, pmp_a2_rd, pmp_a3_rd;
    wire        pmp_allow;
    wire [11:0] csr_a = instr[31:20];
    wire [31:0] csr_wval;
    wire        csr_commit;

    wire pmp_csr_we = csr_commit && ((csr_a == 12'h3A0) ||
                                     (csr_a >= 12'h3B0 && csr_a <= 12'h3B3));
    wire [2:0] pmp_csr_i = (csr_a == 12'h3A0) ? 3'd0
                                              : (3'd1 + {1'b0, csr_a[1:0]});

    pmp u_pmp (
        .clk             (clk),
        .rst_n           (rst_n),
        .csr_we          (pmp_csr_we),
        .csr_addr        (pmp_csr_i),
        .csr_wdata       (csr_wval),
        .csr_rdata_cfg   (pmp_cfg_rd),
        .csr_rdata_addr0 (pmp_a0_rd),
        .csr_rdata_addr1 (pmp_a1_rd),
        .csr_rdata_addr2 (pmp_a2_rd),
        .csr_rdata_addr3 (pmp_a3_rd),
        .priv_m          (priv_m_q),
        .chk_addr        (state[S_FETCH] ? pc[31:2] : addr_r[31:2]),
        .chk_r           (state[S_MEM] && is_load),
        .chk_w           (state[S_MEM] && is_store),
        .chk_x           (state[S_FETCH]),
        .allow           (pmp_allow),
        // second check port is for the 5-stage core's concurrent IF check
        // (rtl/core/core_p5.v); only one access exists at a time here, so it
        // is tied off and yosys trims the unused checker.
        .chk2_addr       (30'd0),
        .chk2_x          (1'b0),
        .allow2          ()
    );

    // ------------------------------------------------------------------
    // CSRs
    // ------------------------------------------------------------------
    wire mip_mtip = irq_timer;
    wire mip_meip = irq_external;

    wire [31:0] mstatus_rd = {19'd0, {2{mpp_m}}, 3'd0, mstatus_mpie,
                              3'd0, mstatus_mie, 3'd0};
    wire [31:0] mie_rd     = {20'd0, mie_meie, 3'd0, mie_mtie, 7'd0};
    wire [31:0] mip_rd     = {20'd0, mip_meip, 3'd0, mip_mtip, 7'd0};

    reg [31:0] csr_rdata;
    reg        csr_impl;
    always @* begin
        csr_impl = 1'b1;
        case (csr_a)
            12'h300: csr_rdata = mstatus_rd;
            12'h301: csr_rdata = 32'd0;                    // misa: read 0
            12'h304: csr_rdata = mie_rd;
            12'h305: csr_rdata = {mtvec_base, 4'd0};
            12'h340: csr_rdata = mscratch;
            12'h341: csr_rdata = {mepc_r, 2'd0};
            12'h342: csr_rdata = {mcause_irq, 26'd0, mcause_code};
            12'h344: csr_rdata = mip_rd;
            12'h3A0: csr_rdata = pmp_cfg_rd;
            12'h3B0: csr_rdata = pmp_a0_rd;
            12'h3B1: csr_rdata = pmp_a1_rd;
            12'h3B2: csr_rdata = pmp_a2_rd;
            12'h3B3: csr_rdata = pmp_a3_rd;
            12'hF11, 12'hF12, 12'hF13, 12'hF14:
                     csr_rdata = 32'd0;   // mvendorid/marchid/mimpid/mhartid
            default: begin csr_rdata = 32'd0; csr_impl = 1'b0; end
        endcase
    end

    wire [31:0] csr_wsrc  = is_csri ? {27'd0, rs1} : rs1_val;
    assign csr_wval = (funct3[1:0] == 2'b01) ? csr_wsrc
                    : (funct3[1:0] == 2'b10) ? (csr_rdata |  csr_wsrc)
                                             : (csr_rdata & ~csr_wsrc);
    wire csr_do_write = (funct3[1:0] == 2'b01) || (rs1 != 5'd0);
    wire csr_illegal  = is_csr && (!csr_impl
                                   || (csr_do_write && csr_a[11:10] == 2'b11)
                                   || !priv_m_q);

    wire decode_ok = is_lui | is_auipc | is_jal | is_jalr | is_branch
                   | is_load | is_store | is_opimm | is_op | is_fence
                   | (is_csr && !csr_illegal)
                   | (is_system && funct3 == 3'b000 && sys_priv_ok);
    wire illegal = !decode_ok;

    assign csr_commit = state[S_EX] && is_csr && !illegal && csr_do_write;

    // ------------------------------------------------------------------
    // Interrupts: sampled only at the fetch boundary, before a fetch is
    // issued (PRV-INT-02). M-level interrupts are always enabled in U-mode.
    // ------------------------------------------------------------------
    wire meip_pend = mip_meip && mie_meie;
    wire mtip_pend = mip_mtip && mie_mtie;
    wire irq_take  = (meip_pend || mtip_pend)
                   && (priv_m_q ? mstatus_mie : 1'b1);
    wire [4:0] irq_code = meip_pend ? 5'd11 : 5'd7;

    // ------------------------------------------------------------------
    // Next PC / writeback
    // ------------------------------------------------------------------
    wire br_jump = is_jal | (is_branch && br_taken);
    wire [31:0] next_pc = is_mret ? {mepc_r, 2'd0}
                        : is_jalr ? {addr_r[31:1], 1'b0}
                        : br_jump ? addr_r
                                  : pc_plus4;
    assign target_misaligned = (is_jalr | br_jump) && (next_pc[1:0] != 2'b00);

    assign rd_wdata = (is_jal | is_jalr) ? pc_plus4
                    : is_load            ? load_val
                                         : result;

    // ------------------------------------------------------------------
    // Bus
    // ------------------------------------------------------------------
    assign bus_valid = (state[S_FETCH] && (fetch_issued ||
                                           (!irq_take && pmp_allow)))
                     || (state[S_MEM] && pmp_allow);
    assign bus_addr     = state[S_FETCH] ? pc : {addr_r[31:2], 2'd0};
    assign bus_wstrb    = (state[S_MEM] && is_store) ? lane_mask : 4'd0;
    assign bus_wdata    = store_wdata;
    assign bus_is_fetch = state[S_FETCH];

    // ------------------------------------------------------------------
    // FSM validity (UAR-FSM-01): one-hot check + duplicated privilege state
    // ------------------------------------------------------------------
    wire state_valid    = (state != 7'd0) && ((state & (state - 7'd1)) == 7'd0);
    wire fsm_fault_now  = !state_valid || (priv_m_q != priv_m_shadow);
    assign fsm_fault    = fsm_fault_now || fsm_fault_sticky;

    // ------------------------------------------------------------------
    // Main sequential process
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_FETCH;
            pc            <= RESET_PC;
            instr         <= 32'd0;
            pc_plus4      <= 32'd0;
            result        <= 32'd0;
            addr_r        <= 32'd0;
            br_taken      <= 1'b0;
            shcnt         <= 5'd0;
            mem_rdata_r   <= 32'd0;
            fetch_issued  <= 1'b0;
            priv_m_q      <= 1'b1;
            priv_m_shadow <= 1'b1;
            mstatus_mie   <= 1'b0;
            mstatus_mpie  <= 1'b0;
            mpp_m         <= 1'b0;
            mtvec_base    <= 28'd0;
            mepc_r        <= 30'd0;
            mcause_irq    <= 1'b0;
            mcause_code   <= 5'd0;
            mscratch      <= 32'd0;
            mie_mtie      <= 1'b0;
            mie_meie      <= 1'b0;
            trap_code     <= 5'd0;
            trap_irq      <= 1'b0;
            intr_flag     <= 1'b0;
            order_cnt     <= 64'd0;
            fsm_fault_sticky <= 1'b0;
            cap_mem_addr  <= 32'd0;
            cap_mem_rdata <= 32'd0;
            cap_mem_wdata <= 32'd0;
            cap_mem_rmask <= 4'd0;
            cap_mem_wmask <= 4'd0;
`ifdef RISCV_FORMAL
            rvfi_valid    <= 1'b0;
            rvfi_order    <= 64'd0;
            rvfi_insn     <= 32'd0;
            rvfi_trap     <= 1'b0;
            rvfi_intr     <= 1'b0;
            rvfi_mode     <= 2'd3;
            rvfi_rs1_addr <= 5'd0;
            rvfi_rs2_addr <= 5'd0;
            rvfi_rs1_rdata <= 32'd0;
            rvfi_rs2_rdata <= 32'd0;
            rvfi_rd_addr  <= 5'd0;
            rvfi_rd_wdata <= 32'd0;
            rvfi_pc_rdata <= 32'd0;
            rvfi_pc_wdata <= 32'd0;
            rvfi_mem_addr <= 32'd0;
            rvfi_mem_rmask <= 4'd0;
            rvfi_mem_wmask <= 4'd0;
            rvfi_mem_rdata <= 32'd0;
            rvfi_mem_wdata <= 32'd0;
`endif
        end else begin
`ifdef RISCV_FORMAL
            rvfi_valid <= 1'b0;
`endif

            if (fsm_fault_now) begin
                // §5.5: corrupted control state → forced trap, sticky alert.
                fsm_fault_sticky <= 1'b1;
                trap_irq  <= 1'b1;          // no RVFI retire for this entry
                trap_code <= EXC_FSM;
                state     <= ST_TRAP;
            end else begin
                case (1'b1)

                state[S_FETCH]: begin
                    if (!fetch_issued && irq_take) begin
                        instr     <= 32'd0;
                        trap_irq  <= 1'b1;
                        trap_code <= irq_code;
                        state     <= ST_TRAP;
                    end else if (!fetch_issued && !pmp_allow) begin
                        instr     <= 32'd0;
                        trap_irq  <= 1'b0;
                        trap_code <= EXC_IFAULT;
                        state     <= ST_TRAP;
                    end else begin
                        pc_plus4     <= add_res;      // adder idles on PC+4
                        fetch_issued <= 1'b1;
                        if (bus_ready) begin
                            fetch_issued <= 1'b0;
                            if (bus_fault) begin
                                instr     <= 32'd0;
                                trap_irq  <= 1'b0;
                                trap_code <= EXC_IFAULT;
                                state     <= ST_TRAP;
                            end else begin
                                instr         <= bus_rdata;
                                cap_mem_addr  <= 32'd0;
                                cap_mem_rdata <= 32'd0;
                                cap_mem_wdata <= 32'd0;
                                cap_mem_rmask <= 4'd0;
                                cap_mem_wmask <= 4'd0;
                                state         <= ST_EX;
                            end
                        end
                    end
                end

                state[S_EX]: begin
                    if (illegal) begin
                        trap_irq  <= 1'b0;
                        trap_code <= EXC_ILL;
                        state     <= ST_TRAP;
                    end else begin
                        case (1'b1)
                            is_lui: begin
                                result <= imm_u;
                                state  <= ST_WB;
                            end
                            is_auipc: begin
                                result <= add_res;
                                state  <= ST_WB;
                            end
                            is_jal, is_jalr: begin
                                addr_r <= add_res;
                                state  <= ST_WB;
                            end
                            is_branch: begin
                                br_taken <= br_cond;
                                state    <= br_cond ? ST_EX2 : ST_WB;
                            end
                            is_load, is_store: begin
                                if (ls_misaligned) begin
                                    trap_irq  <= 1'b0;
                                    trap_code <= is_store ? EXC_SALIGN
                                                          : EXC_LALIGN;
                                    state     <= ST_TRAP;
                                end else begin
                                    addr_r <= add_res;
                                    state  <= ST_MEM;
                                end
                            end
                            is_shift: begin
                                result <= rs1_val;
                                shcnt  <= shamt;
                                state  <= (shamt == 5'd0) ? ST_WB : ST_SHF;
                            end
                            is_op, is_opimm: begin  // non-shift (is_shift wins above)
                                result <= alu_res;
                                state  <= ST_WB;
                            end
                            is_csr: begin
                                result <= csr_rdata;
                                if (csr_do_write) begin
                                    case (csr_a)
                                        12'h300: begin
                                            mstatus_mie  <= csr_wval[3];
                                            mstatus_mpie <= csr_wval[7];
                                            mpp_m <= (csr_wval[12:11] == 2'b11);
                                        end
                                        12'h304: begin
                                            mie_mtie <= csr_wval[7];
                                            mie_meie <= csr_wval[11];
                                        end
                                        12'h305: mtvec_base <= csr_wval[31:4];
                                        12'h340: mscratch   <= csr_wval;
                                        12'h341: mepc_r     <= csr_wval[31:2];
                                        12'h342: begin
                                            mcause_irq  <= csr_wval[31];
                                            mcause_code <= csr_wval[4:0];
                                        end
                                        // 301 misa, 344 mip: writes ignored
                                        // 3A0/3B0-3B3 handled inside pmp.v
                                        default: ;
                                    endcase
                                end
                                state <= ST_WB;
                            end
                            is_ecall: begin
                                trap_irq  <= 1'b0;
                                trap_code <= priv_m_q ? EXC_ECALLM : EXC_ECALLU;
                                state     <= ST_TRAP;
                            end
                            is_ebreak: begin
                                trap_irq  <= 1'b0;
                                trap_code <= EXC_BREAK;
                                state     <= ST_TRAP;
                            end
                            default: state <= ST_WB;  // mret/wfi/fence
                        endcase
                    end
                end

                state[S_EX2]: begin
                    addr_r <= add_res;                // taken-branch target
                    state  <= ST_WB;
                end

                state[S_SHIFT]: begin
                    result <= shift_next;
                    shcnt  <= shcnt - 5'd1;
                    if (shcnt == 5'd1)
                        state <= ST_WB;
                end

                state[S_MEM]: begin
                    if (!pmp_allow) begin
                        trap_irq  <= 1'b0;
                        trap_code <= is_store ? EXC_SFAULT : EXC_LFAULT;
                        state     <= ST_TRAP;
                    end else if (bus_ready) begin
                        if (bus_fault) begin
                            trap_irq  <= 1'b0;
                            trap_code <= is_store ? EXC_SFAULT : EXC_LFAULT;
                            state     <= ST_TRAP;
                        end else begin
                            mem_rdata_r   <= bus_rdata;
                            cap_mem_addr  <= {addr_r[31:2], 2'd0};
                            cap_mem_rmask <= is_load  ? lane_mask : 4'd0;
                            cap_mem_wmask <= is_store ? lane_mask : 4'd0;
                            cap_mem_rdata <= is_load  ? bus_rdata : 32'd0;
                            cap_mem_wdata <= is_store ? store_wdata : 32'd0;
                            state         <= ST_WB;
                        end
                    end
                end

                state[S_WB]: begin
                    if (target_misaligned) begin
                        trap_irq  <= 1'b0;
                        trap_code <= EXC_IALIGN;
                        state     <= ST_TRAP;
                    end else begin
                        pc <= next_pc;
                        if (is_mret) begin
                            mstatus_mie   <= mstatus_mpie;
                            mstatus_mpie  <= 1'b1;
                            priv_m_q      <= mpp_m;
                            priv_m_shadow <= mpp_m;
                            mpp_m         <= 1'b0;
                        end
`ifdef RISCV_FORMAL
                        rvfi_valid     <= 1'b1;
                        rvfi_order     <= order_cnt;
                        order_cnt      <= order_cnt + 64'd1;
                        rvfi_insn      <= instr;
                        rvfi_trap      <= 1'b0;
                        rvfi_intr      <= intr_flag;
                        intr_flag      <= 1'b0;
                        rvfi_mode      <= priv_m_q ? 2'd3 : 2'd0;
                        rvfi_pc_rdata  <= pc;
                        rvfi_pc_wdata  <= next_pc;
                        rvfi_rs1_addr  <= uses_rs1 ? rs1 : 5'd0;
                        rvfi_rs1_rdata <= uses_rs1 ? rs1_val : 32'd0;
                        rvfi_rs2_addr  <= uses_rs2 ? rs2 : 5'd0;
                        rvfi_rs2_rdata <= uses_rs2 ? rs2_val : 32'd0;
                        rvfi_rd_addr   <= uses_rd ? rd : 5'd0;
                        rvfi_rd_wdata  <= (uses_rd && rd != 5'd0) ? rd_wdata
                                                                  : 32'd0;
                        rvfi_mem_addr  <= cap_mem_addr;
                        rvfi_mem_rmask <= cap_mem_rmask;
                        rvfi_mem_wmask <= cap_mem_wmask;
                        rvfi_mem_rdata <= cap_mem_rdata;
                        rvfi_mem_wdata <= cap_mem_wdata;
`endif
                        state <= ST_FETCH;
                    end
                end

                state[S_TRAP]: begin
                    mepc_r        <= pc[31:2];
                    mcause_irq    <= trap_irq;
                    mcause_code   <= trap_code;
                    mstatus_mpie  <= mstatus_mie;
                    mstatus_mie   <= 1'b0;
                    mpp_m         <= priv_m_q;
                    priv_m_q      <= 1'b1;
                    priv_m_shadow <= 1'b1;
                    pc            <= {mtvec_base, 4'd0};
`ifdef RISCV_FORMAL
                    if (!trap_irq) begin
                        // synchronous exception: the instruction retires
                        // with rvfi_trap=1 and no architectural effect
                        rvfi_valid     <= 1'b1;
                        rvfi_order     <= order_cnt;
                        order_cnt      <= order_cnt + 64'd1;
                        rvfi_insn      <= instr;
                        rvfi_trap      <= 1'b1;
                        rvfi_intr      <= intr_flag;
                        rvfi_mode      <= priv_m_q ? 2'd3 : 2'd0;
                        rvfi_pc_rdata  <= pc;
                        rvfi_pc_wdata  <= {mtvec_base, 4'd0};
                        // illegal instructions (incl. RVE violations, where
                        // the 4-bit regfile index would alias) report zeros
                        rvfi_rs1_addr  <= (uses_rs1 && trap_code != EXC_ILL)
                                          ? rs1 : 5'd0;
                        rvfi_rs1_rdata <= (uses_rs1 && trap_code != EXC_ILL)
                                          ? rs1_val : 32'd0;
                        rvfi_rs2_addr  <= (uses_rs2 && trap_code != EXC_ILL)
                                          ? rs2 : 5'd0;
                        rvfi_rs2_rdata <= (uses_rs2 && trap_code != EXC_ILL)
                                          ? rs2_val : 32'd0;
                        rvfi_rd_addr   <= 5'd0;
                        rvfi_rd_wdata  <= 32'd0;
                        rvfi_mem_addr  <= 32'd0;
                        rvfi_mem_rmask <= 4'd0;
                        rvfi_mem_wmask <= 4'd0;
                        rvfi_mem_rdata <= 32'd0;
                        rvfi_mem_wdata <= 32'd0;
                    end
`endif
                    intr_flag <= 1'b1;
                    state     <= ST_FETCH;
                end

                default: ;  // unreachable: fsm_fault_now covers non-one-hot
                endcase
            end
        end
    end

endmodule
