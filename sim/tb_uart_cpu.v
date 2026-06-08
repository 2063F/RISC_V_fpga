`timescale 1ns / 1ps
// =============================================================================
// tb_uart_cpu.v - CPU+UART MMIO Integration Testbench
// =============================================================================
// cpu_top に uart_hello.hex をロードし、UART TX 出力をビットデコードして
// シリアルに送出された文字を表示する。
// 115200 bps @ 50 MHz クロック: 1 bit = 434 クロックサイクル
// =============================================================================

module tb_uart_cpu;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter CLK_PERIOD   = 20;    // 20 ns = 50 MHz
    parameter BAUD_RATE    = 115200;
    // bit period in ns:  1e9 / 115200 ≈ 8680 ns
    parameter BIT_NS       = 1_000_000_000 / BAUD_RATE;  // ≈ 8680 ns
    parameter BIT_HALF_NS  = BIT_NS / 2;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg         clk   = 0;
    reg         rst_n = 0;
    wire        uart_tx_pin;
    wire [31:0] debug_pc;
    wire [31:0] debug_x1;

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    cpu_top #(
        .INIT_FILE("src/uart_hello.hex")
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (),
        .mem_write_data (),
        .mem_write_en   (),
        .mem_read_en    (),
        .mem_read_data  (32'd0),
        .uart_tx_pin    (uart_tx_pin),
        .debug_pc       (debug_pc),
        .debug_x1       (debug_x1)
    );

    // -------------------------------------------------------------------------
    // UART Receiver task: sample 8 data bits at baud rate
    // -------------------------------------------------------------------------
    reg [7:0] rx_char;
    integer char_count;

    task recv_byte;
        output [7:0] data;
        integer i;
        begin
            // Wait for start bit (falling edge)
            @(negedge uart_tx_pin);
            // Wait half bit period to sample center of start bit
            #(BIT_HALF_NS);
            if (uart_tx_pin !== 0)
                $display("  [RX] WARNING: Start bit not 0 (got %b)", uart_tx_pin);
            // Sample 8 data bits
            data = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                data[i] = uart_tx_pin;
            end
            // Skip stop bit
            #(BIT_NS);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test
    // -------------------------------------------------------------------------
    initial begin
        $display("=== UART CPU Integration Simulation Start ===");
        $display("BAUD_RATE=%0d, BIT_PERIOD=%0dns", BAUD_RATE, BIT_NS);

        // Reset
        rst_n = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        $display("Reset released at time %0t", $time);

        // Receive and print first 35 characters
        // "Hello, RISC-V!\r\n" = 17 chars × 2 repetitions + a bit extra
        char_count = 0;
        $write("Received: [");
        while (char_count < 34) begin
            recv_byte(rx_char);
            if (rx_char == 8'h0D) begin
                // \r — ignore for display, count it
            end else if (rx_char == 8'h0A) begin
                $write("\\n");
            end else begin
                $write("%s", rx_char);
            end
            char_count = char_count + 1;
        end
        $display("]");
        $display("=== %0d chars received, simulation complete ===", char_count);

        #1000;
        $finish;
    end

    // Timeout guard: if nothing happens in 200 ms sim time → abort
    initial begin
        #200_000_000_000; // 200ms
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

endmodule
