`timescale 1ns / 1ps
// =============================================================================
// fpga_top.v - FPGA Top-Level Module for RISC-V CPU on Tang Primer 25K
// =============================================================================
// Features:
// - Instantiates the three-stage pipelined RV32IM CPU (cpu_top).
// - Loads the Othello program by default (INIT_FILE); examples/loop55.hex
//   (1+2+...+10 = 55) is the minimal bring-up test.
// - Exposes simple MMIO for LED, button, 8x8 key matrix, 8x8 LED matrix and
//   the USB keyboard on the Dock's USB-A port (see board_io.v).
// - Mirrors the LED matrix bitmaps onto a 640x480 VGA output.
// - Displays status on the 2 onboard LEDs:
//   - LED[0]: Blinks at ~1.5Hz to show that the system clock is running (heartbeat).
//   - LED[1]: ON while x1 == 55 (loop55 finished) or while software sets the
//             MMIO LED control register; OFF otherwise.
// =============================================================================

module fpga_top #(
    parameter INIT_FILE = "examples/othello_embedded/othello.hex",
    parameter SPACE_RESET_CYCLES = 150_000_000 // Space held this long = reset (3 s)
) (
    input  wire       clk,       // 50 MHz onboard crystal oscillator
    input  wire       rst_btn,   // Reset button (active high)
    input  wire       user_btn,  // User button (active high)
    output reg  [1:0] led,       // 2x onboard LEDs
    output wire       uart_tx,   // UART TX pin (connect to USB-UART RX)
    input  wire       uart_rx,   // UART RX pin (connect to USB-UART TX)
    output wire [7:0] kbd_row,   // 8x8 matrix keyboard row drive (active-low)
    input  wire [7:0] kbd_col,   // 8x8 matrix keyboard column sense (active-low)
    output wire [7:0] led_mat_row,   // LED matrix row drive (active-high, anode)
    output wire [7:0] led_mat_col_g, // LED matrix green column (active-low, cathode)
    output wire [7:0] led_mat_col_r, // LED matrix red column (active-low, cathode)
    output wire       vga_r,         // VGA red   (1 bit, via resistor DAC)
    output wire       vga_g,         // VGA green (1 bit, via resistor DAC)
    output wire       vga_b,         // VGA blue  (1 bit, via resistor DAC)
    output wire       vga_hsync,     // VGA HSYNC (active-low)
    output wire       vga_vsync,     // VGA VSYNC (active-low)
    inout  wire       usb_dp,        // USB-A host port D+ (low-speed USB 1.1)
    inout  wire       usb_dm         // USB-A host port D-
);

    // =========================================================================
    // System Reset
    // rst_btn is active-high, CPU expects rst_n (active-low)
    // Holding Space on the USB keyboard for 3 s resets the same logic as S1
    // (CPU and its peripherals) and keeps it in reset until Space is let go.
    // The USB host itself stays out of it so the keyboard is not re-enumerated.
    // =========================================================================
    wire        usb_space_held;
    reg  [27:0] space_cnt;
    wire        space_rst = (space_cnt == SPACE_RESET_CYCLES);

    always @(posedge clk) begin
        if (rst_btn || !usb_space_held) begin
            space_cnt <= 28'd0;
        end else if (!space_rst) begin
            space_cnt <= space_cnt + 28'd1;
        end
    end

    wire cpu_rst_n = ~(rst_btn | space_rst);

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
    wire [63:0] led_green_bitmap;
    wire [63:0] led_red_bitmap;
    wire        usbkey_valid;
    wire [5:0]  usbkey_index;
    wire        usbkey_connected;
    wire        usbkey_pop;

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
        .kbd_col    (kbd_col),
        .usbkey_valid     (usbkey_valid),
        .usbkey_index     (usbkey_index),
        .usbkey_connected (usbkey_connected),
        .usbkey_pop       (usbkey_pop),
        .read_data  (mem_read_data),
        .led_ctrl   (mmio_led_ctrl),
        .kbd_row    (kbd_row),
        .led_green_bitmap (led_green_bitmap),
        .led_red_bitmap   (led_red_bitmap)
    );

    // The LED matrix is mounted upside down relative to the board, so show
    // it rotated 180 degrees: square sq is lit at dot 63 - sq, which is just
    // the bitmap with its bit order reversed. The VGA keeps the bitmaps as-is.
    wire [63:0] led_mat_green;
    wire [63:0] led_mat_red;
    genvar gi;
    generate
        for (gi = 0; gi < 64; gi = gi + 1) begin : g_led_rot180
            assign led_mat_green[gi] = led_green_bitmap[63 - gi];
            assign led_mat_red[gi]   = led_red_bitmap[63 - gi];
        end
    endgenerate

    led_matrix led_mat (
        .clk           (clk),
        .rst_n         (cpu_rst_n),
        .green_bitmap  (led_mat_green),
        .red_bitmap    (led_mat_red),
        .led_row       (led_mat_row),
        .led_col_g     (led_mat_col_g),
        .led_col_r     (led_mat_col_r)
    );

    // The Othello program writes black stones to the green bitmap and white
    // stones to the red one, so the VGA board reuses them as-is.
    vga_board vga (
        .clk           (clk),
        .rst_n         (cpu_rst_n),
        .black_bitmap  (led_green_bitmap),
        .white_bitmap  (led_red_bitmap),
        .vga_r         (vga_r),
        .vga_g         (vga_g),
        .vga_b         (vga_b),
        .vga_hsync     (vga_hsync),
        .vga_vsync     (vga_vsync)
    );

    // =========================================================================
    // USB Keyboard on the Dock's USB-A port (MMIO 0x8000_0040 via board_io)
    // =========================================================================
    // usb_hid_host runs on its own 12 MHz clock; usb_keyboard.v hands the key
    // presses over to the 50 MHz CPU domain.
    wire clk_usb;
    gowin_pll_usb pll_usb (
        .clkin  (clk),
        .clkout (clk_usb)
    );

    reg [1:0] usb_rst_sync;
    always @(posedge clk_usb) usb_rst_sync <= {usb_rst_sync[0], ~rst_btn};

    wire [1:0] usb_typ;
    wire       usb_report;
    wire [7:0] usb_mod, usb_key1, usb_key2, usb_key3, usb_key4;

    usb_hid_host usb_host (
        .usbclk        (clk_usb),
        .usbrst_n      (usb_rst_sync[1]),
        .usb_dm        (usb_dm),
        .usb_dp        (usb_dp),
        .typ           (usb_typ),
        .report        (usb_report),
        .conerr        (),
        .key_modifiers (usb_mod),
        .key1          (usb_key1),
        .key2          (usb_key2),
        .key3          (usb_key3),
        .key4          (usb_key4),
        .mouse_btn     (),
        .mouse_dx      (),
        .mouse_dy      (),
        .game_l (), .game_r (), .game_u (), .game_d (),
        .game_a (), .game_b (), .game_x (), .game_y (), .game_sel (), .game_sta (),
        .dbg_hid_report ()
    );

    usb_keyboard usb_kbd (
        .clk        (clk),
        .rst_n      (cpu_rst_n),
        .pop        (usbkey_pop),
        .key_valid  (usbkey_valid),
        .key_index  (usbkey_index),
        .connected  (usbkey_connected),
        .space_held (usb_space_held),
        .usbclk     (clk_usb),
        .usb_report (usb_report),
        .usb_typ    (usb_typ),
        .usb_mod    (usb_mod),
        .usb_key1   (usb_key1),
        .usb_key2   (usb_key2),
        .usb_key3   (usb_key3),
        .usb_key4   (usb_key4)
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
