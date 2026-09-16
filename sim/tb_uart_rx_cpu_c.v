`timescale 1ns / 1ps
// =============================================================================
// tb_uart_rx_cpu_c.v - CPU + UART C Program Interaction Testbench
// =============================================================================

module tb_uart_rx_cpu_c;

    parameter CLK_PERIOD   = 20;    // 50 MHz
    parameter BAUD_RATE    = 115200;
    parameter BIT_NS       = 1_000_000_000 / BAUD_RATE;  // ~8680 ns
    parameter BIT_HALF_NS  = BIT_NS / 2;

    reg         clk   = 0;
    reg         rst_n = 0;
    reg         uart_rx_pin = 1; // Idle high
    wire        uart_tx_pin;
    wire [31:0] debug_pc;
    wire [31:0] debug_x1;

    always #(CLK_PERIOD/2) clk = ~clk;

    // Instantiate CPU with uart_echo_c.hex
    cpu_top #(
        .INIT_FILE("examples/uart_echo_c.hex")
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (),
        .mem_write_data (),
        .mem_write_en   (),
        .mem_read_en    (),
        .mem_read_data  (32'd0),
        .uart_tx_pin    (uart_tx_pin),
        .uart_rx_pin    (uart_rx_pin),
        .debug_pc       (debug_pc),
        .debug_x1       (debug_x1)
    );

    // -------------------------------------------------------------------------
    // Task: Send a byte to CPU's RX
    // -------------------------------------------------------------------------
    task send_byte;
        input [7:0] data;
        integer i;
        begin
            $display("[TB -> CPU] Sending: %c (0x%x)", data, data);
            // Start bit
            uart_rx_pin = 0;
            #(BIT_NS);
            // Data bits LSB first
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_pin = data[i];
                #(BIT_NS);
            end
            // Stop bit
            uart_rx_pin = 1;
            #(BIT_NS);
            #(BIT_NS); // Extra guard time
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: Receive a byte from CPU's TX
    // -------------------------------------------------------------------------
    task recv_byte;
        output [7:0] data;
        integer i;
        begin
            // Wait for start bit
            @(negedge uart_tx_pin);
            #(BIT_HALF_NS);
            if (uart_tx_pin !== 0)
                $display("  [CPU -> TB] WARNING: Start bit not 0");
            
            data = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                data[i] = uart_tx_pin;
            end
            // Stop bit
            #(BIT_NS);
        end
    endtask

    reg [7:0] rx_val;
    integer pass_count = 0;
    integer fail_count = 0;
    integer i;

    initial begin
        $dumpfile("sim/tb_uart_rx_cpu_c.vcd");
        $dumpvars(0, tb_uart_rx_cpu_c);

        $display("=== C Program Startup & Interaction CPU Simulation ===");
        
        rst_n = 0;
        #100;
        rst_n = 1;
        #500; // wait for initialization

        // 1. Receive startup text message from C program.
        // Expect "Hello from C program with expanded memory!\r\n" (44 chars)
        //        "BSS cleared successfully!\r\n"               (27 chars)
        //        "Entering echo loop...\r\n"                   (23 chars)
        // Total expected characters: 94 chars.
        $write("[CPU -> TB] Startup output: ");
        for (i = 0; i < 94; i = i + 1) begin
            recv_byte(rx_val);
            if (rx_val == 8'h0D) begin
                // Ignore CR for display
            end else if (rx_val == 8'h0A) begin
                $write("\n[CPU -> TB] ");
            end else begin
                $write("%c", rx_val);
            end
        end
        $write("\n");

        #10000;

        // 2. Perform Echoback Test: Send 'X'
        fork
            send_byte(8'h58); // 'X'
            recv_byte(rx_val);
        join
        if (rx_val === 8'h58) begin
            $display("  PASS: Echo 'X' success");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Expected 'X' (0x58), got 0x%x", rx_val);
            fail_count = fail_count + 1;
        end

        // Test: Send '2'
        fork
            send_byte(8'h32); // '2'
            recv_byte(rx_val);
        join
        if (rx_val === 8'h32) begin
            $display("  PASS: Echo '2' success");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Expected '2' (0x32), got 0x%x", rx_val);
            fail_count = fail_count + 1;
        end

        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        $finish;
    end

    // Timeout
    initial begin
        #50_000_000; // 50ms
        $display("TIMEOUT: simulation did not finish");
        $finish;
    end

endmodule
