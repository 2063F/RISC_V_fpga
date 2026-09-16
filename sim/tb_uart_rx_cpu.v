`timescale 1ns / 1ps
// =============================================================================
// tb_uart_rx_cpu.v - CPU + UART RX/TX Loopback Testbench
// =============================================================================

module tb_uart_rx_cpu;

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

    // Instantiate CPU with uart_echo.hex
    cpu_top #(
        .INIT_FILE("src/uart_echo.hex")
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
            $display("[CPU -> TB] Received: %c (0x%x)", data, data);
        end
    endtask

    reg [7:0] rx_val;
    integer pass_count = 0;
    integer fail_count = 0;

    initial begin
        $dumpfile("sim/tb_uart_rx_cpu.vcd");
        $dumpvars(0, tb_uart_rx_cpu);

        $display("=== UART RX/TX Loopback CPU Simulation ===");
        
        rst_n = 0;
        #100;
        rst_n = 1;
        #500; // wait for initialization

        // Test 1: Send 'A' (0x41)
        fork
            send_byte(8'h41);
            recv_byte(rx_val);
        join
        if (rx_val === 8'h41) begin
            $display("  PASS: Echo 'A' success");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Expected 'A' (0x41), got 0x%x", rx_val);
            fail_count = fail_count + 1;
        end

        #5000;

        // Test 2: Send '7' (0x37)
        fork
            send_byte(8'h37);
            recv_byte(rx_val);
        join
        if (rx_val === 8'h37) begin
            $display("  PASS: Echo '7' success");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Expected '7' (0x37), got 0x%x", rx_val);
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
        #500_000_000; // 500ms
        $display("TIMEOUT: simulation did not finish");
        $finish;
    end

endmodule
