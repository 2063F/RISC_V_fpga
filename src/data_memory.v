`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: data_memory
// Project Name: RISC-V RV32I CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Description: 64 KB scratch RAM (0x0001_0000 - 0x0001_FFFF) supporting byte,
//              halfword and word access.
//
// Why this module looks the way it does
// -------------------------------------
// The RAM has to land in BSRAM; there is no other way to fit 64 KB on this
// device. Two things are needed for GowinSynthesis to infer it, both verified
// by running the real flow:
//
//   1. The read port must be REGISTERED. With a combinational read the tool
//      falls back to flip-flops and stops with
//        "ERROR (IF0008) : The number(524288) of DFF used to infer 'mem'
//         exceeds the resource limit(23280)".
//      Read data therefore appears one cycle after the address, and the CPU
//      stalls for one cycle on every load (see cpu_top.v).
//
//   2. Sub-word writes must be separate byte lanes. Writing through bit-selects
//      (mem[a][15:8] <= ...) also blocks inference and hits the same IF0008.
//
// Read and write use the "no change" pattern (the output register holds its
// value during a write). GW5A single-port BSRAM rejects the read-before-write
// mode that other coding styles infer:
//   "ERROR (PA2122) : Not support ... WRITE_MODE = 2'b10".
//////////////////////////////////////////////////////////////////////////////////

`include "riscv_defines.vh"

module data_memory (
    input  wire        clk,
    input  wire [31:0] addr,          // Byte address
    input  wire [31:0] write_data,    // Data to be written
    input  wire        write_en,      // Write enable
    input  wire        read_en,       // Read enable
    input  wire [2:0]  funct3,        // Access size and extension type
    output reg  [31:0] read_data      // Read data, valid one cycle after addr
);

    localparam integer WORDS = 16384; // 16384 words = 64 KB

    // Only 0x0001_0000 - 0x0001_FFFF is implemented.
    wire        addr_valid  = (addr >= 32'h0001_0000) && (addr <= 32'h0001_FFFF);
    wire [13:0] word_addr   = addr[15:2];
    wire [1:0]  byte_offset = addr[1:0];

    // =========================================================================
    // Write lane select
    // =========================================================================
    reg [3:0] byte_we;
    always @(*) begin
        byte_we = 4'b0000;
        if (write_en && addr_valid) begin
            case (funct3)
                `FUNCT3_WORD: byte_we = 4'b1111;
                `FUNCT3_HALF: byte_we = byte_offset[1] ? 4'b1100 : 4'b0011;
                `FUNCT3_BYTE: byte_we = 4'b0001 << byte_offset;
                default:      byte_we = 4'b0000;
            endcase
        end
    end

    // Replicate the payload across all four lanes; byte_we picks the ones that
    // actually land, so every lane can take its slice at a fixed bit position.
    reg [31:0] wdata_lanes;
    always @(*) begin
        case (funct3)
            `FUNCT3_HALF: wdata_lanes = {write_data[15:0], write_data[15:0]};
            `FUNCT3_BYTE: wdata_lanes = {4{write_data[7:0]}};
            default:      wdata_lanes = write_data;
        endcase
    end

    // =========================================================================
    // Four byte-wide BSRAM lanes, registered read, "no change" on write
    // =========================================================================
    reg [7:0] mem0 [0:WORDS-1];
    reg [7:0] mem1 [0:WORDS-1];
    reg [7:0] mem2 [0:WORDS-1];
    reg [7:0] mem3 [0:WORDS-1];

    reg [7:0] q0, q1, q2, q3;

    always @(posedge clk) begin
        if (byte_we[0]) mem0[word_addr] <= wdata_lanes[7:0];
        else            q0 <= mem0[word_addr];
    end

    always @(posedge clk) begin
        if (byte_we[1]) mem1[word_addr] <= wdata_lanes[15:8];
        else            q1 <= mem1[word_addr];
    end

    always @(posedge clk) begin
        if (byte_we[2]) mem2[word_addr] <= wdata_lanes[23:16];
        else            q2 <= mem2[word_addr];
    end

    always @(posedge clk) begin
        if (byte_we[3]) mem3[word_addr] <= wdata_lanes[31:24];
        else            q3 <= mem3[word_addr];
    end

    wire [31:0] raw_data = {q3, q2, q1, q0};

    // =========================================================================
    // Size / sign extension
    // =========================================================================
    // Combinational, applied to the registered word. The CPU holds addr, funct3
    // and read_en steady across the load's stall cycle, so these are still the
    // load's own control signals when raw_data becomes valid.
    always @(*) begin
        if (!read_en || !addr_valid) begin
            read_data = 32'd0;
        end else begin
            case (funct3)
                `FUNCT3_WORD: read_data = raw_data;

                `FUNCT3_HALF: begin
                    if (byte_offset[1] == 1'b0)
                        read_data = {{16{raw_data[15]}}, raw_data[15:0]};
                    else
                        read_data = {{16{raw_data[31]}}, raw_data[31:16]};
                end

                `FUNCT3_HALFU: begin
                    if (byte_offset[1] == 1'b0)
                        read_data = {16'd0, raw_data[15:0]};
                    else
                        read_data = {16'd0, raw_data[31:16]};
                end

                `FUNCT3_BYTE: begin
                    case (byte_offset)
                        2'b00: read_data = {{24{raw_data[7]}},  raw_data[7:0]};
                        2'b01: read_data = {{24{raw_data[15]}}, raw_data[15:8]};
                        2'b10: read_data = {{24{raw_data[23]}}, raw_data[23:16]};
                        2'b11: read_data = {{24{raw_data[31]}}, raw_data[31:24]};
                    endcase
                end

                `FUNCT3_BYTEU: begin
                    case (byte_offset)
                        2'b00: read_data = {24'd0, raw_data[7:0]};
                        2'b01: read_data = {24'd0, raw_data[15:8]};
                        2'b10: read_data = {24'd0, raw_data[23:16]};
                        2'b11: read_data = {24'd0, raw_data[31:24]};
                    endcase
                end

                default: read_data = raw_data;
            endcase
        end
    end

    // =========================================================================
    // Simulation support
    // =========================================================================
    // synthesis translate_off
    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) begin
            mem0[i] = 8'd0;
            mem1[i] = 8'd0;
            mem2[i] = 8'd0;
            mem3[i] = 8'd0;
        end
        q0 = 8'd0; q1 = 8'd0; q2 = 8'd0; q3 = 8'd0;
    end

    // Testbenches read the RAM through this instead of a flat "mem" array,
    // which no longer exists now that the storage is split into byte lanes.
    function [31:0] peek_word;
        input integer word_index;
        begin
            peek_word = {mem3[word_index], mem2[word_index],
                         mem1[word_index], mem0[word_index]};
        end
    endfunction
    // synthesis translate_on

endmodule
