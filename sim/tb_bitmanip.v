`timescale 1ns / 1ps
// =============================================================================
// tb_bitmanip.v - Unit test for bitmanip.v (Zbb CPOP / CTZ)
// =============================================================================
// Checks both ops against a behavioural reference on every one-hot and
// all-ones-below-bit-n value, plus 10000 random words.
// =============================================================================

module tb_bitmanip;

    reg  [31:0] a;
    reg         is_ctz;
    wire [31:0] result;

    bitmanip uut (
        .a      (a),
        .is_ctz (is_ctz),
        .result (result)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    integer n;

    function [31:0] ref_cpop;
        input [31:0] x;
        integer k;
        begin
            ref_cpop = 0;
            for (k = 0; k < 32; k = k + 1) ref_cpop = ref_cpop + x[k];
        end
    endfunction

    function [31:0] ref_ctz;
        input [31:0] x;
        integer k;
        begin
            ref_ctz = 32;
            for (k = 31; k >= 0; k = k - 1) if (x[k]) ref_ctz = k;
        end
    endfunction

    task check;
        input [31:0] x;
        begin
            a = x;
            is_ctz = 1'b0; #1;
            if (result === ref_cpop(x)) pass_count = pass_count + 1;
            else begin
                $display("  FAIL  cpop(0x%h) = %0d (expected %0d)", x, result, ref_cpop(x));
                fail_count = fail_count + 1;
            end
            is_ctz = 1'b1; #1;
            if (result === ref_ctz(x)) pass_count = pass_count + 1;
            else begin
                $display("  FAIL  ctz(0x%h) = %0d (expected %0d)", x, result, ref_ctz(x));
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $display("=== bitmanip (CPOP / CTZ) Unit Testbench ===\n");

        check(32'd0);
        check(32'hFFFF_FFFF);
        for (n = 0; n < 32; n = n + 1) begin
            check(32'd1 << n);
            check((32'd1 << n) - 32'd1);
            check(~((32'd1 << n) - 32'd1));
        end
        for (n = 0; n < 10000; n = n + 1)
            check($random);

        $display("=== Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
