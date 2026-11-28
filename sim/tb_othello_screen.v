`timescale 1ns / 1ps
// =============================================================================
// tb_othello_screen.v - The Othello program's VGA screen
// =============================================================================
// Runs examples/othello_embedded/othello.hex on a two-hart cpu_top with
// board_io and vga_board (fpga_top without the USB host and the LED matrix,
// which make the simulation slow), drives the 8x8 key matrix, and checks
// the text the program writes for the VGA screen, read back from
// vga_board's text RAM:
//
//   1. the menu: board hidden, "OTHELLO" and the menu lines on the screen
//   2. key 1 (level 1, you move first): board shown with red and green
//      stones, the title and a-h on row 0, 1-8 in column 10, ">Red You",
//      "2 discs", the level and the record on the left, the prompt on row 29, and the
//      four opening moves as hints
//
// Each screen is also printed, as 30 lines of text.
// =============================================================================

module tb_othello_screen;

    parameter CLK_PERIOD  = 20;
    parameter BIT_NS      = 1_000_000_000 / 115200;
    parameter BIT_HALF_NS = BIT_NS / 2;

    reg clk = 0;
    reg rst_n = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // CPU and its external bus, as in fpga_top
    wire [31:0] mem_addr, mem_write_data, mem_read_data;
    wire        mem_write_en, mem_read_en;
    wire        uart_tx_pin;

    cpu_top #(
        .INIT_FILE ("examples/othello_embedded/othello.hex"),
        .NUM_HARTS (2)
    ) cpu (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (mem_addr),
        .mem_write_data (mem_write_data),
        .mem_write_en   (mem_write_en),
        .mem_read_en    (mem_read_en),
        .mem_read_data  (mem_read_data),
        .uart_tx_pin    (uart_tx_pin),
        .uart_rx_pin    (1'b1),
        .debug_pc       (),
        .debug_x1       ()
    );

    // Key matrix: key N at row (N-1)/8, column (N-1)%8, both active-low
    reg  [6:0] key = 0;
    wire [7:0] kbd_row;
    wire [2:0] key_row = (key - 7'd1) >> 3;
    wire [2:0] key_col = (key - 7'd1);
    wire [7:0] kbd_col = (key != 0 && !kbd_row[key_row]) ? ~(8'd1 << key_col) : 8'hFF;

    wire [63:0] led_green_bitmap, led_red_bitmap, hint_bitmap;
    wire        show_board;
    wire        red_green;
    wire [6:0]  last_move;
    wire        text_we;
    wire [11:0] text_waddr;
    wire [7:0]  text_wdata;

    board_io io (
        .clk              (clk),
        .rst_n            (rst_n),
        .addr             (mem_addr),
        .write_data       (mem_write_data),
        .write_en         (mem_write_en),
        .read_en          (mem_read_en),
        .user_btn         (1'b0),
        .kbd_col          (kbd_col),
        .usbkey_valid     (1'b0),
        .usbkey_index     (6'd0),
        .usbkey_connected (1'b0),
        .usbkey_pop       (),
        .read_data        (mem_read_data),
        .led_ctrl         (),
        .kbd_row          (kbd_row),
        .led_green_bitmap (led_green_bitmap),
        .led_red_bitmap   (led_red_bitmap),
        .vga_hint_bitmap  (hint_bitmap),
        .vga_show_board   (show_board),
        .vga_red_green    (red_green),
        .vga_last_move    (last_move),
        .vga_text_we      (text_we),
        .vga_text_waddr   (text_waddr),
        .vga_text_wdata   (text_wdata)
    );

    vga_board vga (
        .clk          (clk),
        .rst_n        (rst_n),
        .black_bitmap (led_green_bitmap),
        .white_bitmap (led_red_bitmap),
        .hint_bitmap  (hint_bitmap),
        .last_move    (last_move),
        .show_board   (show_board),
        .red_green    (red_green),
        .text_we      (text_we),
        .text_waddr   (text_waddr),
        .text_wdata   (text_wdata),
        .vga_r (), .vga_g (), .vga_b (), .vga_hsync (), .vga_vsync ()
    );

    // -------------------------------------------------------------------------
    // UART capture (last 48 characters) and waiting for a line
    // -------------------------------------------------------------------------
    reg [8*48-1:0] tail = 0;
    reg [7:0]      data;
    event          got_char;
    integer        i;

    initial forever begin
        @(negedge uart_tx_pin);
        #(BIT_HALF_NS);
        for (i = 0; i < 8; i = i + 1) begin
            #(BIT_NS);
            data[i] = uart_tx_pin;
        end
        #(BIT_NS + BIT_HALF_NS);
        if (data != 8'h0D)               // uart.h sends "\r\n"; match on "\n" alone
                tail = {tail[8*47-1:0], data};
        -> got_char;
    end

    task wait_text(input [8*48-1:0] s, input integer n);
        reg [8*48-1:0] mask;
        begin
            mask = ({(8*48){1'b1}} >> (8*(48 - n)));
            while ((tail & mask) !== (s & mask))
                @(got_char);
        end
    endtask

    // -------------------------------------------------------------------------
    // The screen: print it, and look for a string on a row
    // -------------------------------------------------------------------------
    integer r, c, j, errors = 0;
    reg [7:0] ch;

    task show_screen;
        begin
            $display("+--------------------------------------------------------------------------------+");
            for (r = 0; r < 30; r = r + 1) begin
                $write("|");
                for (c = 0; c < 80; c = c + 1) begin
                    ch = vga.text_mem[r * 128 + c] & 8'h7F;
                    $write("%c", (ch < 8'd32) ? 8'd32 : ch);
                end
                $display("|");
            end
            $display("+--------------------------------------------------------------------------------+");
        end
    endtask

    // 1 if row r holds s (n characters) anywhere
    function row_has(input integer row, input [8*40-1:0] s, input integer n);
        integer col, k, ok;
        begin
            row_has = 0;
            for (col = 0; col + n <= 80; col = col + 1) begin
                ok = 1;
                for (k = 0; k < n; k = k + 1)
                    if ((vga.text_mem[row * 128 + col + k] & 8'h7F) != s[8*(n-1-k) +: 8])
                        ok = 0;
                if (ok) row_has = 1;
            end
        end
    endfunction

    task expect_row(input integer row, input [8*40-1:0] s, input integer n);
        begin
            if (!row_has(row, s, n)) begin
                $display("FAIL: row %0d lacks \"%0s\"", row, s);
                errors = errors + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // The test
    // -------------------------------------------------------------------------
    initial begin
        $display("=== Othello VGA screen testbench ===");
        repeat (5) @(posedge clk);
        rst_n = 1;

        // 1. The menu
        wait_text("a USB keyboard.\n", 16);
        #200_000;                          // the board_io / text RAM writes land
        show_screen;
        if (show_board !== 1'b0) begin
            $display("FAIL: the board is shown in the menu");
            errors = errors + 1;
        end
        expect_row(3,  "OTHELLO", 7);
        expect_row(6,  "1  vs AI, level 1 Settai", 24);
        expect_row(12, "7  Two players", 14);
        expect_row(16, "10  Time per move", 17);

        // 2. Key 1: level 1, you (Red) move first
        key = 7'd1;
        #4_000_000;
        key = 0;
        wait_text("type a square (e.g. d3).\n", 25);
        #200_000;
        show_screen;
        if (show_board !== 1'b1) begin
            $display("FAIL: the board is hidden in the game");
            errors = errors + 1;
        end
        if (red_green !== 1'b1) begin
            $display("FAIL: Red / Green but black and white stones");
            errors = errors + 1;
        end
        expect_row(0,  "OTHELLO", 7);
        for (j = 0; j < 8; j = j + 1) begin
            if ((vga.text_mem[15 + 7 * j] & 8'h7F) != "a" + j) begin
                $display("FAIL: no %c over column %0d", "a" + j, j);
                errors = errors + 1;
            end
            if ((vga.text_mem[((44 + 56 * j) / 16) * 128 + 10] & 8'h7F) != "1" + j) begin
                $display("FAIL: no %c beside row %0d", "1" + j, j);
                errors = errors + 1;
            end
        end
        expect_row(10, "Level 1", 7);
        expect_row(11, "Settai", 6);
        expect_row(12, "(for kids)", 10);
        expect_row(18, "Record", 6);
        expect_row(19, "Games 0", 7);
        expect_row(25, "-", 1);
        expect_row(3,  ">Red You", 8);
        expect_row(4,  "2 discs", 7);
        expect_row(7,  "Green AI", 8);
        expect_row(29, "Your move (Red)", 15);
        if (hint_bitmap !== ((64'h1 << 19) | (64'h1 << 26) | (64'h1 << 37) | (64'h1 << 44))) begin
            $display("FAIL: hints %h, expected d3 c4 f5 e6", hint_bitmap);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #1_000_000_000;                    // 1 s
        $display("FAIL: timed out");
        $finish;
    end

endmodule
