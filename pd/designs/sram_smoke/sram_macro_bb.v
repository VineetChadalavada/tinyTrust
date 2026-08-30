// Blackbox declaration for the IHP SG13G2 single-port SRAM macro.
//
// Synthesis needs the module to *exist* but must not descend into it: the
// macro's physical view comes from the platform LEF and its timing from the
// platform Liberty (both wired up in config.mk). Without this, yosys stops at
// `hierarchy -check` with "Module `\RM_IHPSG13_1P_512x64_c2_bm_bist'
// referenced ... is not part of the design".
//
// ORFS's SYNTH_BLACKBOXES does not solve this case: scripts/synth_preamble.tcl
// runs `hierarchy -check -top` *before* applying `blackbox`, so that variable
// is for modules that are defined but should be flattened out of the
// partition, not for ones with no body at all. A stub is the right answer and
// is also what the P3 cache RTL will need — simulation binds the platform's
// behavioural model in flow/platforms/ihp-sg13g2/verilog/, synthesis binds
// this.
//
// Ports are transcribed from
// flow/platforms/ihp-sg13g2/verilog/RM_IHPSG13_1P_512x64_c2_bm_bist.v
// (IHP PDK, Apache-2.0). 512 words x 64 bit = 4 KiB.

(* blackbox *)
module RM_IHPSG13_1P_512x64_c2_bm_bist (
    input  wire        A_CLK,
    input  wire        A_MEN,       // memory enable
    input  wire        A_WEN,       // write enable
    input  wire        A_REN,       // read enable
    input  wire [8:0]  A_ADDR,
    input  wire [63:0] A_DIN,
    input  wire        A_DLY,       // access-time trim
    output wire [63:0] A_DOUT,
    input  wire [63:0] A_BM,        // per-bit write mask

    // BIST shadow port
    input  wire        A_BIST_CLK,
    input  wire        A_BIST_EN,
    input  wire        A_BIST_MEN,
    input  wire        A_BIST_WEN,
    input  wire        A_BIST_REN,
    input  wire [8:0]  A_BIST_ADDR,
    input  wire [63:0] A_BIST_DIN,
    input  wire [63:0] A_BIST_BM
);
endmodule
