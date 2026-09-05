// TinyTrust -- on-chip main memory (S1-A)
//
// A bus slave backed by the foundry's SRAM blocks. This is where code and
// data live in the first chip (D28, D30).
//
// GEOMETRY
// Each block is 512 words of 64 bits, which is 4 KB. N_MACRO of them side by
// side give N_MACRO x 4 KB. The bus is 32 bits wide, so one bus word is half
// a block word:
//
//   addr[2]                 which half of the 64-bit word
//   addr[11:3]              index within a block
//   addr[11+MSB : 12]       which block
//
// TIMING
// A write completes in the cycle it is issued -- the block's per-bit write
// mask means a byte or halfword write needs no read-modify-write, exactly as
// it does in the cache. A read takes two cycles, because the block registers
// its output. That asymmetry is real and the bus handles it; hiding it behind
// a wait state on writes as well would cost performance for tidiness.
//
// WHY THIS MATTERS BEYOND WORKING
// The SRAM smoke test proved that *one* block hardens, and said explicitly
// that it did not prove several placed together, routed between, or powered
// across. This module is what puts several on the die, which is the gap D29
// keeps the caches in S1 to close.

module soc_ram #(
    parameter N_MACRO   = 4,       // 4 x 4 KB = 16 KB
    parameter USE_MACRO = 1        // 0 = behavioural model, for simulation
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        s_valid,
    input  wire [31:0] s_addr,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    output reg         s_ready,
    output wire [31:0] s_rdata,
    output wire        s_fault
);

    function integer clog2;
        input integer v;
        begin
            clog2 = 0;
            v = v - 1;
            while (v > 0) begin
                clog2 = clog2 + 1;
                v = v >> 1;
            end
        end
    endfunction

    localparam MSEL_BITS = (N_MACRO > 1) ? clog2(N_MACRO) : 1;

    wire                 hi   = s_addr[2];
    wire [8:0]           idx  = s_addr[11:3];
    wire [MSEL_BITS-1:0] msel = (N_MACRO > 1) ? s_addr[11+MSEL_BITS:12]
                                              : {MSEL_BITS{1'b0}};

    wire is_write = (s_wstrb != 4'd0);

    // ------------------------------------------------------------------
    // Two states is all this needs: a write is done immediately, a read has
    // to wait one cycle for the block to present its data.
    // ------------------------------------------------------------------
    localparam S_IDLE = 1'b0,
               S_RD   = 1'b1;

    reg state;
    reg [MSEL_BITS-1:0] msel_q;
    reg                 hi_q;

    reg men, wen, ren;

    always @* begin
        men     = 1'b0;
        wen     = 1'b0;
        ren     = 1'b0;
        s_ready = 1'b0;
        case (state)
            S_IDLE: begin
                if (s_valid) begin
                    men = 1'b1;
                    if (is_write) begin
                        wen     = 1'b1;
                        s_ready = 1'b1;   // captured on this edge
                    end else begin
                        ren = 1'b1;       // data lands next cycle
                    end
                end
            end
            S_RD: begin
                s_ready = 1'b1;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            msel_q <= {MSEL_BITS{1'b0}};
            hi_q   <= 1'b0;
        end else begin
            case (state)
                S_IDLE: if (s_valid && !is_write) begin
                    state  <= S_RD;
                    msel_q <= msel;
                    hi_q   <= hi;
                end
                S_RD: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Write data and mask, placed in the correct half of the block word
    // ------------------------------------------------------------------
    function [31:0] expand4;
        input [3:0] s;
        begin
            expand4 = {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}};
        end
    endfunction

    wire [63:0] din = {s_wdata, s_wdata};          // replicated; the mask picks
    wire [63:0] bm  = hi ? {expand4(s_wstrb), 32'd0}
                         : {32'd0, expand4(s_wstrb)};

    // ------------------------------------------------------------------
    // The blocks
    // ------------------------------------------------------------------
    wire [63:0] dout [0:N_MACRO-1];

    genvar g;
    generate
        for (g = 0; g < N_MACRO; g = g + 1) begin : g_bank
            wire en = men && ((N_MACRO == 1) || (msel == g));
            if (USE_MACRO != 0) begin : g_macro
                RM_IHPSG13_1P_512x64_c2_bm_bist u_m (
                    .A_CLK(clk), .A_MEN(en), .A_WEN(wen && en),
                    .A_REN(ren && en), .A_ADDR(idx), .A_DIN(din),
                    .A_DLY(1'b0), .A_DOUT(dout[g]), .A_BM(bm),
                    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
                    .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
                    .A_BIST_ADDR(9'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
                );
            end else begin : g_model
                sram_1p_bm #(.P_DATA_WIDTH(64), .P_ADDR_WIDTH(9)) u_m (
                    .A_CLK(clk), .A_MEN(en), .A_WEN(wen && en),
                    .A_REN(ren && en), .A_ADDR(idx), .A_DIN(din),
                    .A_BM(bm), .A_DOUT(dout[g])
                );
            end
        end
    endgenerate

    wire [63:0] dout_sel = dout[msel_q];
    assign s_rdata = hi_q ? dout_sel[63:32] : dout_sel[31:0];
    assign s_fault = 1'b0;

endmodule
