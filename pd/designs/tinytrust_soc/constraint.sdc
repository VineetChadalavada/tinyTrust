# TinyTrust S1-C -- timing constraints for the whole chip.
#
# 10 ns, the same constraint the reference chip reports against, so the slack
# numbers are directly comparable. It is deliberately relaxed: the goal at S1
# is a chip that closes and passes its checks, not a frequency record. What
# the design will actually do is whatever the reported slack says, and that
# number means something here in a way P0's did not -- this path runs from a
# real input pad, through the pad's own delay, into the logic and back out
# through an output pad.

set clk_period 10.0

create_clock -name core_clock -period $clk_period [get_ports pad_clk]

# The clock arrives through an input pad like any other signal, so give it a
# realistic uncertainty rather than pretending it is ideal.
set_clock_uncertainty 0.25 [get_clocks core_clock]
set_clock_transition  0.15 [get_clocks core_clock]

# Everything that is not the clock is asynchronous to it in the real system --
# a serial line, mode straps, general-purpose pins. Constrain them anyway so
# the tools have something to work to, at a quarter cycle each way.
set inputs  [remove_from_collection [all_inputs] [get_ports pad_clk]]
set_input_delay  -clock core_clock [expr $clk_period * 0.25] $inputs
set_output_delay -clock core_clock [expr $clk_period * 0.25] [all_outputs]

# Reset is asynchronous by construction: it is synchronised inside the design
# before anything uses it, so timing the raw pin against the clock would be
# meaningless.
set_false_path -from [get_ports pad_rst_n]

# Pads drive real board traces and other chips, not a single gate input.
set_load 5.0 [all_outputs]
