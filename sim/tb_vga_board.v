`timescale 1ns / 1ps
module tb_vga_board;

    reg clk = 0;
    reg rst_n = 0;
    reg [63:0] black_bitmap;
    reg [63:0] white_bitmap;
    wire vga_r, vga_g, vga_b, vga_hsync, vga_vsync;

    vga_board dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .black_bitmap (black_bitmap),
        .white_bitmap (white_bitmap),
        .hint_bitmap  (hint_bitmap),
        .last_move    (last_move),
        .show_board   (show_board),
        .red_green    (red_green),
        .text_we      (text_we),
        .text_waddr   (text_waddr),
        .text_wdata   (text_wdata),
        .vga_r        (vga_r),
        .vga_g        (vga_g),
        .vga_b        (vga_b),
        .vga_hsync    (vga_hsync),
        .vga_vsync    (vga_vsync)
    );

    always #10 clk = ~clk; // 50 MHz

    reg [63:0] hint_bitmap = 64'd0;
    reg [6:0]  last_move   = 7'd0;
    reg        show_board  = 1'b1;
    reg        red_green   = 1'b0;
    reg        text_we     = 1'b0;
    reg [11:0] text_waddr  = 12'd0;
    reg [7:0]  text_wdata  = 8'd0;

    // One character into the text RAM, as board_io would write it
    task put_char;
        input [4:0] row;
        input [6:0] col;
        input [7:0] ch;
        begin
            @(posedge clk);
            text_waddr <= {row, col};
            text_wdata <= ch;
            text_we    <= 1'b1;
            @(posedge clk);
            text_we    <= 1'b0;
        end
    endtask

    integer errors = 0;

    // Wait until the renderer is on pixel (x, y), then check the registered
    // color one clock later.
    task check_pixel;
        input [9:0] x;
        input [9:0] y;
        input [2:0] expect_rgb;
        input [8*24-1:0] what;
        begin
            wait (dut.h_cnt == x && dut.v_cnt == y && dut.pix_en);
            @(posedge clk);
            #1;
            if ({vga_r, vga_g, vga_b} !== expect_rgb) begin
                $display("FAIL: %0s (%0d,%0d) rgb=%b, expected %b",
                         what, x, y, {vga_r, vga_g, vga_b}, expect_rgb);
                errors = errors + 1;
            end
        end
    endtask

    // Sync timing measured in 50 MHz clocks (2 clocks per pixel).
    time t_hfall1, t_hfall2, t_hrise;
    time t_vfall1, t_vfall2, t_vrise;

    initial begin
        // Othello start position plus two corner markers:
        //   a1 (sq 0)  black -> top-left cell
        //   h8 (sq 63) white -> bottom-right cell
        black_bitmap = (64'h1 << 28) | (64'h1 << 35) | 64'h1;
        white_bitmap = (64'h1 << 27) | (64'h1 << 36) | (64'h1 << 63);
        hint_bitmap  = (64'h1 << 19);           // d3: a move the player can make
        last_move    = {1'b1, 6'd28};           // e4: the last move
        #55;
        rst_n = 1;
        // Text: 'A' at row 0 column 1 (white), 'H' at row 29 column 2
        // (yellow), and 'A' at row 5 column 20, under the board.
        put_char(5'd0,  7'd1,  8'h41);
        put_char(5'd29, 7'd2,  8'hC8);
        put_char(5'd5,  7'd20, 8'h41);

        // ---- HSYNC: 96 px low, 800 px period ----
        @(negedge vga_hsync); t_hfall1 = $time;
        @(posedge vga_hsync); t_hrise  = $time;
        @(negedge vga_hsync); t_hfall2 = $time;
        if ((t_hrise - t_hfall1) != 96 * 40) begin
            $display("FAIL: hsync low width %0t ns, expected %0d", t_hrise - t_hfall1, 96 * 40);
            errors = errors + 1;
        end
        if ((t_hfall2 - t_hfall1) != 800 * 40) begin
            $display("FAIL: hsync period %0t ns, expected %0d", t_hfall2 - t_hfall1, 800 * 40);
            errors = errors + 1;
        end

        // ---- VSYNC: 2 lines low, 525 lines period ----
        @(negedge vga_vsync); t_vfall1 = $time;
        @(posedge vga_vsync); t_vrise  = $time;
        @(negedge vga_vsync); t_vfall2 = $time;
        if ((t_vrise - t_vfall1) != 2 * 800 * 40) begin
            $display("FAIL: vsync low width %0t ns, expected %0d", t_vrise - t_vfall1, 2 * 800 * 40);
            errors = errors + 1;
        end
        if ((t_vfall2 - t_vfall1) != 525 * 800 * 40) begin
            $display("FAIL: vsync period %0t ns, expected %0d", t_vfall2 - t_vfall1, 525 * 800 * 40);
            errors = errors + 1;
        end

        // ---- Pixels, in scan order within one frame ----
        // Board origin (96,16), 56 px cells, row 0 on top.
        // Cell (cx, cy) centre = (96 + cx*56 + 28, 16 + cy*56 + 28).
        // Text. 'A' = font rows 0C 1E 33 33 3F 33 33 00 (bit 0 = left
        // pixel), each row two lines high; 'H' row 0 = 33.
        check_pixel(10'd10,  10'd0,   3'b111, "A row 0 lit");
        check_pixel(10'd12,  10'd0,   3'b000, "A row 0 dark");
        check_pixel(10'd8,   10'd8,   3'b111, "A row 4 lit");
        check_pixel(10'd20,  10'd44,  3'b000, "outside board");
        check_pixel(10'd124, 10'd44,  3'b000, "a1 black");
        check_pixel(10'd152, 10'd44,  3'b000, "grid line b1 left");
        check_pixel(10'd180, 10'd44,  3'b010, "b1 empty (green)");
        check_pixel(10'd162, 10'd80,  3'b010, "text under the board hidden");
        check_pixel(10'd292, 10'd140, 3'b010, "d3 hint, off the dot");
        check_pixel(10'd292, 10'd156, 3'b110, "d3 hint dot (yellow)");
        check_pixel(10'd292, 10'd212, 3'b111, "d4 white");
        check_pixel(10'd348, 10'd200, 3'b000, "e4 black, off the dot");
        check_pixel(10'd348, 10'd212, 3'b100, "e4 last move (red)");
        check_pixel(10'd269, 10'd245, 3'b010, "d5 corner off disc");
        check_pixel(10'd292, 10'd268, 3'b000, "d5 black");
        check_pixel(10'd348, 10'd268, 3'b111, "e5 white");
        check_pixel(10'd124, 10'd436, 3'b010, "a8 empty (green)");
        check_pixel(10'd516, 10'd436, 3'b111, "h8 white");
        check_pixel(10'd16,  10'd464, 3'b110, "H row 0 lit (yellow)");
        check_pixel(10'd124, 10'd470, 3'b000, "below board");
        check_pixel(10'd700, 10'd100, 3'b000, "h blanking (next frame)");

        // Text only: the board is gone and the text under it shows
        red_green = 1'b1;
        check_pixel(10'd180, 10'd44,  3'b001, "R/G: b1 empty (blue)");
        check_pixel(10'd292, 10'd156, 3'b110, "R/G: d3 hint dot (yellow)");
        check_pixel(10'd292, 10'd200, 3'b010, "R/G: d4 white -> green");
        check_pixel(10'd348, 10'd200, 3'b100, "R/G: e4 black -> red");
        check_pixel(10'd348, 10'd212, 3'b111, "R/G: e4 last move (white)");
        red_green = 1'b0;

        show_board = 1'b0;
        check_pixel(10'd162, 10'd80,  3'b111, "text where the board was");
        check_pixel(10'd292, 10'd212, 3'b000, "no board in text mode");

        if (errors == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

    // Safety timeout: a frame is 800*525*40 ns = 16.8 ms.
    initial begin
        #150_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
