// TinyTrust — RV32I register file: 32 x 32-bit, 2 async read / 1 sync write
//
// x0 is not stored; reads of x0 return zero, writes to x0 are dropped.
// DFF-based (decision D3); the latch-based area fallback is no longer needed
// on a full die (see docs/RETARGET.md D18 — RV32E -> RV32I).

module regfile (
    input  wire        clk,

    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata,

    input  wire [4:0]  raddr1,
    output wire [31:0] rdata1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata2
);

    reg [31:0] regs [1:31];

    always @(posedge clk) begin
        if (we && waddr != 5'd0)
            regs[waddr] <= wdata;
    end

    assign rdata1 = (raddr1 == 5'd0) ? 32'd0 : regs[raddr1];
    assign rdata2 = (raddr2 == 5'd0) ? 32'd0 : regs[raddr2];

endmodule
