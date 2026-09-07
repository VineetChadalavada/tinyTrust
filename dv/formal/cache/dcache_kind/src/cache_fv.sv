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

    function integer clog2fv;
        input integer v;
        begin
            clog2fv = 0;
            v = v - 1;
            while (v > 0) begin
                clog2fv = clog2fv + 1;
                v = v >> 1;
            end
        end
    endfunction

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
    //
    // Overridable so a run can trade one kind of coverage for another without
    // a second copy of the harness. Defaults are the 16 B / 4-line geometry
    // described above; dcache_wb.sby lowers LINE_BYTES to 8. See that file for
    // why, and for what the smaller line stops covering.
`ifndef FV_LINE_BYTES
  `define FV_LINE_BYTES 16
`endif
`ifndef FV_LINES
  `define FV_LINES 4
`endif
    localparam FV_LINE_BYTES = `FV_LINE_BYTES;
    localparam FV_LINES      = `FV_LINES;

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
`ifdef FORMAL
        ,
        .fv_probe_addr(chk_sram_addr), .fv_probe_data(chk_sram_word64),
        .fv_probe_idx(chk_index_z),    .fv_probe_tag(chk_tag_seen),
        .fv_probe_state(chk_state),    .fv_state(dut_state),
        .fv_beat(dut_beat)
`endif
    );

`ifdef FORMAL
    // ------------------------------------------------------------------
    // The inductive invariant
    //
    // Induction starts from an arbitrary state, so most of what it tries is
    // unreachable nonsense -- a cache claiming to hold a line whose stored
    // data is unrelated to anything ever written. The property alone cannot
    // rule that out, because nothing in it says what the array should
    // contain. These assertions do, and each one is proven as well as used:
    // the induction step gets them as hypotheses in earlier steps and has to
    // establish them in the last.
    //
    // In words: this cache is a correct write-back cache with respect to the
    // tracked word.
    //   - if the line is resident, the array holds what the core last wrote
    //   - if it is resident and clean, memory agrees too
    //   - if it is not resident, memory holds the value
    // The one case with no constraint on memory is a resident dirty line,
    // which is exactly what "dirty" means.
    // ------------------------------------------------------------------
    localparam OFF_B = clog2fv(FV_LINE_BYTES);
    localparam IDX_B = clog2fv(FV_LINES);
    localparam TAG_B = 32 - OFF_B - IDX_B;
    localparam W64_B = clog2fv(FV_LINE_BYTES / 8);

    wire [31:0] chk_byte = {chk_word, 2'b00};

    wire [31:0] chk_index_z   = {{(32-IDX_B){1'b0}}, chk_byte[OFF_B +: IDX_B]};
    wire [31:0] chk_sram_addr = {{(32-(IDX_B+W64_B)){1'b0}},
                                 chk_byte[OFF_B +: IDX_B],
                                 chk_byte[3 +: W64_B]};
    wire [TAG_B-1:0] chk_tag  = chk_byte[31 -: TAG_B];

    wire [63:0] chk_sram_word64;
    wire [31:0] chk_tag_seen;
    wire [1:0]  chk_state;
    wire [3:0]  dut_state;
    wire [31:0] dut_beat;

    wire [31:0] chk_sram_word = chk_byte[2] ? chk_sram_word64[63:32]
                                            : chk_sram_word64[31:0];

    localparam [1:0] ST_I_FV = 2'b00, ST_M_FV = 2'b11;

    wire chk_resident = (chk_state != ST_I_FV)
                     && (chk_tag_seen[TAG_B-1:0] == chk_tag);
    wire chk_dirty    = (chk_state == ST_M_FV);

    // Only claimed while the cache is idle. Mid-refill and mid-writeback the
    // line is deliberately in flux, and constraining it there would be
    // asserting something false.
    wire dut_idle = (dut_state == 4'd0);

    always @* begin
        if (rst_n && dut_idle) begin
            if (chk_resident)
                assert (chk_sram_word == core_shadow);
            if (chk_resident && !chk_dirty)
                assert (mem_shadow == core_shadow);
            if (!chk_resident)
                assert (mem_shadow == core_shadow);
        end
    end
`endif

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

`ifdef FV_DATA_ABSTRACT
    // ---- data abstraction (data independence) ----
    // The cache never branches on a data value. In cache.v, c_wdata, m_rdata
    // and sram_dout appear only in assignments and in one mux whose select is
    // an *address* bit (a_hi); no comparison, no case, nothing in the FSM. A
    // design with no data-dependent control is data-independent, so the set of
    // values the environment may offer can be shrunk without weakening what
    // the transparency property proves about routing and storage.
    //
    // Each byte is restricted to 0x00 or 0xFF. That still lets the solver give
    // any two byte positions distinguishable values, so a byte steered to the
    // wrong offset, half or line is still caught -- which is the entire class
    // of defect this property exists to find. The reachable data space drops
    // from 2^32 per word to 2^4, which is the point: PDR was drowning in the
    // width of the datapath, not in the depth of the protocol.
    //
    // What this gives up: a defect that needs three or more distinct byte
    // values to expose. For a data-oblivious design that class is empty by
    // construction, but the assumption is doing real work and is written down
    // rather than buried in a script.
    always @* begin
        assume (c_wdata[7:0]        == 8'h00 || c_wdata[7:0]        == 8'hFF);
        assume (c_wdata[15:8]       == 8'h00 || c_wdata[15:8]       == 8'hFF);
        assume (c_wdata[23:16]      == 8'h00 || c_wdata[23:16]      == 8'hFF);
        assume (c_wdata[31:24]      == 8'h00 || c_wdata[31:24]      == 8'hFF);
        assume (m_rdata_free[7:0]   == 8'h00 || m_rdata_free[7:0]   == 8'hFF);
        assume (m_rdata_free[15:8]  == 8'h00 || m_rdata_free[15:8]  == 8'hFF);
        assume (m_rdata_free[23:16] == 8'h00 || m_rdata_free[23:16] == 8'hFF);
        assume (m_rdata_free[31:24] == 8'h00 || m_rdata_free[31:24] == 8'hFF);
        assume (init_val[7:0]       == 8'h00 || init_val[7:0]       == 8'hFF);
        assume (init_val[15:8]      == 8'h00 || init_val[15:8]      == 8'hFF);
        assume (init_val[23:16]     == 8'h00 || init_val[23:16]     == 8'hFF);
        assume (init_val[31:24]     == 8'h00 || init_val[31:24]     == 8'hFF);
    end
`endif

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

    // Cover: did the bound actually reach the eviction sequence? For the D$
    // the property only bites once a dirty line has been written back and the
    // word re-read through a later refill -- write, evict, writeback, refill
    // the replacing line, re-read. Whether a given depth reaches that is a
    // question about the design, not one to settle with arithmetic on paper,
    // so it is stated as a cover and checked. This is what justifies the
    // bound in dcache_wb.sby; if it ever stops being reachable there, the
    // bound is too small and the assertion result means less than it appears.
`ifdef DCACHE
    reg wb_seen;
    always @(posedge clk) begin
        if (!rst_n)
            wb_seen <= 1'b0;
        else if (mem_write)
            wb_seen <= 1'b1;
    end
    always @* begin
        if (rst_n && wb_seen && core_read)
            cover (1);
    end
`endif

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
