`timescale 1ns / 1ps
// =============================================================================
// tb_othello_boot.v - Boots othello_embedded and captures its UART output.
// Debug-only testbench to diagnose the reboot loop seen on real hardware;
// not part of the regular regression suite.
// =============================================================================

module tb_othello_boot;

    parameter CLK_PERIOD  = 20;    // 50 MHz
    parameter BAUD_RATE   = 115200;
    parameter BIT_NS      = 1_000_000_000 / BAUD_RATE;
    parameter BIT_HALF_NS = BIT_NS / 2;

    reg        clk = 0;
    reg        rst_btn = 1;
    reg        user_btn = 0;
    wire [1:0] led;
    wire       uart_tx_pin;

    always #(CLK_PERIOD/2) clk = ~clk;

    fpga_top #(
        .INIT_FILE("examples/othello_embedded/othello.hex")
    ) uut (
        .clk      (clk),
        .rst_btn  (rst_btn),
        .user_btn (user_btn),
        .led      (led),
        .uart_tx  (uart_tx_pin),
        .uart_rx  (1'b1),
        .kbd_row  (),
        .kbd_col  (8'hFF)
    );

    task recv_byte;
        output [7:0] data;
        integer i;
        begin
            @(negedge uart_tx_pin);
            #(BIT_HALF_NS);
            data = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                data[i] = uart_tx_pin;
            end
            #(BIT_NS + BIT_HALF_NS);
        end
    endtask

    reg [7:0] rx_val;

    initial begin
        rst_btn = 1;
        repeat(5) @(posedge clk);
        rst_btn = 0;
        $display("=== othello_embedded boot capture ===");
    end

    initial begin
        while (1) begin
            recv_byte(rx_val);
            $write("%c", rx_val);
            $fflush(32'h8000_0001);
        end
    end

    initial begin
        #200_000_000; // 200ms
        $display("\n=== TIMEOUT (200ms) ===");
        $fflush(32'h8000_0001);
        $finish;
    end

endmodule
