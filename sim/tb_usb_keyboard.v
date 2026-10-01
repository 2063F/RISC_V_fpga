`timescale 1ns / 1ps
// =============================================================================
// tb_usb_keyboard.v - USB キーボード -> マス番号 変換回路の単体テスト
// =============================================================================
// usb_hid_host の出力 (12MHz 側) を直接与えて、64個のキーそれぞれが
// A1, A2, ..., H8 (番号 0..63) のイベントになること、押しっぱなしで連打に
// ならないこと、割り当ての無いキーやロールオーバーエラーを無視することを確かめる。
//
//   iverilog -o sim/tb_usb_keyboard.out sim/tb_usb_keyboard.v src/usb_keyboard.v
//   vvp sim/tb_usb_keyboard.out
// =============================================================================

module tb_usb_keyboard;

    reg clk = 0;      always #10 clk = ~clk;        // 50 MHz
    reg usbclk = 0;   always #41.667 usbclk = ~usbclk; // 12 MHz
    reg rst_n = 0;

    reg        report = 0;
    reg [1:0]  typ = 2'd1;
    reg [7:0]  mods = 0, k1 = 0, k2 = 0, k3 = 0, k4 = 0;
    reg        pop = 0;
    wire       key_valid, connected;
    wire [5:0] key_index;

    usb_keyboard dut (
        .clk(clk), .rst_n(rst_n), .pop(pop), .key_valid(key_valid),
        .key_index(key_index), .connected(connected),
        .usbclk(usbclk), .usb_report(report), .usb_typ(typ), .usb_mod(mods),
        .usb_key1(k1), .usb_key2(k2), .usb_key3(k3), .usb_key4(k4)
    );

    // 期待するキー割り当て (0..63 の順)。値は HID usage、
    // 'h100 | bit は修飾キーのビット (右Shift=bit5, 左Alt=bit2)
    reg [8:0] usage [0:63];
    initial begin
        // F1..F12
        usage[0]='h3A; usage[1]='h3B; usage[2]='h3C; usage[3]='h3D; usage[4]='h3E; usage[5]='h3F;
        usage[6]='h40; usage[7]='h41; usage[8]='h42; usage[9]='h43; usage[10]='h44; usage[11]='h45;
        // 1..0 - ^ yen BS
        usage[12]='h1E; usage[13]='h1F; usage[14]='h20; usage[15]='h21; usage[16]='h22; usage[17]='h23;
        usage[18]='h24; usage[19]='h25; usage[20]='h26; usage[21]='h27; usage[22]='h2D; usage[23]='h2E;
        usage[24]='h89; usage[25]='h2A;
        // q w e r t y u i o p @ [
        usage[26]='h14; usage[27]='h1A; usage[28]='h08; usage[29]='h15; usage[30]='h17; usage[31]='h1C;
        usage[32]='h18; usage[33]='h0C; usage[34]='h12; usage[35]='h13; usage[36]='h2F; usage[37]='h30;
        // a s d f g h j k l ; : ]
        usage[38]='h04; usage[39]='h16; usage[40]='h07; usage[41]='h09; usage[42]='h0A; usage[43]='h0B;
        usage[44]='h0D; usage[45]='h0E; usage[46]='h0F; usage[47]='h33; usage[48]='h34; usage[49]='h32;
        // z x c v b n m , . / ro RShift
        usage[50]='h1D; usage[51]='h1B; usage[52]='h06; usage[53]='h19; usage[54]='h05; usage[55]='h11;
        usage[56]='h10; usage[57]='h36; usage[58]='h37; usage[59]='h38; usage[60]='h87; usage[61]='h105;
        // LAlt Muhenkan
        usage[62]='h102; usage[63]='h8B;
    end

    integer fail_count = 0, pass_count = 0;

    // 1回分のレポートを送る (12MHz 側で1クロックのパルス)
    task send_report(input [7:0] m, input [7:0] a, input [7:0] b, input [7:0] c, input [7:0] d);
        begin
            @(negedge usbclk);
            mods = m; k1 = a; k2 = b; k3 = c; k4 = d; report = 1;
            @(negedge usbclk) report = 0;
            repeat (20) @(posedge clk);   // CPU 側へ渡るのを待つ
        end
    endtask

    task press_only(input [8:0] u);
        begin
            if (u[8]) send_report(8'd1 << u[2:0], 0, 0, 0, 0);
            else      send_report(0, u[7:0], 0, 0, 0);
        end
    endtask

    task do_pop;
        begin
            @(negedge clk) pop = 1;
            @(negedge clk) pop = 0;
            @(posedge clk); @(posedge clk);
        end
    endtask

    task expect_event(input [5:0] idx);
        begin
            if (key_valid === 1'b1 && key_index === idx) pass_count = pass_count + 1;
            else begin
                $display("  FAIL: expected event %0d, got valid=%b index=%0d", idx, key_valid, key_index);
                fail_count = fail_count + 1;
            end
            do_pop;
        end
    endtask

    task expect_none(input [8*32-1:0] name);
        begin
            if (key_valid === 1'b0) begin
                $display("  PASS: %0s", name);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %0s: unexpected event %0d", name, key_index);
                fail_count = fail_count + 1;
                do_pop;
            end
        end
    endtask

    integer i;
    initial begin
        $display("=== usb_keyboard test ===");
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // 1) 64個のキーを1つずつ押して離す
        for (i = 0; i < 64; i = i + 1) begin
            press_only(usage[i]);
            expect_event(i);
            send_report(0, 0, 0, 0, 0);
        end
        $display("  checked: all 64 keys map to A1..H8 in order");
        expect_none("no extra events");

        // 2) 押しっぱなし (同じレポートが続く) では1回だけ
        send_report(0, 8'h14, 0, 0, 0);   // Q
        send_report(0, 8'h14, 0, 0, 0);
        send_report(0, 8'h14, 0, 0, 0);
        expect_event(26);
        expect_none("held key does not repeat");
        // Q を押したまま W を追加
        send_report(0, 8'h14, 8'h1A, 0, 0);
        expect_event(27);
        expect_none("only the newly added key");
        send_report(0, 0, 0, 0, 0);

        // 3) 割り当ての無いキー (Enter, Space, 左Shift, 左Ctrl) は無視
        send_report(8'h03, 8'h28, 8'h2C, 0, 0);
        send_report(0, 0, 0, 0, 0);
        expect_none("unassigned keys ignored");

        // 4) ロールオーバーエラー (全部 0x01) は無視し、押下状態も崩さない
        send_report(0, 8'h04, 0, 0, 0);   // A
        expect_event(38);
        send_report(0, 8'h01, 8'h01, 8'h01, 8'h01);
        send_report(0, 8'h04, 0, 0, 0);   // A を押したまま
        expect_none("rollover error ignored");
        send_report(0, 0, 0, 0, 0);

        // 5) 同時に押された2キーは番号順に2つのイベント、CPU が読まなくても溜まる
        send_report(0, 8'h1D, 8'h3A, 0, 0);   // Z (50) と F1 (0)
        send_report(0, 0, 0, 0, 0);
        send_report(8'h04, 0, 0, 0, 0);       // 左Alt (62)
        send_report(0, 0, 0, 0, 0);
        expect_event(0);
        expect_event(50);
        expect_event(62);
        expect_none("queue drained");

        // 6) キーボードが外れたら押下状態を忘れる (付け直して押せば反応する)
        send_report(0, 8'h8B, 0, 0, 0);       // 無変換 (63)
        expect_event(63);
        typ = 2'd0; repeat (50) @(posedge clk);
        if (connected !== 1'b0) begin $display("  FAIL: connected should drop"); fail_count = fail_count + 1; end
        typ = 2'd1; repeat (50) @(posedge clk);
        send_report(0, 8'h8B, 0, 0, 0);
        expect_event(63);

        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED!");
        else                 $display("SOME TESTS FAILED!");
        $finish;
    end

endmodule
