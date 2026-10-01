// =============================================================================
// Timing Constraints for Tang Primer 25K
// =============================================================================

// 50 MHz system clock (period = 20ns)
create_clock -name sys_clk -period 20.000 [get_ports {clk}]

// 12 MHz USB clock from the PLL (usb_hid_host). It only talks to the 50 MHz
// domain through synchronisers in usb_keyboard.v / fpga_top.v.
create_clock -name clk_usb -period 83.333 [get_nets {clk_usb}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clk_usb}]
