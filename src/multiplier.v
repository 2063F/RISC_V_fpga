`timescale 1ns / 1ps
// =============================================================================
// multiplier.v - Multi-cycle multiplier for RV32M MUL / MULH / MULHSU / MULHU
// =============================================================================
// Three cycles from `start` to `done`, arranged so that the 32x32 -> 64 product
// sits between two register stages:
//
//   cycle 1 (S_LOAD) : latch the operands
//   cycle 2 (S_MUL)  : product <= a_q * b_q      <- the long path, reg to reg
//   cycle 3 (S_SEL)  : pick the requested half, assert done
//
// Why this is not combinational
// -----------------------------
// It used to be: alu.v computed all four products combinationally. Once the
// divider had been moved out (see divider.v) this became the new critical path
// - place & route reported 39.377 MHz against the 50 MHz constraint with a
// setup slack of -5.395 ns, and the path ran from the instruction ROM through
// the register file into alu_inst/mul_unsigned's carry chain.
//
// Keeping the half-selection in its own cycle keeps that mux off the
// register-to-register multiply path.
//
// Handshake matches divider.v: `start` for one cycle, `done` for one cycle in
// the same cycle `result` becomes valid.
// =============================================================================

`include "riscv_defines.vh"

module multiplier (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,      // 1-cycle request
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [4:0]  op,         // ALU_MUL / ALU_MULH / ALU_MULHSU / ALU_MULHU

    output reg  [31:0] result,
    output reg         done
);

    localparam [1:0] S_IDLE = 2'd0,
                     S_MUL  = 2'd1,
                     S_SEL  = 2'd2;

    reg [1:0]  state;
    reg [31:0] a_q, b_q;
    reg [4:0]  op_q;
    reg [63:0] product;

    // Sign treatment per RISC-V: MULH is signed x signed, MULHU unsigned x
    // unsigned, MULHSU signed x unsigned. MUL keeps only the low 32 bits, where
    // signedness does not matter.
    wire a_signed = (op_q == `ALU_MULH) || (op_q == `ALU_MULHSU);
    wire b_signed = (op_q == `ALU_MULH);

    wire signed [32:0] a_ext = {a_signed & a_q[31], a_q};
    wire signed [32:0] b_ext = {b_signed & b_q[31], b_q};

    always @(posedge clk) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            result  <= 32'd0;
            done    <= 1'b0;
            a_q     <= 32'd0;
            b_q     <= 32'd0;
            op_q    <= 5'd0;
            product <= 64'd0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        a_q   <= a;
                        b_q   <= b;
                        op_q  <= op;
                        state <= S_MUL;
                    end
                end

                S_MUL: begin
                    product <= a_ext * b_ext;
                    state   <= S_SEL;
                end

                S_SEL: begin
                    result <= (op_q == `ALU_MUL) ? product[31:0] : product[63:32];
                    done   <= 1'b1;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
