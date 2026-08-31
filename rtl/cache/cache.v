// TinyTrust — direct-mapped cache with an SRAM data array (P3, D21/D17/D19)
//
// One module serves both caches: WRITABLE=0 is the instruction cache
// (read-only, no dirty state, no writeback), WRITABLE=1 is the data cache
// (write-back, write-allocate per D17). The core side is exactly the port
// shape core_p5.v already drives on imem/dmem, and the memory side is exactly
// the single-outstanding valid/ready bus the SoC and testbench already speak,
// so a cache drops in between them without either end changing.
//
// Geometry (D21): 4 KiB, 64 B line, direct-mapped, 64 lines.
//
//   addr[31:12]  tag       20 bits, held in flops
//   addr[11:6]   index      6 bits, selects one of 64 lines
//   addr[5:3]    word64     8 x 64-bit words per line
//   addr[2]      half       which 32-bit half of that word
//   addr[1:0]    byte       within the 32-bit word
//
// Data array is one RM_IHPSG13_1P_512x64 (512 x 64 bit = 4 KiB exactly), so
// the SRAM address is {index, word64} — 9 bits, no waste. Tags stay in flops
// (D19) because they need a single-cycle compare, and at P4 a snoop port as
// well; 64 lines x 21-22 bits is ~1,350 flops, the number D21 was chosen to
// keep down.
//
// TIMING
//   read hit    1 wait state. The tag compare is combinational out of flops,
//               so the SRAM address is presented in the same cycle the request
//               arrives, and the data comes back on the next edge — one cycle
//               of SRAM read latency is unavoidable with a synchronous macro.
//   write hit   0 wait states. The macro's per-bit write mask means a partial
//               (SB/SH) write needs no read-modify-write: the byte enables are
//               expanded onto A_BM and the write completes in the same cycle
//               the request arrives. This is the main reason a bit-masked
//               macro was worth choosing.
//   miss        writeback (if dirty) then refill, 16 32-bit beats each, then
//               the request re-runs from S_IDLE and hits. Re-running rather
//               than serving directly out of the fill path costs one lookup
//               cycle per miss and removes a whole class of bypass logic — the
//               core holds addr and valid stable until ready, so it is free to
//               simply try again.
//
// UNCACHEABLE REGION
// Addresses at or above CACHEABLE_LIMIT bypass the cache entirely and become
// a single pass-through transfer. This is not an optimisation, it is required
// for correctness: TOHOST is a device register at 0x0001_0000, and a
// write-back cache would swallow the store that ends every test. The same
// path carries bus faults through unchanged, which is what keeps the core's
// precise access-fault behaviour (and the ls_fault / fetch_fault tests) intact.
//
// NOT HANDLED, deliberately: there is no coherence between the I$ and the D$,
// and the core traps FENCE.I (Zifencei is not claimed), so self-modifying code
// is not supported. Code and data occupy disjoint regions in every test — the
// programs live below 0x7000 and the scratch area starts at 0x8000 — so no
// store can alias a cached instruction line. I$/D$ coherence arrives with the
// snoop channel at P4.

module cache #(
    parameter        WRITABLE        = 0,              // 0 = I$, 1 = D$
    parameter [31:0] CACHEABLE_LIMIT = 32'h0001_0000,
    // Geometry. Defaults are D21 (4 KiB, 64 B line, 64 lines). These are
    // parameters rather than localparams for one concrete reason: the formal
    // proof in dv/formal/cache does not close at the shipped geometry, where a
    // single refill is 16 beats and consumes most of any bounded depth.
    // Proving a reduced configuration keeps the protocol identical -- tag
    // compare, dirty tracking, refill assembly, writeback ordering, fetch
    // buffer -- and shrinks only the counters. P4 wants configurable caches
    // regardless.
    parameter        LINE_BYTES      = 64,
    parameter        LINES           = 64,
    // 1 = instantiate the real SG13G2 macro (requires the 4 KiB geometry);
    // 0 = instantiate the generic behavioural array, sized from the geometry
    // parameters, for reduced-geometry formal runs only. Never 0 in anything
    // that synthesises.
    parameter        USE_MACRO       = 1
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- core side (mirrors core_p5's imem/dmem ports) ----
    input  wire        c_valid,
    input  wire [31:0] c_addr,
    input  wire [31:0] c_wdata,
    input  wire [3:0]  c_wstrb,      // nonzero = store; always 0 for the I$
    output reg         c_ready,
    output reg  [31:0] c_rdata,
    output reg         c_fault,

    // ---- memory side (single-outstanding valid/ready, 32-bit) ----
    output reg         m_valid,
    output reg  [31:0] m_addr,
    output reg  [31:0] m_wdata,
    output reg  [3:0]  m_wstrb,
    input  wire        m_ready,
    input  wire [31:0] m_rdata,
    input  wire        m_fault
);

    function integer clog2;
        input integer v;
        begin
            clog2 = 0;
            v = v - 1;
            while (v > 0) begin
                clog2 = clog2 + 1;
                v = v >> 1;
            end
        end
    endfunction

    localparam OFF_BITS  = clog2(LINE_BYTES);            // 6 at a 64 B line
    localparam IDX_BITS  = clog2(LINES);                 // 6 at 64 lines
    localparam TAG_BITS  = 32 - OFF_BITS - IDX_BITS;     // 20
    localparam BEATS     = LINE_BYTES / 4;               // 16 32-bit beats
    localparam BEAT_BITS = clog2(BEATS);                 // 4
    localparam W64       = LINE_BYTES / 8;               // 8 64-bit words
    localparam W64_BITS  = clog2(W64);                   // 3
    localparam SRAM_AW   = IDX_BITS + W64_BITS;          // 9

    // ------------------------------------------------------------------
    // Address decode
    // ------------------------------------------------------------------
    wire [TAG_BITS-1:0] a_tag   = c_addr[31 -: TAG_BITS];
    wire [IDX_BITS-1:0] a_index = c_addr[OFF_BITS +: IDX_BITS];
    wire [W64_BITS-1:0] a_w64   = c_addr[3 +: W64_BITS];
    wire                a_hi    = c_addr[2];
    wire                cacheable = (c_addr < CACHEABLE_LIMIT);
    wire                is_write  = (c_wstrb != 4'd0);

    // ------------------------------------------------------------------
    // Tag array (flops, D19)
    // ------------------------------------------------------------------
    reg [TAG_BITS-1:0] tag_q   [0:LINES-1];
    reg                valid_q [0:LINES-1];
    reg                dirty_q [0:LINES-1];   // trimmed away when WRITABLE=0

    wire tag_match = valid_q[a_index] && (tag_q[a_index] == a_tag);
    wire hit       = c_valid && cacheable && tag_match;
    wire victim_dirty = (WRITABLE != 0) && valid_q[a_index] && dirty_q[a_index];

    // ------------------------------------------------------------------
    // Data array
    // ------------------------------------------------------------------
    reg  [SRAM_AW-1:0] sram_addr;
    reg  [63:0] sram_din;
    reg  [63:0] sram_bm;
    reg         sram_men, sram_wen, sram_ren;
    wire [63:0] sram_dout;

    generate
        if (USE_MACRO != 0) begin : g_macro
            // The shipped array: one RM_IHPSG13_1P_512x64 = 4 KiB exactly.
            RM_IHPSG13_1P_512x64_c2_bm_bist u_data (
                .A_CLK       (clk),
                .A_MEN       (sram_men),
                .A_WEN       (sram_wen),
                .A_REN       (sram_ren),
                .A_ADDR      (sram_addr),
                .A_DIN       (sram_din),
                .A_DLY       (1'b0),
                .A_DOUT      (sram_dout),
                .A_BM        (sram_bm),
                .A_BIST_CLK  (1'b0),
                .A_BIST_EN   (1'b0),
                .A_BIST_MEN  (1'b0),
                .A_BIST_WEN  (1'b0),
                .A_BIST_REN  (1'b0),
                .A_BIST_ADDR (9'd0),
                .A_BIST_DIN  (64'd0),
                .A_BIST_BM   (64'd0)
            );
        end else begin : g_model
            // Verification-only array, sized from the geometry parameters.
            sram_1p_bm #(.P_DATA_WIDTH(64), .P_ADDR_WIDTH(SRAM_AW)) u_data (
                .A_CLK  (clk),
                .A_MEN  (sram_men),
                .A_WEN  (sram_wen),
                .A_REN  (sram_ren),
                .A_ADDR (sram_addr),
                .A_DIN  (sram_din),
                .A_BM   (sram_bm),
                .A_DOUT (sram_dout)
            );
        end
    endgenerate

    // byte enables -> per-bit write mask
    function [31:0] expand4;
        input [3:0] s;
        begin
            expand4 = {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}};
        end
    endfunction

    // ------------------------------------------------------------------
    // Control
    // ------------------------------------------------------------------
    localparam [3:0] S_IDLE   = 4'd0,
                     S_READ   = 4'd1,   // waiting on SRAM read data (hit)
                     S_BYPASS = 4'd2,   // uncacheable pass-through
                     S_WB_RD  = 4'd3,   // read a line word out of the SRAM
                     S_WB_W0  = 4'd4,   // write its low half to memory
                     S_WB_W1  = 4'd5,   // write its high half to memory
                     S_FILL   = 4'd6,   // pull the line in from memory
                     S_FAULT  = 4'd7;   // refill hit a bus fault

    // ------------------------------------------------------------------
    // Sequential fetch buffer (instruction cache only)
    //
    // One SRAM read returns 64 bits, which is two instructions. Serving only
    // the requested half throws the other one away and makes every fetch cost
    // the SRAM's 1-cycle read latency. Keeping the sibling word means a
    // sequential fetch stream alternates SRAM-read / buffer-hit, so the fetch
    // path averages one cycle per instruction instead of two. This is the
    // reason D21 put the data array in a 64-bit-wide macro.
    //
    // Read-only cache only: with no writes there is nothing that can make a
    // buffered word stale except a refill, so a single conservative clear
    // when a line lands is the whole invalidation story. The D$ takes writes
    // and is left simple.
    // ------------------------------------------------------------------
    reg        fb_valid;
    reg [29:0] fb_word;                 // word address held in the buffer
    reg [31:0] fb_data;

    wire fb_hit = (WRITABLE == 0) && fb_valid && c_valid && cacheable
               && (c_addr[31:2] == fb_word);

    reg [3:0]  state;
    reg [BEAT_BITS-1:0] beat;           // 32-bit beat index within a line
    reg [63:0] wb_data;                 // line word being written back
    reg [31:0] fill_lo;                 // low half of the pair being assembled
    reg [31:0] line_base;               // byte address of the line in flight
    reg [TAG_BITS-1:0] wb_tag;

    // ------------------------------------------------------------------
    // SRAM port muxing
    // ------------------------------------------------------------------
    always @* begin
        sram_men  = 1'b0;
        sram_wen  = 1'b0;
        sram_ren  = 1'b0;
        sram_addr = {a_index, a_w64};
        sram_din  = {c_wdata, c_wdata};        // replicated; A_BM picks a half
        sram_bm   = 64'd0;

        case (state)
            S_IDLE: begin
                if (fb_hit) begin
                    ;                                  // served from the buffer
                end else if (hit && is_write && (WRITABLE != 0)) begin
                    // single-cycle partial write via the macro's bit mask
                    sram_men = 1'b1;
                    sram_wen = 1'b1;
                    sram_bm  = a_hi ? {expand4(c_wstrb), 32'd0}
                                    : {32'd0, expand4(c_wstrb)};
                end else if (hit) begin
                    sram_men = 1'b1;
                    sram_ren = 1'b1;
                end
            end
            S_WB_RD: begin
                sram_men  = 1'b1;
                sram_ren  = 1'b1;
                sram_addr = {a_index, beat[BEAT_BITS-1:1]};
            end
            S_FILL: begin
                // every second beat completes a 64-bit word
                if (m_valid && m_ready && !m_fault && beat[0]) begin
                    sram_men  = 1'b1;
                    sram_wen  = 1'b1;
                    sram_addr = {a_index, beat[BEAT_BITS-1:1]};
                    sram_din  = {m_rdata, fill_lo};
                    sram_bm   = {64{1'b1}};
                end
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Core-side response
    // ------------------------------------------------------------------
    always @* begin
        c_ready = 1'b0;
        c_fault = 1'b0;
        c_rdata = a_hi ? sram_dout[63:32] : sram_dout[31:0];

        case (state)
            S_IDLE: begin
                if (fb_hit) begin
                    c_ready = 1'b1;                    // zero wait states
                    c_rdata = fb_data;
                end else begin
                    // a write hit retires in the cycle it arrives
                    c_ready = hit && is_write && (WRITABLE != 0);
                end
            end
            S_READ:
                c_ready = 1'b1;
            S_BYPASS: begin
                c_ready = m_ready;
                c_fault = m_ready && m_fault;
                c_rdata = m_rdata;
            end
            S_FAULT: begin
                c_ready = 1'b1;
                c_fault = 1'b1;
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Memory-side request
    // ------------------------------------------------------------------
    always @* begin
        m_valid = 1'b0;
        m_addr  = 32'd0;
        m_wdata = 32'd0;
        m_wstrb = 4'd0;

        case (state)
            S_BYPASS: begin
                m_valid = 1'b1;
                m_addr  = c_addr;
                m_wdata = c_wdata;
                m_wstrb = c_wstrb;
            end
            S_WB_W0: begin
                m_valid = 1'b1;
                m_addr  = {wb_tag, a_index, beat[BEAT_BITS-1:1], 3'b000};
                // straight off the SRAM: the data lands on entry to this
                // state, a cycle before wb_data is loaded from it
                m_wdata = sram_dout[31:0];
                m_wstrb = 4'b1111;
            end
            S_WB_W1: begin
                m_valid = 1'b1;
                m_addr  = {wb_tag, a_index, beat[BEAT_BITS-1:1], 3'b100};
                m_wdata = wb_data[63:32];
                m_wstrb = 4'b1111;
            end
            S_FILL: begin
                m_valid = 1'b1;
                m_addr  = line_base | {{(30-BEAT_BITS){1'b0}}, beat, 2'b00};
                m_wstrb = 4'd0;
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential
    // ------------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            beat     <= {BEAT_BITS{1'b0}};
            fb_valid <= 1'b0;
            for (i = 0; i < LINES; i = i + 1) begin
                valid_q[i] <= 1'b0;
                dirty_q[i] <= 1'b0;
                tag_q[i]   <= {TAG_BITS{1'b0}};
            end
        end else begin
            case (state)

                S_IDLE: begin
                    if (fb_hit) begin
                        ;                              // already answered
                    end else if (c_valid && !cacheable) begin
                        state <= S_BYPASS;
                    end else if (c_valid && !tag_match) begin
                        // miss: evict first if the victim holds dirty data
                        beat      <= {BEAT_BITS{1'b0}};
                        line_base <= {a_tag, a_index, {OFF_BITS{1'b0}}};
                        wb_tag    <= tag_q[a_index];
                        // the line is in flux from here until the fill lands
                        valid_q[a_index] <= 1'b0;
                        state     <= victim_dirty ? S_WB_RD : S_FILL;
                    end else if (hit && is_write && (WRITABLE != 0)) begin
                        dirty_q[a_index] <= 1'b1;   // write completed this cycle
                    end else if (hit) begin
                        state <= S_READ;            // SRAM read in flight
                    end
                end

                S_READ: begin
                    state <= S_IDLE;                // data returned this cycle
                    if (WRITABLE == 0) begin
                        // keep the half we are not returning
                        fb_valid <= 1'b1;
                        fb_word  <= {c_addr[31:3], ~c_addr[2]};
                        fb_data  <= a_hi ? sram_dout[31:0] : sram_dout[63:32];
                    end
                end

                S_BYPASS:
                    if (m_ready)
                        state <= S_IDLE;

                // ---- writeback: 8 SRAM words -> 16 memory beats ----
                S_WB_RD:
                    state <= S_WB_W0;               // SRAM latency

                S_WB_W0: begin
                    // latch for S_WB_W1; the macro holds A_DOUT until the next
                    // read, but the high half is not going to depend on that
                    wb_data <= sram_dout;
                    if (m_ready)
                        state <= S_WB_W1;
                end

                S_WB_W1:
                    if (m_ready) begin
                        if (beat[BEAT_BITS-1:1] == (W64-1)) begin
                            beat  <= {BEAT_BITS{1'b0}};
                            state <= S_FILL;
                        end else begin
                            beat  <= beat + 2;
                            state <= S_WB_RD;
                        end
                    end

                // ---- refill: 16 memory beats -> 8 SRAM words ----
                S_FILL:
                    if (m_ready) begin
                        if (m_fault) begin
                            state <= S_FAULT;
                        end else begin
                            if (!beat[0])
                                fill_lo <= m_rdata;
                            if (beat == (BEATS-1)) begin
                                tag_q[a_index]   <= a_tag;
                                valid_q[a_index] <= 1'b1;
                                dirty_q[a_index] <= 1'b0;
                                fb_valid <= 1'b0;   // may have replaced its line
                                state <= S_IDLE;    // request re-runs, now a hit
                            end else begin
                                beat <= beat + 1;
                            end
                        end
                    end

                S_FAULT:
                    state <= S_IDLE;

                default:
                    state <= S_IDLE;
            endcase
        end
    end

endmodule
