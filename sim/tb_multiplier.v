`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_multiplier
// Description: Unit test for the multi-cycle multiplier that replaced the
//              combinational multiply logic in alu.v.
//
//              Operands are chosen so that the three signed/unsigned variants
//              disagree, which is what catches a MULH / MULHU / MULHSU mix-up.
//              Expected values were cross-checked against Python.
//////////////////////////////////////////////////////////////////////////////////

`include "riscv_defines.vh"

module tb_multiplier;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [31:0] a, b;
    reg  [4:0]  op;
    wire [31:0] result;
    wire        done;

    multiplier dut (
        .clk (clk), .rst_n (rst_n), .start (start),
        .a (a), .b (b), .op (op), .result (result), .done (done)
    );

    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;
    integer cycles;

    task run_op;
        input [31:0]  in_a;
        input [31:0]  in_b;
        input [4:0]   in_op;
        input [31:0]  expected;
        input [255:0] name;
        begin
            @(negedge clk);
            a = in_a; b = in_b; op = in_op; start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            cycles = 1;
            while (!done && cycles < 20) begin
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
        $display("=== Multi-cycle Multiplier Testbench ===\n");
        repeat (3) @(negedge clk);
        rst_n = 1;

        $display("--- MUL (low 32 bits) ---");
        run_op(32'd12,       32'd5,        `ALU_MUL,    32'd60,        "MUL  12 * 5         ");
        run_op(32'hFFFFFFF6, 32'd6,        `ALU_MUL,    32'hFFFFFFC4,  "MUL  -10 * 6        ");
        run_op(32'hFFFFFFFF, 32'd2,        `ALU_MUL,    32'hFFFFFFFE,  "MUL  wraps low 32b  ");
        run_op(32'h80000000, 32'h80000000, `ALU_MUL,    32'd0,         "MUL  MIN * MIN      ");

        $display("\n--- MULH (signed x signed, high 32 bits) ---");
        run_op(32'h7FFFFFFF, 32'd2,        `ALU_MULH,   32'd0,         "MULH  MAX * 2       ");
        run_op(32'hFFFFFFFF, 32'hFFFFFFFF, `ALU_MULH,   32'd0,         "MULH  -1 * -1       ");
        run_op(32'h80000000, 32'd2,        `ALU_MULH,   32'hFFFFFFFF,  "MULH  MIN * 2       ");
        run_op(32'h80000000, 32'h80000000, `ALU_MULH,   32'h40000000,  "MULH  MIN * MIN     ");
        run_op(32'hFFFFFFF8, 32'd3,        `ALU_MULH,   32'hFFFFFFFF,  "MULH  -8 * 3        ");

        $display("\n--- MULHU (unsigned x unsigned, high 32 bits) ---");
        run_op(32'hFFFFFFFF, 32'hFFFFFFFF, `ALU_MULHU,  32'hFFFFFFFE,  "MULHU max * max     ");
        run_op(32'hFFFFFFF8, 32'd3,        `ALU_MULHU,  32'd2,         "MULHU 0xFFFFFFF8 * 3");
        run_op(32'h80000000, 32'd2,        `ALU_MULHU,  32'd1,         "MULHU 2^31 * 2      ");

        $display("\n--- MULHSU (signed x unsigned, high 32 bits) ---");
        run_op(32'hFFFFFFFF, 32'hFFFFFFFF, `ALU_MULHSU, 32'hFFFFFFFF,  "MULHSU -1 * max     ");
        run_op(32'hFFFFFFF8, 32'd3,        `ALU_MULHSU, 32'hFFFFFFFF,  "MULHSU -8 * 3u      ");
        run_op(32'd3,        32'hFFFFFFFF, `ALU_MULHSU, 32'd2,         "MULHSU 3 * max      ");

        $display("\n--- Back to back (must return to idle) ---");
        run_op(32'd7,        32'd7,        `ALU_MUL,    32'd49,        "MUL  7 * 7          ");
        run_op(32'd7,        32'd7,        `ALU_MULH,   32'd0,         "MULH 7 * 7          ");

        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED!");
        else                 $display("SOME TESTS FAILED!");
        $finish;
    end

endmodule
