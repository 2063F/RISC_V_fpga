// =============================================================================
// tb_alu.v - Testbench for RISC-V ALU
// =============================================================================
// Tests all 11 ALU operations with multiple input patterns.
// Run: iverilog -I ../src -o tb_alu.out tb_alu.v ../src/alu.v && vvp tb_alu.out
// =============================================================================

`timescale 1ns / 1ps
`include "riscv_defines.vh"

module tb_alu;

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg  [31:0] a, b;
    reg  [3:0]  alu_op;
    wire [31:0] result;
    wire        zero;

    // =========================================================================
    // Instantiate DUT
    // =========================================================================
    alu dut (
        .a      (a),
        .b      (b),
        .alu_op (alu_op),
        .result (result),
        .zero   (zero)
    );

    // =========================================================================
    // Test tracking
    // =========================================================================
    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input [127:0] test_name;   // test label (up to 16 chars)
        input [31:0]  expected;
        begin
            #1; // let combinational settle
            if (result === expected) begin
                $display("  PASS  %s | a=%0d b=%0d -> result=%0d",
                         test_name, $signed(a), $signed(b), $signed(result));
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %s | a=%0d b=%0d | expected=%0d got=%0d",
                         test_name, $signed(a), $signed(b),
                         $signed(expected), $signed(result));
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        $display("=== RISC-V ALU Testbench ===");

        // ------------------------------------------------------------------
        // ADD
        // ------------------------------------------------------------------
        $display("\n--- ADD ---");
        alu_op = `ALU_ADD; a = 32'd10;  b = 32'd20;  check("ADD 10+20  ", 32'd30);
        alu_op = `ALU_ADD; a = 32'd0;   b = 32'd0;   check("ADD 0+0    ", 32'd0);
        alu_op = `ALU_ADD; a = 32'hFFFFFFFF; b = 32'd1; check("ADD wraparound", 32'd0);

        // ------------------------------------------------------------------
        // SUB
        // ------------------------------------------------------------------
        $display("\n--- SUB ---");
        alu_op = `ALU_SUB; a = 32'd30;  b = 32'd10;  check("SUB 30-10  ", 32'd20);
        alu_op = `ALU_SUB; a = 32'd5;   b = 32'd5;   check("SUB 5-5=0  ", 32'd0);
        alu_op = `ALU_SUB; a = 32'd0;   b = 32'd1;   check("SUB 0-1    ", 32'hFFFFFFFF);

        // ------------------------------------------------------------------
        // AND
        // ------------------------------------------------------------------
        $display("\n--- AND ---");
        alu_op = `ALU_AND; a = 32'hFF00FF00; b = 32'h0F0F0F0F; check("AND        ", 32'h0F000F00);
        alu_op = `ALU_AND; a = 32'hFFFFFFFF; b = 32'h12345678; check("AND all1   ", 32'h12345678);

        // ------------------------------------------------------------------
        // OR
        // ------------------------------------------------------------------
        $display("\n--- OR ---");
        alu_op = `ALU_OR;  a = 32'hFF000000; b = 32'h00FF0000; check("OR         ", 32'hFFFF0000);

        // ------------------------------------------------------------------
        // XOR
        // ------------------------------------------------------------------
        $display("\n--- XOR ---");
        alu_op = `ALU_XOR; a = 32'hAAAAAAAA; b = 32'h55555555; check("XOR        ", 32'hFFFFFFFF);
        alu_op = `ALU_XOR; a = 32'h12345678; b = 32'h12345678; check("XOR self=0 ", 32'd0);

        // ------------------------------------------------------------------
        // SLL (Shift Left Logical)
        // ------------------------------------------------------------------
        $display("\n--- SLL ---");
        alu_op = `ALU_SLL; a = 32'd1;   b = 32'd4;   check("SLL 1<<4   ", 32'd16);
        alu_op = `ALU_SLL; a = 32'd1;   b = 32'd31;  check("SLL 1<<31  ", 32'h80000000);

        // ------------------------------------------------------------------
        // SRL (Shift Right Logical)
        // ------------------------------------------------------------------
        $display("\n--- SRL ---");
        alu_op = `ALU_SRL; a = 32'h80000000; b = 32'd1; check("SRL MSB>>1 ", 32'h40000000);
        alu_op = `ALU_SRL; a = 32'd16;  b = 32'd4;  check("SRL 16>>4  ", 32'd1);

        // ------------------------------------------------------------------
        // SRA (Shift Right Arithmetic — sign extends)
        // ------------------------------------------------------------------
        $display("\n--- SRA ---");
        alu_op = `ALU_SRA; a = 32'h80000000; b = 32'd1; check("SRA neg>>1 ", 32'hC0000000);
        alu_op = `ALU_SRA; a = 32'd16;       b = 32'd4; check("SRA pos>>4 ", 32'd1);

        // ------------------------------------------------------------------
        // SLT (Set Less Than — signed)
        // ------------------------------------------------------------------
        $display("\n--- SLT (signed) ---");
        alu_op = `ALU_SLT; a = 32'd5;   b = 32'd10;  check("SLT 5<10   ", 32'd1);
        alu_op = `ALU_SLT; a = 32'd10;  b = 32'd5;   check("SLT 10<5   ", 32'd0);
        alu_op = `ALU_SLT; a = -32'd1;  b = 32'd0;   check("SLT -1<0   ", 32'd1); // signed

        // ------------------------------------------------------------------
        // SLTU (Set Less Than Unsigned)
        // ------------------------------------------------------------------
        $display("\n--- SLTU (unsigned) ---");
        alu_op = `ALU_SLTU; a = 32'd5;        b = 32'd10;       check("SLTU 5<10  ", 32'd1);
        alu_op = `ALU_SLTU; a = 32'hFFFFFFFF; b = 32'd1;        check("SLTU max<1 ", 32'd0);
        alu_op = `ALU_SLTU; a = 32'd0;        b = 32'hFFFFFFFF; check("SLTU 0<max ", 32'd1);

        // ------------------------------------------------------------------
        // PASS_B (for LUI instruction)
        // ------------------------------------------------------------------
        $display("\n--- PASS_B (LUI) ---");
        alu_op = `ALU_PASS_B; a = 32'hDEADBEEF; b = 32'h12345000; check("PASS_B     ", 32'h12345000);

        // ------------------------------------------------------------------
        // Zero flag
        // ------------------------------------------------------------------
        $display("\n--- zero flag ---");
        alu_op = `ALU_SUB; a = 32'd42; b = 32'd42;
        #1;
        if (zero === 1'b1)
            $display("  PASS  zero flag: SUB equal -> zero=1");
        else
            $display("  FAIL  zero flag: SUB equal -> expected zero=1, got %b", zero);

        alu_op = `ALU_ADD; a = 32'd1; b = 32'd1;
        #1;
        if (zero === 1'b0)
            $display("  PASS  zero flag: ADD nonzero -> zero=0");
        else
            $display("  FAIL  zero flag: ADD nonzero -> expected zero=0, got %b", zero);

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        $finish;
    end

endmodule
