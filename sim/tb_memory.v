`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_memory
// Description: Testbench for Phase 4 - SW/LW/SH/LH/SB/LB/LHU/LBU
//              Writes data to memory via SW/SH/SB and reads it back.
//
//              Test program layout (in instruction memory):
//              Instruction memory: 0x0000_0000 -
//              Data memory:        0x0001_0000 -
//
//              Encoding summary:
//               SW rs2, imm(rs1) = S-type  opcode=0100011
//               LW rd, imm(rs1)  = I-type  opcode=0000011 funct3=010
//               LH rd, imm(rs1)  = I-type  opcode=0000011 funct3=001
//               LHU rd, imm(rs1) = I-type  opcode=0000011 funct3=101
//               LB rd, imm(rs1)  = I-type  opcode=0000011 funct3=000
//               LBU rd, imm(rs1) = I-type  opcode=0000011 funct3=100
//
//////////////////////////////////////////////////////////////////////////////////

module tb_memory;

    reg clk;
    reg rst_n;
    wire [31:0] mem_addr;
    wire [31:0] mem_write_data;
    wire        mem_write_en;
    wire        mem_read_en;
    reg  [31:0] mem_read_data;
    wire [31:0] debug_pc;

    cpu_top uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (mem_addr),
        .mem_write_data (mem_write_data),
        .mem_write_en   (mem_write_en),
        .mem_read_en    (mem_read_en),
        .mem_read_data  (mem_read_data),
        .debug_pc       (debug_pc)
    );

    always #10 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    task check_reg;
        input [4:0]   reg_num;
        input [31:0]  expected;
        input [255:0] name;
        begin
            #1;
            if (uut.regfile.regs[reg_num] === expected) begin
                $display("  PASS  %s: x%0d = 0x%h", name, reg_num, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %s: x%0d = 0x%h (expected 0x%h)",
                         name, reg_num, uut.regfile.regs[reg_num], expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Helper: wait N clock cycles
    task wait_cycles;
        input integer n;
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) @(posedge clk);
            #1; // small settle
        end
    endtask

    initial begin
        $dumpfile("sim/tb_memory.vcd");
        $dumpvars(0, tb_memory);

        clk = 0;
        rst_n = 0;
        mem_read_data = 32'd0;

        $display("=== Phase 4 Memory Testbench ===\n");

        // =====================================================================
        // Load the test program
        // =====================================================================
        //
        // Registers prepared:
        //   x1 = base addr 0x0001_0000
        //   x2 = 0xDEADBEEF  (word to store)
        //   x3 = 0x0000_CAFE  (halfword to store)
        //   x4 = 0x0000_00AB  (byte to store)
        //
        // Test sequence:
        //   0:  LUI  x1, 0x10001  -> x1 = 0x0001_0000  (base)
        //       LUI upper: 0x10001 -> bit 31:12 -> 0x10001 << 12 = 0x0001_0001_000 ...
        //       We want 0x0001_0000. 0x00010 << 12 = 0x10000. So LUI x1, 0x10 = 0x00010000
        //       LUI x1, 0x10 -> imm[31:12] = 0x00010 -> rd=x1 -> 32'h000102B7
        //   1:  ADDI x2, x0, -559  -> No, let's keep it simple
        //       LUI x2, 0xDEADB    -> x2 = 0xDEADB000
        //       ADDI x2, x2, 0x1EF -> but 0xEEF is negative (sign bit set)...
        //       Use ADDI x2, x0, 1234 (simpler positive value)
        //       ADDI x2, x0, 1234 -> 32'h4D200113
        //   2:  ADDI x3, x0, 0xCA = 202 -> 32'hCA000193 ... 
        //       ADDI x3, x0, 202  -> 32'hCA000193? Let me encode properly.
        //   3:  ADDI x4, x0, 0xAB = 171 (positive ok) -> 32'hAB000213
        //
        //   4:  SW x2, 0(x1)   -> store word  at 0x0001_0000
        //   5:  SH x3, 4(x1)   -> store half  at 0x0001_0004
        //   6:  SB x4, 8(x1)   -> store byte  at 0x0001_0008
        //
        //   7:  LW  x10, 0(x1) -> x10 = 1234
        //   8:  LH  x11, 4(x1) -> x11 = 202  (sign extended halfword)
        //   9:  LHU x12, 4(x1) -> x12 = 202  (zero extended)
        //  10:  LB  x13, 8(x1) -> x13 = 171  (sign extended byte, positive)
        //  11:  LBU x14, 8(x1) -> x14 = 171  (zero extended byte)
        //  12:  NOP
        //
        // Instruction encodings (all verified by hand):
        //
        //  LUI x1, 0x10      -> imm[31:12]=0x00010, rd=x0001, opcode=0110111
        //    = 00000000000100010000 00001 0110111 = 32'h000102B7
        //
        //  ADDI x2, x0, 1234 -> imm=0x4D2, rs1=x0, funct3=000, rd=x2, opcode=0010011
        //    = 010011010010 00000 000 00010 0010011 = 32'h4D200113
        //
        //  ADDI x3, x0, 202  -> imm=0x0CA, rs1=x0, funct3=000, rd=x3, opcode=0010011
        //    = 000011001010 00000 000 00011 0010011 = 32'h0CA00193
        //
        //  ADDI x4, x0, 171  -> imm=0x0AB, rs1=x0, funct3=000, rd=x4, opcode=0010011
        //    = 000010101011 00000 000 00100 0010011 = 32'h0AB00213
        //
        //  SW x2, 0(x1) -> imm=0, rs2=x2, rs1=x1, funct3=010, opcode=0100011
        //    = 0000000 00010 00001 010 00000 0100011 = 32'h0020A023
        //
        //  SH x3, 4(x1) -> imm=4=0x004, rs2=x3, rs1=x1, funct3=001, opcode=0100011
        //    = 0000000 00011 00001 001 00100 0100011 = 32'h00309223
        //
        //  SB x4, 8(x1) -> imm=8=0x008, rs2=x4, rs1=x1, funct3=000, opcode=0100011
        //    = 0000000 00100 00001 000 01000 0100011 = 32'h00408423
        //
        //  LW x10, 0(x1) -> imm=0, rs1=x1, funct3=010, rd=x10, opcode=0000011
        //    = 000000000000 00001 010 01010 0000011 = 32'h0000A503
        //
        //  LH x11, 4(x1) -> imm=4, rs1=x1, funct3=001, rd=x11, opcode=0000011
        //    = 000000000100 00001 001 01011 0000011 = 32'h00409583
        //
        //  LHU x12, 4(x1) -> imm=4, rs1=x1, funct3=101, rd=x12, opcode=0000011
        //    = 000000000100 00001 101 01100 0000011 = 32'h0040D603
        //
        //  LB x13, 8(x1) -> imm=8, rs1=x1, funct3=000, rd=x13, opcode=0000011
        //    = 000000001000 00001 000 01101 0000011 = 32'h00808683
        //
        //  LBU x14, 8(x1) -> imm=8, rs1=x1, funct3=100, rd=x14, opcode=0000011
        //    = 000000001000 00001 100 01110 0000011 = 32'h00814703

        // Correct instruction encodings:
        //
        //  LUI x1, 0x10
        //    imm[31:12]=0x00010, rd=00001, opcode=0110111
        //    = 0000_0000_0001_0000 | 0000_0000_1011_0111 = 0x000100B7
        //
        //  ADDI x2, x0, 1234 (0x4D2)
        //    imm=010011010010, rs1=00000, funct3=000, rd=00010, opcode=0010011
        //    = 0100_1101_0010_0000 | 0000_0001_0001_0011 = 0x4D200113  (OK)
        //
        //  ADDI x3, x0, 202 (0x0CA)
        //    imm=000011001010, rs1=00000, funct3=000, rd=00011, opcode=0010011
        //    = 0000_1100_1010_0000 | 0000_0001_1001_0011 = 0x0CA00193  (OK)
        //
        //  ADDI x4, x0, 171 (0x0AB)
        //    imm=000010101011, rs1=00000, funct3=000, rd=00100, opcode=0010011
        //    = 0000_1010_1011_0000 | 0000_0010_0001_0011 = 0x0AB00213  (OK)
        //
        //  SW x2, 0(x1)
        //    imm[11:5]=0000000, rs2=00010, rs1=00001, funct3=010, imm[4:0]=00000, opcode=0100011
        //    = 0000_0000_0010_0000 | 0001_0100_0010_0011 = 0x0020A023  (OK)
        //
        //  SH x3, 4(x1)
        //    imm=4=0x4: imm[11:5]=0000000, rs2=00011, rs1=00001, funct3=001, imm[4:0]=00100
        //    = 0000_0000_0011_0000 | 0001_0010_0010_0011 = 0x00309223  (OK)
        //
        //  SB x4, 8(x1)
        //    imm=8=0x8: imm[11:5]=0000000, rs2=00100, rs1=00001, funct3=000, imm[4:0]=01000
        //    = 0000_0000_0100_0000 | 0001_0100_0010_0011
        //    Let me re-encode: inst = imm[11:5] rs2 rs1 funct3 imm[4:0] opcode
        //    imm=8: imm[11:5]=7'b0000000, imm[4:0]=5'b01000
        //    = {7'b0000000, 5'b00100, 5'b00001, 3'b000, 5'b01000, 7'b0100011}
        //    = 32'h00408423  (OK)
        //
        //  LW x10, 0(x1)
        //    imm=0, rs1=00001, funct3=010, rd=01010, opcode=0000011
        //    = {12'b0, 5'b00001, 3'b010, 5'b01010, 7'b0000011}
        //    = 32'h0000A503  (OK)
        //
        //  LH x11, 4(x1)
        //    imm=4=0x004, rs1=00001, funct3=001, rd=01011, opcode=0000011
        //    = {12'h004, 5'b00001, 3'b001, 5'b01011, 7'b0000011}
        //    = 32'h00409583  (OK)
        //
        //  LHU x12, 4(x1)
        //    imm=4, rs1=00001, funct3=101, rd=01100, opcode=0000011
        //    = {12'h004, 5'b00001, 3'b101, 5'b01100, 7'b0000011}
        //    = 32'h0040D603  (OK)
        //
        //  LB x13, 8(x1)
        //    imm=8, rs1=00001, funct3=000, rd=01101, opcode=0000011
        //    = {12'h008, 5'b00001, 3'b000, 5'b01101, 7'b0000011}
        //    = 32'h00808683  (OK)
        //
        //  LBU x14, 8(x1)
        //    imm=8, rs1=00001, funct3=100, rd=01110, opcode=0000011
        //    = {12'h008, 5'b00001, 3'b100, 5'b01110, 7'b0000011}
        //    = 32'h00814703  (OK)

        uut.imem.mem[0]  = 32'h000100B7; // LUI  x1,  0x10       -> x1 = 0x0001_0000  *** FIXED ***
        uut.imem.mem[1]  = 32'h4D200113; // ADDI x2,  x0, 1234   -> x2 = 1234
        uut.imem.mem[2]  = 32'h0CA00193; // ADDI x3,  x0, 202    -> x3 = 202
        uut.imem.mem[3]  = 32'h0AB00213; // ADDI x4,  x0, 171    -> x4 = 171
        uut.imem.mem[4]  = 32'h0020A023; // SW   x2,  0(x1)      store word
        uut.imem.mem[5]  = 32'h00309223; // SH   x3,  4(x1)      store halfword
        uut.imem.mem[6]  = 32'h00408423; // SB   x4,  8(x1)      store byte
        uut.imem.mem[7]  = 32'h0000A503; // LW   x10, 0(x1)      load word
        uut.imem.mem[8]  = 32'h00409583; // LH   x11, 4(x1)      load halfword (signed)
        uut.imem.mem[9]  = 32'h0040D603; // LHU  x12, 4(x1)      load halfword (unsigned)
        uut.imem.mem[10] = 32'h00808683; // LB   x13, 8(x1)      load byte (signed)
        uut.imem.mem[11] = 32'h0080C703; // LBU  x14, 8(x1)      load byte (unsigned) *** FIXED ***
        uut.imem.mem[12] = 32'h00000013; // NOP

        // Reset
        #25;
        rst_n = 1;

        // =====================================================================
        // Run cycles and verify
        // =====================================================================
        $display("--- Initialization ---");
        wait_cycles(4);  // Cycles 1-4: LUI x1, ADDI x2, ADDI x3, ADDI x4
        check_reg(1, 32'h00010000, "LUI  x1=base addr");
        check_reg(2, 32'd1234,     "ADDI x2=1234");
        check_reg(3, 32'd202,      "ADDI x3=202");
        check_reg(4, 32'd171,      "ADDI x4=171");

        $display("\n--- Store ---");
        wait_cycles(3);  // Cycles 5-7: SW, SH, SB
        // Verify data written to internal memory directly
        if (uut.dmem.mem[0] === 32'd1234) begin
            $display("  PASS  SW: dmem[0] = 0x%h (1234)", uut.dmem.mem[0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  SW: dmem[0] = 0x%h (expected 0x%h)", uut.dmem.mem[0], 32'd1234);
            fail_count = fail_count + 1;
        end
        if (uut.dmem.mem[1][15:0] === 16'd202) begin
            $display("  PASS  SH: dmem[1][15:0] = %0d (202)", uut.dmem.mem[1][15:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  SH: dmem[1][15:0] = %0d (expected 202)", uut.dmem.mem[1][15:0]);
            fail_count = fail_count + 1;
        end
        if (uut.dmem.mem[2][7:0] === 8'd171) begin
            $display("  PASS  SB: dmem[2][7:0] = %0d (171)", uut.dmem.mem[2][7:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  SB: dmem[2][7:0] = %0d (expected 171)", uut.dmem.mem[2][7:0]);
            fail_count = fail_count + 1;
        end

        $display("\n--- Load ---");
        wait_cycles(6);  // Cycles 8-13: LW, LH, LHU, LB, LBU + 1 extra settle
        check_reg(10, 32'd1234,       "LW  x10=1234");
        check_reg(11, 32'd202,        "LH  x11=202 (signed)");
        check_reg(12, 32'd202,        "LHU x12=202 (unsigned)");
        // 0xAB = 171 = 1010_1011 -> MSB=1 -> sign extend -> 0xFFFFFFAB
        check_reg(13, 32'hFFFFFFAB,   "LB  x13=0xAB (sign-ext)");
        check_reg(14, 32'h000000AB,   "LBU x14=0xAB (zero-ext)");

        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        $finish;
    end

endmodule
