// TinyTrust — block-level cache testbench (vplan L1, milestone P3)
//
// Checks rtl/cache/cache.v against a golden model of what a coherent memory
// would return, and — separately — checks that it is actually *caching*.
// Those are two different claims and a data-only check proves just the first:
// a cache that missed on every access would pass it. So the memory-side beats
// are counted, and hits are asserted to generate none.
//
// Phases:
//   1. directed — cold miss, read hit, write hit, dirty eviction with
//      writeback, uncacheable pass-through, and a bus fault during refill
//   2. random   — mixed reads and writes over an address range chosen to
//      force index conflicts, every read checked against the golden model
//   3. sweep    — read back every address ever written. This is what proves
//      writeback: an evicted dirty line is only re-readable if its data
//      actually reached memory.
//
// Compile with -DDCACHE for the write-back data cache, without it for the
// read-only instruction cache.

`timescale 1ns/1ps

module tb_cache;

`ifdef DCACHE
    localparam WRITABLE = 1;
`else
    localparam WRITABLE = 0;
`endif

    localparam [31:0] CACHEABLE_LIMIT = 32'h0001_0000;
    localparam [31:0] DEVICE_ADDR     = 32'h0001_0000;  // uncacheable, no fault
    localparam [31:0] FAULT_ADDR      = 32'h0002_0000;  // uncacheable, faults

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- core side ----
    reg         c_valid = 1'b0;
    reg  [31:0] c_addr  = 32'd0;
    reg  [31:0] c_wdata = 32'd0;
    reg  [3:0]  c_wstrb = 4'd0;
    wire        c_ready, c_fault;
    wire [31:0] c_rdata;

    // ---- memory side ----
    wire        m_valid;
    wire [31:0] m_addr, m_wdata;
    wire [3:0]  m_wstrb;
    reg         m_ready = 1'b0;
    reg  [31:0] m_rdata = 32'd0;
    reg         m_fault = 1'b0;

    cache #(.WRITABLE(WRITABLE), .CACHEABLE_LIMIT(CACHEABLE_LIMIT)) dut (
        .clk(clk), .rst_n(rst_n),
        .c_valid(c_valid), .c_addr(c_addr), .c_wdata(c_wdata),
        .c_wstrb(c_wstrb), .c_ready(c_ready), .c_rdata(c_rdata),
        .c_fault(c_fault),
        .m_valid(m_valid), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_wstrb(m_wstrb), .m_ready(m_ready), .m_rdata(m_rdata),
        .m_fault(m_fault)
    );

    // ------------------------------------------------------------------
    // Backing memory, and the golden view of what reads must return.
    // mem[] lags gold[] for as long as a dirty line sits in the cache; that
    // gap is exactly what phase 3 exists to close.
    // ------------------------------------------------------------------
    reg [31:0] mem  [0:16383];
    reg [31:0] gold [0:16383];
    reg        written [0:16383];

    integer seed = 1;
    integer max_lat = 3;
    integer beats;              // memory-side transfers, for hit/miss checks
    integer errors = 0;
    integer i, k;

    // memory model: randomized latency, faults above the device word
    integer delay;
    reg     active = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_ready <= 1'b0; m_rdata <= 32'd0; m_fault <= 1'b0;
            active  <= 1'b0; delay <= 0;
        end else begin
            m_ready <= 1'b0;
            m_fault <= 1'b0;
            if (m_ready) begin
                active <= 1'b0;
            end else if (m_valid && !active) begin
                active <= 1'b1;
                delay  <= {$random(seed)} % (max_lat + 1);
            end else if (m_valid && active) begin
                if (delay == 0) begin : svc
                    reg [31:0] w;
                    m_ready <= 1'b1;
                    beats = beats + 1;
                    if (m_addr < 32'h0001_0000) begin
                        w = mem[m_addr[15:2]];
                        if (m_wstrb[0]) w[7:0]   = m_wdata[7:0];
                        if (m_wstrb[1]) w[15:8]  = m_wdata[15:8];
                        if (m_wstrb[2]) w[23:16] = m_wdata[23:16];
                        if (m_wstrb[3]) w[31:24] = m_wdata[31:24];
                        if (m_wstrb != 4'd0) mem[m_addr[15:2]] <= w;
                        m_rdata <= mem[m_addr[15:2]];
                    end else if (m_addr[31:2] == DEVICE_ADDR[31:2]) begin
                        m_rdata <= 32'hD0D0_D0D0;
                    end else begin
                        m_rdata <= 32'd0;
                        m_fault <= 1'b1;
                    end
                end else begin
                    delay <= delay - 1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // One core-side transaction. Inputs are driven on the falling edge and
    // c_ready is sampled mid-cycle, so nothing races the DUT's own edge.
    // ------------------------------------------------------------------
    reg [31:0] got_rdata;
    reg        got_fault;

    task do_req(input [31:0] addr, input [31:0] wdata, input [3:0] wstrb);
        begin
            @(negedge clk);
            c_valid = 1'b1; c_addr = addr; c_wdata = wdata; c_wstrb = wstrb;
            #1;
            while (!c_ready) begin
                @(negedge clk);
                #1;
            end
            got_rdata = c_rdata;
            got_fault = c_fault;
            @(posedge clk);
            #1;
            c_valid = 1'b0; c_wstrb = 4'd0;
        end
    endtask

    task check_read(input [31:0] addr, input [255:0] what);
        begin
            do_req(addr, 32'd0, 4'd0);
            if (got_fault !== 1'b0) begin
                $display("FAIL %0s: unexpected fault at %08x", what, addr);
                errors = errors + 1;
            end else if (got_rdata !== gold[addr[15:2]]) begin
                $display("FAIL %0s: read %08x got %08x expected %08x",
                         what, addr, got_rdata, gold[addr[15:2]]);
                errors = errors + 1;
            end
        end
    endtask

    task do_write(input [31:0] addr, input [31:0] wdata, input [3:0] wstrb);
        reg [31:0] g;
        begin
            do_req(addr, wdata, wstrb);
            g = gold[addr[15:2]];
            if (wstrb[0]) g[7:0]   = wdata[7:0];
            if (wstrb[1]) g[15:8]  = wdata[15:8];
            if (wstrb[2]) g[23:16] = wdata[23:16];
            if (wstrb[3]) g[31:24] = wdata[31:24];
            gold[addr[15:2]] = g;
            written[addr[15:2]] = 1'b1;
        end
    endtask

    task expect_beats(input integer want, input [255:0] what);
        begin
            if (beats !== want) begin
                $display("FAIL %0s: %0d memory beats, expected %0d",
                         what, beats, want);
                errors = errors + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    integer nrand;
    reg [31:0] a;
    reg [3:0]  ws;

    initial begin
        for (i = 0; i < 16384; i = i + 1) begin
            mem[i]  = 32'hA5A5_0000 | i;    // distinct, so a wrong word shows
            gold[i] = mem[i];
            written[i] = 1'b0;
        end
        if (!$value$plusargs("seed=%d", seed))   seed = 1;
        if (!$value$plusargs("maxlat=%d", max_lat)) max_lat = 3;
        if (!$value$plusargs("nrand=%d", nrand)) nrand = 4000;

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        @(negedge clk);

        // ---------------- phase 1: directed ----------------
        // cold miss: one full 16-beat line fill
        beats = 0;
        check_read(32'h0000_0100, "cold-miss");
        expect_beats(16, "cold-miss fill");

        // same line again: must be a hit, so no memory traffic at all
        beats = 0;
        check_read(32'h0000_0104, "hit-same-line");
        check_read(32'h0000_013C, "hit-same-line-end");
        expect_beats(0, "hits must not touch memory");

        // a different line that maps to a different index: another fill
        beats = 0;
        check_read(32'h0000_0200, "second-line");
        expect_beats(16, "second-line fill");

        if (WRITABLE != 0) begin
            // write hit into an already-resident line: no memory traffic,
            // and the line becomes dirty
            beats = 0;
            do_write(32'h0000_0104, 32'hDEAD_BEEF, 4'b1111);
            expect_beats(0, "write hit must not touch memory");
            check_read(32'h0000_0104, "write-hit readback");
            expect_beats(0, "write hit + readback stay in cache");

            // partial writes exercise the macro's bit mask (no RMW)
            do_write(32'h0000_0108, 32'h0000_0011, 4'b0001);
            do_write(32'h0000_0108, 32'h0000_2200, 4'b0010);
            do_write(32'h0000_010C, 32'h3344_0000, 4'b1100);
            check_read(32'h0000_0108, "byte-write readback");
            check_read(32'h0000_010C, "halfword-write readback");

            // conflict: same index, different tag -> evict the dirty line.
            // 4 KiB cache, so +0x1000 collides exactly.
            beats = 0;
            check_read(32'h0000_1100, "conflict-miss");
            expect_beats(32, "dirty evict = 16 writeback + 16 fill");

            // the evicted data must have reached memory: read it back, which
            // now requires another fill from the backing store
            check_read(32'h0000_0104, "readback-after-evict");
        end

        // uncacheable device word: passes through, one beat, every time
        beats = 0;
        do_req(DEVICE_ADDR, 32'd0, 4'd0);
        if (got_rdata !== 32'hD0D0_D0D0 || got_fault !== 1'b0) begin
            $display("FAIL device read: got %08x fault=%b", got_rdata, got_fault);
            errors = errors + 1;
        end
        do_req(DEVICE_ADDR, 32'd0, 4'd0);
        expect_beats(2, "uncacheable accesses must not be cached");

        if (WRITABLE != 0) begin
            beats = 0;
            do_req(DEVICE_ADDR, 32'hCAFE_0000, 4'b1111);
            expect_beats(1, "uncacheable write passes straight through");
        end

        // bus fault must propagate, and must not leave a valid line behind
        do_req(FAULT_ADDR, 32'd0, 4'd0);
        if (got_fault !== 1'b1) begin
            $display("FAIL fault: c_fault not asserted for %08x", FAULT_ADDR);
            errors = errors + 1;
        end
        do_req(FAULT_ADDR, 32'd0, 4'd0);
        if (got_fault !== 1'b1) begin
            $display("FAIL fault: second access to %08x did not fault",
                     FAULT_ADDR);
            errors = errors + 1;
        end

        // ---------------- phase 2: random ----------------
        // 0x0000..0x3FFF over a 4 KiB cache = 4 tags per index, so conflict
        // misses and evictions happen constantly rather than by luck.
        for (k = 0; k < nrand; k = k + 1) begin
            a = ({$random(seed)} % 32'h4000) & ~32'd3;
            if (WRITABLE != 0 && ({$random(seed)} % 100) < 40) begin
                ws = 4'b1111;
                case ({$random(seed)} % 3)
                    0: ws = 4'b0001 << ({$random(seed)} % 4);
                    1: ws = ({$random(seed)} % 2) ? 4'b1100 : 4'b0011;
                    default: ws = 4'b1111;
                endcase
                do_write(a, {$random(seed)}, ws);
            end else begin
                check_read(a, "random");
            end
        end

        // ---------------- phase 3: sweep ----------------
        // Reading everything back forces every remaining dirty line out and
        // proves the writeback path: data written long ago must survive
        // eviction, land in memory, and come back on the next fill.
        for (i = 0; i < 16384; i = i + 1) begin
            if (written[i])
                check_read(i * 4, "sweep");
        end

        if (errors == 0)
            $display("CACHE PASS (%0s): %0d random ops, 0 errors",
                     (WRITABLE != 0) ? "dcache" : "icache", nrand);
        else
            $display("CACHE FAIL (%0s): %0d errors",
                     (WRITABLE != 0) ? "dcache" : "icache", errors);
        $finish;
    end

    // watchdog
    integer cycles = 0;
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > 20000000) begin
            $display("CACHE FAIL: timeout");
            $finish;
        end
    end

endmodule
