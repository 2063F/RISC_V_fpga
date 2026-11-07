`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_amo
// Description: Runs sim/amo_test.hex, a self-checking program for LR.W, SC.W
//              and every AMO*.W, twice side by side: on a one-hart cpu_top as
//              built, and on a two-hart one with BUS_STRESS wait states (hart
//              1 stays in reset there; the point is the SoC's multi-step
//              atomic sequence under random wait states).
//
//              The program keeps its own pass/fail counts (s0/s1) and the
//              number of the first failing check (s3), and sets gp = 0xD0E
//              when it has run to the end.
//////////////////////////////////////////////////////////////////////////////////

module tb_amo;

    parameter CLK_PERIOD = 20;

    reg clk = 0;
    reg rst_n = 0;

    always #(CLK_PERIOD/2) clk = ~clk;

    wire        done_a, done_b;
    wire [31:0] pass_a, fail_a, first_a;
    wire [31:0] pass_b, fail_b, first_b;

    amo_run #(.NUM_HARTS(1), .BUS_STRESS(0)) run_a (
        .clk(clk), .rst_n(rst_n), .done(done_a),
        .passed(pass_a), .failed(fail_a), .first_fail(first_a));
    amo_run #(.NUM_HARTS(2), .BUS_STRESS(1)) run_b (
        .clk(clk), .rst_n(rst_n), .done(done_b),
        .passed(pass_b), .failed(fail_b), .first_fail(first_b));

    initial begin
        $display("=== Atomics Testbench (amo_test.hex) ===");
        repeat (5) @(posedge clk);
        rst_n = 1;
        wait (done_a && done_b);
        #(CLK_PERIOD * 2);
        $display("  one hart              : %0d passed, %0d failed (first failing check %0d)",
                 pass_a, fail_a, first_a);
        $display("  two harts, wait states: %0d passed, %0d failed (first failing check %0d)",
                 pass_b, fail_b, first_b);
        if (fail_a == 0 && fail_b == 0 && pass_a > 0 && pass_a == pass_b)
            $display("ALL TESTS PASSED!");
        else
            $display("FAIL");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 200_000);
        $display("FAIL: timed out (done = %0d / %0d, passed = %0d / %0d)",
                 done_a, done_b, pass_a, pass_b);
        $finish;
    end

endmodule

module amo_run #(
    parameter integer NUM_HARTS  = 1,
    parameter integer BUS_STRESS = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    output wire        done,
    output wire [31:0] passed,
    output wire [31:0] failed,
    output wire [31:0] first_fail
);

    cpu_top #(
        .INIT_FILE  ("sim/amo_test.hex"),
        .NUM_HARTS  (NUM_HARTS),
        .BUS_STRESS (BUS_STRESS)
    ) uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (),
        .mem_write_data (),
        .mem_write_en   (),
        .mem_read_en    (),
        .mem_read_data  (32'd0),
        .uart_tx_pin    (),
        .uart_rx_pin    (1'b1),
        .debug_pc       (),
        .debug_x1       ()
    );

    assign passed     = uut.core0.regfile.regs[8];
    assign failed     = uut.core0.regfile.regs[9];
    assign first_fail = uut.core0.regfile.regs[19];
    assign done       = (uut.core0.regfile.regs[3] == 32'hD0E);

endmodule
