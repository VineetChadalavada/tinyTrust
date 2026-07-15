// Self-checking KAT testbench for ascon_p against pyascon-generated vectors.
// Run: iverilog -g2005 -o sim.vvp tb_ascon_p.v ../../rtl/periph/ascon_p.v
//      vvp sim.vvp
// Prints "ALL TESTS PASSED" or per-mismatch FAIL lines + "TESTS FAILED".

`timescale 1ns / 1ps

module tb_ascon_p;

    localparam NTESTS = 66;
    localparam WORDS_PER_TEST = 21;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [3:0]  num_rounds = 0;
    wire        busy;
    reg         we = 0;
    reg  [3:0]  waddr = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  raddr = 0;
    wire [31:0] rdata;

    ascon_p dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .num_rounds(num_rounds), .busy(busy),
        .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata)
    );

    always #5 clk = ~clk;

    reg [31:0] vec [0:NTESTS*WORDS_PER_TEST-1];

    integer t, w, base, errors, cycles;
    reg [31:0] expect_w;

    initial begin
        $readmemh("vectors.memh", vec);
        errors = 0;

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        for (t = 0; t < NTESTS; t = t + 1) begin
            base = t * WORDS_PER_TEST;

            // load input state
            for (w = 0; w < 10; w = w + 1) begin
                @(negedge clk);
                we    = 1;
                waddr = w[3:0];
                wdata = vec[base + 1 + w];
            end
            @(negedge clk);
            we = 0;

            // start permutation
            num_rounds = vec[base][3:0];
            start = 1;
            @(negedge clk);
            start = 0;

            // wait for completion (with timeout)
            cycles = 0;
            @(posedge clk);
            while (busy && cycles < 100) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (busy) begin
                $display("FAIL test %0d: timeout, busy stuck", t);
                errors = errors + 1;
            end

            // check output state
            for (w = 0; w < 10; w = w + 1) begin
                @(negedge clk);
                raddr = w[3:0];
                #1;
                expect_w = vec[base + 11 + w];
                if (rdata !== expect_w) begin
                    $display("FAIL test %0d rounds=%0d word %0d: got %08x expected %08x",
                             t, vec[base][3:0], w, rdata, expect_w);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0)
            $display("ALL TESTS PASSED (%0d tests)", NTESTS);
        else
            $display("TESTS FAILED: %0d mismatches", errors);
        $finish;
    end

endmodule
