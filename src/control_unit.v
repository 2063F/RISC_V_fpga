`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/23
// Design Name: 
// Module Name: control_unit
// Project Name: RISC-V RV32IM CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Tool Versions: 
// Description: Control Unit for the EX stage of the pipelined RISC-V CPU.
//              Generates the program counter select from the instruction and
//              the register operands. Branches and jumps are resolved here,
//              in EX. (The ALU operand selects are made in ID; see rv_core.)
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
    
    // Branch operands (rs1 / rs2, forwarding already applied in ID)
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,
    
    // Outputs to Datapath MUXs
    output reg  [1:0]  pc_sel     // 0: PC+4, 1: PC+imm (Branch taken / JAL), 2: rs1+imm (JALR)
);

    reg branch_taken;

    // The branch compares its operands directly rather than looking at the
    // ALU result: going through the ALU put its operation decode and the
    // 32-bit zero detect in front of the branch decision, which feeds the
    // next-PC mux, the pipeline flush and the trap logic.
    wire eq  = (rs1_data == rs2_data);
    wire lt  = ($signed(rs1_data) < $signed(rs2_data));
    wire ltu = (rs1_data < rs2_data);

    // Branch Condition Evaluation
    always @(*) begin
        branch_taken = 1'b0;
        if (branch) begin
            case (funct3)
                `FUNCT3_BEQ:  branch_taken = eq;
                `FUNCT3_BNE:  branch_taken = !eq;
                `FUNCT3_BLT:  branch_taken = lt;
                `FUNCT3_BGE:  branch_taken = !lt;
                `FUNCT3_BLTU: branch_taken = ltu;
                `FUNCT3_BGEU: branch_taken = !ltu;
                default:      branch_taken = 1'b0;
            endcase
        end
    end

    // Datapath Multiplexer Control
    always @(*) begin
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
