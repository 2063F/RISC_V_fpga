`timescale 1ns / 1ps
module tb_led_matrix;

    reg clk = 0;
    reg rst_n = 0;
    reg [63:0] green_bitmap;
    reg [63:0] red_bitmap;
    wire [7:0] led_row;
    wire [7:0] led_col_g;
    wire [7:0] led_col_r;

    led_matrix dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .green_bitmap (green_bitmap),
        .red_bitmap   (red_bitmap),
        .led_row      (led_row),
        .led_col_g    (led_col_g),
        .led_col_r    (led_col_r)
    );

    always #10 clk = ~clk;

    integer dots_checked;
    integer i;
    reg [5:0] expect_dot;

    initial begin
        rst_n = 0;
        // dot 0  = row0,col0 -> GREEN
        // dot 31 = row3,col7 -> RED
        green_bitmap = 64'h1;
        red_bitmap   = (64'h1 << 31);
        #25;
        rst_n = 1;

        dots_checked = 0;
        for (i = 0; i < 64; i = i + 1) begin
            expect_dot = i[5:0];
            // Wait until dut is scanning this dot: row matches and, since
            // rows repeat every 8 dots, use the internal dot_idx directly
            // to unambiguously identify the scan step.
            wait (dut.dot_idx == expect_dot);
            #1; // let the combinational outputs settle after dot_idx changes

            if (led_row !== (8'b1 << dut.row_idx)) begin
                $display("FAIL: dot %0d led_row = %b, expected one-hot for row %0d", i, led_row, dut.row_idx);
                $finish;
            end

            if (expect_dot == 6'd0) begin
                if (led_col_g !== ~(8'h01)) begin
                    $display("FAIL: dot0 led_col_g = %b, expected %b", led_col_g, ~(8'h01));
                    $finish;
                end
                if (led_col_r !== 8'hFF) begin
                    $display("FAIL: dot0 led_col_r should be dark, got %b", led_col_r);
                    $finish;
                end
                dots_checked = dots_checked + 1;
            end else if (expect_dot == 6'd31) begin
                if (led_col_r !== ~(8'h80)) begin
                    $display("FAIL: dot31 led_col_r = %b, expected %b", led_col_r, ~(8'h80));
                    $finish;
                end
                if (led_col_g !== 8'hFF) begin
                    $display("FAIL: dot31 led_col_g should be dark, got %b", led_col_g);
                    $finish;
                end
                dots_checked = dots_checked + 1;
            end else begin
                if (led_col_g !== 8'hFF || led_col_r !== 8'hFF) begin
                    $display("FAIL: dot%0d should be fully dark, got g=%b r=%b", i, led_col_g, led_col_r);
                    $finish;
                end
            end

            wait (dut.dot_idx != expect_dot);
        end

        if (dots_checked !== 2) begin
            $display("FAIL: expected to check 2 lit dots, saw %0d", dots_checked);
            $finish;
        end

        $display("ALL TESTS PASSED!");
        $finish;
    end

    // Safety timeout: one full refresh cycle is 64 * 2^12 clk periods
    // (~5.24ms at 20ns/clk).
    initial begin
        #10_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
