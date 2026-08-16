# TinyTrust P0 timing constraints — ihp-sg13g2.
#
# 10 ns (100 MHz) is deliberately relaxed for the flow smoke test: the v1 core
# is multicycle with a single shared 32-bit adder, so its critical path is long
# and unoptimised. A relaxed clock keeps a timing failure from masking genuine
# flow problems, which is what P0 is actually looking for.
#
# Reference points: ORFS flow/designs/ihp-sg13g2/riscv32i targets 6.0 ns
# (166 MHz); hft-chip closed at 112 MHz on this process. Revisit at P2 once
# the 5-stage pipeline exists and the target is real.

set clk_name      clk
set clk_port_name clk
set clk_period    10.0
set clk_io_pct    0.2

set clk_port [get_ports $clk_port_name]

create_clock -name $clk_name -period $clk_period $clk_port

set clk_io_name vclk_$clk_name
create_clock -name $clk_io_name -period $clk_period

set_clock_latency 0.595 [get_clocks $clk_name]
set_clock_latency 0.595 [get_clocks $clk_io_name]

set non_clock_inputs [list]
foreach input [all_inputs] {
  if { $clk_port != $input } {
    lappend $non_clock_inputs $input
  }
}

set_input_delay  [expr $clk_period * $clk_io_pct] -clock $clk_io_name $non_clock_inputs
set_output_delay [expr $clk_period * $clk_io_pct] -clock $clk_io_name [all_outputs]
