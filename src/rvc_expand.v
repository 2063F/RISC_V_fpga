`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: rvc_expand
// Project Name: RISC-V RV32IMAC CPU
// Description: Expands a 16-bit RV32C instruction into the 32-bit instruction
//              it stands for, so that the decoder only ever sees RV32I/M/A.
//              Combinational.
//
// Every RV32C instruction without F/D is covered. Encodings that are reserved,
// RV64/RV128-only or floating point raise illegal; that includes the all-zero
// halfword. HINTs (e.g. C.ADDI with rd = x0, C.LI with rd = x0) expand to the
// base instruction they correspond to, which writes nothing.
//////////////////////////////////////////////////////////////////////////////////

module rvc_expand (
    input  wire [15:0] c,         // the compressed instruction (c[1:0] != 2'b11)
    output reg  [31:0] inst,      // its 32-bit equivalent
    output reg         illegal
);

    localparam [6:0] OP_LOAD   = 7'b0000011;
    localparam [6:0] OP_IMM    = 7'b0010011;
    localparam [6:0] OP_STORE  = 7'b0100011;
    localparam [6:0] OP_OP     = 7'b0110011;
    localparam [6:0] OP_LUI    = 7'b0110111;
    localparam [6:0] OP_BRANCH = 7'b1100011;
    localparam [6:0] OP_JALR   = 7'b1100111;
    localparam [6:0] OP_JAL    = 7'b1101111;

    localparam [4:0] X0 = 5'd0, RA = 5'd1, SP = 5'd2;

    wire [2:0] funct3 = c[15:13];

    // Full register fields (CR/CI/CSS) and the x8-x15 ones (CIW/CL/CS/CA/CB)
    wire [4:0] rd   = c[11:7];
    wire [4:0] rs2  = c[6:2];
    wire [4:0] rdp  = {2'b01, c[4:2]};   // rd' / rs2'
    wire [4:0] rs1p = {2'b01, c[9:7]};   // rs1' / rd'

    // Immediates, already sign- or zero-extended to 12 bits (or 20 for JAL)
    wire [11:0] imm_ci     = {{7{c[12]}}, c[6:2]};                                   // C.ADDI, C.LI, C.ANDI
    wire [11:0] imm_4spn   = {2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00};          // C.ADDI4SPN
    wire [11:0] imm_lw     = {5'b00000, c[5], c[12:10], c[6], 2'b00};                // C.LW / C.SW
    wire [11:0] imm_lwsp   = {4'b0000, c[3:2], c[12], c[6:4], 2'b00};                // C.LWSP
    wire [11:0] imm_swsp   = {4'b0000, c[8:7], c[12:9], 2'b00};                      // C.SWSP
    wire [11:0] imm_16sp   = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000};        // C.ADDI16SP
    wire [19:0] imm_lui    = {{15{c[12]}}, c[6:2]};                                  // C.LUI (imm[31:12])
    wire [20:0] imm_j      = {{10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11],
                              c[5:3], 1'b0};                                         // C.J / C.JAL
    wire [12:0] imm_b      = {{5{c[12]}}, c[6:5], c[2], c[11:10], c[4:3], 1'b0};     // C.BEQZ / C.BNEZ
    wire [4:0]  shamt      = c[6:2];

    always @(*) begin
        inst    = 32'h0000_0013;      // nop, for the illegal cases
        illegal = 1'b0;

        case (c[1:0])
            // -----------------------------------------------------------------
            // Quadrant 0
            // -----------------------------------------------------------------
            2'b00: case (funct3)
                3'b000: begin   // C.ADDI4SPN: addi rd', sp, nzuimm
                    inst    = {imm_4spn, SP, 3'b000, rdp, OP_IMM};
                    illegal = (imm_4spn == 12'd0);           // includes 0x0000
                end
                3'b010:         // C.LW: lw rd', uimm(rs1')
                    inst = {imm_lw, rs1p, 3'b010, rdp, OP_LOAD};
                3'b110:         // C.SW: sw rs2', uimm(rs1')
                    inst = {imm_lw[11:5], rdp, rs1p, 3'b010, imm_lw[4:0], OP_STORE};
                default:        // C.FLD/FLW/FSD/FSW and the reserved 100
                    illegal = 1'b1;
            endcase

            // -----------------------------------------------------------------
            // Quadrant 1
            // -----------------------------------------------------------------
            2'b01: case (funct3)
                3'b000:         // C.ADDI (C.NOP with rd = 0): addi rd, rd, imm
                    inst = {imm_ci, rd, 3'b000, rd, OP_IMM};
                3'b001,         // C.JAL: jal ra, offset
                3'b101:         // C.J:   jal x0, offset
                    inst = {imm_j[20], imm_j[10:1], imm_j[11], imm_j[19:12],
                            funct3[2] ? X0 : RA, OP_JAL};
                3'b010:         // C.LI: addi rd, x0, imm
                    inst = {imm_ci, X0, 3'b000, rd, OP_IMM};
                3'b011: begin
                    if (rd == SP) begin // C.ADDI16SP: addi sp, sp, nzimm
                        inst    = {imm_16sp, SP, 3'b000, SP, OP_IMM};
                        illegal = (imm_16sp == 12'd0);
                    end else begin      // C.LUI: lui rd, nzimm
                        inst    = {imm_lui, rd, OP_LUI};
                        illegal = ({c[12], c[6:2]} == 6'd0);
                    end
                end
                3'b100: case (c[11:10])
                    2'b00: begin    // C.SRLI
                        inst    = {7'b0000000, shamt, rs1p, 3'b101, rs1p, OP_IMM};
                        illegal = c[12];                     // shamt[5]: RV64 only
                    end
                    2'b01: begin    // C.SRAI
                        inst    = {7'b0100000, shamt, rs1p, 3'b101, rs1p, OP_IMM};
                        illegal = c[12];
                    end
                    2'b10:          // C.ANDI
                        inst = {imm_ci, rs1p, 3'b111, rs1p, OP_IMM};
                    2'b11: begin
                        if (c[12]) begin
                            illegal = 1'b1;                  // C.SUBW / C.ADDW / reserved
                        end else case (c[6:5])
                            2'b00: inst = {7'b0100000, rdp, rs1p, 3'b000, rs1p, OP_OP}; // C.SUB
                            2'b01: inst = {7'b0000000, rdp, rs1p, 3'b100, rs1p, OP_OP}; // C.XOR
                            2'b10: inst = {7'b0000000, rdp, rs1p, 3'b110, rs1p, OP_OP}; // C.OR
                            2'b11: inst = {7'b0000000, rdp, rs1p, 3'b111, rs1p, OP_OP}; // C.AND
                        endcase
                    end
                endcase
                3'b110,         // C.BEQZ: beq rs1', x0, offset
                3'b111:         // C.BNEZ: bne rs1', x0, offset
                    inst = {imm_b[12], imm_b[10:5], X0, rs1p, 2'b00, funct3[0],
                            imm_b[4:1], imm_b[11], OP_BRANCH};
            endcase

            // -----------------------------------------------------------------
            // Quadrant 2
            // -----------------------------------------------------------------
            2'b10: case (funct3)
                3'b000: begin   // C.SLLI
                    inst    = {7'b0000000, shamt, rd, 3'b001, rd, OP_IMM};
                    illegal = c[12];
                end
                3'b010: begin   // C.LWSP: lw rd, uimm(sp)
                    inst    = {imm_lwsp, SP, 3'b010, rd, OP_LOAD};
                    illegal = (rd == X0);
                end
                3'b100: begin
                    if (!c[12]) begin
                        if (rs2 == X0) begin    // C.JR: jalr x0, 0(rs1)
                            inst    = {12'd0, rd, 3'b000, X0, OP_JALR};
                            illegal = (rd == X0);
                        end else begin          // C.MV: add rd, x0, rs2
                            inst = {7'b0000000, rs2, X0, 3'b000, rd, OP_OP};
                        end
                    end else begin
                        if (rs2 == X0 && rd == X0)  // C.EBREAK
                            inst = 32'h0010_0073;
                        else if (rs2 == X0)         // C.JALR: jalr ra, 0(rs1)
                            inst = {12'd0, rd, 3'b000, RA, OP_JALR};
                        else                        // C.ADD: add rd, rd, rs2
                            inst = {7'b0000000, rs2, rd, 3'b000, rd, OP_OP};
                    end
                end
                3'b110:         // C.SWSP: sw rs2, uimm(sp)
                    inst = {imm_swsp[11:5], rs2, SP, 3'b010, imm_swsp[4:0], OP_STORE};
                default:        // C.FLDSP/FLWSP/FSDSP/FSWSP
                    illegal = 1'b1;
            endcase

            default: illegal = 1'b1;    // 2'b11 is not a compressed instruction
        endcase
    end

endmodule
