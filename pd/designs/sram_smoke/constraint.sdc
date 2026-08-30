# TinyTrust SRAM smoke test timing constraints — ihp-sg13g2.
#
# 10 ns, same as the P0 core harden. This design exists to answer a flow
# question (does the SRAM macro survive synthesis -> P&R -> GDS merge), so the
# clock is deliberately relaxed: a timing failure here would mask the thing
# actually being measured. The real SRAM access-time budget gets set at P3,
# once the cache architecture picks a macro and a pipeline position for it.

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
