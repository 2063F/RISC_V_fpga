`timescale 1ns / 1ps
// =============================================================================
// instruction_memory.v - Dual-port ROM module for Instructions and .rodata
// =============================================================================

module instruction_memory #(
    parameter INIT_FILE = ""
) (
    // Port A: Instruction Fetch
    input  wire [31:0] addr,
    output wire [31:0] dout,

    // Port B: Data Read (.rodata constants)
    input  wire [31:0] addr_b,
    output wire [31:0] dout_b
);

    // 8192-word instruction/rodata ROM (32 KB total)
    reg [31:0] mem [0:8191];

    wire [12:0] word_addr   = addr[14:2];
    wire [12:0] word_addr_b = addr_b[14:2];

    // Read logic: outputs instructions/rodata when the byte address is within the
    // implemented 32 KB region (0x0000_0000 - 0x0000_7FFF).
    assign dout   = (addr   < 32'h0000_8000) ? mem[word_addr]   : 32'h0000_0013;
    assign dout_b = (addr_b < 32'h0000_8000) ? mem[word_addr_b] : 32'h0000_0000;

    integer i;
    initial begin
        // Fill the unused words with NOPs so that a testbench which only writes
        // a handful of instructions still runs off into harmless code.
        //
        // GowinSynthesis unrolls for-loops and errors out past 2000 iterations
        // ("Loop count limit of 2000 exceeded"), which turned this whole module
        // into a black box and failed synthesis. The fill is only needed in
        // simulation - BSRAM powers up zeroed on the device - so it is hidden
        // from the synthesiser. $readmemh below stays visible: that is what
        // initialises the ROM contents in the bitstream.
        // synthesis translate_off
        for (i = 0; i < 8192; i = i + 1) begin
            mem[i] = 32'h0000_0013; // NOP
        end
        // synthesis translate_on
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

endmodule
