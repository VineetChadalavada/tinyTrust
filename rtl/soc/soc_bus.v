// TinyTrust -- SoC bus (S1-A)
//
// Connects several masters to several slaves, one transfer at a time, with a
// round-robin arbiter and an address decoder.
//
// WHY THIS SHAPE
// The interface is exactly the one the caches already speak on their memory
// side and the one core_p5 already drives: valid/ready, 32-bit, one transfer
// outstanding. Nothing on either end had to change to connect to it. D26
// chose the same interface for the two-core coherent bus, so S2 replaces the
// arbiter here and adds a snoop channel without touching the caches or the
// processor.
//
// TWO MASTERS FROM DAY ONE
// Even the single-core chip has two masters: the instruction cache and the
// data cache each have their own memory port. So arbitration is not something
// S2 introduces -- it is exercised from S1, on a design simple enough to
// debug it in.
//
// ADDRESS DECODE
// One nibble, addr[31:28], as ARCHITECTURE.md 4 specified. Cheap, and it is
// what fixes the memory map. Each slave declares the nibble it answers to
// through SLAVE_NIBBLE, four bits per slave with slave 0 in the low bits.
//
// An address matching no slave is answered immediately with ready and fault
// in the same cycle. That is deliberate: an unmapped access must not hang the
// bus waiting for a slave that will never answer, and the processor already
// knows how to turn a bus fault into a precise trap. A hang here would look
// like a processor bug and be far harder to find than a trap.
//
// PARAMETERISABLE TO N MASTERS
// D14 keeps the arbiter written for any number of masters, so the second core
// costs a parameter change rather than a rewrite.

module soc_bus #(
    parameter NM = 2,                          // masters
    parameter NS = 4,                          // slaves
    // Address nibble per slave, 4 bits each, slave 0 in the low bits.
    // Default 0x3210: slave 0 -> 0x0, slave 1 -> 0x1, slave 2 -> 0x2,
    // slave 3 -> 0x3, matching the S1 memory map (D30).
    parameter [NS*4-1:0] SLAVE_NIBBLE = 16'h3210
) (
    input  wire                clk,
    input  wire                rst_n,

    // ---- master side (one port per master, flattened) ----
    input  wire [NM-1:0]       m_valid,
    input  wire [NM*32-1:0]    m_addr,
    input  wire [NM*32-1:0]    m_wdata,
    input  wire [NM*4-1:0]     m_wstrb,
    output reg  [NM-1:0]       m_ready,
    output wire [NM*32-1:0]    m_rdata,
    output reg  [NM-1:0]       m_fault,

    // ---- slave side (request is broadcast; only the selected slave sees
    //      its valid asserted, so address and data need only one copy) ----
    output reg  [NS-1:0]       s_valid,
    output wire [31:0]         s_addr,
    output wire [31:0]         s_wdata,
    output wire [3:0]          s_wstrb,
    input  wire [NS-1:0]       s_ready,
    input  wire [NS*32-1:0]    s_rdata,
    input  wire [NS-1:0]       s_fault
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

    localparam MW = (NM > 1) ? clog2(NM) : 1;

    integer i, k, idx;

    // ------------------------------------------------------------------
    // Round-robin pick
    //
    // Scanned downwards so that the *earliest* master in rotation order is
    // the last one to write `pick`, and blocking assignment leaves it there.
    // The rotation offset avoids a modulo: the index is only ever one NM
    // above the range, so a single conditional subtract brings it back.
    // ------------------------------------------------------------------
    reg [MW-1:0] last;          // who was granted most recently
    reg [MW-1:0] gnt;           // who holds a locked grant
    reg          busy;          // a transfer is in flight

    reg [MW-1:0] pick;
    reg          pick_valid;

    always @* begin
        pick       = {MW{1'b0}};
        pick_valid = 1'b0;
        for (i = NM-1; i >= 0; i = i - 1) begin
            idx = i + last + 1;
            if (idx >= NM) idx = idx - NM;
            if (m_valid[idx]) begin
                pick       = idx[MW-1:0];
                pick_valid = 1'b1;
            end
        end
    end

    // While a transfer is in flight the grant is locked, so a slow slave
    // cannot have the bus pulled out from under it mid-transfer.
    wire [MW-1:0] sel       = busy ? gnt : pick;
    wire          sel_valid = busy ? 1'b1 : pick_valid;

    // ------------------------------------------------------------------
    // Route the selected master's request out
    // ------------------------------------------------------------------
    wire [31:0] sel_addr  = m_addr [sel*32 +: 32];
    assign      s_addr    = sel_addr;
    assign      s_wdata   = m_wdata[sel*32 +: 32];
    assign      s_wstrb   = m_wstrb[sel*4  +: 4];

    // ------------------------------------------------------------------
    // Decode
    // ------------------------------------------------------------------
    reg [NS-1:0] s_hit;
    always @* begin
        for (k = 0; k < NS; k = k + 1)
            s_hit[k] = (sel_addr[31:28] == SLAVE_NIBBLE[k*4 +: 4]);
    end

    wire mapped = |s_hit;

    always @* begin
        s_valid = {NS{1'b0}};
        if (sel_valid)
            s_valid = s_hit;
    end

    // ------------------------------------------------------------------
    // Response back to the selected master
    //
    // An unmapped address completes in the same cycle with fault set, rather
    // than waiting for a slave that does not exist.
    // ------------------------------------------------------------------
    reg [31:0] mux_rdata;
    always @* begin
        mux_rdata = 32'd0;
        for (k = 0; k < NS; k = k + 1)
            if (s_hit[k])
                mux_rdata = s_rdata[k*32 +: 32];
    end

    wire cur_ready = sel_valid && (mapped ? |(s_ready & s_hit) : 1'b1);
    wire cur_fault = sel_valid && (mapped ? |(s_fault & s_hit) : 1'b1);

    always @* begin
        m_ready = {NM{1'b0}};
        m_fault = {NM{1'b0}};
        if (sel_valid) begin
            m_ready[sel] = cur_ready;
            m_fault[sel] = cur_fault;
        end
    end

    // Read data is broadcast. Only the master seeing `ready` acts on it, so
    // one copy is enough and it saves a mux per master.
    genvar g;
    generate
        for (g = 0; g < NM; g = g + 1) begin : g_rdata
            assign m_rdata[g*32 +: 32] = mux_rdata;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Arbiter state
    //
    // A transfer that completes in the cycle it is issued never sets `busy`
    // at all -- the grant is only latched when the slave makes us wait.
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            gnt  <= {MW{1'b0}};
            last <= (NM > 1) ? (NM-1) : 0;
        end else if (!busy) begin
            if (pick_valid) begin
                last <= pick;
                if (!cur_ready) begin
                    busy <= 1'b1;
                    gnt  <= pick;
                end
            end
        end else if (cur_ready) begin
            busy <= 1'b0;
        end
    end

endmodule
