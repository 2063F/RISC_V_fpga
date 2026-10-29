`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_multicore
// Description: Runs examples/multicore_demo.hex on a two-hart cpu_top, twice
//              side by side: once as built, and once with BUS_STRESS adding
//              pseudo-random wait states on top of the arbitration. The demo
//              checks its own results (both harts hammering the bus, .rodata
//              in RAM, a 1000-round ping-pong between the harts, and an
//              inter-processor interrupt) and prints "ALL OK" when all pass.
//////////////////////////////////////////////////////////////////////////////////

module tb_multicore;

    parameter CLK_PERIOD = 20;

    reg clk = 0;
    reg rst_n = 0;

    always #(CLK_PERIOD/2) clk = ~clk;

    wire done_plain, ok_plain;
    wire done_stress, ok_stress;

    multicore_run #(.BUS_STRESS(0)) plain  (.clk(clk), .rst_n(rst_n), .done(done_plain),  .ok(ok_plain));
    multicore_run #(.BUS_STRESS(1)) stress (.clk(clk), .rst_n(rst_n), .done(done_stress), .ok(ok_stress));

    initial begin
        $display("=== Two-hart Testbench (multicore_demo.c) ===");
        repeat (5) @(posedge clk);
        rst_n = 1;
        wait (done_plain && done_stress);
        #(CLK_PERIOD * 10);
        $display("\n--- checks ---");
        $display("  %0s  as built", ok_plain  ? "PASS" : "FAIL");
        $display("  %0s  with bus wait states", ok_stress ? "PASS" : "FAIL");
        if (ok_plain && ok_stress)
            $display("ALL TESTS PASSED!");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 5_000_000);
        $display("\nFAIL: timed out (as built done = %0d, with wait states done = %0d)",
                 done_plain, done_stress);
        $finish;
    end

endmodule

// One two-hart CPU running the demo, with its UART output captured. done goes
// high on "ALL OK" or "SOME FAILED"; ok says which.
module multicore_run #(
    parameter integer BUS_STRESS = 0
) (
    input  wire clk,
    input  wire rst_n,
    output reg  done = 0,
    output reg  ok = 0
);

    parameter BIT_NS      = 1_000_000_000 / 115200;
    parameter BIT_HALF_NS = BIT_NS / 2;

    wire uart_tx_pin;

    cpu_top #(
        .INIT_FILE  ("examples/multicore_demo.hex"),
        .NUM_HARTS  (2),
        .BUS_STRESS (BUS_STRESS)
    ) uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (),
        .mem_write_data (),
        .mem_write_en   (),
        .mem_read_en    (),
        .mem_read_data  (32'd0),
        .uart_tx_pin    (uart_tx_pin),
        .uart_rx_pin    (1'b1),
        .debug_pc       (),
        .debug_x1       ()
    );

    // The last 16 characters received, newest in the low byte.
    reg [8*16-1:0] tail = 0;
    reg [7:0]      data;
    integer        i;

    initial begin
        forever begin
            @(negedge uart_tx_pin);
            #(BIT_HALF_NS);
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                data[i] = uart_tx_pin;
            end
            #(BIT_NS + BIT_HALF_NS);
            if (BUS_STRESS == 0)
                $write("%c", data);
            tail = {tail[8*15-1:0], data};
            if (tail[8*6-1:0] == "ALL OK") begin
                ok   = 1;
                done = 1;
            end else if (tail[8*6-1:0] == "FAILED") begin
                done = 1;
            end
        end
    end

endmodule
