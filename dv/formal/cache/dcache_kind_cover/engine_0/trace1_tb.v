`ifndef VERILATOR
module testbench;
  reg [4095:0] vcdfile;
  reg clock;
`else
module testbench(input clock, output reg genclock);
  initial genclock = 1;
`endif
  reg genclock = 1;
  reg [31:0] cycle = 0;
  wire [0:0] PI_clk = clock;
  cache_fv UUT (
    .clk(PI_clk)
  );
`ifndef VERILATOR
  initial begin
    if ($value$plusargs("vcd=%s", vcdfile)) begin
      $dumpfile(vcdfile);
      $dumpvars(0, testbench);
    end
    #5 clock = 0;
    while (genclock) begin
      #5 clock = 0;
      #5 clock = 1;
    end
  end
`endif
  initial begin
`ifndef VERILATOR
    #1;
`endif
    // UUT.$auto$async2sync.\cc:253:execute$2205  = 26'b00000000000000000000000000;
    // UUT.$auto$async2sync.\cc:253:execute$2207  = 26'b00000000000000000000000000;
    // UUT.$auto$async2sync.\cc:253:execute$2209  = 26'b00000000000000000000000000;
    // UUT.$auto$async2sync.\cc:253:execute$2211  = 26'b00000000000000000000000000;
    // UUT.$auto$async2sync.\cc:253:execute$2213  = 2'b00;
    // UUT.$auto$async2sync.\cc:253:execute$2215  = 2'b00;
    // UUT.$auto$async2sync.\cc:253:execute$2217  = 2'b00;
    // UUT.$auto$async2sync.\cc:253:execute$2219  = 2'b00;
    // UUT.$auto$async2sync.\cc:253:execute$2221  = 2'b00;
    // UUT.$auto$async2sync.\cc:253:execute$2223  = 4'b0000;
    UUT.p_addr = 32'b00000000000000000000000000000000;
    UUT.p_pending = 1'b0;
    UUT.p_wdata = 32'b00000000000000000000000000000000;
    UUT.p_wstrb = 4'b0000;
    UUT.rst_cnt = 2'b00;
    UUT.stall_cnt = 2'b01;
    UUT.uut.line_base = 32'b00000000000000000000000000000000;
    UUT.uut.wb_tag = 26'b00000000000000000000000000;
    UUT.wb_seen = 1'b0;
    UUT.init_val = 32'b11111111111111111111111111111111;
    UUT.chk_word = 30'b000000000000000000000000101110;

    // state 0
    UUT.m_rdata_free = 32'b11111111111111111111111111111111;
    UUT.c_addr = 32'b00000000000000000000000000000000;
    UUT.c_valid = 1'b0;
    UUT.c_wstrb_raw = 4'b0000;
    UUT.m_ready = 1'b0;
    UUT.c_wdata = 32'b11111111111111111111111111111111;
  end
  always @(posedge clock) begin
    // state 1
    if (cycle == 0) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000000000000;
      UUT.c_valid <= 1'b0;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b0;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 2
    if (cycle == 1) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000000000000;
      UUT.c_valid <= 1'b0;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b0;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 3
    if (cycle == 2) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000010111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0010;
      UUT.m_ready <= 1'b0;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 4
    if (cycle == 3) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000010111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0010;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 5
    if (cycle == 4) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000010111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0010;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 6
    if (cycle == 5) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000010111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0010;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 7
    if (cycle == 6) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000010111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0010;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 8
    if (cycle == 7) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000010111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0010;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 9
    if (cycle == 8) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 10
    if (cycle == 9) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 11
    if (cycle == 10) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 12
    if (cycle == 11) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 13
    if (cycle == 12) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 14
    if (cycle == 13) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 15
    if (cycle == 14) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 16
    if (cycle == 15) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 17
    if (cycle == 16) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 18
    if (cycle == 17) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 19
    if (cycle == 18) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 20
    if (cycle == 19) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 21
    if (cycle == 20) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000011111100;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 22
    if (cycle == 21) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000010111011;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 23
    if (cycle == 22) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000010111011;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 24
    if (cycle == 23) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000010111011;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 25
    if (cycle == 24) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000010111011;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 26
    if (cycle == 25) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000010111011;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 27
    if (cycle == 26) begin
      UUT.m_rdata_free <= 32'b00000000000000000000000000000000;
      UUT.c_addr <= 32'b00000000000000000000000010111011;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    // state 28
    if (cycle == 27) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000010111011;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b11111111111111111111111111111111;
    end

    genclock <= cycle < 28;
    cycle <= cycle + 1;
  end
endmodule
