# TinyTrust S1-C -- timing constraints for the whole chip.
#
# 10 ns, the same constraint the reference chip reports its slack against, so
# the numbers are comparable. Deliberately relaxed: the goal at S1 is a chip
# that closes and passes its checks, not a frequency record.
#
# Structured after the platform's own pad-ring reference design
# (flow/designs/ihp-sg13g2/i2c-gpio-expander), because two things about a
# chip with pads are easy to get wrong:
#
#   1. The clock is created on the pad's *core-side output pin*, not on the
#      package port. The clock tree starts where the signal enters the logic,
#      after the input pad's own delay. Creating it on the port instead makes
#      the tools try to balance the pad into the tree.
#
#   2. Ordinary pins are timed against a *virtual* clock. They are
#      asynchronous to the core clock in the real system -- a serial line,
#      mode straps, general-purpose pins -- and timing them against the core
#      clock would claim a relationship that does not exist.

current_design soc_chip
set_units -time ns -resistance kOhm -capacitance pF -voltage V -current uA

set clk_period 10.0
set io_delay   [expr $clk_period * 0.25]

# ---- the core clock, taken from inside the clock pad ----
set_ideal_network [get_pins sg13g2_IOPad_clk/p2c]
create_clock -name core_clock -period $clk_period \
             [get_pins sg13g2_IOPad_clk/p2c]

# ---- a virtual clock for the board side ----
create_clock -name virt_clock -period $clk_period

set_clock_uncertainty 0.25 [get_clocks core_clock]
set_clock_transition  0.15 [get_clocks core_clock]
set_clock_uncertainty 0.25 [get_clocks virt_clock]

# ---- ports ----
set in_ports  [get_ports {pad_rst_n pad_uart_rx pad_strap[*] pad_gpio_in[*]}]
set out_ports [get_ports {pad_uart_tx pad_alert pad_gpio_out[*]}]
set clk_ports [get_ports pad_clk]

# What is on the other side of the package pin: another chip's output driver.
set_driving_cell -lib_cell sg13g2_IOPadIn -pin pad $clk_ports
set_driving_cell -lib_cell sg13g2_IOPadIn -pin pad $in_ports

set_input_delay  -clock virt_clock $io_delay $in_ports
set_output_delay -clock virt_clock $io_delay $out_ports

# Pads drive board traces and other chips, not one gate input.
set_load 5.0 $out_ports

# Reset is asynchronous by construction -- it is synchronised inside the
# design before anything uses it, so timing the raw pin would be meaningless.
set_false_path -from [get_ports pad_rst_n]

set_max_fanout 8 [current_design]
set_max_transition 3 [current_design]
