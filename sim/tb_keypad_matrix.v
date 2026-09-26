`timescale 1ns / 1ps
// =============================================================================
// tb_keypad_matrix.v - 8x8 キーマトリクス走査回路の単体テスト
// =============================================================================
// スイッチの行列をモデル化し (押されたキーは、その行が Low のとき列を Low にする)、
// チャタリング・同時押し・読み出し(pop) を確認する。走査を速くするため
// ROW_CYCLES を小さくしている。
//
//   iverilog -o sim/tb_keypad_matrix.out sim/tb_keypad_matrix.v src/keypad_matrix.v
//   vvp sim/tb_keypad_matrix.out
// =============================================================================

module tb_keypad_matrix;

    localparam integer ROW_CYCLES = 20;
    localparam integer SCAN       = ROW_CYCLES * 8;  // 1回の全走査のクロック数

    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk;

    wire [7:0] row_n;
    wire [7:0] col_n;
    reg  [63:0] pressed = 64'd0;   // pressed[r*8+c]
    reg         pop = 0;
    wire        key_valid;
    wire [5:0]  key_index;

    // ---- スイッチ行列のモデル (行はハイインピーダンス時にプルアップ)
    wire [7:0] row_level;
    genvar r, c;
    generate
        for (r = 0; r < 8; r = r + 1) begin : g_r
            assign row_level[r] = (row_n[r] === 1'b0) ? 1'b0 : 1'b1;
        end
        for (c = 0; c < 8; c = c + 1) begin : g_c
            wire [7:0] hits;
            for (r = 0; r < 8; r = r + 1) begin : g_h
                assign hits[r] = pressed[r*8 + c] && !row_level[r];
            end
            assign col_n[c] = ~|hits;
        end
    endgenerate

    // 同時に Low を出す行は常に1本以下であること (出力同士の短絡防止)
    always @(posedge clk) begin
        if (rst_n && ((~row_level & (~row_level - 8'd1)) != 8'd0)) begin
            $display("FAIL: more than one row driven low: %b", row_n);
            fail_count = fail_count + 1;
        end
    end

    keypad_matrix #(.ROW_CYCLES(ROW_CYCLES), .STABLE_SCANS(3)) dut (
        .clk(clk), .rst_n(rst_n), .row_n(row_n), .col_n(col_n),
        .pop(pop), .key_valid(key_valid), .key_index(key_index)
    );

    integer fail_count = 0;
    integer pass_count = 0;

    task wait_scans(input integer n);
        begin
            repeat (n * SCAN) @(posedge clk);
        end
    endtask

    task do_pop;
        begin
            @(negedge clk) pop = 1;
            @(negedge clk) pop = 0;
        end
    endtask

    task expect_event(input [5:0] idx, input [8*40-1:0] name);
        begin
            if (key_valid === 1'b1 && key_index === idx) begin
                $display("  PASS: %0s -> key %0d", name, idx);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %0s: valid=%b index=%0d (expected %0d)", name, key_valid, key_index, idx);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task expect_none(input [8*40-1:0] name);
        begin
            if (key_valid === 1'b0) begin
                $display("  PASS: %0s -> no event", name);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %0s: unexpected event %0d", name, key_index);
                fail_count = fail_count + 1;
            end
        end
    endtask

    integer k;
    initial begin
        $display("=== keypad_matrix test ===");
        #100 rst_n = 1;
        wait_scans(5);
        expect_none("idle");

        // 1) 行3・列5 (key 29) をチャタリング付きで押す
        for (k = 0; k < 6; k = k + 1) begin
            pressed[29] = ~pressed[29];
            repeat (SCAN / 3) @(posedge clk);
        end
        pressed[29] = 1;
        wait_scans(6);
        expect_event(6'd29, "bouncy press of r3 c5");
        do_pop;
        wait_scans(6);
        expect_none("held key repeats nothing");
        pressed[29] = 0;
        wait_scans(6);
        expect_none("release");

        // 2) 隅のキー (key 0 と key 63)
        pressed[0] = 1;
        wait_scans(6);
        expect_event(6'd0, "r0 c0");
        do_pop;
        pressed[0] = 0;
        pressed[63] = 1;
        wait_scans(6);
        expect_event(6'd63, "r7 c7");
        do_pop;
        pressed[63] = 0;
        wait_scans(6);

        // 3) 2キー同時押し -> 小さい番号から順に2つの事象
        pressed[10] = 1;
        pressed[45] = 1;
        wait_scans(6);
        expect_event(6'd10, "simultaneous (1st)");
        do_pop;
        @(posedge clk); @(posedge clk);
        expect_event(6'd45, "simultaneous (2nd)");
        do_pop;
        @(posedge clk); @(posedge clk);
        expect_none("queue drained");
        pressed[10] = 0;
        pressed[45] = 0;
        wait_scans(6);

        // 4) CPU が読まない間に押した2つのキーも失われない
        pressed[7] = 1;  wait_scans(6); pressed[7] = 0;  wait_scans(6);
        pressed[56] = 1; wait_scans(6); pressed[56] = 0; wait_scans(6);
        expect_event(6'd7, "queued press (1st)");
        do_pop;
        @(posedge clk); @(posedge clk);
        expect_event(6'd56, "queued press (2nd)");
        do_pop;
        @(posedge clk); @(posedge clk);
        expect_none("queue drained again");

        // 5) 1走査より短いノイズは無視される
        pressed[20] = 1;
        repeat (SCAN / 2) @(posedge clk);
        pressed[20] = 0;
        wait_scans(6);
        expect_none("short glitch ignored");

        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED!");
        else                 $display("SOME TESTS FAILED!");
        $finish;
    end

endmodule
