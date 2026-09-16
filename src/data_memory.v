`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/23
// Design Name: 
// Module Name: data_memory
// Project Name: RISK-V RV32I CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Tool Versions: 
// Description: Data Memory (RAM) module supporting byte, halfword, and word
//              reads and writes in a 128-word (512-byte) scratch RAM.
//              The implemented region is 0x0001_0000 - 0x0001_01FF.
//
// Dependencies: riscv_defines.vh
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`include "riscv_defines.vh"

module data_memory (
    input  wire        clk,
    input  wire [31:0] addr,          // Byte address
    input  wire [31:0] write_data,    // Data to be written
    input  wire        write_en,      // Write enable
    input  wire        read_en,       // Read enable
    input  wire [2:0]  funct3,        // Access size and extension type
    output reg  [31:0] read_data      // Read data (output formatted)
);

    // 16384-word data RAM (64 KB total)
    reg [31:0] mem [0:16383];

    // Address Decode
    // Only the lower 64 KB of the 0x0001_0000 region are implemented,
    // so valid addresses are 0x0001_0000 - 0x0001_FFFF.
    wire addr_valid = (addr >= 32'h0001_0000) && (addr <= 32'h0001_FFFF);

    // Index within the 16384-word memory (bits [15:2] of the byte address)
    wire [13:0] word_addr = addr[15:2];
    wire [1:0]  byte_offset = addr[1:0];

    // =========================================================================
    // Memory Write Logic (Synchronous)
    // Supports Word, Halfword, and Byte writes
    // =========================================================================
    always @(posedge clk) begin
        if (write_en && addr_valid) begin
            case (funct3)
                // SW (Store Word)
                `FUNCT3_WORD: begin
                    mem[word_addr] <= write_data;
                end
                
                // SH (Store Halfword)
                `FUNCT3_HALF: begin
                    if (byte_offset[1] == 1'b0) begin
                        mem[word_addr][15:0] <= write_data[15:0];
                    end else begin
                        mem[word_addr][31:16] <= write_data[15:0];
                    end
                end
                
                // SB (Store Byte)
                `FUNCT3_BYTE: begin
                    case (byte_offset)
                        2'b00: mem[word_addr][7:0]   <= write_data[7:0];
                        2'b01: mem[word_addr][15:8]  <= write_data[7:0];
                        2'b10: mem[word_addr][23:16] <= write_data[7:0];
                        2'b11: mem[word_addr][31:24] <= write_data[7:0];
                    endcase
                end
                
                default: begin
                    // Fallback
                end
            endcase
        end
    end

    // =========================================================================
    // Memory Read Logic (Asynchronous / Combinational)
    // Supports Word, Halfword, and Byte reads with Sign/Zero extension
    // =========================================================================
    wire [31:0] raw_data = (addr_valid) ? mem[word_addr] : 32'd0;

    always @(*) begin
        if (!read_en || !addr_valid) begin
            read_data = 32'd0;
        end else begin
            case (funct3)
                // LW (Load Word)
                `FUNCT3_WORD: begin
                    read_data = raw_data;
                end
                
                // LH (Load Halfword - Signed)
                `FUNCT3_HALF: begin
                    if (byte_offset[1] == 1'b0) begin
                        read_data = {{16{raw_data[15]}}, raw_data[15:0]};
                    end else begin
                        read_data = {{16{raw_data[31]}}, raw_data[31:16]};
                    end
                end
                
                // LHU (Load Halfword - Unsigned)
                `FUNCT3_HALFU: begin
                    if (byte_offset[1] == 1'b0) begin
                        read_data = {16'd0, raw_data[15:0]};
                    end else begin
                        read_data = {16'd0, raw_data[31:16]};
                    end
                end
                
                // LB (Load Byte - Signed)
                `FUNCT3_BYTE: begin
                    case (byte_offset)
                        2'b00: read_data = {{24{raw_data[7]}},  raw_data[7:0]};
                        2'b01: read_data = {{24{raw_data[15]}}, raw_data[15:8]};
                        2'b10: read_data = {{24{raw_data[23]}}, raw_data[23:16]};
                        2'b11: read_data = {{24{raw_data[31]}}, raw_data[31:24]};
                    endcase
                end
                
                // LBU (Load Byte - Unsigned)
                `FUNCT3_BYTEU: begin
                    case (byte_offset)
                        2'b00: read_data = {24'd0, raw_data[7:0]};
                        2'b01: read_data = {24'd0, raw_data[15:8]};
                        2'b10: read_data = {24'd0, raw_data[23:16]};
                        2'b11: read_data = {24'd0, raw_data[31:24]};
                    endcase
                end
                
                default: begin
                    read_data = raw_data;
                end
            endcase
        end
    end

    // =========================================================================
    // Memory Initialization (Optional, for simulation convenience)
    // =========================================================================
    integer i;
    initial begin
        for (i = 0; i < 16384; i = i + 1) begin
            mem[i] = 32'd0;
        end
    end

    // Note: Local loop variable i has been declared outside of the initial block
    // to strictly adhere to Verilog-2001 rules, preventing tool compilation errors.

endmodule
