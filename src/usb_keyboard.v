`timescale 1ns / 1ps
// =============================================================================
// usb_keyboard.v - USB keyboard (usb_hid_host) -> Othello square key events
// =============================================================================
// Takes the boot-protocol keyboard report from usb_hid_host (12 MHz domain),
// moves it to the CPU clock domain and turns every newly pressed key that has a
// square assigned into one event, using the same event format as
// keypad_matrix.v (key index 0..63 = A1, A2, ..., A8, B1, ..., H8).
//
// Key assignment (Japanese / JIS keyboard, in index order):
//   0-11  : F1 ... F12
//   12-25 : 1 2 3 4 5 6 7 8 9 0 - ^ \ (yen) Backspace
//   26-37 : Q W E R T Y U I O P @ [
//   38-49 : A S D F G H J K L ; : ]
//   50-61 : Z X C V B N M , . / \ (ro) Right-Shift
//   62-63 : Left-Alt  Muhenkan
// Keys not listed are ignored. Holding a key produces one event; release and
// press again for another. Reports with the "phantom" rollover error code are
// ignored.
// =============================================================================

module usb_keyboard (
    // CPU clock domain
    input  wire        clk,
    input  wire        rst_n,
    input  wire        pop,          // one-cycle pulse: consume the current event
    output reg         key_valid,
    output reg  [5:0]  key_index,
    output wire        connected,    // a keyboard is attached

    // usb_hid_host outputs (usbclk domain)
    input  wire        usbclk,
    input  wire        usb_report,   // pulse: new report
    input  wire [1:0]  usb_typ,      // 1 = keyboard
    input  wire [7:0]  usb_mod,      // modifier bits
    input  wire [7:0]  usb_key1,
    input  wire [7:0]  usb_key2,
    input  wire [7:0]  usb_key3,
    input  wire [7:0]  usb_key4
);

    // ---------------------------------------------------------------- usbclk domain
    // Snapshot the report and flip a toggle. The snapshot then stays still until
    // the next report (milliseconds later), long enough for the CPU domain to
    // read it after synchronising the toggle.
    reg [39:0] snap;
    reg        snap_toggle = 1'b0;

    always @(posedge usbclk) begin
        if (usb_report && usb_typ == 2'd1 && usb_key1 != 8'h01) begin
            snap        <= {usb_mod, usb_key1, usb_key2, usb_key3, usb_key4};
            snap_toggle <= ~snap_toggle;
        end
    end

    // ---------------------------------------------------------------- CPU domain
    reg [2:0] tog_sync = 3'd0;
    reg [1:0] kbd_sync = 2'd0;
    always @(posedge clk) begin
        tog_sync <= {tog_sync[1:0], snap_toggle};
        kbd_sync <= {kbd_sync[0], usb_typ == 2'd1};
    end
    assign connected = kbd_sync[1];
    wire new_report = tog_sync[2] ^ tog_sync[1];

    // HID usage ID -> square index (bit 6 = assigned)
    function [6:0] usage_to_index(input [7:0] u);
        begin
            case (u)
                8'h3A: usage_to_index = {1'b1, 6'd0};   // F1
                8'h3B: usage_to_index = {1'b1, 6'd1};   // F2
                8'h3C: usage_to_index = {1'b1, 6'd2};   // F3
                8'h3D: usage_to_index = {1'b1, 6'd3};   // F4
                8'h3E: usage_to_index = {1'b1, 6'd4};   // F5
                8'h3F: usage_to_index = {1'b1, 6'd5};   // F6
                8'h40: usage_to_index = {1'b1, 6'd6};   // F7
                8'h41: usage_to_index = {1'b1, 6'd7};   // F8
                8'h42: usage_to_index = {1'b1, 6'd8};   // F9
                8'h43: usage_to_index = {1'b1, 6'd9};   // F10
                8'h44: usage_to_index = {1'b1, 6'd10};  // F11
                8'h45: usage_to_index = {1'b1, 6'd11};  // F12
                8'h1E: usage_to_index = {1'b1, 6'd12};  // 1
                8'h1F: usage_to_index = {1'b1, 6'd13};  // 2
                8'h20: usage_to_index = {1'b1, 6'd14};  // 3
                8'h21: usage_to_index = {1'b1, 6'd15};  // 4
                8'h22: usage_to_index = {1'b1, 6'd16};  // 5
                8'h23: usage_to_index = {1'b1, 6'd17};  // 6
                8'h24: usage_to_index = {1'b1, 6'd18};  // 7
                8'h25: usage_to_index = {1'b1, 6'd19};  // 8
                8'h26: usage_to_index = {1'b1, 6'd20};  // 9
                8'h27: usage_to_index = {1'b1, 6'd21};  // 0
                8'h2D: usage_to_index = {1'b1, 6'd22};  // -
                8'h2E: usage_to_index = {1'b1, 6'd23};  // ^
                8'h89: usage_to_index = {1'b1, 6'd24};  // yen (International 3)
                8'h2A: usage_to_index = {1'b1, 6'd25};  // Backspace
                8'h14: usage_to_index = {1'b1, 6'd26};  // Q
                8'h1A: usage_to_index = {1'b1, 6'd27};  // W
                8'h08: usage_to_index = {1'b1, 6'd28};  // E
                8'h15: usage_to_index = {1'b1, 6'd29};  // R
                8'h17: usage_to_index = {1'b1, 6'd30};  // T
                8'h1C: usage_to_index = {1'b1, 6'd31};  // Y
                8'h18: usage_to_index = {1'b1, 6'd32};  // U
                8'h0C: usage_to_index = {1'b1, 6'd33};  // I
                8'h12: usage_to_index = {1'b1, 6'd34};  // O
                8'h13: usage_to_index = {1'b1, 6'd35};  // P
                8'h2F: usage_to_index = {1'b1, 6'd36};  // @
                8'h30: usage_to_index = {1'b1, 6'd37};  // [
                8'h04: usage_to_index = {1'b1, 6'd38};  // A
                8'h16: usage_to_index = {1'b1, 6'd39};  // S
                8'h07: usage_to_index = {1'b1, 6'd40};  // D
                8'h09: usage_to_index = {1'b1, 6'd41};  // F
                8'h0A: usage_to_index = {1'b1, 6'd42};  // G
                8'h0B: usage_to_index = {1'b1, 6'd43};  // H
                8'h0D: usage_to_index = {1'b1, 6'd44};  // J
                8'h0E: usage_to_index = {1'b1, 6'd45};  // K
                8'h0F: usage_to_index = {1'b1, 6'd46};  // L
                8'h33: usage_to_index = {1'b1, 6'd47};  // ;
                8'h34: usage_to_index = {1'b1, 6'd48};  // :
                8'h32: usage_to_index = {1'b1, 6'd49};  // ] (JIS keyboards send Non-US #)
                8'h31: usage_to_index = {1'b1, 6'd49};  // ] (some send Backslash)
                8'h1D: usage_to_index = {1'b1, 6'd50};  // Z
                8'h1B: usage_to_index = {1'b1, 6'd51};  // X
                8'h06: usage_to_index = {1'b1, 6'd52};  // C
                8'h19: usage_to_index = {1'b1, 6'd53};  // V
                8'h05: usage_to_index = {1'b1, 6'd54};  // B
                8'h11: usage_to_index = {1'b1, 6'd55};  // N
                8'h10: usage_to_index = {1'b1, 6'd56};  // M
                8'h36: usage_to_index = {1'b1, 6'd57};  // ,
                8'h37: usage_to_index = {1'b1, 6'd58};  // .
                8'h38: usage_to_index = {1'b1, 6'd59};  // /
                8'h87: usage_to_index = {1'b1, 6'd60};  // ro (International 1)
                // 61: Right Shift and 62: Left Alt come from the modifier byte
                8'h8B: usage_to_index = {1'b1, 6'd63};  // Muhenkan (International 5)
                default: usage_to_index = 7'd0;
            endcase
        end
    endfunction

    function [63:0] key_bit(input [7:0] u);
        reg [6:0] m;
        begin
            m = usage_to_index(u);
            key_bit = m[6] ? (64'd1 << m[5:0]) : 64'd0;
        end
    endfunction

    // Keys held in the latest report (stable while new_report is high, see above)
    wire [7:0]  s_mod = snap[39:32];
    wire [63:0] held  = key_bit(snap[31:24]) | key_bit(snap[23:16]) |
                        key_bit(snap[15:8])  | key_bit(snap[7:0])   |
                        ({63'd0, s_mod[5]} << 61) |   // Right Shift
                        ({63'd0, s_mod[2]} << 62);    // Left Alt

    reg  [63:0] prev;      // keys held in the previous report
    reg  [63:0] pending;   // pressed but not yet reported

    wire [63:0] pending_add = new_report ? (held & ~prev) : 64'd0;

    reg [5:0] first_idx;
    integer i;
    always @(*) begin
        first_idx = 6'd0;
        for (i = 63; i >= 0; i = i - 1)
            if (pending[i]) first_idx = i;
    end

    wire take = (!key_valid || pop) && (pending != 64'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            prev      <= 64'd0;
            pending   <= 64'd0;
            key_valid <= 1'b0;
            key_index <= 6'd0;
        end else begin
            if (!connected)      prev <= 64'd0;
            else if (new_report) prev <= held;

            if (take) begin
                key_valid <= 1'b1;
                key_index <= first_idx;
                pending   <= (pending & ~(64'd1 << first_idx)) | pending_add;
            end else begin
                if (pop) key_valid <= 1'b0;
                pending <= pending | pending_add;
            end
        end
    end

endmodule
