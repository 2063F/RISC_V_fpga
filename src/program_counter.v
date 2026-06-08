`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/23
// Design Name: 
// Module Name: program_counter
// Project Name: RISC-V RV32I CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Tool Versions: 
// Description: Program Counter (PC) register for single cycle CPU.
//              Holds the address of the instruction to be executed.
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module program_counter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] pc_in,
    output reg  [31:0] pc_out
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_out <= 32'h0000_0000;
        end else begin
            pc_out <= pc_in;
        end
    end

endmodule
