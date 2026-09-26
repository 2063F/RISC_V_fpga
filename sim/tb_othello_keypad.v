`timescale 1ns / 1ps
// =============================================================================
// tb_othello_keypad.v - fpga_top + オセロAI + キーマトリクスの統合テスト
// =============================================================================
// UART で "b" を送って対局を始め、キーマトリクスの 行3・列2 (キー番号26 = 'q')
// を押すと、ボードが d3 に着手して "Your move: d3[q]" と表示することを確認する。
// 走査を速くするため KEY_ROW_CYCLES を小さくしている。
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

    always #(CLK_PERIOD/2) clk = ~clk;

    fpga_top #(
        .INIT_FILE      ("othello_ai_c/othello_AI/othello_fpga.hex"),
        .KEY_ROW_CYCLES (50)
    ) dut (
        .clk       (clk),
        .rst_btn   (rst_btn),
        .user_btn  (1'b0),
        .led       (led),
        .uart_tx   (uart_tx),
        .uart_rx   (uart_rx),
        .kbd_row_n (kbd_row_n),
        .kbd_col_n (kbd_col_n)
    );

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
        pressed[26] = 1;               // 行3・列2 = キー番号26 = 'q' = d3
        wait (line_len == 0);          // 着手表示の行が終わるまで待つ
        pressed[26] = 0;

        if (last_line[8*16-1:0] == "Your move: d3[q]") begin
            $display("\nPASS: key matrix press played d3");
            $display("ALL TESTS PASSED!");
        end else begin
            $display("\nFAIL: unexpected line");
            $display("SOME TESTS FAILED!");
        end
        $finish;
    end

    initial begin
        #1_000_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
