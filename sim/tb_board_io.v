`timescale 1ns / 1ps

module tb_board_io;

    reg clk;
    reg rst_n;
    reg user_btn;
    reg [31:0] addr;
    reg [31:0] write_data;
    reg write_en;
    reg read_en;
    reg [7:0] kbd_col;
    wire [31:0] read_data;
    wire led_ctrl;
    wire [7:0] kbd_row;
    wire [63:0] led_green_bitmap;
    wire [63:0] led_red_bitmap;

    board_io dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .addr       (addr),
        .write_data (write_data),
        .write_en   (write_en),
        .read_en    (read_en),
        .user_btn   (user_btn),
        .kbd_col    (kbd_col),
        .usbkey_valid     (1'b0),
        .usbkey_index     (6'd0),
        .usbkey_connected (1'b0),
        .usbkey_pop       (),
        .read_data  (read_data),
        .led_ctrl   (led_ctrl),
        .kbd_row    (kbd_row),
        .led_green_bitmap (led_green_bitmap),
        .led_red_bitmap   (led_red_bitmap)
    );

    always #10 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        user_btn = 0;
        addr = 32'd0;
        write_data = 32'd0;
        write_en = 0;
        read_en = 0;
        kbd_col = 8'hFF;

        #25;
        rst_n = 1;

        if (kbd_row !== 8'hFF) begin
            $display("FAIL: kbd_row reset value should be 0xFF (idle)");
            $finish;
        end

        addr = 32'h8000_0020;
        write_data = 32'd1;
        write_en = 1;
        @(posedge clk);
        #1;
        write_en = 0;
        if (led_ctrl !== 1'b1) begin
            $display("FAIL: LED MMIO write did not set led_ctrl");
            $finish;
        end

        addr = 32'h8000_0024;
        read_en = 1;
        user_btn = 1;
        @(posedge clk);   // read data is registered: valid one clock later
        #1;
        if (read_data[0] !== 1'b1) begin
            $display("FAIL: button MMIO read did not reflect user_btn");
            $finish;
        end

        read_en = 0;

        // Keyboard ROW write: select row 3
        addr = 32'h8000_0028;
        write_data = 32'hFFFF_FFF7; // row 3 driven low (~(1<<3) & 0xFF = 0xF7)
        write_en = 1;
        @(posedge clk);
        #1;
        write_en = 0;
        if (kbd_row !== 8'hF7) begin
            $display("FAIL: kbd_row did not update to 0xF7, got %h", kbd_row);
            $finish;
        end

        // Keyboard COL read: column 5 pulled low (key pressed)
        addr = 32'h8000_002C;
        read_en = 1;
        kbd_col = 8'hDF; // ~(1<<5) & 0xFF
        #1;
        if (read_data[7:0] !== 8'hDF) begin
            $display("FAIL: keyboard COL MMIO read did not reflect kbd_col");
            $finish;
        end
        read_en = 0;

        // LED matrix GREEN bitmap: write low/high halves, read back
        addr = 32'h8000_0030;
        write_data = 32'hDEAD_BEEF;
        write_en = 1;
        @(posedge clk);
        #1;
        addr = 32'h8000_0034;
        write_data = 32'h1234_5678;
        @(posedge clk);
        #1;
        write_en = 0;
        if (led_green_bitmap !== {32'h1234_5678, 32'hDEAD_BEEF}) begin
            $display("FAIL: led_green_bitmap = %h, expected 12345678DEADBEEF", led_green_bitmap);
            $finish;
        end

        // LED matrix RED bitmap: write low/high halves, read back
        addr = 32'h8000_0038;
        write_data = 32'hCAFE_BABE;
        write_en = 1;
        @(posedge clk);
        #1;
        addr = 32'h8000_003C;
        write_data = 32'h0000_0001;
        @(posedge clk);
        #1;
        write_en = 0;
        if (led_red_bitmap !== {32'h0000_0001, 32'hCAFE_BABE}) begin
            $display("FAIL: led_red_bitmap = %h, expected 00000001CAFEBABE", led_red_bitmap);
            $finish;
        end

        addr = 32'h8000_0030;
        read_en = 1;
        #1;
        if (read_data !== 32'hDEAD_BEEF) begin
            $display("FAIL: LED_GREEN_LO readback = %h", read_data);
            $finish;
        end
        read_en = 0;

        $display("ALL TESTS PASSED!");
        $finish;
    end

endmodule