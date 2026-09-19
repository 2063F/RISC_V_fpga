`timescale 1ns / 1ps
// =============================================================================
// divider.v - Multi-cycle restoring divider for RV32M DIV / DIVU / REM / REMU
// =============================================================================
// One quotient bit per clock: 34 cycles from `start` to `done` for a normal
// division, 2 cycles for the degenerate cases (divide by zero, and the signed
// MIN_INT / -1 overflow).
//
// Why this is not combinational
// -----------------------------
// It used to be: alu.v unrolled the whole 32-iteration restoring loop into
// combinational logic. That built a ripple chain long enough to dominate the
// entire design - place & route reported a maximum frequency of 5.031 MHz
// against the 50 MHz constraint, with a setup slack of -178.7 ns, and the
// critical path ran straight through the divider. Everything else in the CPU
// met timing comfortably.
//
// Handshake
// ---------
//   start : assert for one cycle with the operands valid. Ignored unless idle.
//   done  : asserted for one cycle, in the same cycle `result` becomes valid.
//           The CPU stalls from the start cycle until done (see cpu_top.v), so
//           the operands and the destination register are still the divide's.
//
// Results follow the RISC-V spec:
//   divide by zero : DIV/DIVU -> all ones, REM/REMU -> the dividend
//   MIN_INT / -1   : DIV -> MIN_INT, REM -> 0 (signed forms only)
// =============================================================================

module divider (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,      // 1-cycle request
    input  wire [31:0] a,          // dividend
    input  wire [31:0] b,          // divisor
    input  wire        is_signed,  // 1 = DIV/REM, 0 = DIVU/REMU
    input  wire        want_rem,   // 1 = REM/REMU, 0 = DIV/DIVU

    output reg  [31:0] result,
    output reg         done
);

    localparam [1:0] S_IDLE = 2'd0,
                     S_CALC = 2'd1,
                     S_FIN  = 2'd2;

    reg [1:0]  state;
    reg [31:0] quotient;
    reg [32:0] remainder;   // 33 bits so the shift-in can never overflow
    reg [31:0] divisor;
    reg [31:0] dividend;
    reg [5:0]  count;
    reg        neg_quotient;
    reg        neg_remainder;
    reg        want_rem_q;

    // Operand preparation for the normal (non-degenerate) path.
    wire        a_neg = is_signed && a[31];
    wire        b_neg = is_signed && b[31];
    wire [31:0] abs_a = a_neg ? (~a + 32'd1) : a;
    wire [31:0] abs_b = b_neg ? (~b + 32'd1) : b;

    wire div_by_zero = (b == 32'd0);
    wire overflow    = is_signed && (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);

    // One restoring step, applied to the registered state.
    wire [32:0] shifted  = {remainder[31:0], dividend[31]};
    wire        subtract = (shifted >= {1'b0, divisor});

    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            result        <= 32'd0;
            done          <= 1'b0;
            quotient      <= 32'd0;
            remainder     <= 33'd0;
            divisor       <= 32'd0;
            dividend      <= 32'd0;
            count         <= 6'd0;
            neg_quotient  <= 1'b0;
            neg_remainder <= 1'b0;
            want_rem_q    <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        want_rem_q <= want_rem;

                        if (div_by_zero) begin
                            result <= want_rem ? a : 32'hFFFF_FFFF;
                            done   <= 1'b1;
                        end else if (overflow) begin
                            result <= want_rem ? 32'd0 : 32'h8000_0000;
                            done   <= 1'b1;
                        end else begin
                            dividend      <= abs_a;
                            divisor       <= abs_b;
                            quotient      <= 32'd0;
                            remainder     <= 33'd0;
                            neg_quotient  <= a_neg ^ b_neg;
                            neg_remainder <= a_neg;
                            count         <= 6'd32;
                            state         <= S_CALC;
                        end
                    end
                end

                S_CALC: begin
                    dividend <= dividend << 1;

                    if (subtract) begin
                        remainder <= shifted - {1'b0, divisor};
                        quotient  <= {quotient[30:0], 1'b1};
                    end else begin
                        remainder <= shifted;
                        quotient  <= {quotient[30:0], 1'b0};
                    end

                    count <= count - 6'd1;
                    if (count == 6'd1) begin
                        state <= S_FIN;
                    end
                end

                S_FIN: begin
                    // Apply the signs. RISC-V defines the remainder to take the
                    // sign of the dividend, and the quotient the XOR of both.
                    if (want_rem_q)
                        result <= neg_remainder ? (~remainder[31:0] + 32'd1)
                                                : remainder[31:0];
                    else
                        result <= neg_quotient ? (~quotient + 32'd1)
                                               : quotient;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
