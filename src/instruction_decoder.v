// =============================================================================
// instruction_decoder.v - Instruction Decoder for RISC-V RV32I CPU
// =============================================================================
// Decodes the 32-bit instruction into control signals for the datapath.
// Extremely simple compared to x86 due to fixed length and format.
// =============================================================================

`include "riscv_defines.vh"

module instruction_decoder (
    input  wire [31:0] inst,

    // Register file control
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [4:0]  rd,
    output reg         reg_write,

    // Immediate generator control
    output reg  [2:0]  imm_type,

    // ALU control
    output reg  [3:0]  alu_op,
    output reg         alu_src_b, // 0: rs2, 1: immediate

    // Branch/Jump control
    output reg         branch,
    output reg         jump,

    // Memory control
    output reg         mem_read,
    output reg         mem_write,
    
    // Write-back control
    output reg  [1:0]  wb_sel     // 0: ALU, 1: Memory, 2: PC+4 (for JAL/JALR)
);

    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];

    // Fixed register fields for all instruction formats
    assign rs1 = inst[19:15];
    assign rs2 = inst[24:20];
    assign rd  = inst[11:7];

    always @(*) begin
        // Default control signals (prevent latches)
        reg_write = 1'b0;
        imm_type  = `IMM_I;
        alu_op    = `ALU_ADD;
        alu_src_b = 1'b0;
        branch    = 1'b0;
        jump      = 1'b0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        wb_sel    = 2'd0; // Default ALU

        case (opcode)
            // ------------------------------------------------------------------
            // Register-Register ALU Operations
            // ------------------------------------------------------------------
            `OP_OP: begin
                reg_write = 1'b1;
                alu_src_b = 1'b0; // Use rs2
                wb_sel    = 2'd0;
                case (funct3)
                    `FUNCT3_ADD_SUB: alu_op = (funct7 == `FUNCT7_ALT) ? `ALU_SUB : `ALU_ADD;
                    `FUNCT3_SLL:     alu_op = `ALU_SLL;
                    `FUNCT3_SLT:     alu_op = `ALU_SLT;
                    `FUNCT3_SLTU:    alu_op = `ALU_SLTU;
                    `FUNCT3_XOR:     alu_op = `ALU_XOR;
                    `FUNCT3_SRL_SRA: alu_op = (funct7 == `FUNCT7_ALT) ? `ALU_SRA : `ALU_SRL;
                    `FUNCT3_OR:      alu_op = `ALU_OR;
                    `FUNCT3_AND:     alu_op = `ALU_AND;
                    default:         alu_op = `ALU_ADD;
                endcase
            end

            // ------------------------------------------------------------------
            // Register-Immediate ALU Operations
            // ------------------------------------------------------------------
            `OP_OP_IMM: begin
                reg_write = 1'b1;
                alu_src_b = 1'b1; // Use immediate
                imm_type  = `IMM_I;
                wb_sel    = 2'd0;
                case (funct3)
                    `FUNCT3_ADD_SUB: alu_op = `ALU_ADD; // ADDI is always ADD
                    `FUNCT3_SLL:     alu_op = `ALU_SLL;
                    `FUNCT3_SLT:     alu_op = `ALU_SLT;
                    `FUNCT3_SLTU:    alu_op = `ALU_SLTU;
                    `FUNCT3_XOR:     alu_op = `ALU_XOR;
                    `FUNCT3_SRL_SRA: alu_op = (funct7 == `FUNCT7_ALT) ? `ALU_SRA : `ALU_SRL;
                    `FUNCT3_OR:      alu_op = `ALU_OR;
                    `FUNCT3_AND:     alu_op = `ALU_AND;
                    default:         alu_op = `ALU_ADD;
                endcase
            end

            // ------------------------------------------------------------------
            // Load Upper Immediate
            // ------------------------------------------------------------------
            `OP_LUI: begin
                reg_write = 1'b1;
                imm_type  = `IMM_U;
                alu_src_b = 1'b1;
                alu_op    = `ALU_PASS_B; // Pass immediate directly
                wb_sel    = 2'd0;
            end

            // ------------------------------------------------------------------
            // Add Upper Immediate to PC (AUIPC)
            // ------------------------------------------------------------------
            `OP_AUIPC: begin
                // In single cycle CPU, this will be handled by passing PC to ALU A input
                // For now, just generate the immediate
                reg_write = 1'b1;
                imm_type  = `IMM_U;
                alu_src_b = 1'b1;
                alu_op    = `ALU_ADD; // Actually PC + imm
                wb_sel    = 2'd0;
            end

            // ------------------------------------------------------------------
            // Branches
            // ------------------------------------------------------------------
            `OP_BRANCH: begin
                branch    = 1'b1;
                imm_type  = `IMM_B;
                alu_src_b = 1'b0; // Use rs2 for comparison
                case (funct3)
                    `FUNCT3_BEQ,
                    `FUNCT3_BNE:  alu_op = `ALU_SUB;
                    `FUNCT3_BLT,
                    `FUNCT3_BGE:  alu_op = `ALU_SLT;
                    `FUNCT3_BLTU,
                    `FUNCT3_BGEU: alu_op = `ALU_SLTU;
                    default:      alu_op = `ALU_SUB;
                endcase
            end

            // ------------------------------------------------------------------
            // Memory Load
            // ------------------------------------------------------------------
            `OP_LOAD: begin
                reg_write = 1'b1;
                mem_read  = 1'b1;
                imm_type  = `IMM_I;
                alu_src_b = 1'b1; // Addr = rs1 + imm
                alu_op    = `ALU_ADD;
                wb_sel    = 2'd1; // Write back from memory
            end

            // ------------------------------------------------------------------
            // Memory Store
            // ------------------------------------------------------------------
            `OP_STORE: begin
                mem_write = 1'b1;
                imm_type  = `IMM_S;
                alu_src_b = 1'b1; // Addr = rs1 + imm
                alu_op    = `ALU_ADD;
            end

            // ------------------------------------------------------------------
            // Jump and Link (JAL)
            // ------------------------------------------------------------------
            `OP_JAL: begin
                reg_write = 1'b1;
                jump      = 1'b1;
                imm_type  = `IMM_J;
                wb_sel    = 2'd2; // Write back PC + 4
            end

            // ------------------------------------------------------------------
            // Jump and Link Register (JALR)
            // ------------------------------------------------------------------
            `OP_JALR: begin
                reg_write = 1'b1;
                jump      = 1'b1;
                imm_type  = `IMM_I;
                wb_sel    = 2'd2; // Write back PC + 4
            end

            default: begin
                // Unhandled or invalid opcode
            end
        endcase
    end

endmodule
