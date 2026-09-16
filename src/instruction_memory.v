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
    // Initialize memory with NOPs
    initial begin
        for (i = 0; i < 8192; i = i + 1) begin
            mem[i] = 32'h0000_0013; // NOP
        end
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

endmodule
