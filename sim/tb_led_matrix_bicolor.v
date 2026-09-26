`timescale 1ns / 1ps
// =============================================================================
// tb_led_matrix_bicolor.v - 赤/緑ドットマトリクス LED 駆動回路の単体テスト
// =============================================================================
// MMIO でフレームバッファを書き、各行の点灯時間中に
//   - 点灯している行が1本だけであること
//   - 列 (赤/緑) の出力がその行のフレームバッファと一致すること
// 行の切り替わりでは行・列とも全消灯 (ブランキング) になることを確認する。
//
//   iverilog -o sim/tb_led_matrix_bicolor.out sim/tb_led_matrix_bicolor.v src/led_matrix_bicolor.v
//   vvp sim/tb_led_matrix_bicolor.out
// =============================================================================

module tb_led_matrix_bicolor;

    localparam integer ROW_CYCLES   = 40;
    localparam integer BLANK_CYCLES = 5;

    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk;

    reg  [31:0] addr = 0;
    reg  [31:0] wdata = 0;
    reg         we = 0;
    wire [7:0]  row, col_r, col_g;

    led_matrix_bicolor #(
        .ROW_CYCLES(ROW_CYCLES), .BLANK_CYCLES(BLANK_CYCLES),
        .ROW_ACTIVE_LOW(1), .COL_ACTIVE_LOW(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .addr(addr), .write_data(wdata), .write_en(we),
        .row(row), .col_red(col_r), .col_grn(col_g)
    );

    task mmio_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk); addr = a; wdata = d; we = 1;
            @(negedge clk); we = 0;
        end
    endtask

    integer fail_count = 0;
    integer checks = 0;
    reg [63:0] exp_red, exp_grn;

    // 点灯中の行を毎クロック確認する
    wire [7:0] row_on = ~row;
    wire [7:0] red_on = ~col_r;
    wire [7:0] grn_on = ~col_g;
    integer ri;
    reg checking = 0;
    always @(posedge clk) if (checking) begin
        if (row_on == 8'd0) begin
            if (red_on != 0 || grn_on != 0) begin
                $display("FAIL: columns on while no row is on (%b %b)", red_on, grn_on);
                fail_count = fail_count + 1;
            end
        end else if ((row_on & (row_on - 8'd1)) != 0) begin
            $display("FAIL: more than one row on: %b", row_on);
            fail_count = fail_count + 1;
        end else begin
            for (ri = 0; ri < 8; ri = ri + 1)
                if (row_on[ri]) begin
                    if (red_on != exp_red[ri*8 +: 8] || grn_on != exp_grn[ri*8 +: 8]) begin
                        $display("FAIL: row %0d red=%b grn=%b expected red=%b grn=%b",
                                 ri, red_on, grn_on, exp_red[ri*8 +: 8], exp_grn[ri*8 +: 8]);
                        fail_count = fail_count + 1;
                    end
                    checks = checks + 1;
                end
        end
    end

    // 1フレームで各行が点灯したか
    reg [7:0] rows_seen;
    always @(posedge clk) if (checking) rows_seen = rows_seen | row_on;

    task check_frame(input [63:0] r, input [63:0] g, input [8*32-1:0] name);
        begin
            exp_red = r; exp_grn = g;
            mmio_write(32'h8000_0040, r[31:0]);
            mmio_write(32'h8000_0044, r[63:32]);
            mmio_write(32'h8000_0048, g[31:0]);
            mmio_write(32'h8000_004C, g[63:32]);
            // 書き込み途中の状態は検査しない: 1フレーム待ってから2フレーム検査
            repeat (ROW_CYCLES * 8 + 2) @(posedge clk);
            rows_seen = 0;
            checking = 1;
            repeat (ROW_CYCLES * 16) @(posedge clk);
            checking = 0;
            if (rows_seen != 8'hFF) begin
                $display("FAIL: %0s: not every row was lit (%b)", name, rows_seen);
                fail_count = fail_count + 1;
            end else begin
                $display("  checked: %0s", name);
            end
        end
    endtask

    initial begin
        $display("=== led_matrix_bicolor test ===");
        #100 rst_n = 1;
        exp_red = 0; exp_grn = 0;

        check_frame(64'd0, 64'd0, "all off");
        // オセロ初期配置相当: 赤2個・緑2個
        check_frame(64'h0000_0010_0800_0000, 64'h0000_0008_1000_0000, "initial position");
        check_frame(64'hFFFF_FFFF_FFFF_FFFF, 64'd0, "all red");
        check_frame(64'd0, 64'hFFFF_FFFF_FFFF_FFFF, "all green");
        check_frame(64'h8040_2010_0804_0201, 64'h0102_0408_1020_4080, "diagonals");

        // ブランキング: 行の切り替わり直後の BLANK_CYCLES は全消灯
        wait (dut.cnt == 0);
        @(posedge clk); #1;
        if (row !== 8'hFF || col_r !== 8'hFF || col_g !== 8'hFF) begin
            $display("FAIL: not blank right after a row change");
            fail_count = fail_count + 1;
        end else $display("  checked: blanking at row change");

        $display("\n=== Summary: %0d row-slot checks, %0d failed ===", checks, fail_count);
        if (fail_count == 0 && checks > 0) $display("ALL TESTS PASSED!");
        else                               $display("SOME TESTS FAILED!");
        $finish;
    end

endmodule
