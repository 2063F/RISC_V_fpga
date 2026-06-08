`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/23
// Design Name: 
// Module Name: instruction_memory
// Project Name: RISC-V RV32I CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Tool Versions: 
// Description: Instruction Memory (ROM) module.
//              Holds the program code (16 KB = 4096 words of 32-bit).
//              Initialized with NOPs. Can be loaded using $readmemh.
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module instruction_memory #(
    parameter INIT_FILE = ""
) (
    input  wire [31:0] addr,
    output wire [31:0] dout
);

    // 512 B instruction memory (128 words of 32-bit)
    reg [31:0] mem [0:127];

    // Word addressing: Ignore lower 2 bits (since instructions are 4-byte aligned)
    // and use bits [8:2] for indexing 128 words.
    wire [6:0] word_addr = addr[8:2];

    // Read logic: Outputs instructions when address is within 0x0000_0000 - 0x0000_01FF.
    // Otherwise, outputs NOP (addi x0, x0, 0 -> 32'h00000013).
    assign dout = (addr < 32'h0000_0200) ? mem[word_addr] : 32'h0000_0013;

    integer i;
    // Initialize memory with NOPs
    initial begin
        for (i = 0; i < 128; i = i + 1) begin
            mem[i] = 32'h0000_0013; // NOP
        end
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

endmodule
