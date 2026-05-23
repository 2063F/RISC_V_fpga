// =============================================================================
// Timing Constraints for Tang Primer 25K
// =============================================================================

// 50 MHz system clock (period = 20ns)
create_clock -name sys_clk -period 20.000 [get_ports {clk}]
