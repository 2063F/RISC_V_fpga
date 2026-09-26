`timescale 1ns / 1ps
// =============================================================================
// keypad_matrix.v - 8x8 key switch matrix scanner
// =============================================================================
// Wiring (active low, no external resistors needed):
//   row_n[r] : FPGA output. Driven 0 only while row r is being scanned and left
//              high-impedance otherwise (the pad's pull-up keeps it high), so
//              pressing several keys at once can never short two outputs.
//   col_n[c] : FPGA input with the pad pull-up enabled. Reads 0 when the key at
//              (row r, col c) is pressed while row r is being scanned.
//   With diodes (for n-key rollover), put the cathode on the row side.
//
// Key index = row * 8 + col (0..63). One key press (release -> press after
// debouncing) produces one event. Events are held one at a time in
// key_valid/key_index until the CPU pops them; presses that arrive meanwhile
// wait in a 64-bit pending set, so nothing is lost while the CPU is busy
// (a key pressed again before its first event is popped counts once).
//
// Timing at 50 MHz with the defaults: each row is driven for 0.5 ms, a full
// scan takes 4 ms, and a key must read the same for STABLE_SCANS consecutive
// full scans (12 ms) before it counts, which filters out contact bounce.
// =============================================================================

module keypad_matrix #(
    parameter integer ROW_CYCLES   = 25000, // clocks per row (0.5 ms @ 50 MHz)
    parameter integer STABLE_SCANS = 3      // identical scans needed to accept
) (
    input  wire       clk,
    input  wire       rst_n,
    output wire [7:0] row_n,
    input  wire [7:0] col_n,
    input  wire       pop,        // one-cycle pulse: consume the current event
    output reg        key_valid,
    output reg  [5:0] key_index
);

    // ---------------------------------------------------------------- scanning
    reg [2:0]  row;
    reg [31:0] row_cnt;

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : g_row
            assign row_n[g] = (row == g) ? 1'b0 : 1'bz;
        end
    endgenerate

    // Two-flop synchroniser for the asynchronous column inputs
    reg [7:0] col_s1, col_s2;
    always @(posedge clk) begin
        col_s1 <= col_n;
        col_s2 <= col_s1;
    end

    wire row_end = (row_cnt == ROW_CYCLES - 1);

    reg  [63:0] scan_cur;   // rows 0..6 of the scan in progress
    wire [63:0] scan_full = {~col_s2, scan_cur[55:0]}; // complete when row == 7

    reg  [63:0] scan_prev;  // previous complete scan
    reg  [7:0]  same_count; // consecutive identical complete scans
    reg  [63:0] stable;     // debounced key state (1 = pressed)
    reg  [63:0] pending;    // pressed but not yet reported

    wire scan_done = row_end && (row == 3'd7);
    wire accept    = scan_done && (scan_full == scan_prev) &&
                     (same_count >= STABLE_SCANS - 1);

    // Lowest set bit of pending
    reg  [5:0] first_idx;
    integer i;
    always @(*) begin
        first_idx = 6'd0;
        for (i = 63; i >= 0; i = i - 1)
            if (pending[i]) first_idx = i;
    end

    wire [63:0] pending_add = accept ? (scan_full & ~stable) : 64'd0;
    wire        take        = (!key_valid || pop) && (pending != 64'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            row        <= 3'd0;
            row_cnt    <= 32'd0;
            scan_cur   <= 64'd0;
            scan_prev  <= 64'd0;
            same_count <= 8'd0;
            stable     <= 64'd0;
            pending    <= 64'd0;
            key_valid  <= 1'b0;
            key_index  <= 6'd0;
        end else begin
            // ---- scan: sample the columns at the end of each row's slot
            if (row_end) begin
                row_cnt <= 32'd0;
                row     <= row + 3'd1;
                scan_cur[row*8 +: 8] <= ~col_s2;
            end else begin
                row_cnt <= row_cnt + 32'd1;
            end

            // ---- debounce: accept a scan once it repeats STABLE_SCANS times
            if (scan_done) begin
                scan_prev <= scan_full;
                if (scan_full != scan_prev)       same_count <= 8'd0;
                else if (same_count != 8'hFF)     same_count <= same_count + 8'd1;
                if (accept) stable <= scan_full;
            end

            // ---- event queue: one visible event, the rest in pending
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
