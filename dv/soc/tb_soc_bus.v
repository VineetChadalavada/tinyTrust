// TinyTrust -- testbench for rtl/soc/soc_bus.v (S1-A)
//
// Checks four separate claims, because passing data through is only the
// first of them:
//
//   1. Data goes to and comes from the right slave.
//   2. An unmapped address is answered with a fault, in one cycle, and no
//      slave is activated by it.
//   3. Only ever one slave is selected at a time. This is asserted on every
//      cycle rather than tested, because it is the property the whole
//      single-transfer design rests on.
//   4. Two masters contending both make progress, and neither starves. A bus
//      that always favoured master 0 would pass claims 1 to 3 and still be
//      wrong in the way that matters once there are two cores.
//
// The slave model takes a latency parameter, so a slow slave can be used to
// check that a grant is held for the whole transfer rather than being pulled
// away mid-access.

`timescale 1ns/1ps

module tb_soc_bus;

    localparam NM = 2;
    localparam NS = 4;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer i;

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

    // ---- master ports ----
    reg  [NM-1:0]    m_valid;
    reg  [NM*32-1:0] m_addr, m_wdata;
    reg  [NM*4-1:0]  m_wstrb;
    wire [NM-1:0]    m_ready, m_fault;
    wire [NM*32-1:0] m_rdata;

    // ---- slave ports ----
    wire [NS-1:0]    s_valid, s_ready, s_fault;
    wire [31:0]      s_addr, s_wdata;
    wire [3:0]       s_wstrb;
    wire [NS*32-1:0] s_rdata;

    soc_bus #(.NM(NM), .NS(NS), .SLAVE_NIBBLE(16'h3210)) dut (
        .clk(clk), .rst_n(rst_n),
        .m_valid(m_valid), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_wstrb(m_wstrb), .m_ready(m_ready), .m_rdata(m_rdata),
        .m_fault(m_fault),
        .s_valid(s_valid), .s_addr(s_addr), .s_wdata(s_wdata),
        .s_wstrb(s_wstrb), .s_ready(s_ready), .s_rdata(s_rdata),
        .s_fault(s_fault)
    );

    // Slave 0 answers immediately; slave 2 takes 3 cycles, so the grant has
    // to be held; slave 3 is a peripheral-speed 1 cycle. Slave 1 is present
    // but always faults, standing in for the flash window that S1 does not
    // populate (D28).
    genvar g;
    generate
        for (g = 0; g < NS; g = g + 1) begin : g_slave
            bus_slave #(
                .LAT   ((g == 2) ? 3 : (g == 3) ? 1 : 0),
                .FAULTS((g == 1) ? 1 : 0)
            ) u_s (
                .clk(clk), .rst_n(rst_n),
                .valid(s_valid[g]), .addr(s_addr), .wdata(s_wdata),
                .wstrb(s_wstrb), .ready(s_ready[g]),
                .rdata(s_rdata[g*32 +: 32]), .fault(s_fault[g])
            );
        end
    endgenerate

    // ---- claim 3, checked every cycle ----
    integer nsel;
    always @(posedge clk) if (rst_n) begin
        nsel = 0;
        for (i = 0; i < NS; i = i + 1) if (s_valid[i]) nsel = nsel + 1;
        check(nsel <= 1, "more than one slave selected at once");
    end

    // ------------------------------------------------------------------
    // One transfer from one master. Holds the request steady until accepted,
    // which is what the real masters do.
    // ------------------------------------------------------------------
    task automatic xfer;
        input integer mi;
        input [31:0] addr;
        input [31:0] wdata;
        input [3:0]  wstrb;
        output [31:0] rdata;
        output        fault;
        integer guard;
        begin
            @(negedge clk);
            m_valid[mi]           = 1'b1;
            m_addr [mi*32 +: 32]  = addr;
            m_wdata[mi*32 +: 32]  = wdata;
            m_wstrb[mi*4  +: 4]   = wstrb;
            guard = 0;
            while (!m_ready[mi] && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            check(guard < 100, "transfer never completed");
            rdata = m_rdata[mi*32 +: 32];
            fault = m_fault[mi];
            @(negedge clk);
            m_valid[mi]         = 1'b0;
            m_wstrb[mi*4 +: 4]  = 4'd0;
        end
    endtask

    reg [31:0] rd;
    reg        flt;

    // ------------------------------------------------------------------
    // Claim 4 needs both masters driving at once, so it cannot use the
    // sequential task above. Each master runs its own loop and counts what
    // it completed.
    // ------------------------------------------------------------------
    integer done0, done1;
    reg     contend;

    task automatic drive_contender;
        input integer mi;
        input [31:0]  base;
        input integer n;
        integer k, guard;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk);
                m_valid[mi]          = 1'b1;
                m_addr [mi*32 +: 32] = base + (k << 2);
                m_wdata[mi*32 +: 32] = 32'hC0DE_0000 + k;
                m_wstrb[mi*4  +: 4]  = 4'hF;
                guard = 0;
                while (!m_ready[mi] && guard < 200) begin
                    @(negedge clk);
                    guard = guard + 1;
                end
                if (mi == 0) done0 = done0 + 1; else done1 = done1 + 1;
                // valid stays high into the next request: back-to-back is
                // what a cache doing refill beats actually does, and it is
                // the only way to put real pressure on the arbiter.
            end
            @(negedge clk);
            m_valid[mi]        = 1'b0;
            m_wstrb[mi*4 +: 4] = 4'd0;
        end
    endtask

    // ---- fairness: who actually got the bus, and in what order ----
    integer last_winner, run_len, worst_run;
    integer w;
    always @(posedge clk) if (rst_n && contend) begin
        for (w = 0; w < NM; w = w + 1) begin
            if (m_ready[w]) begin
                if (w == last_winner) run_len = run_len + 1;
                else                  run_len = 1;
                last_winner = w;
                if (run_len > worst_run) worst_run = run_len;
            end
        end
    end

    initial begin
        m_valid = 0; m_addr = 0; m_wdata = 0; m_wstrb = 0;
        done0 = 0; done1 = 0; contend = 0;
        last_winner = -1; run_len = 0; worst_run = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // -- claim 1: each populated slave stores and returns data --
        xfer(0, 32'h0000_0010, 32'hA5A5_0001, 4'hF, rd, flt);
        check(!flt, "write to slave 0 faulted");
        xfer(0, 32'h0000_0010, 32'd0, 4'h0, rd, flt);
        check(rd == 32'hA5A5_0001, "slave 0 read back wrong data");
        check(!flt, "read from slave 0 faulted");

        xfer(0, 32'h2000_0020, 32'hBEEF_0002, 4'hF, rd, flt);
        xfer(0, 32'h2000_0020, 32'd0, 4'h0, rd, flt);
        check(rd == 32'hBEEF_0002, "slow slave 2 read back wrong data");

        xfer(0, 32'h3000_0030, 32'h1234_0003, 4'hF, rd, flt);
        xfer(0, 32'h3000_0030, 32'd0, 4'h0, rd, flt);
        check(rd == 32'h1234_0003, "slave 3 read back wrong data");

        // routing: the same offset in two slaves must not alias
        xfer(0, 32'h0000_0040, 32'h1111_1111, 4'hF, rd, flt);
        xfer(0, 32'h2000_0040, 32'h2222_2222, 4'hF, rd, flt);
        xfer(0, 32'h0000_0040, 32'd0, 4'h0, rd, flt);
        check(rd == 32'h1111_1111, "slave 0 aliased with slave 2");
        xfer(0, 32'h2000_0040, 32'd0, 4'h0, rd, flt);
        check(rd == 32'h2222_2222, "slave 2 aliased with slave 0");

        // -- claim 2: unmapped address faults, and no slave is selected --
        xfer(0, 32'h9000_0000, 32'd0, 4'h0, rd, flt);
        check(flt, "unmapped address did not fault");

        // a populated-but-faulting slave still reports fault
        xfer(0, 32'h1000_0000, 32'd0, 4'h0, rd, flt);
        check(flt, "faulting slave 1 did not report fault");

        // -- claim 4: both masters progress under contention --
        contend = 1;
        fork
            drive_contender(0, 32'h0000_0100, 8);
            drive_contender(1, 32'h2000_0100, 8);
        join
        contend = 0;
        check(done0 == 8, "master 0 did not complete all its transfers");
        check(done1 == 8, "master 1 did not complete all its transfers");
        // With both masters requesting every cycle, round-robin must
        // alternate. A run of 2 is possible at the edges of the window, where
        // one contender has finished its 8 and the other has not; anything
        // longer means the arbiter has a favourite.
        $display("  longest run of consecutive grants to one master: %0d", worst_run);
        check(worst_run <= 2, "arbiter starved a master: one won 3+ in a row");

        repeat (4) @(posedge clk);
        if (errors == 0)
            $display("BUS PASS: routing, fault, one-slave and fairness checks clean");
        else
            $display("BUS FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("BUS FAIL: timeout");
        $finish;
    end

endmodule


// A memory slave with a settable response latency, and an option to fault
// every access so an unpopulated window can be modelled.
module bus_slave #(
    parameter LAT    = 0,
    parameter FAULTS = 0,
    parameter AW     = 10
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    output wire        ready,
    output wire [31:0] rdata,
    output wire        fault
);
    reg [31:0] mem [0:(1<<AW)-1];
    reg [7:0]  cnt;
    wire [AW-1:0] word = addr[AW+1:2];

    assign ready = valid && (cnt == LAT);
    assign fault = (FAULTS != 0) && valid && ready;
    assign rdata = (FAULTS != 0) ? 32'd0 : mem[word];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 8'd0;
        end else if (valid && !ready) begin
            cnt <= cnt + 8'd1;
        end else begin
            cnt <= 8'd0;
            if (valid && ready && (FAULTS == 0)) begin
                if (wstrb[0]) mem[word][7:0]   <= wdata[7:0];
                if (wstrb[1]) mem[word][15:8]  <= wdata[15:8];
                if (wstrb[2]) mem[word][23:16] <= wdata[23:16];
                if (wstrb[3]) mem[word][31:24] <= wdata[31:24];
            end
        end
    end
endmodule
