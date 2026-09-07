// TinyTrust — simulation model of the IHP SG13G2 single-port SRAM macro.
//
// WHY THIS FILE EXISTS
// --------------------
// The ORFS ihp-sg13g2 platform ships ten macro wrappers in
// flow/platforms/ihp-sg13g2/verilog/, and every one of them delegates its
// `ifdef FUNCTIONAL branch to
//
//     SRAM_1P_behavioral_bm_bist #(.P_DATA_WIDTH(..), .P_ADDR_WIDTH(..))
//
// — a module that is *never defined anywhere in the platform*. The wrappers
// reference it, nothing provides it, so the FUNCTIONAL simulation path is
// unusable as shipped. (Second gap found in these macros; the first is the
// max_capacitance defect documented in pd/designs/sram_smoke/patch_sram_lib.sh.)
//
// So the behavioural model is written here. The semantics of a synchronous
// single-port SRAM with a per-bit write mask are unambiguous, and the timing
// they have to match — one cycle of read latency — is pinned by the Liberty
// the real macro is characterised with.
//
// This is a SIMULATION-ONLY file. Synthesis and P&R never see it: they bind
// the macro through its LEF and Liberty, with the blackbox stub supplying the
// module declaration. Keeping the two paths apart is the point — the cache
// RTL instantiates one module name and gets the real macro in silicon and
// this model in the testbench.

// ---------------------------------------------------------------------------
// Generic behavioural single-port SRAM with bit-mask write.
//
// Timing: address, enables and write data are sampled on the rising edge;
// read data appears after that edge and holds until the next read. That is
// one full cycle of read latency, which is what the cache's hit path is built
// around (rtl/cache/cache.v).
//
// Semantics:
//   A_MEN=0            : no access, A_DOUT holds
//   A_MEN=1, A_WEN=1   : write, per-bit under A_BM (1 = update that bit)
//   A_MEN=1, A_REN=1   : read
// A write does not update A_DOUT: this is not a read-during-write model, and
// the cache never relies on one.
// ---------------------------------------------------------------------------
module sram_1p_bm #(
    parameter P_DATA_WIDTH = 64,
    parameter P_ADDR_WIDTH = 9
) (
    input  wire                      A_CLK,
    input  wire                      A_MEN,
    input  wire                      A_WEN,
    input  wire                      A_REN,
    input  wire [P_ADDR_WIDTH-1:0]   A_ADDR,
    input  wire [P_DATA_WIDTH-1:0]   A_DIN,
    input  wire [P_DATA_WIDTH-1:0]   A_BM,
    output reg  [P_DATA_WIDTH-1:0]   A_DOUT
`ifdef FORMAL
    // A read port that exists only for proofs. An inductive invariant has to
    // say what the array *holds*, not just what it last returned, and yosys
    // has no way to reach into a module from outside -- an attempt to write
    // `uut.mem[...]` in the harness silently becomes an undriven wire. So the
    // access is a real port, present only under FORMAL, and no synthesised
    // build ever sees it.
    ,
    input  wire [P_ADDR_WIDTH-1:0]   fv_probe_addr,
    output wire [P_DATA_WIDTH-1:0]   fv_probe_data
`endif
);
    // 32'd1, not 1: an unsized literal makes the shift an unsized
    // expression, which iverilog widens to thousands of bits and warns about.
    localparam DEPTH = (32'd1 << P_ADDR_WIDTH);

    reg [P_DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge A_CLK) begin
        if (A_MEN) begin
            if (A_WEN)
                mem[A_ADDR] <= (A_DIN & A_BM) | (mem[A_ADDR] & ~A_BM);
            else if (A_REN)
                A_DOUT <= mem[A_ADDR];
        end
    end

`ifdef FORMAL
    assign fv_probe_data = mem[fv_probe_addr];
`endif
endmodule


// ---------------------------------------------------------------------------
// Macro-named wrapper: same module name and port list as
// flow/platforms/ihp-sg13g2/verilog/RM_IHPSG13_1P_512x64_c2_bm_bist.v, so the
// cache instantiates one name across simulation and synthesis.
//
// The BIST shadow port is accepted and ignored — TinyTrust does not drive it
// (see pd/designs/sram_smoke/sram_smoke.v; wiring BIST is a P6 concern).
// ---------------------------------------------------------------------------
module RM_IHPSG13_1P_512x64_c2_bm_bist (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [8:0]  A_ADDR,
    input  wire [63:0] A_DIN,
    input  wire        A_DLY,
    output wire [63:0] A_DOUT,
    input  wire [63:0] A_BM,

    input  wire        A_BIST_CLK,
    input  wire        A_BIST_EN,
    input  wire        A_BIST_MEN,
    input  wire        A_BIST_WEN,
    input  wire        A_BIST_REN,
    input  wire [8:0]  A_BIST_ADDR,
    input  wire [63:0] A_BIST_DIN,
    input  wire [63:0] A_BIST_BM
);
    sram_1p_bm #(.P_DATA_WIDTH(64), .P_ADDR_WIDTH(9)) u_mem (
        .A_CLK  (A_CLK),
        .A_MEN  (A_MEN),
        .A_WEN  (A_WEN),
        .A_REN  (A_REN),
        .A_ADDR (A_ADDR),
        .A_DIN  (A_DIN),
        .A_BM   (A_BM),
        .A_DOUT (A_DOUT)
    );
endmodule
