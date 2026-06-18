`timescale 1ns / 1ps
// =============================================================================
// fpga_top.v - FPGA Top-Level Module for RISC-V CPU on Tang Primer 25K
// =============================================================================
// Features:
// - Instantiates the single-cycle RISC-V CPU.
// - Loads the loop55.hex test program (1+2+...+10 = 55).
// - Displays status on the 2 onboard LEDs:
//   - LED[0]: Blinks at ~1Hz to show that the system clock is running (heartbeat).
//   - LED[1]: Turns ON constantly if the CPU successfully computes x1 = 55.
//             If the CPU has not finished or failed, LED[1] is OFF.
// =============================================================================

module fpga_top (
    input  wire       clk,       // 50 MHz onboard crystal oscillator
    input  wire       rst_btn,   // Reset button (active high)
    input  wire       user_btn,  // User button (active high)
    output reg  [1:0] led,       // 2x onboard LEDs
    output wire       uart_tx    // UART TX pin (connect to USB-UART RX)
);

    // =========================================================================
    // System Reset
    // rst_btn is active-high, CPU expects rst_n (active-low)
    // =========================================================================
    wire cpu_rst_n = ~rst_btn;

    // =========================================================================
    // CPU Instantiation
    // =========================================================================
    wire [31:0] debug_pc;
    wire [31:0] debug_x1;

    cpu_top #(
        .INIT_FILE("uart_debug.hex")
    ) cpu (
        .clk            (clk),
        .rst_n          (cpu_rst_n),
        .mem_addr       (),
        .mem_write_data (),
        .mem_write_en   (),
        .mem_read_en    (),
        .mem_read_data  (32'd0),
        .uart_tx_pin    (uart_tx),
        .debug_pc       (debug_pc),
        .debug_x1       (debug_x1)
    );

    // =========================================================================
    // Heartbeat Counter (50 MHz clock / 2^25 = 1.49 Hz blink)
    // =========================================================================
    reg [24:0] blink_counter;
    always @(posedge clk) begin
        if (rst_btn) begin
            blink_counter <= 25'd0;
        end else begin
            blink_counter <= blink_counter + 25'd1;
        end
    end

    // =========================================================================
    // LED Output Logic
    // =========================================================================
    always @(posedge clk) begin
        if (rst_btn) begin
            led <= 2'b00;
        end else begin
            // LED[0] is the heartbeat
            led[0] <= blink_counter[24];

            // LED[1] is ON if CPU has computed x1 = 55 (0x37)
            if (debug_x1 == 32'd55) begin
                led[1] <= 1'b1;
            end else begin
                led[1] <= 1'b0;
            end
        end
    end

endmodule
