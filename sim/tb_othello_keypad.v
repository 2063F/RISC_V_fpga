`timescale 1ns / 1ps
// =============================================================================
// tb_othello_keypad.v - fpga_top + オセロAI + キーマトリクス + ドットマトリクスLED
//                       の統合テスト
// =============================================================================
// UART で "b" を送って対局を始め、キーマトリクスの 行3・列2 (キー番号26 = 'q')
// を押すと、ボードが d3 に着手して "Your move: d3[q]" と表示することを確認する。
// ドットマトリクス LED のフレームバッファが、着手前後の盤面 (白=赤, 黒=緑,
// 8段目が LED の行1) になっていることも確認する。
// 走査を速くするため KEY_ROW_CYCLES / LED_ROW_CYCLES を小さくしている。
//
//   make -C othello_ai_c/othello_AI fpga
//   iverilog -I src -o sim/tb_othello_keypad.out sim/tb_othello_keypad.v src/*.v
//   vvp sim/tb_othello_keypad.out
// =============================================================================

module tb_othello_keypad;

    parameter CLK_PERIOD = 20;
    parameter BIT_NS     = 1_000_000_000 / 115200;

    reg  clk = 0;
    reg  rst_btn = 1;
    reg  uart_rx = 1;
    wire uart_tx;
    wire [1:0] led;
    wire [7:0] kbd_row_n;
    wire [7:0] kbd_col_n;
    wire [7:0] led_row, led_col_r, led_col_g;

    always #(CLK_PERIOD/2) clk = ~clk;

    fpga_top #(
        .INIT_FILE      ("othello_ai_c/othello_AI/othello_fpga.hex"),
        .KEY_ROW_CYCLES (50),
        .LED_ROW_CYCLES (100),
        .LED_BLANK_CYCLES (10)
    ) dut (
        .clk       (clk),
        .rst_btn   (rst_btn),
        .user_btn  (1'b0),
        .led       (led),
        .uart_tx   (uart_tx),
        .uart_rx   (uart_rx),
        .kbd_row_n (kbd_row_n),
        .kbd_col_n (kbd_col_n),
        .led_row   (led_row),
        .led_col_r (led_col_r),
        .led_col_g (led_col_g)
    );

    integer fail_count = 0;

    // LED の bit = (7 - 段) * 8 + 列  (段 0 = 1段目, 列 0 = a)
    function [63:0] led_bits4(input integer s0, input integer s1, input integer s2, input integer s3);
        begin
            led_bits4 = 0;
            if (s0 >= 0) led_bits4[(7 - s0/8)*8 + s0%8] = 1'b1;
            if (s1 >= 0) led_bits4[(7 - s1/8)*8 + s1%8] = 1'b1;
            if (s2 >= 0) led_bits4[(7 - s2/8)*8 + s2%8] = 1'b1;
            if (s3 >= 0) led_bits4[(7 - s3/8)*8 + s3%8] = 1'b1;
        end
    endfunction

    task check_led(input [63:0] exp_red, input [63:0] exp_grn, input [8*24-1:0] name);
        begin
            if (dut.dot_matrix.red === exp_red && dut.dot_matrix.grn === exp_grn)
                $display("\nPASS: LED shows %0s", name);
            else begin
                $display("\nFAIL: LED %0s: red=%h grn=%h expected red=%h grn=%h", name,
                         dut.dot_matrix.red, dut.dot_matrix.grn, exp_red, exp_grn);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ---- スイッチ行列のモデル
    reg [63:0] pressed = 64'd0;
    genvar r, c;
    generate
        for (c = 0; c < 8; c = c + 1) begin : g_c
            wire [7:0] hits;
            for (r = 0; r < 8; r = r + 1) begin : g_h
                assign hits[r] = pressed[r*8 + c] && (kbd_row_n[r] === 1'b0);
            end
            assign kbd_col_n[c] = ~|hits;
        end
    endgenerate

    // ---- UART 受信 (表示と、直近の行の記録)
    reg [8*64-1:0] line_buf = 0;
    reg [8*64-1:0] last_line = 0;
    integer line_len = 0;
    reg     saw_thinking = 0;   // "AI is thinking..." の行を受信した
    reg [7:0] rx_byte;
    integer k;
    always begin
        @(negedge uart_tx);
        #(BIT_NS / 2);
        for (k = 0; k < 8; k = k + 1) begin
            #(BIT_NS);
            rx_byte[k] = uart_tx;
        end
        #(BIT_NS);
        if (rx_byte == 8'h0A) begin
            $write("\n");
            if (line_buf[8*17-1:0] == "AI is thinking...") saw_thinking = 1;
            last_line = line_buf; line_buf = 0; line_len = 0;
        end else if (rx_byte != 8'h0D) begin
            $write("%c", rx_byte);
            line_buf = {line_buf[8*63-1:0], rx_byte};
            line_len = line_len + 1;
        end
        $fflush;
    end

    task send_byte(input [7:0] data);
        integer i;
        begin
            uart_rx = 0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin uart_rx = data[i]; #(BIT_NS); end
            uart_rx = 1; #(BIT_NS * 2);
        end
    endtask

    initial begin
        $display("=== Othello + key matrix integration test ===");
        #200 rst_btn = 0;

        wait (line_len == 2 && line_buf[15:0] == "> ");
        send_byte("b");
        send_byte(8'h0D);

        wait (line_len == 11 && line_buf[8*11-1:0] == "Your move: ");
        // 初期配置: 黒 = d5(35), e4(28) / 白 = d4(27), e5(36)
        check_led(led_bits4(27, 36, -1, -1), led_bits4(35, 28, -1, -1), "initial position");
        pressed[26] = 1;               // 行3・列2 = キー番号26 = 'q' = d3
        wait (line_len == 0);          // 着手表示の行が終わるまで待つ
        pressed[26] = 0;

        if (last_line[8*16-1:0] == "Your move: d3[q]") begin
            $display("\nPASS: key matrix press played d3");
        end else begin
            $display("\nFAIL: unexpected line");
            fail_count = fail_count + 1;
        end

        // d3 の後: 黒 = d3(19), d4(27), e4(28), d5(35) / 白 = e5(36)
        wait (saw_thinking);
        check_led(led_bits4(36, -1, -1, -1), led_bits4(19, 27, 28, 35), "position after d3");

        // 実際のピン: 走査中に行3(=盤面5段目)が点灯しているとき、
        // 赤 = e5 (列4)、緑 = d5 (列3) が Low (点灯) になっている
        wait (led_row == 8'b1111_0111 && led_col_r != 8'hFF);
        if (led_col_r == ~8'b0001_0000 && led_col_g == ~8'b0000_1000)
            $display("PASS: LED pins for row 3 (rank 5)");
        else begin
            $display("FAIL: LED pins row=%b red=%b grn=%b", led_row, led_col_r, led_col_g);
            fail_count = fail_count + 1;
        end

        if (fail_count == 0) $display("ALL TESTS PASSED!");
        else                 $display("SOME TESTS FAILED!");
        $finish;
    end

    initial begin
        #1_000_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
