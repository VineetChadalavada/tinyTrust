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
// Plusargs: +prog=<hex> +trace=<out> [+seed=N] [+maxcycles=N] [+maxlat=N]

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

    reg [31:0] ram [0:16383];

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
                $display("COSIM DONE tohost=%08x retired=%0d", tohost_val,
                         rvfi_order + 1);
                $fclose(trace_fd);
                $finish;
            end
        end
    end

    // CPU-SHIFT-01 cycle-count clause: the iterative shifter must spend
    // exactly shamt cycles in S_SHIFT (shamt = 0 takes none). The RVFI
    // trace compare is untimed, so this is checked directly per retire.
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
        for (i = 0; i < 16384; i = i + 1)
            ram[i] = 32'd0;
        $readmemh(prog_file, ram);
        trace_fd = $fopen(trace_file, "w");
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
    end

endmodule
