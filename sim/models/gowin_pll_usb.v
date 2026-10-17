`timescale 1ns / 1ps
// =============================================================================
// gowin_pll_usb.v (simulation model) - 12 MHz clock for usb_hid_host
// =============================================================================
// Stands in for src/gowin/gowin_pll_usb.v (Gowin PLLA primitive), which only
// the Gowin tools can elaborate. Compile this file instead in simulations.
// =============================================================================

module gowin_pll_usb (clkout, clkin);
    output reg clkout = 1'b0;
    input      clkin;
    always #41.667 clkout = ~clkout;   // 12 MHz
endmodule
