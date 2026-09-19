`timescale 1ns / 1ps
// =============================================================================
// instruction_memory.v - Dual-port ROM for instructions and .rodata
// =============================================================================
// 8192-word (32 KB) ROM covering 0x0000_0000 - 0x0000_7FFF.
//
// Both ports have a REGISTERED read, which is what GowinSynthesis needs to map
// the array onto BSRAM; a combinational read makes it fall back to flip-flops
// and blow past the device limit (see data_memory.v for the same story).
//
// Port A is the instruction fetch. Its output register IS the IF/ID pipeline
// register - the address is applied in the fetch cycle and the instruction
// appears in the execute cycle, exactly the timing cpu_top had when it latched
// a combinational read into its own ifid_inst register. `ce` freezes it while
// the CPU stalls, so a stalled instruction is not overwritten by the next one.
// It reports out-of-range fetches through dout_valid instead of substituting a
// NOP itself; cpu_top folds that into the flush mask it already needs.
//
// Port B reads .rodata constants. Its data also arrives one cycle late, which
// the CPU covers with the same one-cycle load stall it uses for the RAM.
// =============================================================================

module instruction_memory #(
    parameter INIT_FILE = ""
) (
    input  wire        clk,

    // Port A: instruction fetch
    input  wire        ce,          // clock enable (0 = hold dout, used while stalled)
    input  wire [31:0] addr,
    output wire [31:0] dout,        // raw ROM word, NOT masked for range
    output wire        dout_valid,  // 0 = addr was outside the ROM

    // Port B: data read (.rodata constants)
    input  wire [31:0] addr_b,
    output wire [31:0] dout_b
);

    localparam integer WORDS    = 8192;
    localparam [31:0]  NOP_INST = 32'h0000_0013;

    reg [31:0] mem [0:WORDS-1];

    wire [12:0] word_addr   = addr[14:2];
    wire [12:0] word_addr_b = addr_b[14:2];

    // Out-of-range fetches read as NOP, out-of-range data reads as 0. The range
    // check is registered alongside the data so it stays aligned with it.
    wire addr_in_range   = (addr   < 32'h0000_8000);
    wire addr_b_in_range = (addr_b < 32'h0000_8000);

    reg [31:0] q_a, q_b;
    reg        q_a_in_range, q_b_in_range;

    always @(posedge clk) begin
        if (ce) begin
            q_a          <= mem[word_addr];
            q_a_in_range <= addr_in_range;
        end
    end

    always @(posedge clk) begin
        q_b          <= mem[word_addr_b];
        q_b_in_range <= addr_b_in_range;
    end

    // Port A hands the raw word and a validity bit to cpu_top, which already
    // has to mask flushed slots to a NOP. Masking here as well would put two
    // muxes back to back on the fetch path, and that path (ROM -> register file
    // -> ALU) is the critical path of the design.
    assign dout       = q_a;
    assign dout_valid = q_a_in_range;

    assign dout_b = q_b_in_range ? q_b : 32'h0000_0000;

    // =========================================================================
    // ROM contents
    // =========================================================================
    integer i;
    initial begin
        // Fill the unused words with NOPs so that a testbench which only writes
        // a handful of instructions still runs off into harmless code.
        //
        // GowinSynthesis unrolls for-loops and errors out past 2000 iterations
        // ("Loop count limit of 2000 exceeded"), so the fill is hidden from it.
        // BSRAM comes up zeroed on the device, and $readmemh below is what
        // actually puts the program into the bitstream.
        // synthesis translate_off
        for (i = 0; i < WORDS; i = i + 1) begin
            mem[i] = NOP_INST;
        end
        q_a = NOP_INST; q_b = 32'd0;
        q_a_in_range = 1'b1; q_b_in_range = 1'b0;
        // synthesis translate_on
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

endmodule
