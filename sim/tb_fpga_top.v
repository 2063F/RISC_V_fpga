`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_fpga_top
// Description: Testbench for the fpga_top wrapper module.
//              Verifies that the CPU runs loop55.hex and that led[1] turns ON
//              after the calculation is done (when x1 becomes 55).
//////////////////////////////////////////////////////////////////////////////////

module tb_fpga_top;

    reg clk;
    reg rst_btn;
    reg user_btn;
    wire [1:0] led;

    // Instantiate FPGA top-level wrapper
    fpga_top uut (
        .clk      (clk),
        .rst_btn  (rst_btn),
        .user_btn (user_btn),
        .led      (led)
    );

    // Clock generation: 50 MHz (20ns period)
    always #10 clk = ~clk;

    initial begin
        clk = 0;
        rst_btn = 1; // active-high reset
        user_btn = 0;

        $display("=== FPGA Top Level Testbench ===");

        // Wait 50ns, release reset
        #50;
        rst_btn = 0;
        $display("Reset released. CPU should start running loop55.hex...");

        // Wait for loop to finish
        // At 50MHz (20ns/cycle), the loop takes ~35 cycles.
        // Let's run for 1000ns (50 cycles).
        #1000;

        $display("After 1000ns:");
        $display("  debug_x1 = %0d (expected 55)", uut.cpu.debug_x1);
        $display("  led[1]   = %b (expected 1)", led[1]);

        if (uut.cpu.debug_x1 === 32'd55 && led[1] === 1'b1) begin
            $display("SUCCESS: led[1] turned ON after correct calculation!");
            $display("ALL TESTS PASSED!");
        end else begin
            $display("FAILURE: led[1] did not turn ON or debug_x1 is not 55.");
            $display("  led = 2'b%b", led);
        end

        $finish;
    end

endmodule
