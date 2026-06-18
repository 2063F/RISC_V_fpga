`timescale 1ns / 1ps
// =============================================================================
// tb_alu_m.v - Testbench for RV32M Extension ALU Operations
// =============================================================================

`include "riscv_defines.vh"

module tb_alu_m;

    reg  [31:0] a;
    reg  [31:0] b;
    reg  [4:0]  alu_op;
    wire [31:0] result;
    wire        zero;

    // Instantiate ALU
    alu uut (
        .a      (a),
        .b      (b),
        .alu_op (alu_op),
        .result (result),
        .zero   (zero)
    );

    integer failures = 0;

    task check;
        input [31:0] expected;
        input [256:0] op_name;
        begin
            if (result !== expected) begin
                $display("FAIL: %s | A=0x%h, B=0x%h | Got 0x%h, Expected 0x%h",
                         op_name, a, b, result, expected);
                failures = failures + 1;
            end else begin
                $display("PASS: %s | A=0x%h, B=0x%h | Got 0x%h",
                         op_name, a, b, result);
            end
        end
    endtask

    initial begin
        $display("=== RV32M ALU Simulation Start ===");

        // 1. MUL (a * b)
        alu_op = `ALU_MUL;
        a = 32'd12; b = 32'd5; #10; check(32'd60, "MUL positive");
        a = -32'd10; b = 32'd6; #10; check(-32'd60, "MUL negative");
        a = 32'hFFFF_FFFF; b = 32'd2; #10; check(32'hFFFF_FFFE, "MUL overflow lower 32b");

        // 2. MULH (signed * signed, upper 32b)
        alu_op = `ALU_MULH;
        a = 32'h7FFF_FFFF; b = 32'd2; #10; check(32'd0, "MULH upper positive");
        a = 32'hFFFF_FFFF; b = 32'hFFFF_FFFF; #10; check(32'd0, "MULH (-1 * -1)");
        a = 32'h8000_0000; b = 32'd2; #10; check(32'hFFFF_FFFF, "MULH (MIN_INT * 2)"); // upper bits should be FFFF_FFFF (-1)

        // 3. MULHU (unsigned * unsigned, upper 32b)
        alu_op = `ALU_MULHU;
        a = 32'hFFFF_FFFF; b = 32'hFFFF_FFFF; #10; check(32'hFFFF_FFFE, "MULHU (MAX_UINT * MAX_UINT)");

        // 4. MULHSU (signed * unsigned, upper 32b)
        alu_op = `ALU_MULHSU;
        a = -32'd1; b = 32'hFFFF_FFFF; #10; check(32'hFFFF_FFFF, "MULHSU (-1 * MAX_UINT)");

        // 5. DIV (signed division)
        alu_op = `ALU_DIV;
        a = 32'd20; b = 32'd5; #10; check(32'd4, "DIV (20 / 5)");
        a = -32'd20; b = 32'd5; #10; check(-32'd4, "DIV (-20 / 5)");
        a = 32'd20; b = -32'd5; #10; check(-32'd4, "DIV (20 / -5)");
        a = -32'd20; b = -32'd5; #10; check(32'd4, "DIV (-20 / -5)");
        // Edge cases
        a = 32'd10; b = 32'd0; #10; check(32'hFFFF_FFFF, "DIV by zero");
        a = 32'h8000_0000; b = 32'hFFFF_FFFF; #10; check(32'h8000_0000, "DIV overflow (MIN_INT / -1)");

        // 6. DIVU (unsigned division)
        alu_op = `ALU_DIVU;
        a = 32'd20; b = 32'd5; #10; check(32'd4, "DIVU (20 / 5)");
        a = 32'hFFFF_FFFE; b = 32'd2; #10; check(32'h7FFF_FFFF, "DIVU large unsigned");
        a = 32'd10; b = 32'd0; #10; check(32'hFFFF_FFFF, "DIVU by zero");

        // 7. REM (signed remainder)
        alu_op = `ALU_REM;
        a = 32'd22; b = 32'd5; #10; check(32'd2, "REM (22 % 5)");
        a = -32'd22; b = 32'd5; #10; check(-32'd2, "REM (-22 % 5)");
        a = 32'd10; b = 32'd0; #10; check(32'd10, "REM by zero");
        a = 32'h8000_0000; b = 32'hFFFF_FFFF; #10; check(32'd0, "REM overflow (MIN_INT % -1)");

        // 8. REMU (unsigned remainder)
        alu_op = `ALU_REMU;
        a = 32'd22; b = 32'd5; #10; check(32'd2, "REMU (22 % 5)");
        a = 32'd10; b = 32'd0; #10; check(32'd10, "REMU by zero");

        if (failures == 0) begin
            $display("ALL M EXTENSION ALU TESTS PASSED!");
        end else begin
            $display("SOME TESTS FAILED! Failures: %d", failures);
        end

        $finish;
    end

endmodule
