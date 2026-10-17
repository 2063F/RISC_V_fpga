`timescale 1ns / 1ps
// =============================================================================
// bitmanip.v - Zbb CPOP / CTZ for the RV32IM soft CPU
// =============================================================================
//   cpop rd, rs1 : number of set bits in rs1                (0..32)
//   ctz  rd, rs1 : number of trailing zero bits in rs1      (32 when rs1 == 0)
//
// Only these two of Zbb are implemented, so the compiler must not be told
// -march=rv32im_zbb (it would emit the rest of Zbb as well). Software reaches
// them through examples/zbb.h, which encodes them with .insn.
//
// Why this is not in alu.v
// ------------------------
// alu_result drives address decoding, the memory address and the branch
// comparison - the paths that set the 50 MHz margin. This unit hangs off
// ex_rs1_data like multiplier.v and divider.v and is muxed in at write-back
// only, so none of those paths get longer.
//
// Both are single-cycle and combinational, with shallow logic:
//   - cpop is an explicit adder tree (2 -> 3 -> 4 -> 5 -> 6 bits). A plain
//     `cnt = cnt + a[i]` loop would synthesise as a 32-deep adder chain.
//   - ctz isolates the lowest set bit with a & -a (one carry chain) and then
//     encodes that one-hot word with five wide ORs. a == 0 gives a & -a == 0,
//     so the encoder already outputs 0 and only bit 5 needs the zero test.
// =============================================================================

module bitmanip (
    input  wire [31:0] a,
    input  wire        is_ctz,     // 0: cpop, 1: ctz
    output wire [31:0] result
);

    // -------------------------------------------------------------------------
    // CPOP: adder tree
    // -------------------------------------------------------------------------
    wire [1:0] c2 [0:15];
    wire [2:0] c3 [0:7];
    wire [3:0] c4 [0:3];
    wire [4:0] c5 [0:1];
    wire [5:0] cpop = c5[0] + c5[1];

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_c2
            assign c2[i] = a[2*i] + a[2*i+1];
        end
        for (i = 0; i < 8; i = i + 1) begin : g_c3
            assign c3[i] = c2[2*i] + c2[2*i+1];
        end
        for (i = 0; i < 4; i = i + 1) begin : g_c4
            assign c4[i] = c3[2*i] + c3[2*i+1];
        end
        for (i = 0; i < 2; i = i + 1) begin : g_c5
            assign c5[i] = c4[2*i] + c4[2*i+1];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // CTZ: isolate the lowest set bit, then one-hot -> binary
    // -------------------------------------------------------------------------
    wire [31:0] lsb = a & (~a + 32'd1);

    wire [5:0] ctz;
    assign ctz[0] = |(lsb & 32'hAAAA_AAAA);
    assign ctz[1] = |(lsb & 32'hCCCC_CCCC);
    assign ctz[2] = |(lsb & 32'hF0F0_F0F0);
    assign ctz[3] = |(lsb & 32'hFF00_FF00);
    assign ctz[4] = |(lsb & 32'hFFFF_0000);
    assign ctz[5] = (a == 32'd0);

    assign result = {26'd0, is_ctz ? ctz : cpop};

endmodule
