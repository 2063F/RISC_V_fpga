// =============================================================================
// riscv_defines.vh - Common Definitions for RISC-V RV32IM CPU
// =============================================================================

// =========================================================================
// Opcodes (inst[6:0])
// =========================================================================
`define OP_LUI      7'b0110111   // Load Upper Immediate
`define OP_AUIPC    7'b0010111   // Add Upper Immediate to PC
`define OP_JAL      7'b1101111   // Jump And Link
`define OP_JALR     7'b1100111   // Jump And Link Register
`define OP_BRANCH   7'b1100011   // Branch (BEQ, BNE, BLT, BGE, BLTU, BGEU)
`define OP_LOAD     7'b0000011   // Load (LB, LH, LW, LBU, LHU)
`define OP_STORE    7'b0100011   // Store (SB, SH, SW)
`define OP_OP_IMM   7'b0010011   // Register-Immediate ALU (ADDI, SLTI, etc.)
`define OP_OP       7'b0110011   // Register-Register ALU (ADD, SUB, etc.)
`define OP_FENCE    7'b0001111   // Memory Fence (FENCE, FENCE.I)
`define OP_SYSTEM   7'b1110011   // System (ECALL, EBREAK, MRET, WFI, CSR*)

// =========================================================================
// ALU Operation Codes (5-bit width)
// =========================================================================
`define ALU_ADD     5'd0
`define ALU_SUB     5'd1
`define ALU_AND     5'd2
`define ALU_OR      5'd3
`define ALU_XOR     5'd4
`define ALU_SLL     5'd5    // Shift Left Logical
`define ALU_SRL     5'd6    // Shift Right Logical
`define ALU_SRA     5'd7    // Shift Right Arithmetic
`define ALU_SLT     5'd8    // Set Less Than (signed)
`define ALU_SLTU    5'd9    // Set Less Than (unsigned)
`define ALU_PASS_B  5'd10   // Pass operand B through (for LUI)
`define ALU_MUL     5'd11   // mul
`define ALU_MULH    5'd12   // mulh
`define ALU_MULHSU  5'd13   // mulhsu
`define ALU_MULHU   5'd14   // mulhu
`define ALU_DIV     5'd15   // div
`define ALU_DIVU    5'd16   // divu
`define ALU_REM     5'd17   // rem
`define ALU_REMU    5'd18   // remu



// =========================================================================
// funct3 for Branch instructions
// =========================================================================
`define FUNCT3_BEQ   3'b000
`define FUNCT3_BNE   3'b001
`define FUNCT3_BLT   3'b100
`define FUNCT3_BGE   3'b101
`define FUNCT3_BLTU  3'b110
`define FUNCT3_BGEU  3'b111

// =========================================================================
// funct3 for Load/Store instructions
// =========================================================================
`define FUNCT3_BYTE   3'b000   // LB / SB
`define FUNCT3_HALF   3'b001   // LH / SH
`define FUNCT3_WORD   3'b010   // LW / SW
`define FUNCT3_BYTEU  3'b100   // LBU (unsigned)
`define FUNCT3_HALFU  3'b101   // LHU (unsigned)

// =========================================================================
// funct3 for ALU operations (R-type and I-type)
// =========================================================================
`define FUNCT3_ADD_SUB  3'b000  // ADD/SUB (distinguished by funct7)
`define FUNCT3_SLL      3'b001
`define FUNCT3_SLT      3'b010
`define FUNCT3_SLTU     3'b011
`define FUNCT3_XOR      3'b100
`define FUNCT3_SRL_SRA  3'b101  // SRL/SRA (distinguished by funct7)
`define FUNCT3_OR       3'b110
`define FUNCT3_AND      3'b111

// =========================================================================
// funct7 distinguishing bits
// =========================================================================
`define FUNCT7_NORMAL  7'b0000000   // ADD, SRL
`define FUNCT7_ALT     7'b0100000   // SUB, SRA
`define FUNCT7_MEXT    7'b0000001   // RV32M Extension

// =========================================================================
// funct3 for RV32M instructions
// =========================================================================
`define FUNCT3_MUL      3'b000
`define FUNCT3_MULH     3'b001
`define FUNCT3_MULHSU   3'b010
`define FUNCT3_MULHU    3'b011
`define FUNCT3_DIV      3'b100
`define FUNCT3_DIVU     3'b101
`define FUNCT3_REM      3'b110
`define FUNCT3_REMU     3'b111

// =========================================================================
// Immediate type encoding (for immediate generator)
// =========================================================================
`define IMM_I  3'd0   // I-type
`define IMM_S  3'd1   // S-type
`define IMM_B  3'd2   // B-type
`define IMM_U  3'd3   // U-type
`define IMM_J  3'd4   // J-type

// =========================================================================
// SYSTEM instructions (opcode OP_SYSTEM)
// =========================================================================
// funct3 = 000 selects the privileged group, identified by the whole word.
`define FUNCT3_PRIV     3'b000
`define INST_ECALL      32'h0000_0073
`define INST_EBREAK     32'h0010_0073
`define INST_MRET       32'h3020_0073
`define INST_WFI        32'h1050_0073

// The other funct3 values are the Zicsr instructions. funct3[2] selects the
// immediate form (uimm in the rs1 field) and funct3[1:0] the operation.
`define CSR_OP_RW       2'b01
`define CSR_OP_RS       2'b10
`define CSR_OP_RC       2'b11

// =========================================================================
// Write-back select (wb_sel)
// =========================================================================
`define WB_ALU   2'd0
`define WB_MEM   2'd1
`define WB_PC4   2'd2
`define WB_CSR   2'd3

// =========================================================================
// CSR addresses (machine mode only)
// =========================================================================
`define CSR_MSTATUS     12'h300
`define CSR_MISA        12'h301
`define CSR_MIE         12'h304
`define CSR_MTVEC       12'h305
`define CSR_MSTATUSH    12'h310
`define CSR_MSCRATCH    12'h340
`define CSR_MEPC        12'h341
`define CSR_MCAUSE      12'h342
`define CSR_MTVAL       12'h343
`define CSR_MIP         12'h344
`define CSR_MCYCLE      12'hB00
`define CSR_MINSTRET    12'hB02
`define CSR_MCYCLEH     12'hB80
`define CSR_MINSTRETH   12'hB82
`define CSR_CYCLE       12'hC00
`define CSR_TIME        12'hC01
`define CSR_INSTRET     12'hC02
`define CSR_CYCLEH      12'hC80
`define CSR_TIMEH       12'hC81
`define CSR_INSTRETH    12'hC82
`define CSR_MVENDORID   12'hF11
`define CSR_MARCHID     12'hF12
`define CSR_MIMPID      12'hF13
`define CSR_MHARTID     12'hF14

// =========================================================================
// mcause codes
// =========================================================================
// Exceptions (mcause[31] = 0)
`define EXC_INST_MISALIGNED   4'd0
`define EXC_INST_ACCESS       4'd1
`define EXC_ILLEGAL_INST      4'd2
`define EXC_BREAKPOINT        4'd3
`define EXC_LOAD_MISALIGNED   4'd4
`define EXC_STORE_MISALIGNED  4'd6
`define EXC_ECALL_M           4'd11
// Interrupts (mcause[31] = 1)
`define IRQ_M_SOFT            4'd3
`define IRQ_M_TIMER           4'd7
`define IRQ_M_EXT             4'd11
