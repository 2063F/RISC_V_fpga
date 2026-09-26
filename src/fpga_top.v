`timescale 1ns / 1ps
// =============================================================================
// fpga_top.v - FPGA Top-Level Module for RISC-V CPU on Tang Primer 25K
// =============================================================================
// Features:
// - Instantiates the single-cycle RISC-V CPU.
// - Loads the loop55.hex test program (1+2+...+10 = 55).
// - Exposes simple MMIO for LED, button and 8x8 key matrix access.
// - Displays status on the 2 onboard LEDs:
//   - LED[0]: Blinks at ~1Hz to show that the system clock is running (heartbeat).
//   - LED[1]: Turns ON constantly if the CPU successfully computes x1 = 55.
//             If the CPU has not finished or failed, LED[1] is OFF.
// =============================================================================

module fpga_top #(
    parameter INIT_FILE = "examples/loop55.hex",
    parameter KEY_ROW_CYCLES = 25000  // key matrix: clocks per row (0.5 ms)
) (
    input  wire       clk,       // 50 MHz onboard crystal oscillator
    input  wire       rst_btn,   // Reset button (active high)
    input  wire       user_btn,  // User button (active high)
    output reg  [1:0] led,       // 2x onboard LEDs
    output wire       uart_tx,   // UART TX pin (connect to USB-UART RX)
    input  wire       uart_rx,   // UART RX pin (connect to USB-UART TX)
    output wire [7:0] kbd_row_n, // Key matrix rows (driven low one at a time, else Hi-Z)
    input  wire [7:0] kbd_col_n  // Key matrix columns (pulled up, low = pressed)
);

    // =========================================================================
    // System Reset
    // rst_btn is active-high, CPU expects rst_n (active-low)
    // =========================================================================
    wire cpu_rst_n = ~rst_btn;

    // =========================================================================
    // CPU Instantiation
    // =========================================================================
    wire [31:0] mem_addr;
    wire [31:0] mem_write_data;
    wire        mem_write_en;
    wire        mem_read_en;
    wire [31:0] mem_read_data;
    wire [31:0] debug_pc;
    wire [31:0] debug_x1;
    wire        mmio_led_ctrl;

    cpu_top #(
        .INIT_FILE(INIT_FILE)
    ) cpu (
        .clk            (clk),
        .rst_n          (cpu_rst_n),
        .mem_addr       (mem_addr),
        .mem_write_data (mem_write_data),
        .mem_write_en   (mem_write_en),
        .mem_read_en    (mem_read_en),
        .mem_read_data  (mem_read_data),
        .uart_tx_pin    (uart_tx),
        .uart_rx_pin    (uart_rx),
        .debug_pc       (debug_pc),
        .debug_x1       (debug_x1)
    );

    board_io io_bridge (
        .clk        (clk),
        .rst_n      (cpu_rst_n),
        .addr       (mem_addr),
        .write_data (mem_write_data),
        .write_en   (mem_write_en),
        .read_en    (mem_read_en),
        .user_btn   (user_btn),
        .key_valid  (key_valid),
        .key_index  (key_index),
        .key_pop    (key_pop),
        .read_data  (mem_read_data),
        .led_ctrl   (mmio_led_ctrl)
    );

    // =========================================================================
    // 8x8 Key Switch Matrix (MMIO 0x8000_0028 via board_io)
    // =========================================================================
    wire       key_valid;
    wire [5:0] key_index;
    wire       key_pop;

    keypad_matrix #(
        .ROW_CYCLES (KEY_ROW_CYCLES)
    ) keypad (
        .clk       (clk),
        .rst_n     (cpu_rst_n),
        .row_n     (kbd_row_n),
        .col_n     (kbd_col_n),
        .pop       (key_pop),
        .key_valid (key_valid),
        .key_index (key_index)
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
            // or software explicitly enables the MMIO LED overlay.
            if (debug_x1 == 32'd55 || mmio_led_ctrl) begin
                led[1] <= 1'b1;
            end else begin
                led[1] <= 1'b0;
            end
        end
    end

endmodule
