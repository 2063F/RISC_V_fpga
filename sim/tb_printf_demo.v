`timescale 1ns / 1ps
// =============================================================================
// tb_printf_demo.v - Testbench for Phase 3 C Runtime & printf Demonstration
// =============================================================================

module tb_printf_demo;

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

    // Instantiate CPU with printf_demo.hex
    cpu_top #(
        .INIT_FILE("examples/printf_demo.hex")
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

    // Task to send a byte to CPU's RX
    task send_byte;
        input [7:0] data;
        integer i;
        begin
            $display("\n[TB -> CPU] Sending byte: '%c' (0x%x)", data, data);
            $fflush(32'h8000_0001);
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
            #(BIT_NS); // Extra guard
        end
    endtask

    // Task to receive a byte from CPU's TX
    task recv_byte;
        output [7:0] data;
        integer i;
        begin
            // Wait for start bit
            @(negedge uart_tx_pin);
            #(BIT_HALF_NS);
            
            data = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                data[i] = uart_tx_pin;
            end
            // Finish stop bit (1.5 bit periods remaining in total 10-bit window)
            #(BIT_NS + BIT_HALF_NS);
        end
    endtask

    reg [7:0] rx_val;

    // Reset sequence & UART RX stimulus
    initial begin
        $display("=== Phase 3 printf_demo Simulation Started ===");
        $fflush(32'h8000_0001);
        
        rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        
        // Wait 25ms for CPU to finish initial printf messages then send 'Z'
        #25_000_000;
        send_byte(8'h5A); // Send 'Z' (0x5A)
        
        // Wait 5ms for CPU to echo 'Z' and print "Done!"
        #5_000_000;
        $display("\n=== Simulation Complete ===");
        $fflush(32'h8000_0001);
        $finish;
    end

    // Continuous UART RX logger
    initial begin
        while (1) begin
            recv_byte(rx_val);
            $write("%c", rx_val);
            $fflush(32'h8000_0001);
        end
    end

    // Safety Timeout
    initial begin
        #40_000_000; // 40ms timeout
        $display("\nTIMEOUT: Simulation exceeded 40ms limit");
        $fflush(32'h8000_0001);
        $finish;
    end

endmodule
