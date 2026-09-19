// =============================================================================
// alu.v - 32-bit ALU for RISC-V RV32I CPU
// =============================================================================
// Operations: ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU, and the
//             RV32M multiplies. Division lives in divider.v (multi-cycle).
//
// Key differences from x86 ALU:
//   - No flag registers (CF, ZF, SF, OF, PF, AF) — not needed!
//   - Always 32-bit — no 8/16/32-bit size switching
//   - Only 'zero' output needed for branch instructions
//   - Much simpler: ~100 lines vs 357 lines for x86
// =============================================================================

`include "riscv_defines.vh"

module alu (
    input  wire [31:0] a,        // Operand A (always from register)
    input  wire [31:0] b,        // Operand B (register or immediate)
    input  wire [4:0]  alu_op,   // Operation select (see riscv_defines.vh)

    output reg  [31:0] result,   // Operation result
    output wire        zero      // 1 when result == 0 (used for branch)
);

    // Intermediate 64-bit results for multiplication
    wire signed [63:0] mul_signed          = $signed(a) * $signed(b);
    wire signed [63:0] mul_signed_unsigned = $signed(a) * $signed({1'b0, b});
    wire        [63:0] mul_unsigned        = {32'd0, a} * {32'd0, b};

    // zero flag: used by BEQ/BNE branch logic in control unit
    assign zero = (result == 32'd0);

    always @(*) begin
        case (alu_op)
            // ------------------------------------------------------------------
            // ADD: a + b
            // ------------------------------------------------------------------
            `ALU_ADD:    result = a + b;

            // ------------------------------------------------------------------
            // SUB: a - b
            // ------------------------------------------------------------------
            `ALU_SUB:    result = a - b;

            // ------------------------------------------------------------------
            // AND: a & b
            // ------------------------------------------------------------------
            `ALU_AND:    result = a & b;

            // ------------------------------------------------------------------
            // OR: a | b
            // ------------------------------------------------------------------
            `ALU_OR:     result = a | b;

            // ------------------------------------------------------------------
            // XOR: a ^ b
            // ------------------------------------------------------------------
            `ALU_XOR:    result = a ^ b;

            // ------------------------------------------------------------------
            // SLL: Shift Left Logical — shift amount = b[4:0]
            // ------------------------------------------------------------------
            `ALU_SLL:    result = a << b[4:0];

            // ------------------------------------------------------------------
            // SRL: Shift Right Logical — shift amount = b[4:0]
            // ------------------------------------------------------------------
            `ALU_SRL:    result = a >> b[4:0];

            // ------------------------------------------------------------------
            // SRA: Shift Right Arithmetic (sign-extending) — shift = b[4:0]
            // ------------------------------------------------------------------
            `ALU_SRA:    result = $signed(a) >>> b[4:0];

            // ------------------------------------------------------------------
            // SLT: Set Less Than (signed comparison)
            //      result = 1 if a < b (signed), else 0
            // ------------------------------------------------------------------
            `ALU_SLT:    result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;

            // ------------------------------------------------------------------
            // SLTU: Set Less Than Unsigned
            //       result = 1 if a < b (unsigned), else 0
            // ------------------------------------------------------------------
            `ALU_SLTU:   result = (a < b) ? 32'd1 : 32'd0;

            // ------------------------------------------------------------------
            // PASS_B: Pass operand B through unchanged
            //         Used for LUI: rd = imm (no addition needed)
            // ------------------------------------------------------------------
            `ALU_PASS_B: result = b;

            // ------------------------------------------------------------------
            // M Extension: Multiplication (MUL, MULH, MULHSU, MULHU)
            // ------------------------------------------------------------------
            `ALU_MUL:    result = a * b;
            `ALU_MULH:   result = mul_signed[63:32];
            `ALU_MULHSU: result = mul_signed_unsigned[63:32];
            `ALU_MULHU:  result = mul_unsigned[63:32];

            // ------------------------------------------------------------------
            // M Extension: Division and Remainder (DIV, DIVU, REM, REMU)
            // ------------------------------------------------------------------
            // Not handled here. The 32-iteration restoring loop used to be
            // unrolled into combinational logic in this module, and it became
            // the critical path of the whole design: place & route reported a
            // maximum frequency of 5.031 MHz against the 50 MHz constraint.
            // divider.v now does it over 34 cycles and cpu_top stalls; the
            // result is muxed in at write-back, so these opcodes fall through
            // to the default below.

            default:     result = 32'd0;
        endcase
    end

endmodule
