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
    UUT.chk_word = 30'b000000000000000000000000001111;

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
      UUT.c_addr <= 32'b00000000000000000000000000111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b0;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 4
    if (cycle == 3) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000000111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 5
    if (cycle == 4) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000000111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 6
    if (cycle == 5) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000000111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 7
    if (cycle == 6) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000000111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 8
    if (cycle == 7) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000000111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    // state 9
    if (cycle == 8) begin
      UUT.m_rdata_free <= 32'b11111111111111111111111111111111;
      UUT.c_addr <= 32'b00000000000000000000000000111111;
      UUT.c_valid <= 1'b1;
      UUT.c_wstrb_raw <= 4'b0000;
      UUT.m_ready <= 1'b1;
      UUT.c_wdata <= 32'b00000000000000000000000000000000;
    end

    genclock <= cycle < 9;
    cycle <= cycle + 1;
  end
endmodule
