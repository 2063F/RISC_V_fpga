`timescale 1ns / 1ps
// =============================================================================
// led_matrix_bicolor.v - 8x8 red/green dot matrix LED driver (dynamic drive)
// =============================================================================
// Target: Lite-On LTP-12188M-08 (anode = rows, cathode = columns, separate red
// and green cathodes per column), or any matrix wired the same way.
//
// One row is lit at a time for ROW_CYCLES clocks (8 rows -> 1/8 duty). At every
// row change the rows and columns are all switched off for BLANK_CYCLES first,
// giving the row driver time to turn off so the next row's pattern does not
// flash on the previous row (ghosting).
//
// Output polarity is set by parameters so the same RTL fits the usual drivers:
//   ROW_ACTIVE_LOW = 1 : row pin -> base resistor -> PNP high-side switch
//                        (a row sources up to 8 LEDs - too much for an FPGA pin)
//   COL_ACTIVE_LOW = 1 : column pin -> current-limit resistor -> cathode,
//                        the FPGA pin sinks one LED's current
//
// Frame buffer (written by the CPU, see MMIO below): bit (row * 8 + col) of
// red / green turns that dot on, row 0..7 = the part's "row 1..8", col 0..7 =
// "column 1..8".
//
// MMIO (write only, 32-bit stores):
//   0x8000_0040 : red   rows 0-3  (bit row*8+col)
//   0x8000_0044 : red   rows 4-7  (bit (row-4)*8+col)
//   0x8000_0048 : green rows 0-3
//   0x8000_004C : green rows 4-7
// =============================================================================

module led_matrix_bicolor #(
    parameter integer ROW_CYCLES     = 50000, // 1 ms per row -> 125 Hz refresh
    parameter integer BLANK_CYCLES   = 250,   // 5 us all-off at each row change
    parameter         ROW_ACTIVE_LOW = 1,
    parameter         COL_ACTIVE_LOW = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    // CPU bus (external MMIO of cpu_top)
    input  wire [31:0] addr,
    input  wire [31:0] write_data,
    input  wire        write_en,
    // LED pins
    output reg  [7:0]  row,     // anodes, row 0..7
    output reg  [7:0]  col_red, // red cathodes, column 0..7
    output reg  [7:0]  col_grn  // green cathodes, column 0..7
);

    localparam [31:0] RED_LO = 32'h8000_0040;
    localparam [31:0] RED_HI = 32'h8000_0044;
    localparam [31:0] GRN_LO = 32'h8000_0048;
    localparam [31:0] GRN_HI = 32'h8000_004C;

    // ---------------------------------------------------------------- frame buffer
    reg [63:0] red;
    reg [63:0] grn;

    always @(posedge clk) begin
        if (!rst_n) begin
            red <= 64'd0;
            grn <= 64'd0;
        end else if (write_en) begin
            case (addr)
                RED_LO: red[31:0]  <= write_data;
                RED_HI: red[63:32] <= write_data;
                GRN_LO: grn[31:0]  <= write_data;
                GRN_HI: grn[63:32] <= write_data;
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------------- scanning
    reg [2:0]  cur_row;
    reg [31:0] cnt;

    wire       blank   = (cnt < BLANK_CYCLES);
    wire [7:0] row_on  = blank ? 8'd0 : (8'd1 << cur_row);
    wire [7:0] red_on  = blank ? 8'd0 : red[cur_row*8 +: 8];
    wire [7:0] grn_on  = blank ? 8'd0 : grn[cur_row*8 +: 8];

    always @(posedge clk) begin
        if (!rst_n) begin
            cur_row <= 3'd0;
            cnt     <= 32'd0;
            row     <= ROW_ACTIVE_LOW ? 8'hFF : 8'h00;
            col_red <= COL_ACTIVE_LOW ? 8'hFF : 8'h00;
            col_grn <= COL_ACTIVE_LOW ? 8'hFF : 8'h00;
        end else begin
            if (cnt == ROW_CYCLES - 1) begin
                cnt     <= 32'd0;
                cur_row <= cur_row + 3'd1;
            end else begin
                cnt <= cnt + 32'd1;
            end
            // Registered outputs: glitch-free pins
            row     <= ROW_ACTIVE_LOW ? ~row_on : row_on;
            col_red <= COL_ACTIVE_LOW ? ~red_on : red_on;
            col_grn <= COL_ACTIVE_LOW ? ~grn_on : grn_on;
        end
    end

endmodule
