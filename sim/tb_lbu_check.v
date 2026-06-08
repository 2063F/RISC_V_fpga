`timescale 1ns / 1ps
// Quick diagnostic: check what funct3 is output for LBU instruction
`include "riscv_defines.vh"

module tb_lbu_check;
    reg [31:0] inst;
    wire [4:0] rs1, rs2, rd;
    wire       reg_write;
    wire [2:0] imm_type;
    wire [3:0] alu_op;
    wire       alu_src_b, branch, jump, mem_read, mem_write;
    wire [1:0] wb_sel;

    instruction_decoder dec (
        .inst(inst), .rs1(rs1), .rs2(rs2), .rd(rd),
        .reg_write(reg_write), .imm_type(imm_type), .alu_op(alu_op),
        .alu_src_b(alu_src_b), .branch(branch), .jump(jump),
        .mem_read(mem_read), .mem_write(mem_write), .wb_sel(wb_sel)
    );

    initial begin
        // LBU x14, 8(x1): {12'h008, 5'b00001, 3'b100, 5'b01110, 7'b0000011}
        inst = 32'h00814703;
        #1;
        $display("LBU x14,8(x1): opcode=%07b funct3=%03b rd=%05b rs1=%05b",
                 inst[6:0], inst[14:12], inst[11:7], inst[19:15]);
        $display("  mem_read=%b wb_sel=%d alu_src_b=%b alu_op=%d",
                 mem_read, wb_sel, alu_src_b, alu_op);
        $display("  FUNCT3_BYTEU = %03b", `FUNCT3_BYTEU);

        // Also check LB
        inst = 32'h00808683; // LB x13, 8(x1)
        #1;
        $display("LB  x13,8(x1): opcode=%07b funct3=%03b rd=%05b rs1=%05b",
                 inst[6:0], inst[14:12], inst[11:7], inst[19:15]);
        $display("  mem_read=%b wb_sel=%d", mem_read, wb_sel);

        $finish;
    end
endmodule
