// TinyTrust — formal harness for rtl/cache/cache.v (P3, D22)
//
// D22 put the formal boundary at the core's ports and gave the cache its own
// proof. This is that proof, and the property is the only one that matters at
// this level:
//
//     THE CACHE IS TRANSPARENT.
//     A read returns the last value written to that address.
//
// Everything a cache can get wrong shows up as a violation of it — a tag
// compared against the wrong bits, a line evicted without its dirty data
// reaching memory, a refill assembled in the wrong order, a byte-enable
// applied to the wrong half of the 64-bit word, a fetch buffer that answers
// for an address it does not hold. None of those need a separate property.
//
// ONE-ADDRESS ABSTRACTION
// A cache is far too big to model exhaustively: 4 KiB of SRAM plus a backing
// memory. The standard move is to prove the property for a single arbitrary
// address and let the solver pick which. `chk_word` is `anyconst`, so a proof
// covers every address rather than one the author chose. Only two shadow
// registers are then needed:
//
//   core_shadow  what a correct cache must return for chk_word
//   mem_shadow   what the backing memory holds at chk_word
//
// Memory answers with mem_shadow for chk_word and with free data everywhere
// else. That is sound: the tracked word's value is fully determined, and no
// other word can affect it in a correct design — if the cache ever returns
// another word's data for chk_word, the free data makes it a mismatch and the
// assertion fires. The abstraction is what keeps the state space small enough
// to close.
//
// Faults are excluded (m_fault tied low). The uncacheable and fault paths are
// pass-through, covered by the block-level testbench in dv/cache/, and mixing
// them in here would only add environment states without strengthening the
// property being proven.

module cache_fv (
    input clk
);

    // Reset is generated here rather than taken as a port: a free `rst_n`
    // input lets the solver hold the design in reset for the whole bound, or
    // re-assert it mid-transaction, and neither is a real environment.
    //
    // Three cycles, not fifteen. The DUT's reset is asynchronous and clears
    // everything on the first edge, so a long reset buys nothing and costs
    // depth directly: every cycle spent in reset is a cycle of the bound not
    // spent on cache behaviour, and BMC cost grows steeply with depth. The
    // first attempt held reset for 15 of 40 cycles, i.e. threw away a third
    // of the proof.
    reg [1:0] rst_cnt = 2'd0;
    wire rst_n = (rst_cnt == 2'd3);
    always @(posedge clk)
        if (rst_cnt != 2'd3)
            rst_cnt <= rst_cnt + 2'd1;

`ifdef DCACHE
    localparam WRITABLE = 1;
`else
    localparam WRITABLE = 0;
`endif

    localparam [31:0] CACHEABLE_LIMIT = 32'h0001_0000;

    // Reduced geometry (see cache.v's parameter block). At the shipped 64 B /
    // 64-line configuration one refill is 16 beats, so a bounded proof spends
    // its whole depth inside a single line transfer and never reaches the
    // sequences that matter — a write, an eviction, the writeback, a refill of
    // the replacing line, and a re-read. Measured: depth 55 at the shipped
    // geometry ran 6h21m on boolector without returning a verdict (no
    // counterexample either; it simply did not terminate).
    //
    // 16 B lines and 4 lines make a refill 4 beats, so that whole sequence
    // fits in ~25 cycles and closes. What is being proven is unchanged: the
    // tag compare, the dirty tracking, the refill assembly order, the
    // writeback ordering and the fetch buffer are all geometry-independent
    // logic. Only counter widths differ, and those are derived with clog2
    // rather than written out, so there is no separate code path being
    // proven. What this does NOT cover is a bug that only appears at a
    // specific width — the block-level testbench in dv/cache/ runs the
    // shipped geometry and is what covers that.
    localparam FV_LINE_BYTES = 16;
    localparam FV_LINES      = 4;

    // ---- unconstrained core-side stimulus ----
    (* anyseq *) reg        c_valid;
    (* anyseq *) reg [31:0] c_addr;
    (* anyseq *) reg [31:0] c_wdata;
    (* anyseq *) reg [3:0]  c_wstrb_raw;

    wire [3:0]  c_wstrb = (WRITABLE != 0) ? c_wstrb_raw : 4'd0;
    wire        c_ready, c_fault;
    wire [31:0] c_rdata;

    // ---- memory side ----
    wire        m_valid;
    wire [31:0] m_addr, m_wdata;
    wire [3:0]  m_wstrb;
    (* anyseq *) reg        m_ready;
    (* anyseq *) reg [31:0] m_rdata_free;
    wire [31:0] m_rdata;
    wire        m_fault = 1'b0;

    // ---- the address under proof ----
    (* anyconst *) reg [29:0] chk_word;    // word address
    (* anyconst *) reg [31:0] init_val;    // memory contents at reset

    reg [31:0] core_shadow;
    reg [31:0] mem_shadow;

    // Memory is exact for the tracked word and arbitrary elsewhere.
    assign m_rdata = (m_addr[31:2] == chk_word) ? mem_shadow : m_rdata_free;

    cache #(.WRITABLE(WRITABLE), .CACHEABLE_LIMIT(CACHEABLE_LIMIT),
            .LINE_BYTES(FV_LINE_BYTES), .LINES(FV_LINES),
            .USE_MACRO(0)) uut (
        .clk(clk), .rst_n(rst_n),
        .c_valid(c_valid), .c_addr(c_addr), .c_wdata(c_wdata),
        .c_wstrb(c_wstrb), .c_ready(c_ready), .c_rdata(c_rdata),
        .c_fault(c_fault),
        .m_valid(m_valid), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_wstrb(m_wstrb), .m_ready(m_ready), .m_rdata(m_rdata),
        .m_fault(m_fault)
    );

    // ------------------------------------------------------------------
    // Environment constraints
    // ------------------------------------------------------------------
    // The tracked address is in the cacheable region: the uncacheable path is
    // a pass-through with no state, and is covered in simulation.
    always @* assume (chk_word < (CACHEABLE_LIMIT >> 2));

    // The core holds a request stable until it is accepted. This is a real
    // property of core_p5's imem/dmem ports, not a convenience: nothing in
    // the cache latches the request, so without it the solver could change
    // the address mid-transaction, which the core cannot do.
    reg [31:0] p_addr, p_wdata;
    reg [3:0]  p_wstrb;
    reg        p_pending;
    always @(posedge clk) begin
        if (!rst_n) begin
            p_pending <= 1'b0;
        end else begin
            p_addr  <= c_addr;
            p_wdata <= c_wdata;
            p_wstrb <= c_wstrb;
            p_pending <= c_valid && !c_ready;
        end
    end
    always @* begin
        if (rst_n && p_pending) begin
            assume (c_valid);
            assume (c_addr  == p_addr);
            assume (c_wdata == p_wdata);
            assume (c_wstrb == p_wstrb);
        end
    end

    // Bus fairness: memory answers within two cycles, so the bound is spent
    // on cache behaviour rather than on stalled refills.
    reg [1:0] stall_cnt;
    always @(posedge clk) begin
        if (!rst_n)
            stall_cnt <= 2'd0;
        else if (m_valid && !m_ready)
            stall_cnt <= stall_cnt + 2'd1;
        else
            stall_cnt <= 2'd0;
    end
    always @* assume (stall_cnt < 2'd2);

    // ------------------------------------------------------------------
    // Shadow tracking
    // ------------------------------------------------------------------
    wire core_acc   = rst_n && c_valid && c_ready && !c_fault;
    wire core_hits  = core_acc && (c_addr[31:2] == chk_word);
    wire core_write = core_hits && (c_wstrb != 4'd0);
    wire core_read  = core_hits && (c_wstrb == 4'd0);

    wire mem_acc    = rst_n && m_valid && m_ready;
    wire mem_write  = mem_acc && (m_addr[31:2] == chk_word) && (m_wstrb != 4'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            core_shadow <= init_val;
            mem_shadow  <= init_val;
        end else begin
            if (core_write) begin
                if (c_wstrb[0]) core_shadow[7:0]   <= c_wdata[7:0];
                if (c_wstrb[1]) core_shadow[15:8]  <= c_wdata[15:8];
                if (c_wstrb[2]) core_shadow[23:16] <= c_wdata[23:16];
                if (c_wstrb[3]) core_shadow[31:24] <= c_wdata[31:24];
            end
            if (mem_write) begin
                if (m_wstrb[0]) mem_shadow[7:0]   <= m_wdata[7:0];
                if (m_wstrb[1]) mem_shadow[15:8]  <= m_wdata[15:8];
                if (m_wstrb[2]) mem_shadow[23:16] <= m_wdata[23:16];
                if (m_wstrb[3]) mem_shadow[31:24] <= m_wdata[31:24];
            end
        end
    end

    // ------------------------------------------------------------------
    // THE property
    // ------------------------------------------------------------------
    always @* begin
        if (rst_n && core_read)
            assert (c_rdata == core_shadow);
    end

    // Liveness-ish sanity: a request must not be answered with a fault in the
    // cacheable region when memory never faults.
    always @* begin
        if (rst_n && c_valid && c_ready && (c_addr < CACHEABLE_LIMIT))
            assert (!c_fault);
    end

    // Cover: the proof is worthless if the environment cannot even complete a
    // read of the tracked word, which from a cold cache requires a full
    // refill first. Stated at the boundary, not as a hierarchical reference
    // into the DUT — yosys's read_verilog has no hierarchical refs and turns
    // one into a silently undriven wire (BUG-002).
    always @* begin
        if (rst_n)
            cover (core_read);
    end

endmodule
