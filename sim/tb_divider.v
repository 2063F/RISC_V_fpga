`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_divider
// Description: Unit test for the multi-cycle divider that replaced the
//              combinational division logic in alu.v.
//
//              Covers the four RV32M division instructions including the two
//              cases the spec calls out explicitly (divide by zero and the
//              signed MIN_INT / -1 overflow), plus large unsigned operands
//              where a signed/unsigned mix-up would show up.
//////////////////////////////////////////////////////////////////////////////////

module tb_divider;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [31:0] a, b;
    reg         is_signed, want_rem;
    wire [31:0] result;
    wire        done;

    divider dut (
        .clk (clk), .rst_n (rst_n), .start (start),
        .a (a), .b (b), .is_signed (is_signed), .want_rem (want_rem),
        .result (result), .done (done)
    );

    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;
    integer cycles;

    task run_op;
        input [31:0]  in_a;
        input [31:0]  in_b;
        input         sgn;
        input         rem;
        input [31:0]  expected;
        input [255:0] name;
        begin
            @(negedge clk);
            a = in_a; b = in_b; is_signed = sgn; want_rem = rem; start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            cycles = 1;
            while (!done && cycles < 100) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            if (!done) begin
                $display("  FAIL  %s: never asserted done", name);
                fail_count = fail_count + 1;
            end else if (result === expected) begin
                $display("  PASS  %s: 0x%h (%0d cycles)", name, result, cycles);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %s: got 0x%h, expected 0x%h", name, result, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $display("=== Multi-cycle Divider Testbench ===\n");
        repeat (3) @(negedge clk);
        rst_n = 1;

        $display("--- DIV (signed quotient) ---");
        run_op(32'd20,          32'd5,          1, 0, 32'd4,          "DIV   20 / 5        ");
        run_op(32'hFFFFFFEC,    32'd5,          1, 0, 32'hFFFFFFFC,   "DIV  -20 / 5        ");
        run_op(32'd20,          32'hFFFFFFFB,   1, 0, 32'hFFFFFFFC,   "DIV   20 / -5       ");
        run_op(32'hFFFFFFEC,    32'hFFFFFFFB,   1, 0, 32'd4,          "DIV  -20 / -5       ");
        run_op(32'd7,           32'd2,          1, 0, 32'd3,          "DIV    7 / 2 (trunc)");
        run_op(32'hFFFFFFF9,    32'd2,          1, 0, 32'hFFFFFFFD,   "DIV   -7 / 2 (trunc)");

        $display("\n--- DIVU (unsigned quotient) ---");
        run_op(32'd20,          32'd5,          0, 0, 32'd4,          "DIVU  20 / 5        ");
        run_op(32'hFFFFFFFE,    32'd2,          0, 0, 32'h7FFFFFFF,   "DIVU  big / 2       ");
        run_op(32'hFFFFFFF8,    32'd3,          0, 0, 32'h55555552,   "DIVU  0xFFFFFFF8 / 3");
        run_op(32'hFFFFFFFF,    32'hFFFFFFFF,   0, 0, 32'd1,          "DIVU  max / max     ");
        run_op(32'hFFFFFFFF,    32'h80000001,   0, 0, 32'd1,          "DIVU  max / 2^31+1  ");
        run_op(32'hFFFFFFFF,    32'hC0000000,   0, 0, 32'd1,          "DIVU  max / 0xC0..  ");

        $display("\n--- REM (signed remainder) ---");
        run_op(32'd22,          32'd5,          1, 1, 32'd2,          "REM   22 % 5        ");
        run_op(32'hFFFFFFEA,    32'd5,          1, 1, 32'hFFFFFFFE,   "REM  -22 % 5        ");
        run_op(32'd22,          32'hFFFFFFFB,   1, 1, 32'd2,          "REM   22 % -5       ");
        run_op(32'hFFFFFFF8,    32'd3,          1, 1, 32'hFFFFFFFE,   "REM   -8 % 3        ");

        $display("\n--- REMU (unsigned remainder) ---");
        run_op(32'd22,          32'd5,          0, 1, 32'd2,          "REMU  22 % 5        ");
        run_op(32'hFFFFFFF8,    32'd3,          0, 1, 32'd2,          "REMU  0xFFFFFFF8 % 3");
        run_op(32'hFFFFFFFF,    32'hC0000000,   0, 1, 32'h3FFFFFFF,   "REMU  max % 0xC0..  ");

        $display("\n--- Divide by zero (spec: quotient all ones, remainder = dividend) ---");
        run_op(32'd10,          32'd0,          1, 0, 32'hFFFFFFFF,   "DIV   10 / 0        ");
        run_op(32'd10,          32'd0,          0, 0, 32'hFFFFFFFF,   "DIVU  10 / 0        ");
        run_op(32'd10,          32'd0,          1, 1, 32'd10,         "REM   10 % 0        ");
        run_op(32'd10,          32'd0,          0, 1, 32'd10,         "REMU  10 % 0        ");

        $display("\n--- Signed overflow MIN_INT / -1 ---");
        run_op(32'h80000000,    32'hFFFFFFFF,   1, 0, 32'h80000000,   "DIV   MIN / -1      ");
        run_op(32'h80000000,    32'hFFFFFFFF,   1, 1, 32'd0,          "REM   MIN % -1      ");

        $display("\n--- Back to back (divider must return to idle) ---");
        run_op(32'd100,         32'd7,          0, 0, 32'd14,         "DIVU 100 / 7        ");
        run_op(32'd100,         32'd7,          0, 1, 32'd2,          "REMU 100 % 7        ");

        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED!");
        else                 $display("SOME TESTS FAILED!");
        $finish;
    end

endmodule
