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
//   0x8000_0028 : Keyboard matrix ROW output register (8x8 scan matrix)
//                 - bits [7:0], active-low: write 0 to the row being
//                   scanned, 1 to all other rows. Reset value 0xFF (idle).
//   0x8000_002C : Keyboard matrix COL input register
//                 - bits [7:0], active-low: read returns kbd_col, a
//                   pressed key pulls its column bit to 0.
//   0x8000_0030 : 8x8 LED matrix GREEN bitmap, bits [31:0]  (low half)
//   0x8000_0034 : 8x8 LED matrix GREEN bitmap, bits [63:32] (high half)
//   0x8000_0038 : 8x8 LED matrix RED   bitmap, bits [31:0]  (low half)
//   0x8000_003C : 8x8 LED matrix RED   bitmap, bits [63:32] (high half)
//                 - bit (row*8+col) of the combined 64-bit value lights
//                   that dot in that color; led_matrix.v scans it out on
//                   its own once written. Reset value 0 (all dark).
//   0x8000_0040 : USB keyboard event register (usb_keyboard.v)
//                 - read: bit 9 = keyboard connected, bit 8 = an event is
//                   waiting, bits 5:0 = key index (0 = a1, 1 = b1, ...
//                   7 = h1, 8 = a2, ... 63 = h8). Reading does not consume
//                   the event.
//                 - write (any value): consume the event. The pop reaches
//                   usb_keyboard one clock after the store, so a read in
//                   that clock reports no event (bit 8 = 0) rather than the
//                   one being consumed; the next read sees the next event.
//
// read_data is registered: it answers the address one clock later. The CPU
// samples external load data in the load's second (data) cycle with the
// address held steady, so this costs nothing and keeps the address decode
// off the CPU's write-back path.
// =============================================================================

module board_io (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] addr,
    input  wire [31:0] write_data,
    input  wire        write_en,
    input  wire        read_en,
    input  wire        user_btn,
    input  wire [7:0]  kbd_col,
    input  wire        usbkey_valid,
    input  wire [5:0]  usbkey_index,
    input  wire        usbkey_connected,
    output reg         usbkey_pop,
    output reg  [31:0] read_data,
    output reg         led_ctrl,
    output reg  [7:0]  kbd_row,
    output reg  [63:0] led_green_bitmap,
    output reg  [63:0] led_red_bitmap
);

    localparam [31:0] LED_ADDR          = 32'h8000_0020;
    localparam [31:0] BTN_ADDR          = 32'h8000_0024;
    localparam [31:0] KBD_ROW_ADDR      = 32'h8000_0028;
    localparam [31:0] KBD_COL_ADDR      = 32'h8000_002C;
    localparam [31:0] LED_GREEN_LO_ADDR = 32'h8000_0030;
    localparam [31:0] LED_GREEN_HI_ADDR = 32'h8000_0034;
    localparam [31:0] LED_RED_LO_ADDR   = 32'h8000_0038;
    localparam [31:0] LED_RED_HI_ADDR   = 32'h8000_003C;
    localparam [31:0] USBKEY_ADDR       = 32'h8000_0040;

    // Stores never stall in the CPU, so write_en is a single-cycle pulse.
    // The pop is registered: combinational, it ran from the CPU's address
    // adder straight into usb_keyboard's 64-bit pending update and was the
    // critical path.
    always @(posedge clk) begin
        if (!rst_n)
            usbkey_pop <= 1'b0;
        else
            usbkey_pop <= write_en && (addr == USBKEY_ADDR);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            led_ctrl         <= 1'b0;
            kbd_row          <= 8'hFF;
            led_green_bitmap <= 64'd0;
            led_red_bitmap   <= 64'd0;
        end else begin
            if (write_en && addr == LED_ADDR) begin
                led_ctrl <= write_data[0];
            end
            if (write_en && addr == KBD_ROW_ADDR) begin
                kbd_row <= write_data[7:0];
            end
            if (write_en && addr == LED_GREEN_LO_ADDR) begin
                led_green_bitmap[31:0] <= write_data;
            end
            if (write_en && addr == LED_GREEN_HI_ADDR) begin
                led_green_bitmap[63:32] <= write_data;
            end
            if (write_en && addr == LED_RED_LO_ADDR) begin
                led_red_bitmap[31:0] <= write_data;
            end
            if (write_en && addr == LED_RED_HI_ADDR) begin
                led_red_bitmap[63:32] <= write_data;
            end
        end
    end

    always @(posedge clk) begin
        read_data <= 32'd0;
        if (read_en) begin
            case (addr)
                LED_ADDR:          read_data <= {31'd0, led_ctrl};
                BTN_ADDR:          read_data <= {31'd0, user_btn};
                KBD_ROW_ADDR:      read_data <= {24'd0, kbd_row};
                KBD_COL_ADDR:      read_data <= {24'd0, kbd_col};
                LED_GREEN_LO_ADDR: read_data <= led_green_bitmap[31:0];
                LED_GREEN_HI_ADDR: read_data <= led_green_bitmap[63:32];
                LED_RED_LO_ADDR:   read_data <= led_red_bitmap[31:0];
                LED_RED_HI_ADDR:   read_data <= led_red_bitmap[63:32];
                USBKEY_ADDR:       read_data <= {22'd0, usbkey_connected, usbkey_valid && !usbkey_pop,
                                                 2'd0, usbkey_index};
                default:           read_data <= 32'd0;
            endcase
        end
    end

endmodule