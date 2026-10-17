`timescale 1ns / 1ps
// =============================================================================
// vga_board.v - 640x480@60Hz VGA renderer for the 8x8 Othello board
// =============================================================================
// Draws the board straight from two 64-bit bitmaps, the same ones the CPU
// already writes for the LED matrix (board_io.v 0x8000_0030..0x8000_003C):
//   black_bitmap = led_green_bitmap (black stones)
//   white_bitmap = led_red_bitmap   (white stones)
// so no extra MMIO or software change is needed - whatever the LED matrix
// shows, the monitor shows too.
//
// Output is 1 bit per color (8 colors), meant for a plain resistor DAC:
//   vga_r/g/b --[~270 ohm]-- VGA R/G/B (75 ohm terminated -> ~0.7 V full scale)
//   vga_hsync/vga_vsync -- VGA HSYNC/VSYNC (direct, or ~100 ohm in series)
//   GND -- R/G/B returns and sync ground
//
// Layout: square pixels, 56x56 cells, 448x448 board centred on the screen.
// Bit (row*8+col) is drawn with row 0 at the top and col 0 at the left, the
// same orientation print_board() uses on the UART (a1 = top-left).
//   empty square = green, black stone = black disc, white stone = white disc,
//   grid lines = black, outside the board = black.
//
// Timing: 25 MHz pixel rate from the 50 MHz clock via a clock enable (no PLL,
// no second clock domain). The standard is 25.175 MHz; 25.0 MHz (59.5 Hz
// frame) is within what monitors accept for 640x480.
// =============================================================================

module vga_board (
    input  wire        clk,          // 50 MHz
    input  wire        rst_n,
    input  wire [63:0] black_bitmap,
    input  wire [63:0] white_bitmap,
    output reg         vga_r,
    output reg         vga_g,
    output reg         vga_b,
    output reg         vga_hsync,    // active-low
    output reg         vga_vsync     // active-low
);

    // 640x480@60 timing, in pixels / lines
    localparam integer H_VISIBLE = 640;
    localparam integer H_FRONT   = 16;
    localparam integer H_SYNC    = 96;
    localparam integer H_BACK    = 48;
    localparam integer H_TOTAL   = H_VISIBLE + H_FRONT + H_SYNC + H_BACK; // 800

    localparam integer V_VISIBLE = 480;
    localparam integer V_FRONT   = 10;
    localparam integer V_SYNC    = 2;
    localparam integer V_BACK    = 33;
    localparam integer V_TOTAL   = V_VISIBLE + V_FRONT + V_SYNC + V_BACK; // 525

    // Board geometry
    // Sized to match the 10-bit scan counters.
    localparam [9:0] CELL    = 10'd56;
    localparam [9:0] BOARD   = CELL * 8;                     // 448
    localparam [9:0] BOARD_X = (H_VISIBLE - BOARD) / 2;      // 96
    localparam [9:0] BOARD_Y = (V_VISIBLE - BOARD) / 2;      // 16

    // Stone radius, in doubled coordinates (see disc test below): 22 px.
    localparam integer DISC_R2 = (2 * 22) * (2 * 22);

    // -------------------------------------------------------------------------
    // Pixel clock enable and scan counters
    // -------------------------------------------------------------------------
    reg       pix_en;
    reg [9:0] h_cnt;
    reg [9:0] v_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            pix_en <= 1'b0;
            h_cnt  <= 10'd0;
            v_cnt  <= 10'd0;
        end else begin
            pix_en <= ~pix_en;
            if (pix_en) begin
                if (h_cnt == H_TOTAL - 1) begin
                    h_cnt <= 10'd0;
                    v_cnt <= (v_cnt == V_TOTAL - 1) ? 10'd0 : v_cnt + 10'd1;
                end else begin
                    h_cnt <= h_cnt + 10'd1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Board hit test
    // -------------------------------------------------------------------------
    // Which of the 8 cells an offset (0..447) into the board falls in.
    function [2:0] cell_of;
        input [9:0] ofs;
        begin
            if      (ofs >= CELL * 7) cell_of = 3'd7;
            else if (ofs >= CELL * 6) cell_of = 3'd6;
            else if (ofs >= CELL * 5) cell_of = 3'd5;
            else if (ofs >= CELL * 4) cell_of = 3'd4;
            else if (ofs >= CELL * 3) cell_of = 3'd3;
            else if (ofs >= CELL * 2) cell_of = 3'd2;
            else if (ofs >= CELL * 1) cell_of = 3'd1;
            else                      cell_of = 3'd0;
        end
    endfunction

    wire       visible  = (h_cnt < H_VISIBLE) && (v_cnt < V_VISIBLE);
    wire       on_board = (h_cnt >= BOARD_X) && (h_cnt < BOARD_X + BOARD) &&
                          (v_cnt >= BOARD_Y) && (v_cnt < BOARD_Y + BOARD);

    wire [9:0] board_x = h_cnt - BOARD_X;
    wire [9:0] board_y = v_cnt - BOARD_Y;

    wire [2:0] cell_x  = cell_of(board_x);
    wire [2:0] cell_y  = cell_of(board_y);   // 0 = top of screen

    // Position inside the cell, 0..55
    wire [9:0] in_x_w  = board_x - cell_x * CELL;
    wire [9:0] in_y_w  = board_y - cell_y * CELL;

    // -------------------------------------------------------------------------
    // Pipeline register between the cell split and the disc test
    // -------------------------------------------------------------------------
    // The cell split (compare chain + multiply) and the disc test (another
    // multiply) do not fit one 50 MHz cycle together. The scan counters only
    // move on pix_en, so they hold for two clocks: registering here on every
    // clock leaves the stage-1 values matching the current h_cnt/v_cnt by the
    // time the outputs load on the next pix_en. The picture is not shifted.
    reg       show_q;                 // visible && on_board
    reg [5:0] in_x, in_y;
    reg [5:0] sq;

    // Row 0 (rank 1) is drawn at the top, matching print_board().
    always @(posedge clk) begin
        show_q <= visible && on_board;
        in_x   <= in_x_w[5:0];
        in_y   <= in_y_w[5:0];
        sq     <= {cell_y, cell_x};
    end

    // 1 px on each side of every cell -> 2 px inner lines, 1 px outer frame.
    wire grid = (in_x == 6'd0) || (in_x == CELL - 1) ||
                (in_y == 6'd0) || (in_y == CELL - 1);

    // Disc test in doubled coordinates so the centre (27.5, 27.5) is exact:
    // d = 2*in - 55 ranges over odd values -55..55.
    wire signed [7:0]  dx   = $signed({1'b0, in_x, 1'b0}) - 8'sd55;
    wire signed [7:0]  dy   = $signed({1'b0, in_y, 1'b0}) - 8'sd55;
    wire        [13:0] dist = dx * dx + dy * dy;
    wire               disc = (dist < DISC_R2);

    wire is_black = black_bitmap[sq];
    wire is_white = white_bitmap[sq];

    // -------------------------------------------------------------------------
    // Registered outputs (sync and color share the same one-pixel latency)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            {vga_r, vga_g, vga_b} <= 3'b000;
            vga_hsync             <= 1'b1;
            vga_vsync             <= 1'b1;
        end else if (pix_en) begin
            vga_hsync <= ~((h_cnt >= H_VISIBLE + H_FRONT) &&
                           (h_cnt <  H_VISIBLE + H_FRONT + H_SYNC));
            vga_vsync <= ~((v_cnt >= V_VISIBLE + V_FRONT) &&
                           (v_cnt <  V_VISIBLE + V_FRONT + V_SYNC));

            if (!show_q || grid) begin
                {vga_r, vga_g, vga_b} <= 3'b000;
            end else if (disc && is_black) begin
                {vga_r, vga_g, vga_b} <= 3'b000;
            end else if (disc && is_white) begin
                {vga_r, vga_g, vga_b} <= 3'b111;
            end else begin
                {vga_r, vga_g, vga_b} <= 3'b010;   // board green
            end
        end
    end

endmodule
