`timescale 1ns / 1ps
// =============================================================================
// led_matrix.v - Dynamic-scan driver for an 8x8 bicolor (green/red) dot
// matrix LED, e.g. Lite-On LTP-12188M-07 (ANODE ROW / CATHODE COLUMN).
// =============================================================================
// Row = common anode per row: drive HIGH to select a row, LOW otherwise.
// Column = separate cathode per color: drive LOW to light that dot, HIGH to
// leave it dark.
//
// This board wires the FPGA pins straight to the LED (current-limiting
// resistors on the columns only, no row driver transistors). A row pin can
// only source a few mA before it droops, so lighting a whole row's worth of
// dots at once (the usual 1/8-duty scan, one row high with up to 8 columns
// low) starved whichever dots needed the most current and they stayed dark.
// Scanning one dot at a time instead (1/64 duty: one row high, at most one
// column low) keeps every row pin's load down to a single dot regardless of
// how many dots are lit, at the cost of the display being dimmer (each dot
// is lit 1/8 as long per frame as the row-at-a-time scheme).
//
// green_bitmap/red_bitmap bit (row*8+col) = 1 lights that dot in that color.
// Software just writes the two 64-bit bitmaps and this module keeps the
// display refreshed on its own - no CPU attention needed once written.
// =============================================================================

module led_matrix (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [63:0] green_bitmap,
    input  wire [63:0] red_bitmap,
    output reg  [7:0]  led_row,    // active-high, one-hot (anode)
    output reg  [7:0]  led_col_g,  // active-low (cathode, green)
    output reg  [7:0]  led_col_r   // active-low (cathode, red)
);

    // 50 MHz / 2^12 per dot / 64 dots per frame ~= 191 Hz full-frame
    // refresh - flicker-free. (Briefly ran with DIV_BITS=18 as a diagnostic
    // to slow the scan down and check whether a wrong-dot-lights-up symptom
    // was a row/column settling-time issue; investigation is still open,
    // this is back to the normal speed.)
    localparam integer DIV_BITS = 12;

    reg [DIV_BITS-1:0] div_cnt;
    reg [5:0]          dot_idx; // 0..63, dot_idx = row*8 + col

    wire [2:0] row_idx = dot_idx[5:3];
    wire [2:0] col_idx = dot_idx[2:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            div_cnt <= {DIV_BITS{1'b0}};
            dot_idx <= 6'd0;
        end else begin
            div_cnt <= div_cnt + 1'b1;
            if (div_cnt == {DIV_BITS{1'b0}}) begin
                dot_idx <= dot_idx + 1'b1;
            end
        end
    end

    always @(*) begin
        led_row   = (8'b0000_0001 << row_idx);
        led_col_g = green_bitmap[dot_idx] ? ~(8'b0000_0001 << col_idx) : 8'hFF;
        led_col_r = red_bitmap[dot_idx]   ? ~(8'b0000_0001 << col_idx) : 8'hFF;
    end

endmodule
