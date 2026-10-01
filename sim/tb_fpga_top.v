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
    integer timeout;

    // Instantiate FPGA top-level wrapper
    fpga_top #(
        .INIT_FILE("examples/loop55.hex")
    ) uut (
        .clk      (clk),
        .rst_btn  (rst_btn),
        .user_btn (user_btn),
        .led      (led),
        .uart_rx  (1'b1)   // UART RX line idle (high)
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

        // Wait until the program finishes naturally rather than relying on a
        // fixed delay. This makes the integration test stronger and more robust.
        timeout = 0;
        while (uut.cpu.debug_x1 !== 32'd55 && timeout < 100000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        // Allow at least one extra clock so the LED logic can observe the
        // completed x1 value in a real synchronous timing flow.
        @(posedge clk);
        @(posedge clk);

        $display("After waiting for completion:");
        $display("  debug_x1 = %0d (expected 55)", uut.cpu.debug_x1);
        $display("  led[1]   = %b (expected 1)", led[1]);
        $display("  debug_pc = 0x%h", uut.cpu.debug_pc);

        if (uut.cpu.debug_x1 !== 32'd55) begin
            $display("FAILURE: CPU did not reach x1 = 55 within timeout.");
            $finish;
        end

        // Check LED behavior only after the CPU has actually completed the loop.
        if (led[1] !== 1'b1) begin
            $display("FAILURE: led[1] did not turn ON after x1 reached 55.");
            $display("  led = 2'b%b", led);
            $finish;
        end

        $display("SUCCESS: FPGA integration verified with real completion detection!");
        $display("ALL TESTS PASSED!");
        $finish;
    end

endmodule
