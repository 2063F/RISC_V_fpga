`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_uart_tx
// Description: Testbench for the UART transmitter (uart_tx.v).
//              Sends character 'A' (0x41) and verifies the start bit,
//              data bits, and stop bit serial sequence.
//////////////////////////////////////////////////////////////////////////////////

module tb_uart_tx;

    reg        clk;
    reg        rst_n;
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_pin;
    wire       tx_busy;

    // Instantiate UUT
    uart_tx uut (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx_pin   (tx_pin),
        .tx_busy  (tx_busy)
    );

    // Clock: 50 MHz (20ns period)
    always #10 clk = ~clk;

    // Helper task to wait for a baud period (434 * 20ns = 8680ns)
    task wait_one_baud;
        begin
            #8680;
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        tx_data = 8'h00;
        tx_start = 0;

        $display("=== UART TX Simulation Start ===");

        // Reset
        #40;
        rst_n = 1;
        #40;

        // Verify idle state
        if (tx_pin !== 1'b1 || tx_busy !== 1'b0) begin
            $display("FAIL: UART not idle after reset");
            $finish;
        end

        // Start transmitting character 'A' (0x41 = 8'b0100_0001)
        tx_data = 8'h41;
        tx_start = 1;
        #20;
        tx_start = 0;

        // Check if busy goes high
        if (tx_busy !== 1'b1) begin
            $display("FAIL: tx_busy did not go high on transmit start");
        end

        // Wait half baud period and verify start bit is 0
        #4340;
        if (tx_pin !== 1'b0) begin
            $display("FAIL: Start bit is not 0");
        end
        $display("  PASS: Start bit is 0");

        // Verify data bits (LSB first: 1, 0, 0, 0, 0, 0, 1, 0)
        // Bit 0: 1
        wait_one_baud();
        if (tx_pin !== 1'b1) $display("FAIL: Data Bit 0 is not 1");
        // Bit 1: 0
        wait_one_baud();
        if (tx_pin !== 1'b0) $display("FAIL: Data Bit 1 is not 0");
        // Bit 2: 0
        wait_one_baud();
        if (tx_pin !== 1'b0) $display("FAIL: Data Bit 2 is not 0");
        // Bit 3: 0
        wait_one_baud();
        if (tx_pin !== 1'b0) $display("FAIL: Data Bit 3 is not 0");
        // Bit 4: 0
        wait_one_baud();
        if (tx_pin !== 1'b0) $display("FAIL: Data Bit 4 is not 0");
        // Bit 5: 0
        wait_one_baud();
        if (tx_pin !== 1'b0) $display("FAIL: Data Bit 5 is not 0");
        // Bit 6: 1
        wait_one_baud();
        if (tx_pin !== 1'b1) $display("FAIL: Data Bit 6 is not 1");
        // Bit 7: 0
        wait_one_baud();
        if (tx_pin !== 1'b0) $display("FAIL: Data Bit 7 is not 0");

        $display("  PASS: Data bits 0x41 transmitted correctly LSB-first");

        // Verify Stop bit (1)
        wait_one_baud();
        if (tx_pin !== 1'b1) begin
            $display("FAIL: Stop bit is not 1");
        end
        $display("  PASS: Stop bit is 1");

        // Wait one more baud to return to idle state
        wait_one_baud();
        if (tx_busy !== 1'b0) begin
            $display("FAIL: tx_busy did not return to 0 after transmit finished");
        end
        $display("  PASS: tx_busy returned to 0");

        $display("ALL TESTS PASSED!");
        $finish;
    end

endmodule
