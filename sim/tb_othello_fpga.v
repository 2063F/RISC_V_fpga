`timescale 1ns / 1ps
// =============================================================================
// tb_othello_fpga.v - オセロAI (othello_ai_c/othello_AI/othello_fpga.c) の CPU 統合テスト
// =============================================================================
// 起動メニューを受信したあと、UART から BESTMOVE コマンドを送り、
// 返ってきた "MOVE ..." 行を期待値と比較する。持ち時間を指定した探索が
// 時間内 (サイクルカウンタで計測) に応答するかも確認する。
//
//   iverilog -I src -o sim/tb_othello_fpga.out sim/tb_othello_fpga.v src/cpu_top.v ... (src/*.v)
//   vvp sim/tb_othello_fpga.out
// =============================================================================

module tb_othello_fpga;

    parameter CLK_PERIOD = 20;                         // 50 MHz
    parameter BIT_NS     = 1_000_000_000 / 115200;     // ~8680 ns

    reg  clk = 0;
    reg  rst_n = 0;
    reg  uart_rx_pin = 1;
    wire uart_tx_pin;

    always #(CLK_PERIOD/2) clk = ~clk;

    cpu_top #(
        .INIT_FILE("othello_ai_c/othello_AI/othello_fpga.hex")
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (),
        .mem_write_data (),
        .mem_write_en   (),
        .mem_read_en    (),
        .mem_read_data  (32'd0),
        .uart_tx_pin    (uart_tx_pin),
        .uart_rx_pin    (uart_rx_pin),
        .debug_pc       (),
        .debug_x1       ()
    );

    // ---------------------------------------------------------------- TX 受信
    // CPU の出力を常時デコードして表示し、直近の1行を line_buf に溜める
    reg [8*128-1:0] line_buf;
    reg [8*128-1:0] last_line;
    integer         line_len = 0;
    integer         lines_seen = 0;
    reg [7:0]       rx_byte;
    integer         k;

    always begin
        @(negedge uart_tx_pin);
        #(BIT_NS / 2);
        for (k = 0; k < 8; k = k + 1) begin
            #(BIT_NS);
            rx_byte[k] = uart_tx_pin;
        end
        #(BIT_NS);
        if (rx_byte == 8'h0A) begin
            $write("\n");
            last_line  = line_buf;
            line_buf   = 0;
            line_len   = 0;
            lines_seen = lines_seen + 1;
        end else if (rx_byte != 8'h0D) begin
            $write("%c", rx_byte);
            line_buf = {line_buf[8*127-1:0], rx_byte};
            line_len = line_len + 1;
        end
        $fflush;
    end

    // ---------------------------------------------------------------- RX 送信
    task send_byte(input [7:0] data);
        integer i;
        begin
            uart_rx_pin = 0;
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_pin = data[i];
                #(BIT_NS);
            end
            uart_rx_pin = 1;
            #(BIT_NS * 2);
        end
    endtask

    // 文字列を先頭から送る (Verilog の文字列は右詰めなので先頭の NUL は飛ばす)
    task send_str(input [8*96-1:0] s);
        integer i;
        begin
            for (i = 95; i >= 0; i = i - 1)
                if (s[i*8 +: 8] != 0) send_byte(s[i*8 +: 8]);
        end
    endtask

    // 「> 」プロンプトが出るまで待つ
    task wait_prompt;
        begin
            wait (line_len == 2 && line_buf[15:0] == "> ");
        end
    endtask

    integer fail_count = 0;
    time    t_sent;

    task check_bestmove(input [8*96-1:0] cmd, input [8*32-1:0] exp_prefix, input integer max_ms);
        integer before;
        begin
            wait_prompt;
            send_str(cmd);
            before = lines_seen;
            send_byte(8'h0D);
            // エコー行の改行が出た時点から MOVE 行の1文字目までを探索時間とみなす
            wait (lines_seen == before + 1);
            t_sent = $time;
            wait (line_len == 1);
            $display("  [search took %0d cycles]", ($time - t_sent) / CLK_PERIOD);
            if (($time - t_sent) > max_ms * 1_000_000) begin
                $display("  FAIL: took longer than %0d ms", max_ms);
                fail_count = fail_count + 1;
            end
            wait (lines_seen == before + 2);
            if (!match_prefix(last_line, exp_prefix)) begin
                $display("  FAIL: expected line to start with \"%0s\"", exp_prefix);
                fail_count = fail_count + 1;
            end else begin
                $display("  PASS");
            end
        end
    endtask

    // last_line は右詰めで行末が LSB 側にあるので、先頭を探して比較する
    function match_prefix(input [8*128-1:0] line, input [8*32-1:0] prefix);
        integer top, plen, i;
        begin
            top = 127;
            while (top > 0 && line[top*8 +: 8] == 0) top = top - 1;
            plen = 31;
            while (plen > 0 && prefix[plen*8 +: 8] == 0) plen = plen - 1;
            match_prefix = 1;
            for (i = 0; i <= plen; i = i + 1)
                if (line[(top - i)*8 +: 8] != prefix[(plen - i)*8 +: 8])
                    match_prefix = 0;
        end
    endfunction

    initial begin
        $display("=== Othello AI on RV32IM: CPU simulation ===");
        #100 rst_n = 1;

        // 期待値は同じソースを PC 上でビルドした結果 (OTHELLO_HOST_TEST) と一致させてある。
        // 初期局面 (黒番)、深さ3
        check_bestmove("BESTMOVE 0000000810000000 0000001008000000 b 3 99999 10", "MOVE d3 3.70 3 53", 99999);
        // 中盤局面 (黒番)、深さ4。PC版 engine_cli も c4 / 33.26
        check_bestmove("BESTMOVE 10201e0408480000 085260583014281c b 4 99999 10", "MOVE c4 33.26 4 1091", 99999);
        // 持ち時間 250ms 指定 (大会規定 0.309s 用の設定)。時間内に応答すること
        check_bestmove("BESTMOVE 0080402808080000 0040b81010100000 b 60 250 14", "MOVE ", 255);
        // 残り8マスの終盤。250ms 以内に完全読みして正確な石差 (PC版と同じ +14) を返すこと
        check_bestmove("BESTMOVE 84c898a60ba5c2e0 70306659f45a2d1f b 60 250 14", "MOVE e2 14.00 8", 255);

        if (fail_count == 0) $display("\nALL TESTS PASSED!");
        else                 $display("\nSOME TESTS FAILED! (%0d)", fail_count);
        $finish;
    end

    initial begin
        #3_000_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
