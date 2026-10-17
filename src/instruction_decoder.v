// =============================================================================
// instruction_decoder.v - Instruction Decoder for RISC-V RV32IM CPU
// =============================================================================
// Decodes the 32-bit instruction into control signals for the datapath.
// Extremely simple compared to x86 due to fixed length and format.
//
// Every encoding that is not a supported instruction raises `illegal`, which
// cpu_top turns into an illegal-instruction exception. That covers unknown
// opcodes (including 16-bit compressed instructions, whose low two bits are
// never 2'b11), reserved funct3/funct7 values, and SYSTEM encodings other than
// ECALL / EBREAK / MRET / WFI / CSR*. The other outputs may still be non-zero
// for an illegal instruction; cpu_top suppresses all of its side effects.
//
// FENCE and FENCE.I decode as no-ops: there is no cache or store buffer, and
// the instruction ROM cannot be written. WFI is a no-op too, which the spec
// allows - software has to wrap it in a loop that re-checks its condition.
//
// Whether a CSR address exists is not decided here; csr_file owns that list
// and checks it in the same cycle (see cpu_top).
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
    output reg  [4:0]  alu_op,
    output reg         alu_src_b, // 0: rs2, 1: immediate

    // Branch/Jump control
    output reg         branch,
    output reg         jump,

    // Memory control
    output reg         mem_read,
    output reg         mem_write,
    
    // Write-back control
    output reg  [1:0]  wb_sel,    // 0: ALU, 1: Memory, 2: PC+4 (JAL/JALR), 3: CSR

    // System / trap control
    output reg         illegal,   // not a supported instruction
    output reg         ecall,
    output reg         ebreak,
    output reg         mret,
    output reg         csr,       // CSRRW/CSRRS/CSRRC and immediate forms
    output reg         csr_write  // the CSR instruction writes its CSR
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
        illegal   = 1'b0;
        ecall     = 1'b0;
        ebreak    = 1'b0;
        mret      = 1'b0;
        csr       = 1'b0;
        csr_write = 1'b0;

        case (opcode)
            // ------------------------------------------------------------------
            // Register-Register ALU Operations
            // ------------------------------------------------------------------
            `OP_OP: begin
                reg_write = 1'b1;
                alu_src_b = 1'b0; // Use rs2
                wb_sel    = 2'd0;
                // funct7 = 0100000 only exists for SUB and SRA.
                if (funct7 == `FUNCT7_ALT)
                    illegal = (funct3 != `FUNCT3_ADD_SUB) && (funct3 != `FUNCT3_SRL_SRA);
                else
                    illegal = (funct7 != `FUNCT7_NORMAL) && (funct7 != `FUNCT7_MEXT);

                if (funct7 == `FUNCT7_MEXT) begin
                    case (funct3)
                        `FUNCT3_MUL:    alu_op = `ALU_MUL;
                        `FUNCT3_MULH:   alu_op = `ALU_MULH;
                        `FUNCT3_MULHSU: alu_op = `ALU_MULHSU;
                        `FUNCT3_MULHU:  alu_op = `ALU_MULHU;
                        `FUNCT3_DIV:    alu_op = `ALU_DIV;
                        `FUNCT3_DIVU:   alu_op = `ALU_DIVU;
                        `FUNCT3_REM:    alu_op = `ALU_REM;
                        `FUNCT3_REMU:   alu_op = `ALU_REMU;
                        default:        alu_op = `ALU_ADD;
                    endcase
                end else begin
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
            end

            // ------------------------------------------------------------------
            // Register-Immediate ALU Operations
            // ------------------------------------------------------------------
            `OP_OP_IMM: begin
                reg_write = 1'b1;
                alu_src_b = 1'b1; // Use immediate
                imm_type  = `IMM_I;
                wb_sel    = 2'd0;
                // Shift-immediates keep funct7 in the upper immediate bits;
                // only SRAI may set bit 30 there.
                if (funct3 == `FUNCT3_SLL)
                    illegal = (funct7 != `FUNCT7_NORMAL);
                else if (funct3 == `FUNCT3_SRL_SRA)
                    illegal = (funct7 != `FUNCT7_NORMAL) && (funct7 != `FUNCT7_ALT);

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
                // control_unit switches ALU input A to the PC for AUIPC, so
                // the ADD below computes PC + imm.
                reg_write = 1'b1;
                imm_type  = `IMM_U;
                alu_src_b = 1'b1;
                alu_op    = `ALU_ADD; // PC + imm
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
                    default: begin              // funct3 = 010 / 011
                        alu_op  = `ALU_SUB;
                        illegal = 1'b1;
                    end
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
                // LB/LH/LW/LBU/LHU only; 011, 110 and 111 are reserved.
                illegal   = (funct3 == 3'b011) || (funct3[2:1] == 2'b11);
            end

            // ------------------------------------------------------------------
            // Memory Store
            // ------------------------------------------------------------------
            `OP_STORE: begin
                mem_write = 1'b1;
                imm_type  = `IMM_S;
                alu_src_b = 1'b1; // Addr = rs1 + imm
                alu_op    = `ALU_ADD;
                illegal   = (funct3[2] || funct3[1:0] == 2'b11); // SB/SH/SW only
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
                illegal   = (funct3 != 3'b000);
            end

            // ------------------------------------------------------------------
            // FENCE / FENCE.I: no-ops on this core
            // ------------------------------------------------------------------
            `OP_FENCE: begin
                illegal   = funct3[2] || funct3[1];
            end

            // ------------------------------------------------------------------
            // SYSTEM: ECALL, EBREAK, MRET, WFI and the CSR instructions
            // ------------------------------------------------------------------
            `OP_SYSTEM: begin
                if (funct3 == `FUNCT3_PRIV) begin
                    case (inst)
                        `INST_ECALL:  ecall  = 1'b1;
                        `INST_EBREAK: ebreak = 1'b1;
                        `INST_MRET:   mret   = 1'b1;
                        `INST_WFI:    ;               // no-op
                        default:      illegal = 1'b1;
                    endcase
                end else if (funct3 == 3'b100) begin
                    illegal = 1'b1;
                end else begin
                    // rd <= old CSR value. CSRRS/CSRRC with rs1 = x0 (or a
                    // zero uimm) only read, which is what lets them access a
                    // read-only CSR such as cycle without trapping.
                    csr       = 1'b1;
                    csr_write = (funct3[1:0] == `CSR_OP_RW) || (rs1 != 5'd0);
                    reg_write = 1'b1;
                    imm_type  = `IMM_I;  // CSR address sits in imm[11:0]
                    wb_sel    = `WB_CSR;
                end
            end

            default: begin
                // Unknown opcode, including every 16-bit compressed instruction.
                illegal = 1'b1;
            end
        endcase
    end

endmodule
