// TinyTrust -- chip top level (S1-A)
//
// The first complete chip: one pipelined processor, its two caches, the bus,
// on-chip memory, the boot ROM and the peripherals.
//
//   processor ─┬─ instruction cache ─┐
//              │                     ├─ bus ─┬─ boot ROM      0x0…
//              └─ data cache ────────┘       ├─ main memory   0x2… cached
//                                            │                0x4… uncached
//                                            └─ peripherals   0x3…
//
// The 0x1… window is deliberately absent. It is where external flash lives in
// the full design, and S1 does not populate it (D28), so an access there hits
// no slave and faults -- which is what should happen to a program that
// assumes flash is present.
//
// MAIN MEMORY APPEARS TWICE, AND THAT IS NOT AN ACCIDENT (D31)
// Cached at 0x2, uncached at 0x4, the same memory behind both. The boot
// loader receives a program over the serial port and has to get it into
// memory *and* have the instruction cache see it. Writing through the cached
// window would leave the bytes dirty in the write-back data cache while the
// instruction cache fetched whatever main memory still held; there is no
// flush instruction to fix that, because D25 deliberately keeps the two
// caches out of any coherence scheme. Writing through the uncached window
// sidesteps the problem entirely, at the cost of one decoder bit.
//
// This is the first place the "no coherence between the two caches"
// restriction has actually bitten, and it is worth noticing that it bit
// during bring-up rather than in a corner case: the very first program the
// chip runs is one that writes code and then executes it.

module soc_top #(
    parameter USE_MACRO       = 1,        // 0 = behavioural memory, for sim
    parameter N_RAM_MACRO     = 4,        // 4 x 4 KB = 16 KB
    parameter [15:0] UART_DIV_RESET = 16'd10415
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [3:0] gpio_out,
    input  wire [3:0] gpio_in,
    output wire       sec_alert,
    input  wire [1:0] straps
);

    localparam [31:0] CACHEABLE_LIMIT = 32'h3000_0000;

    localparam NM = 2;
    localparam NS = 3;

    // slave 0: boot ROM      nibble 0
    // slave 1: main memory   nibbles 2 and 4
    // slave 2: peripherals   nibble 3
    localparam [NS*16-1:0] SLAVE_MASK = {16'h0008, 16'h0014, 16'h0001};

    // ------------------------------------------------------------------
    // Processor
    // ------------------------------------------------------------------
    wire        imem_valid, imem_ready, imem_fault;
    wire [31:0] imem_addr,  imem_rdata;

    wire        dmem_valid, dmem_ready, dmem_fault;
    wire [31:0] dmem_addr,  dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;

    wire        irq_timer;
    wire        fsm_fault;

    core_p5 #(.RESET_PC(32'h0000_0000)) u_core (
        .clk(clk), .rst_n(rst_n),
        .imem_valid(imem_valid), .imem_addr(imem_addr),
        .imem_ready(imem_ready), .imem_rdata(imem_rdata),
        .imem_fault(imem_fault),
        .dmem_valid(dmem_valid), .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb),
        .dmem_ready(dmem_ready), .dmem_rdata(dmem_rdata),
        .dmem_fault(dmem_fault),
        .irq_timer(irq_timer), .irq_external(1'b0),
        .fsm_fault(fsm_fault)
    );

    // ------------------------------------------------------------------
    // Caches. Master 0 is the instruction side, master 1 the data side.
    // ------------------------------------------------------------------
    wire [NM-1:0]    bm_valid, bm_ready, bm_fault;
    wire [NM*32-1:0] bm_addr, bm_wdata, bm_rdata;
    wire [NM*4-1:0]  bm_wstrb;

    cache #(.WRITABLE(0), .CACHEABLE_LIMIT(CACHEABLE_LIMIT),
            .LINE_BYTES(64), .LINES(64), .USE_MACRO(USE_MACRO)) u_icache (
        .clk(clk), .rst_n(rst_n),
        .c_valid(imem_valid), .c_addr(imem_addr), .c_wdata(32'd0),
        .c_wstrb(4'd0), .c_ready(imem_ready), .c_rdata(imem_rdata),
        .c_fault(imem_fault),
        .m_valid(bm_valid[0]), .m_addr(bm_addr[0*32 +: 32]),
        .m_wdata(bm_wdata[0*32 +: 32]), .m_wstrb(bm_wstrb[0*4 +: 4]),
        .m_ready(bm_ready[0]), .m_rdata(bm_rdata[0*32 +: 32]),
        .m_fault(bm_fault[0])
    );

    cache #(.WRITABLE(1), .CACHEABLE_LIMIT(CACHEABLE_LIMIT),
            .LINE_BYTES(64), .LINES(64), .USE_MACRO(USE_MACRO)) u_dcache (
        .clk(clk), .rst_n(rst_n),
        .c_valid(dmem_valid), .c_addr(dmem_addr), .c_wdata(dmem_wdata),
        .c_wstrb(dmem_wstrb), .c_ready(dmem_ready), .c_rdata(dmem_rdata),
        .c_fault(dmem_fault),
        .m_valid(bm_valid[1]), .m_addr(bm_addr[1*32 +: 32]),
        .m_wdata(bm_wdata[1*32 +: 32]), .m_wstrb(bm_wstrb[1*4 +: 4]),
        .m_ready(bm_ready[1]), .m_rdata(bm_rdata[1*32 +: 32]),
        .m_fault(bm_fault[1])
    );

    // ------------------------------------------------------------------
    // Bus
    // ------------------------------------------------------------------
    wire [NS-1:0]    bs_valid, bs_ready, bs_fault;
    wire [31:0]      bs_addr, bs_wdata;
    wire [3:0]       bs_wstrb;
    wire [NS*32-1:0] bs_rdata;

    soc_bus #(.NM(NM), .NS(NS), .SLAVE_MASK(SLAVE_MASK)) u_bus (
        .clk(clk), .rst_n(rst_n),
        .m_valid(bm_valid), .m_addr(bm_addr), .m_wdata(bm_wdata),
        .m_wstrb(bm_wstrb), .m_ready(bm_ready), .m_rdata(bm_rdata),
        .m_fault(bm_fault),
        .s_valid(bs_valid), .s_addr(bs_addr), .s_wdata(bs_wdata),
        .s_wstrb(bs_wstrb), .s_ready(bs_ready), .s_rdata(bs_rdata),
        .s_fault(bs_fault)
    );

    // ------------------------------------------------------------------
    // Slave 0 -- boot ROM
    //
    // Combinational, so it answers in the cycle it is asked. A write to it
    // faults: the ROM is the root of trust and must not be writable, and
    // saying so here costs one gate.
    // ------------------------------------------------------------------
    wire [31:0] rom_rdata;
    bootrom u_rom (.addr(bs_addr[8:2]), .rdata(rom_rdata));

    assign bs_rdata[0*32 +: 32] = rom_rdata;
    assign bs_ready[0]          = bs_valid[0];
    assign bs_fault[0]          = bs_valid[0] && (bs_wstrb != 4'd0);

    // ------------------------------------------------------------------
    // Slave 1 -- main memory, reachable through both windows
    // ------------------------------------------------------------------
    soc_ram #(.N_MACRO(N_RAM_MACRO), .USE_MACRO(USE_MACRO)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_valid(bs_valid[1]), .s_addr(bs_addr), .s_wdata(bs_wdata),
        .s_wstrb(bs_wstrb), .s_ready(bs_ready[1]),
        .s_rdata(bs_rdata[1*32 +: 32]), .s_fault(bs_fault[1])
    );

    // ------------------------------------------------------------------
    // Slave 2 -- peripherals
    // ------------------------------------------------------------------
    soc_mmio #(.GPIO_W(4), .UART_DIV_RESET(UART_DIV_RESET)) u_mmio (
        .clk(clk), .rst_n(rst_n),
        .s_valid(bs_valid[2]), .s_addr(bs_addr), .s_wdata(bs_wdata),
        .s_wstrb(bs_wstrb), .s_ready(bs_ready[2]),
        .s_rdata(bs_rdata[2*32 +: 32]), .s_fault(bs_fault[2]),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_out(gpio_out), .gpio_in(gpio_in),
        .sec_alert(sec_alert), .irq_timer(irq_timer),
        .fsm_fault(fsm_fault), .straps(straps)
    );

endmodule
