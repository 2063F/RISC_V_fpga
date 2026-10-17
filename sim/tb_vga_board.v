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
        .vga_r        (vga_r),
        .vga_g        (vga_g),
        .vga_b        (vga_b),
        .vga_hsync    (vga_hsync),
        .vga_vsync    (vga_vsync)
    );

    always #10 clk = ~clk; // 50 MHz

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
        #55;
        rst_n = 1;

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
        check_pixel(10'd20,  10'd44,  3'b000, "outside board");
        check_pixel(10'd124, 10'd44,  3'b000, "a1 black");
        check_pixel(10'd152, 10'd44,  3'b000, "grid line b1 left");
        check_pixel(10'd180, 10'd44,  3'b010, "b1 empty (green)");
        check_pixel(10'd292, 10'd212, 3'b111, "d4 white");
        check_pixel(10'd348, 10'd212, 3'b000, "e4 black");
        check_pixel(10'd269, 10'd245, 3'b010, "d5 corner off disc");
        check_pixel(10'd292, 10'd268, 3'b000, "d5 black");
        check_pixel(10'd348, 10'd268, 3'b111, "e5 white");
        check_pixel(10'd124, 10'd436, 3'b010, "a8 empty (green)");
        check_pixel(10'd516, 10'd436, 3'b111, "h8 white");
        check_pixel(10'd124, 10'd470, 3'b000, "below board");
        check_pixel(10'd700, 10'd100, 3'b000, "h blanking");

        if (errors == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

    // Safety timeout: a frame is 800*525*40 ns = 16.8 ms.
    initial begin
        #80_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
