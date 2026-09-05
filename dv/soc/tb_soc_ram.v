// TinyTrust -- testbench for rtl/soc/soc_ram.v (S1-A)
//
// Checks the things that actually go wrong when a 32-bit bus sits in front of
// 64-bit memory blocks:
//
//   1. A word written to one half of a block word does not disturb the other
//      half. Getting addr[2] wrong makes every other word alias, and simple
//      sequential tests miss it.
//   2. Byte and halfword writes change only the bytes they name.
//   3. Blocks do not alias with each other -- the same index in two different
//      blocks holds different data.
//   4. A read returns the value most recently written, after any mixture of
//      full and partial writes.

`timescale 1ns/1ps

module tb_soc_ram;

    localparam N_MACRO = 4;              // 16 KB

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    task check;
        input cond;
        input [511:0] what;
        begin
            if (!cond) begin
                $display("  FAIL: %0s (t=%0t)", what, $time);
                errors = errors + 1;
            end
        end
    endtask

    reg         s_valid;
    reg  [31:0] s_addr, s_wdata;
    reg  [3:0]  s_wstrb;
    wire        s_ready, s_fault;
    wire [31:0] s_rdata;

    soc_ram #(.N_MACRO(N_MACRO), .USE_MACRO(0)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_addr(s_addr), .s_wdata(s_wdata),
        .s_wstrb(s_wstrb), .s_ready(s_ready), .s_rdata(s_rdata),
        .s_fault(s_fault)
    );

    task automatic wr;
        input [31:0] a;
        input [31:0] d;
        input [3:0]  be;
        integer guard;
        begin
            @(negedge clk);
            s_valid = 1; s_addr = a; s_wdata = d; s_wstrb = be;
            guard = 0;
            while (!s_ready && guard < 20) begin @(negedge clk); guard = guard + 1; end
            check(guard < 20, "write never completed");
            @(negedge clk);
            s_valid = 0; s_wstrb = 0;
        end
    endtask

    task automatic rd;
        input  [31:0] a;
        output [31:0] d;
        integer guard;
        begin
            @(negedge clk);
            s_valid = 1; s_addr = a; s_wstrb = 0;
            guard = 0;
            while (!s_ready && guard < 20) begin @(negedge clk); guard = guard + 1; end
            check(guard < 20, "read never completed");
            d = s_rdata;
            @(negedge clk);
            s_valid = 0;
        end
    endtask

    reg [31:0] v;
    integer i;

    initial begin
        s_valid = 0; s_addr = 0; s_wdata = 0; s_wstrb = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // -- claim 1: the two halves of one block word are independent --
        wr(32'h2000_0000, 32'hAAAA_0001, 4'hF);   // low half
        wr(32'h2000_0004, 32'hBBBB_0002, 4'hF);   // high half of the same word
        rd(32'h2000_0000, v);
        check(v == 32'hAAAA_0001, "low half corrupted by the high-half write");
        rd(32'h2000_0004, v);
        check(v == 32'hBBBB_0002, "high half read back wrong");

        // -- claim 2: partial writes touch only their own bytes --
        wr(32'h2000_0010, 32'h1122_3344, 4'hF);
        wr(32'h2000_0010, 32'h0000_00FF, 4'h1);   // byte 0 only
        rd(32'h2000_0010, v);
        check(v == 32'h1122_33FF, "byte write changed more than one byte");
        wr(32'h2000_0010, 32'hEEEE_0000, 4'hC);   // top halfword only
        rd(32'h2000_0010, v);
        check(v == 32'hEEEE_33FF, "halfword write changed the wrong bytes");

        // and the neighbouring half must still be untouched
        wr(32'h2000_0014, 32'h5555_5555, 4'hF);
        wr(32'h2000_0010, 32'h0000_AA00, 4'h2);
        rd(32'h2000_0014, v);
        check(v == 32'h5555_5555, "partial write leaked into the other half");

        // -- claim 3: blocks do not alias --
        for (i = 0; i < N_MACRO; i = i + 1)
            wr(32'h2000_0020 + (i << 12), 32'h7000_0000 + i, 4'hF);
        for (i = 0; i < N_MACRO; i = i + 1) begin
            rd(32'h2000_0020 + (i << 12), v);
            check(v == (32'h7000_0000 + i), "blocks alias with each other");
        end

        // -- claim 4: a sweep survives --
        for (i = 0; i < 64; i = i + 1)
            wr(32'h2000_0800 + (i << 2), 32'hC0DE_0000 + i, 4'hF);
        for (i = 0; i < 64; i = i + 1) begin
            rd(32'h2000_0800 + (i << 2), v);
            check(v == (32'hC0DE_0000 + i), "sweep read back wrong");
        end

        repeat (4) @(posedge clk);
        if (errors == 0) $display("RAM PASS: halves, byte enables, banks and sweep clean");
        else             $display("RAM FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("RAM FAIL: timeout");
        $finish;
    end

endmodule
