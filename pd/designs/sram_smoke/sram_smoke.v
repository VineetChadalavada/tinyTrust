// TinyTrust — SRAM macro smoke test (docs/RETARGET.md §8 risk, deferred by P0)
//
// This is a FLOW test, not a design. Its only job is to answer one question
// before the P3 cache architecture is committed: does an IHP SG13G2 SRAM
// macro survive the ORFS flow end to end — synthesis blackbox, floorplan,
// macro placement, PDN, CTS, route, and above all the KLayout GDS merge?
//
// RETARGET.md §8 records the risk as "OpenROAD has reported GDS-merge
// failures with some SG13G2 SRAM BITKIT cells (missing GDS/OAS for LEF
// cells)" and assigns the mitigation to P0. P0 hardened the core but did not
// touch macros (pd/results/p0/METRICS.md says so explicitly), so the risk is
// still live and D19 — "cache data arrays in SRAM macros" — rests on it.
//
// Macro choice: RM_IHPSG13_1P_512x64_c2_bm_bist, 512 words x 64 bit = 4 KiB.
// That is the capacity RETARGET.md §4 budgeted per cache data array. Note the
// §4 text names RM_IHPSG13_1P_1024x32, which does not exist in this PDK — the
// available widths are 8, 16, 48 and 64 bits (see the P3 notes in §4).
//
// The wrapper registers every macro input and the read data, so the design
// contains real reg -> macro -> reg timing paths rather than pure feedthrough,
// and so placement has standard cells to work with. Byte enables are exposed
// as an 8-bit mask expanded onto the macro's per-bit A_BM, which is the shape
// a cache data array actually needs.
//
// The BIST port is tied off. BIST is a production-test feature; wiring it is a
// P6 concern and irrelevant to whether the macro hardens.

module sram_smoke (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req,          // access this cycle
    input  wire        we,           // 1 = write, 0 = read
    input  wire [8:0]  addr,         // 512 words
    input  wire [63:0] wdata,
    input  wire [7:0]  wstrb,        // byte enables
    output reg  [63:0] rdata
);

    // ---- input registers ----
    reg        req_q, we_q;
    reg [8:0]  addr_q;
    reg [63:0] wdata_q;
    reg [7:0]  wstrb_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_q   <= 1'b0;
            we_q    <= 1'b0;
            addr_q  <= 9'd0;
            wdata_q <= 64'd0;
            wstrb_q <= 8'd0;
        end else begin
            req_q   <= req;
            we_q    <= we;
            addr_q  <= addr;
            wdata_q <= wdata;
            wstrb_q <= wstrb;
        end
    end

    // Byte mask -> per-bit mask. The macro writes a bit where A_BM is 1.
    wire [63:0] bit_mask = {{8{wstrb_q[7]}}, {8{wstrb_q[6]}},
                            {8{wstrb_q[5]}}, {8{wstrb_q[4]}},
                            {8{wstrb_q[3]}}, {8{wstrb_q[2]}},
                            {8{wstrb_q[1]}}, {8{wstrb_q[0]}}};

    wire [63:0] macro_dout;

    RM_IHPSG13_1P_512x64_c2_bm_bist u_sram (
        .A_CLK       (clk),
        .A_MEN       (req_q),
        .A_WEN       (we_q),
        .A_REN       (~we_q),
        .A_ADDR      (addr_q),
        .A_DIN       (wdata_q),
        .A_DLY       (1'b0),
        .A_DOUT      (macro_dout),
        .A_BM        (bit_mask),
        // BIST port unused: production-test feature, not part of this check
        .A_BIST_CLK  (1'b0),
        .A_BIST_EN   (1'b0),
        .A_BIST_MEN  (1'b0),
        .A_BIST_WEN  (1'b0),
        .A_BIST_REN  (1'b0),
        .A_BIST_ADDR (9'd0),
        .A_BIST_DIN  (64'd0),
        .A_BIST_BM   (64'd0)
    );

    // ---- output register ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rdata <= 64'd0;
        else
            rdata <= macro_dout;
    end

endmodule
