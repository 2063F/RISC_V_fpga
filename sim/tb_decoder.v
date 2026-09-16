// =============================================================================
// tb_decoder.v - Testbench for RISC-V Instruction Decoder and Imm Gen
// =============================================================================
// Runs various RV32I instructions through the decoder and verifies signals.
// Run: iverilog -I ../src -o tb_decoder.out tb_decoder.v ../src/instruction_decoder.v ../src/imm_gen.v
//      vvp tb_decoder.out
// =============================================================================

`timescale 1ns / 1ps
`include "riscv_defines.vh"

module tb_decoder;

    // =========================================================================
    // Signals
    // =========================================================================
    reg  [31:0] inst;

    // Decoder outputs
    wire [4:0]  rs1, rs2, rd;
    wire        reg_write;
    wire [2:0]  imm_type;
    wire [4:0]  alu_op;
    wire        alu_src_b;
    wire        branch;
    wire        jump;
    wire        mem_read;
    wire        mem_write;
    wire [1:0]  wb_sel;

    // Imm gen outputs
    wire [31:0] imm;

    // =========================================================================
    // Instantiate DUTs
    // =========================================================================
    instruction_decoder dec (
        .inst      (inst),
        .rs1       (rs1),
        .rs2       (rs2),
        .rd        (rd),
        .reg_write (reg_write),
        .imm_type  (imm_type),
        .alu_op    (alu_op),
        .alu_src_b (alu_src_b),
        .branch    (branch),
        .jump      (jump),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .wb_sel    (wb_sel)
    );

    imm_gen igen (
        .inst      (inst),
        .imm_type  (imm_type),
        .imm       (imm)
    );

    // =========================================================================
    // Test tracking
    // =========================================================================
    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input [127:0] name;
        input exp_reg_write;
        input [2:0] exp_imm_type;
        input [3:0] exp_alu_op;
        input exp_alu_src_b;
        begin
            #1; // Settling time
            if (reg_write === exp_reg_write &&
                imm_type === exp_imm_type &&
                alu_op === exp_alu_op &&
                alu_src_b === exp_alu_src_b) begin
                $display("  PASS  %s", name);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %s | expected: rw=%b itype=%d aluop=%d asrc=%b | got: rw=%b itype=%d aluop=%d asrc=%b",
                         name, exp_reg_write, exp_imm_type, exp_alu_op, exp_alu_src_b,
                         reg_write, imm_type, alu_op, alu_src_b);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        $display("=== RISC-V Decoder Testbench ===");

        // ------------------------------------------------------------------
        // R-type: ADD x3, x1, x2 -> 0000000 00010 00001 000 00011 0110011
        // ------------------------------------------------------------------
        inst = 32'b0000000_00010_00001_000_00011_0110011;
        check("ADD  ", 1, `IMM_I, `ALU_ADD, 0);

        // ------------------------------------------------------------------
        // R-type: SUB x4, x1, x2 -> 0100000 00010 00001 000 00100 0110011
        // ------------------------------------------------------------------
        inst = 32'b0100000_00010_00001_000_00100_0110011;
        check("SUB  ", 1, `IMM_I, `ALU_SUB, 0);

        // ------------------------------------------------------------------
        // I-type: ADDI x5, x1, 10 -> 000000001010 00001 000 00101 0010011
        // ------------------------------------------------------------------
        inst = 32'b000000001010_00001_000_00101_0010011;
        check("ADDI ", 1, `IMM_I, `ALU_ADD, 1);
        #1; if (imm === 32'd10) $display("  PASS  ADDI imm = 10"); else begin $display("  FAIL  ADDI imm"); fail_count++; end

        // ------------------------------------------------------------------
        // I-type (shift): SRAI x6, x1, 5 -> 0100000 00101 00001 101 00110 0010011
        // ------------------------------------------------------------------
        inst = 32'b0100000_00101_00001_101_00110_0010011;
        check("SRAI ", 1, `IMM_I, `ALU_SRA, 1);

        // ------------------------------------------------------------------
        // U-type: LUI x7, 0x12345 -> 00010010001101000101 00111 0110111
        // ------------------------------------------------------------------
        inst = 32'b00010010001101000101_00111_0110111;
        check("LUI  ", 1, `IMM_U, `ALU_PASS_B, 1);
        #1; if (imm === 32'h12345000) $display("  PASS  LUI imm = 0x12345000"); else begin $display("  FAIL  LUI imm"); fail_count++; end

        // ------------------------------------------------------------------
        // S-type: SW x2, 4(x1) -> 0000000 00010 00001 010 00100 0100011
        // ------------------------------------------------------------------
        inst = 32'b0000000_00010_00001_010_00100_0100011;
        check("SW   ", 0, `IMM_S, `ALU_ADD, 1);
        #1; if (imm === 32'd4) $display("  PASS  SW imm = 4"); else begin $display("  FAIL  SW imm"); fail_count++; end
        if (mem_write === 1'b1) $display("  PASS  SW mem_write = 1"); else begin $display("  FAIL  SW mem_write"); fail_count++; end

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
