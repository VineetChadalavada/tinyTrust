// TinyTrust — core lockstep co-sim TB (vplan dv/core_iss, layer L2).
//
// Memory model (mirrored exactly by the ISS in rv32e.py):
//   0x0000_0000..0x0000_FFFF : 64 KiB RAM (code + data), zero-initialized
//   0x0001_0000              : TOHOST — any write ends the test after that
//                              store retires; reads return 0
//   anything else            : bus fault
//
// Bus latency is randomized (2 .. 2+maxlat cycles) to stress the
// valid/ready handshake and the FSM wait states.
//
// One TB serves both cores so the CPI comparison in docs/RETARGET.md §P2 is
// measured on an identical memory model, identical stimulus and an identical
// trace format. Compile with -DCORE_P5 for the 5-stage core (rtl/core/
// core_p5.v), without it for the multicycle core (rtl/core/core.v). The
// 5-stage core has split instruction and data ports; a fixed-priority
// arbiter (data over fetch, grant locked for the duration of a transaction)
// folds them back onto the single-port model, which is what the unified
// memory of the current SoC actually looks like. P3 replaces the arbiter
// with an I$ and a D$.
//
// +fastmem=1 (5-stage core only) makes the *instruction* port zero-wait-state
// — ready and rdata combinational — while leaving the data port on the timed
// model. This is not cosmetic. Through the shared timed model a fetch costs a
// minimum of three cycles, so consecutive instructions are never closer than
// three pipeline stages apart, and a whole class of pipeline states is
// unreachable in simulation: notably a consumer pinned in EX across a data
// stall while its producer sits in WB, which is where BUG-005 lived.
// riscv-formal reaches those states freely because it drives ready as a free
// variable; this mode lets the co-sim reach them too, and is what an I$ hit
// in front of slower data memory will look like at P3. Making the *data* port
// fast as well would defeat the purpose — with no data stall the pipeline
// never holds an instruction in EX at all. Not the default: the randomized
// timed model is still the stronger handshake stress, so regress.ps1 runs
// both.
//
// Plusargs: +prog=<hex> +trace=<out> [+seed=N] [+maxcycles=N] [+maxlat=N]
//           [+fastmem=1]

`timescale 1ns/1ps

module tb_core;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    wire        bus_valid, bus_is_fetch;
    wire [31:0] bus_addr, bus_wdata;
    wire [3:0]  bus_wstrb;
    reg         bus_ready;
    reg  [31:0] bus_rdata;
    reg         bus_fault;
    wire        fsm_fault;

    // 64 KiB backing store. Declared up here because the +fastmem instruction
    // path reads it from a continuous assign below, and Verilog needs a memory
    // declared ahead of its use.
    reg [31:0] ram [0:16383];

    integer fast_mem = 0;   // from +fastmem; settled before reset releases

    wire        rvfi_valid;
    wire [63:0] rvfi_order;
    wire [31:0] rvfi_insn;
    wire        rvfi_trap, rvfi_halt, rvfi_intr;
    wire [1:0]  rvfi_mode, rvfi_ixl;
    wire [4:0]  rvfi_rs1_addr, rvfi_rs2_addr, rvfi_rd_addr;
    wire [31:0] rvfi_rs1_rdata, rvfi_rs2_rdata, rvfi_rd_wdata;
    wire [31:0] rvfi_pc_rdata, rvfi_pc_wdata;
    wire [31:0] rvfi_mem_addr;
    wire [3:0]  rvfi_mem_rmask, rvfi_mem_wmask;
    wire [31:0] rvfi_mem_rdata, rvfi_mem_wdata;

`ifdef CORE_P5
    // ---------------- 5-stage core: split I/D ports -----------------------
    wire        imem_valid, dmem_valid;
    wire [31:0] imem_addr, dmem_addr, dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire        imem_ready, imem_fault, dmem_ready, dmem_fault;
    wire [31:0] imem_rdata, dmem_rdata;

    // What the bus arbiter sees. Without caches these are the core's own
    // ports; with -DWITH_CACHE a cache sits in between and these carry the
    // caches' refill and writeback traffic instead.
    wire        bi_valid, bd_valid;
    wire [31:0] bi_addr, bd_addr, bd_wdata;
    wire [3:0]  bd_wstrb;
    wire        bi_ready, bi_fault, bd_ready, bd_fault;
    wire [31:0] bi_rdata, bd_rdata;

`ifdef WITH_CACHE
    // P3: 4 KiB direct-mapped I$ and D$ (D21) with SRAM data arrays (D19).
    // +fastmem is not available in this configuration and cosim.py rejects
    // the combination: the I$ *is* the fast instruction path now, and letting
    // both drive imem_ready would put two drivers on one wire.
    cache #(.WRITABLE(0)) u_icache (
        .clk     (clk),        .rst_n   (rst_n),
        .c_valid (imem_valid), .c_addr  (imem_addr),
        .c_wdata (32'd0),      .c_wstrb (4'd0),
        .c_ready (imem_ready), .c_rdata (imem_rdata), .c_fault (imem_fault),
        .m_valid (bi_valid),   .m_addr  (bi_addr),
        .m_wdata (),           .m_wstrb (),
        .m_ready (bi_ready),   .m_rdata (bi_rdata),   .m_fault (bi_fault)
    );

    cache #(.WRITABLE(1)) u_dcache (
        .clk     (clk),        .rst_n   (rst_n),
        .c_valid (dmem_valid), .c_addr  (dmem_addr),
        .c_wdata (dmem_wdata), .c_wstrb (dmem_wstrb),
        .c_ready (dmem_ready), .c_rdata (dmem_rdata), .c_fault (dmem_fault),
        .m_valid (bd_valid),   .m_addr  (bd_addr),
        .m_wdata (bd_wdata),   .m_wstrb (bd_wstrb),
        .m_ready (bd_ready),   .m_rdata (bd_rdata),   .m_fault (bd_fault)
    );
`else
    assign bi_valid   = imem_valid;
    assign bi_addr    = imem_addr;
    assign imem_ready = bi_ready;
    assign imem_rdata = bi_rdata;
    assign imem_fault = bi_fault;

    assign bd_valid   = dmem_valid;
    assign bd_addr    = dmem_addr;
    assign bd_wdata   = dmem_wdata;
    assign bd_wstrb   = dmem_wstrb;
    assign dmem_ready = bd_ready;
    assign dmem_rdata = bd_rdata;
    assign dmem_fault = bd_fault;
`endif

    reg  arb_busy, arb_grant_d;   // grant is locked for the whole transaction
    // With +fastmem the instruction side is served combinationally below and
    // never touches the shared model, so the data side simply owns it.
    wire sel_d = (fast_mem != 0) ? 1'b1
                                 : (arb_busy ? arb_grant_d : bd_valid);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arb_busy    <= 1'b0;
            arb_grant_d <= 1'b0;
        end else if (arb_busy) begin
            if (bus_ready) arb_busy <= 1'b0;
        end else if (bi_valid || bd_valid) begin
            arb_busy    <= 1'b1;
            arb_grant_d <= bd_valid;
        end
    end

    assign bus_valid    = (fast_mem != 0) ? bd_valid : (bi_valid | bd_valid);
    assign bus_addr     = sel_d ? bd_addr  : bi_addr;
    assign bus_wdata    = bd_wdata;
    assign bus_wstrb    = sel_d ? bd_wstrb : 4'd0;
    assign bus_is_fetch = ~sel_d;

    assign bd_ready = (fast_mem != 0) ? bus_ready : (bus_ready & sel_d);
    assign bd_rdata = bus_rdata;
    assign bd_fault = bus_fault;

`ifdef WITH_CACHE
    assign bi_ready = bus_ready & ~sel_d;
    assign bi_rdata = bus_rdata;
    assign bi_fault = bus_fault;
`else
    // zero-wait-state instruction path (+fastmem). Fetches never write, so
    // the shared model's write and TOHOST side effects are untouched by this.
    wire i_in_ram = (bi_addr <  32'h0001_0000);
    wire i_in_th  = (bi_addr == 32'h0001_0000);
    assign bi_ready = (fast_mem != 0) ? 1'b1 : (bus_ready & ~sel_d);
    assign bi_rdata = (fast_mem != 0)
                      ? (i_in_ram ? ram[bi_addr[15:2]] : 32'd0)
                      : bus_rdata;
    assign bi_fault = (fast_mem != 0) ? (!i_in_ram && !i_in_th) : bus_fault;
`endif

    core_p5 dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .imem_valid     (imem_valid),
        .imem_addr      (imem_addr),
        .imem_ready     (imem_ready),
        .imem_rdata     (imem_rdata),
        .imem_fault     (imem_fault),
        .dmem_valid     (dmem_valid),
        .dmem_addr      (dmem_addr),
        .dmem_wdata     (dmem_wdata),
        .dmem_wstrb     (dmem_wstrb),
        .dmem_ready     (dmem_ready),
        .dmem_rdata     (dmem_rdata),
        .dmem_fault     (dmem_fault),
        .irq_timer      (1'b0),
        .irq_external   (1'b0),
        .fsm_fault      (fsm_fault),
        .rvfi_valid     (rvfi_valid),
        .rvfi_order     (rvfi_order),
        .rvfi_insn      (rvfi_insn),
        .rvfi_trap      (rvfi_trap),
        .rvfi_halt      (rvfi_halt),
        .rvfi_intr      (rvfi_intr),
        .rvfi_mode      (rvfi_mode),
        .rvfi_ixl       (rvfi_ixl),
        .rvfi_rs1_addr  (rvfi_rs1_addr),
        .rvfi_rs2_addr  (rvfi_rs2_addr),
        .rvfi_rs1_rdata (rvfi_rs1_rdata),
        .rvfi_rs2_rdata (rvfi_rs2_rdata),
        .rvfi_rd_addr   (rvfi_rd_addr),
        .rvfi_rd_wdata  (rvfi_rd_wdata),
        .rvfi_pc_rdata  (rvfi_pc_rdata),
        .rvfi_pc_wdata  (rvfi_pc_wdata),
        .rvfi_mem_addr  (rvfi_mem_addr),
        .rvfi_mem_rmask (rvfi_mem_rmask),
        .rvfi_mem_wmask (rvfi_mem_wmask),
        .rvfi_mem_rdata (rvfi_mem_rdata),
        .rvfi_mem_wdata (rvfi_mem_wdata)
    );
`else
    // ---------------- multicycle core: single unified port ----------------
    // +fastmem has no meaning here: this core has one port and one access in
    // flight, so there is no fetch/data timing split to make.
    core dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .bus_valid      (bus_valid),
        .bus_addr       (bus_addr),
        .bus_wdata      (bus_wdata),
        .bus_wstrb      (bus_wstrb),
        .bus_is_fetch   (bus_is_fetch),
        .bus_ready      (bus_ready),
        .bus_rdata      (bus_rdata),
        .bus_fault      (bus_fault),
        .irq_timer      (1'b0),
        .irq_external   (1'b0),
        .fsm_fault      (fsm_fault),
        .rvfi_valid     (rvfi_valid),
        .rvfi_order     (rvfi_order),
        .rvfi_insn      (rvfi_insn),
        .rvfi_trap      (rvfi_trap),
        .rvfi_halt      (rvfi_halt),
        .rvfi_intr      (rvfi_intr),
        .rvfi_mode      (rvfi_mode),
        .rvfi_ixl       (rvfi_ixl),
        .rvfi_rs1_addr  (rvfi_rs1_addr),
        .rvfi_rs2_addr  (rvfi_rs2_addr),
        .rvfi_rs1_rdata (rvfi_rs1_rdata),
        .rvfi_rs2_rdata (rvfi_rs2_rdata),
        .rvfi_rd_addr   (rvfi_rd_addr),
        .rvfi_rd_wdata  (rvfi_rd_wdata),
        .rvfi_pc_rdata  (rvfi_pc_rdata),
        .rvfi_pc_wdata  (rvfi_pc_wdata),
        .rvfi_mem_addr  (rvfi_mem_addr),
        .rvfi_mem_rmask (rvfi_mem_rmask),
        .rvfi_mem_wmask (rvfi_mem_wmask),
        .rvfi_mem_rdata (rvfi_mem_rdata),
        .rvfi_mem_wdata (rvfi_mem_wdata)
    );
`endif

    integer seed, max_lat, max_cycles;
    integer delay;
    reg     active;
    reg     tohost_armed;
    reg [31:0] tohost_val;
    integer trace_fd;
    reg [1023:0] prog_file, trace_file;
    integer cycles;
    integer i;

    // one-transaction bus with randomized completion latency
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_ready <= 1'b0;
            bus_rdata <= 32'd0;
            bus_fault <= 1'b0;
            active    <= 1'b0;
            delay     <= 0;
        end else begin
            bus_ready <= 1'b0;
            bus_fault <= 1'b0;
            if (bus_ready) begin
                active <= 1'b0;
            end else if (bus_valid && !active) begin
                active <= 1'b1;
                delay  <= {$random(seed)} % (max_lat + 1);
            end else if (bus_valid && active) begin
                if (delay == 0) begin : svc
                    reg [31:0] w;
                    bus_ready <= 1'b1;
                    if (bus_addr < 32'h0001_0000) begin
                        bus_rdata <= ram[bus_addr[15:2]];
                        w = ram[bus_addr[15:2]];
                        if (bus_wstrb[0]) w[7:0]   = bus_wdata[7:0];
                        if (bus_wstrb[1]) w[15:8]  = bus_wdata[15:8];
                        if (bus_wstrb[2]) w[23:16] = bus_wdata[23:16];
                        if (bus_wstrb[3]) w[31:24] = bus_wdata[31:24];
                        if (bus_wstrb != 4'd0)
                            ram[bus_addr[15:2]] <= w;
                    end else if (bus_addr == 32'h0001_0000) begin
                        bus_rdata <= 32'd0;
                        if (bus_wstrb != 4'd0) begin
                            tohost_armed <= 1'b1;
                            tohost_val   <= bus_wdata;
                        end
                    end else begin
                        bus_rdata <= 32'd0;
                        bus_fault <= 1'b1;
                    end
                end else begin
                    delay <= delay - 1;
                end
            end
        end
    end

    // RVFI trace dump; format matches rv32e.REC_FMT field for field
    always @(posedge clk) begin
        if (rst_n && rvfi_valid) begin
            $fwrite(trace_fd,
                "%016x %08x %08x %x %x %x %02x %08x %02x %08x %02x %08x %08x %08x %x %x %08x %08x\n",
                rvfi_order, rvfi_pc_rdata, rvfi_insn, rvfi_trap, rvfi_mode,
                rvfi_intr, rvfi_rs1_addr, rvfi_rs1_rdata, rvfi_rs2_addr,
                rvfi_rs2_rdata, rvfi_rd_addr, rvfi_rd_wdata, rvfi_pc_wdata,
                rvfi_mem_addr, rvfi_mem_rmask, rvfi_mem_wmask,
                rvfi_mem_rdata, rvfi_mem_wdata);
            if (tohost_armed) begin
                $display("COSIM DONE tohost=%08x retired=%0d cycles=%0d",
                         tohost_val, rvfi_order + 1, cycles);
                $fclose(trace_fd);
                $finish;
            end
        end
    end

`ifndef CORE_P5
    // CPU-SHIFT-01 cycle-count clause: the iterative shifter must spend
    // exactly shamt cycles in S_SHIFT (shamt = 0 takes none). The RVFI
    // trace compare is untimed, so this is checked directly per retire.
    // The 5-stage core replaces the iterative shifter with a single-cycle
    // barrel shifter (reverses D5), so the clause does not apply to it.
    integer shift_cycles;
    reg [4:0] exp_shamt;
    reg       is_shift_ret;
    always @(posedge clk) begin
        if (!rst_n) begin
            shift_cycles = 0;
        end else begin
            if (dut.state[3])           // S_SHIFT (one-hot bit index)
                shift_cycles = shift_cycles + 1;
            if (rvfi_valid) begin
                is_shift_ret = !rvfi_trap
                    && (rvfi_insn[6:0] == 7'b0110011
                        || rvfi_insn[6:0] == 7'b0010011)
                    && (rvfi_insn[14:12] == 3'b001
                        || rvfi_insn[14:12] == 3'b101);
                exp_shamt = rvfi_insn[5] ? rvfi_rs2_rdata[4:0]  // R-form
                                         : rvfi_insn[24:20];    // I-form
                if (is_shift_ret && shift_cycles !== {27'd0, exp_shamt}) begin
                    $display("COSIM SHIFTERR pc=%08x insn=%08x cycles=%0d shamt=%0d",
                             rvfi_pc_rdata, rvfi_insn, shift_cycles, exp_shamt);
                    $fclose(trace_fd);
                    $finish;
                end
                if (!is_shift_ret && shift_cycles != 0) begin
                    $display("COSIM SHIFTERR non-shift insn=%08x used S_SHIFT",
                             rvfi_insn);
                    $fclose(trace_fd);
                    $finish;
                end
                shift_cycles = 0;
            end
        end
    end
`endif

    always @(posedge clk) begin
        if (fsm_fault) begin
            $display("COSIM FSMFAULT");
            $fclose(trace_fd);
            $finish;
        end
        cycles = cycles + 1;
        if (cycles > max_cycles) begin
            $display("COSIM TIMEOUT");
            $fclose(trace_fd);
            $finish;
        end
    end

    initial begin
        cycles = 0;
        tohost_armed = 1'b0;
        tohost_val = 32'd0;
        if (!$value$plusargs("prog=%s", prog_file)) begin
            $display("COSIM ERROR: missing +prog=");
            $finish;
        end
        if (!$value$plusargs("trace=%s", trace_file)) begin
            $display("COSIM ERROR: missing +trace=");
            $finish;
        end
        if (!$value$plusargs("seed=%d", seed))          seed = 1;
        if (!$value$plusargs("maxcycles=%d", max_cycles)) max_cycles = 5000000;
        if (!$value$plusargs("maxlat=%d", max_lat))     max_lat = 3;
        if (!$value$plusargs("fastmem=%d", fast_mem))   fast_mem = 0;
        for (i = 0; i < 16384; i = i + 1)
            ram[i] = 32'd0;
        $readmemh(prog_file, ram);
        trace_fd = $fopen(trace_file, "w");
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
    end

endmodule
