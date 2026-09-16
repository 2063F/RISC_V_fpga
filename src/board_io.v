`timescale 1ns / 1ps
// =============================================================================
// board_io.v - Simple board MMIO bridge for LEDs and user button
// =============================================================================
// Memory map:
//   0x8000_0020 : LED control register
//                 - bit 0 controls the status LED overlay
//                 - read returns the latched LED state in bit 0
//   0x8000_0024 : User button status register
//                 - read returns user_btn in bit 0
// =============================================================================

module board_io (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] addr,
    input  wire [31:0] write_data,
    input  wire        write_en,
    input  wire        read_en,
    input  wire        user_btn,
    output reg  [31:0] read_data,
    output reg         led_ctrl
);

    localparam [31:0] LED_ADDR = 32'h8000_0020;
    localparam [31:0] BTN_ADDR = 32'h8000_0024;

    always @(posedge clk) begin
        if (!rst_n) begin
            led_ctrl <= 1'b0;
        end else if (write_en && addr == LED_ADDR) begin
            led_ctrl <= write_data[0];
        end
    end

    always @(*) begin
        read_data = 32'd0;
        if (read_en) begin
            case (addr)
                LED_ADDR: read_data = {31'd0, led_ctrl};
                BTN_ADDR: read_data = {31'd0, user_btn};
                default:  read_data = 32'd0;
            endcase
        end
    end

endmodule