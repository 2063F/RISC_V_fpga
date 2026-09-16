`timescale 1ns / 1ps

module tb_board_io;

    reg clk;
    reg rst_n;
    reg user_btn;
    reg [31:0] addr;
    reg [31:0] write_data;
    reg write_en;
    reg read_en;
    wire [31:0] read_data;
    wire led_ctrl;

    board_io dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .addr       (addr),
        .write_data (write_data),
        .write_en   (write_en),
        .read_en    (read_en),
        .user_btn   (user_btn),
        .read_data  (read_data),
        .led_ctrl   (led_ctrl)
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

        #25;
        rst_n = 1;

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
        #1;
        if (read_data[0] !== 1'b1) begin
            $display("FAIL: button MMIO read did not reflect user_btn");
            $finish;
        end

        $display("ALL TESTS PASSED!");
        $finish;
    end

endmodule