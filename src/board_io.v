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
//                   usb_keyboard two clocks after the store, so a read in
//                   that clock reports no event (bit 8 = 0) rather than the
//                   one being consumed; the next read sees the next event.
//   0x8000_0044 : VGA hint bitmap, bits [31:0]  (squares marked with a dot)
//   0x8000_0048 : VGA hint bitmap, bits [63:32]
//   0x8000_004C : VGA control: bit 0 = show the board (1 after reset; 0 = the
//                 whole screen is text), bit 1 = red and green stones (the
//                 sides called Red / Green; 0 after reset = black and white)
//   0x8000_0050 : VGA last move: bit 6 = valid, bits 5:0 = square (red dot)
//   0x8000_1000 - 0x8000_1FFF : VGA text, write only: byte at
//                 0x8000_1000 + row * 128 + column (80 x 30), bits 6:0 the
//                 character, bit 7 = yellow (see vga_board.v)
//
// read_data is registered: it answers the address one clock later. The CPU
// samples external load data in the load's second (data) cycle with the
// address held steady, so this costs nothing and keeps the address decode
// off the CPU's write-back path.
//
// Writes are registered on the way in and decoded a clock later, so that
// the CPU's address adder is not in front of every register's enable (it
// was the critical path). A store therefore takes effect one clock late;
// cpu_top accepts no access in the clock after a store to anything but its
// RAM, so a load can never get there first.
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
    output reg  [63:0] led_red_bitmap,
    output reg  [63:0] vga_hint_bitmap,
    output reg         vga_show_board,
    output reg         vga_red_green,
    output reg  [6:0]  vga_last_move,
    output reg         vga_text_we,
    output reg  [11:0] vga_text_waddr,
    output reg  [7:0]  vga_text_wdata
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
    localparam [31:0] VGA_HINT_LO_ADDR  = 32'h8000_0044;
    localparam [31:0] VGA_HINT_HI_ADDR  = 32'h8000_0048;
    localparam [31:0] VGA_CTRL_ADDR     = 32'h8000_004C;
    localparam [31:0] VGA_LAST_ADDR     = 32'h8000_0050;
    localparam [19:0] VGA_TEXT_PAGE     = 20'h8000_1;     // 0x8000_1000 - 0x8000_1FFF

    // The store, a clock late (see the top of this file). Stores never stall
    // in the CPU, so write_en is a single-cycle pulse.
    reg        wr_q;
    reg [31:0] waddr_q;
    reg [31:0] wdata_q;

    always @(posedge clk) begin
        if (!rst_n)
            wr_q <= 1'b0;
        else
            wr_q <= write_en;
        waddr_q <= addr;
        wdata_q <= write_data;
    end

    // Text RAM writes go straight on to vga_board (its write port is registered
    // there, a clock later again; nothing reads the text back)
    always @(posedge clk) begin
        vga_text_we    <= rst_n && wr_q && (waddr_q[31:12] == VGA_TEXT_PAGE);
        vga_text_waddr <= waddr_q[11:0];
        vga_text_wdata <= wdata_q[7:0];
    end

    // The pop is registered as well: combinational, it ran into
    // usb_keyboard's 64-bit pending update.
    always @(posedge clk) begin
        if (!rst_n)
            usbkey_pop <= 1'b0;
        else
            usbkey_pop <= wr_q && (waddr_q == USBKEY_ADDR);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            led_ctrl         <= 1'b0;
            kbd_row          <= 8'hFF;
            led_green_bitmap <= 64'd0;
            led_red_bitmap   <= 64'd0;
            vga_hint_bitmap  <= 64'd0;
            vga_show_board   <= 1'b1;
            vga_red_green    <= 1'b0;
            vga_last_move    <= 7'd0;
        end else begin
            if (wr_q && waddr_q == LED_ADDR) begin
                led_ctrl <= wdata_q[0];
            end
            if (wr_q && waddr_q == KBD_ROW_ADDR) begin
                kbd_row <= wdata_q[7:0];
            end
            if (wr_q && waddr_q == LED_GREEN_LO_ADDR) begin
                led_green_bitmap[31:0] <= wdata_q;
            end
            if (wr_q && waddr_q == LED_GREEN_HI_ADDR) begin
                led_green_bitmap[63:32] <= wdata_q;
            end
            if (wr_q && waddr_q == LED_RED_LO_ADDR) begin
                led_red_bitmap[31:0] <= wdata_q;
            end
            if (wr_q && waddr_q == LED_RED_HI_ADDR) begin
                led_red_bitmap[63:32] <= wdata_q;
            end
            if (wr_q && waddr_q == VGA_HINT_LO_ADDR) begin
                vga_hint_bitmap[31:0] <= wdata_q;
            end
            if (wr_q && waddr_q == VGA_HINT_HI_ADDR) begin
                vga_hint_bitmap[63:32] <= wdata_q;
            end
            if (wr_q && waddr_q == VGA_CTRL_ADDR) begin
                vga_show_board <= wdata_q[0];
                vga_red_green  <= wdata_q[1];
            end
            if (wr_q && waddr_q == VGA_LAST_ADDR) begin
                vga_last_move <= wdata_q[6:0];
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
                VGA_HINT_LO_ADDR:  read_data <= vga_hint_bitmap[31:0];
                VGA_HINT_HI_ADDR:  read_data <= vga_hint_bitmap[63:32];
                VGA_CTRL_ADDR:     read_data <= {30'd0, vga_red_green, vga_show_board};
                VGA_LAST_ADDR:     read_data <= {25'd0, vga_last_move};
                default:           read_data <= 32'd0;
            endcase
        end
    end

endmodule