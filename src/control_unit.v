`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/23
// Design Name: 
// Module Name: control_unit
// Project Name: RISC-V RV32I CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Tool Versions: 
// Description: Control Unit for single cycle RISC-V CPU.
//              Generates control signals for program counter multiplexers
//              and ALU input A multiplexers based on instructions and flags.
// 
// Dependencies: riscv_defines.vh
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`include "riscv_defines.vh"

module control_unit (
    input  wire [6:0]  opcode,
    input  wire [2:0]  funct3,
    
    // Inputs from Decoder
    input  wire        branch,
    input  wire        jump,
    
    // Inputs from ALU (for branch evaluation)
    input  wire        alu_zero,
    input  wire [31:0] alu_result,
    
    // Outputs to Datapath MUXs
    output reg         alu_src_a, // 0: rs1, 1: PC (for AUIPC)
    output reg  [1:0]  pc_sel     // 0: PC+4, 1: PC+imm (Branch taken / JAL), 2: rs1+imm (JALR)
);

    reg branch_taken;

    // Branch Condition Evaluation
    always @(*) begin
        branch_taken = 1'b0;
        if (branch) begin
            case (funct3)
                `FUNCT3_BEQ:  branch_taken = alu_zero;          // rs1 == rs2
                `FUNCT3_BNE:  branch_taken = !alu_zero;         // rs1 != rs2
                `FUNCT3_BLT:  branch_taken = alu_result[0];     // rs1 < rs2 (SLT result = 1)
                `FUNCT3_BGE:  branch_taken = !alu_result[0];    // rs1 >= rs2
                `FUNCT3_BLTU: branch_taken = alu_result[0];     // rs1 < rs2 (unsigned, SLTU result = 1)
                `FUNCT3_BGEU: branch_taken = !alu_result[0];    // rs1 >= rs2 (unsigned)
                default:      branch_taken = 1'b0;
            endcase
        end
    end

    // Datapath Multiplexer Control
    always @(*) begin
        // ALU Input A Source Select:
        // - AUIPC needs PC as the first operand.
        // - Other instructions (R-type, I-type, Load, Store) use rs1.
        if (opcode == `OP_AUIPC) begin
            alu_src_a = 1'b1; // PC
        end else begin
            alu_src_a = 1'b0; // rs1
        end

        // Next PC Source Select:
        // - 0: PC + 4 (Normal execution)
        // - 1: PC + imm (JAL or taken Branch)
        // - 2: rs1 + imm (JALR)
        if (opcode == `OP_JALR) begin
            pc_sel = 2'd2; // rs1 + imm
        end else if (jump || branch_taken) begin
            pc_sel = 2'd1; // PC + imm
        end else begin
            pc_sel = 2'd0; // PC + 4
        end
    end

endmodule
