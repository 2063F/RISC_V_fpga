`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_memory_full
// Description: Phase E - Full coverage memory instruction testbench.
//              Tests SW/SH/SB/LW/LH/LHU/LB/LBU with edge cases:
//              - Negative values (sign extension verification)
//              - Upper halfword store/load (addr offset bit[1]=1)
//              - Multiple byte offsets (0,1,2,3) for SB/LB/LBU
//              - Zero value handling
//              - Maximum values (0xFF, 0xFFFF, 0xFFFFFFFF)
//////////////////////////////////////////////////////////////////////////////////

`include "riscv_defines.vh"

module tb_memory_full;

    reg  clk;
    reg  rst_n;
    wire uart_tx_pin;
    wire [31:0] mem_addr;
    wire [31:0] mem_write_data;
    wire        mem_write_en;
    wire        mem_read_en;
    reg  [31:0] mem_read_data;
    wire [31:0] debug_pc;
    wire [31:0] debug_x1;

    cpu_top uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (mem_addr),
        .mem_write_data (mem_write_data),
        .mem_write_en   (mem_write_en),
        .mem_read_en    (mem_read_en),
        .mem_read_data  (mem_read_data),
        .uart_tx_pin    (uart_tx_pin),
        .debug_pc       (debug_pc),
        .debug_x1       (debug_x1)
    );

    always #10 clk = ~clk;

    integer pass_count;
    integer fail_count;

    task check_reg;
        input [4:0]   reg_num;
        input [31:0]  expected;
        input [255:0] name;
        begin
            #1;
            if (uut.regfile.regs[reg_num] === expected) begin
                $display("  PASS  %s: x%0d = 0x%08h", name, reg_num, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %s: x%0d = 0x%08h (expected 0x%08h)",
                         name, reg_num, uut.regfile.regs[reg_num], expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check_dmem_word;
        input [6:0]   word_idx;
        input [31:0]  expected;
        input [255:0] name;
        begin
            if (uut.dmem.peek_word(word_idx) === expected) begin
                $display("  PASS  %s: dmem[%0d] = 0x%08h", name, word_idx, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %s: dmem[%0d] = 0x%08h (expected 0x%08h)",
                         name, word_idx, uut.dmem.peek_word(word_idx), expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task wait_cycles;
        input integer n;
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) @(posedge clk);
            #1;
        end
    endtask

    // =========================================================================
    // Instruction Encoding Reference:
    //   Base addr: x1 = 0x0001_0000 (LUI x1, 0x10 = 0x000100B7)
    //   x5  = 0xDEADBEEF  (LUI x5, 0xDEADB -> x5=0xDEADB000, ADDI x5,x5,-273)
    //                     (Actually use LUI x5, 0xDEADC then ADDI x5,x5,-273 = 0xEEF)
    //                     Easier: just store 0x0000_8000 (min signed halfword value test)
    //   x6  = 0x0000_8000  -> signed halfword = -32768, LHU=32768
    //   x7  = 0x0000_00FF  -> signed byte = -1 (0xFF), LBU=255
    //   x8  = 0x0000_0000  -> zero
    //   x9  = 0xFFFF_FFFF  -> full word test
    //
    // Programs are loaded directly into instruction memory.
    // =========================================================================

    initial begin
        $dumpfile("sim/tb_memory_full.vcd");
        $dumpvars(0, tb_memory_full);

        clk       = 0;
        rst_n     = 0;
        mem_read_data = 32'd0;
        pass_count = 0;
        fail_count = 0;

        // =====================================================================
        // PROGRAM BLOCK 1: Store tests
        // Registers:
        //   x1  = 0x0001_0000  (base)
        //   x5  = 0x0000_8000  (halfword test: signed -32768)
        //   x6  = 0x0000_00FF  (byte test: 0xFF = signed -1)
        //   x7  = 0x0000_0000  (zero)
        //   x9  = 0xFFFF_FFFF  (full word -1 signed)
        //
        // Memory layout (word index from base):
        //   [0]  SW  x9,  0(x1)   -> word 0x0001_0000 = 0xFFFF_FFFF
        //   [1]  SH  x5,  4(x1)   -> half [15:0] of word@0x0001_0004 = 0x8000
        //   [2]  SH  x5,  6(x1)   -> half [31:16] of word@0x0001_0004 = 0x8000_8000
        //   [2]  SB  x6,  8(x1)   -> byte[0] of word@0x0001_0008 = 0xFF
        //   [3]  SB  x6,  9(x1)   -> byte[1] of word@0x0001_0008 = 0xFF_FF
        //   [4]  SB  x6, 10(x1)   -> byte[2] of word@0x0001_0008 = 0xFF_FF_FF
        //   [5]  SB  x6, 11(x1)   -> byte[3] of word@0x0001_0008 = 0xFF_FF_FF_FF
        //   [6]  SW  x7,  12(x1)  -> zero word
        //
        // Load tests (read back):
        //   LW  x10, 0(x1)   -> x10 = 0xFFFF_FFFF
        //   LH  x11, 4(x1)   -> x11 = 0xFFFF_8000  (sign-ext: 0x8000 is negative)
        //   LHU x12, 4(x1)   -> x12 = 0x0000_8000  (zero-ext)
        //   LH  x13, 6(x1)   -> x13 = 0xFFFF_8000  (upper halfword, sign-ext)
        //   LHU x14, 6(x1)   -> x14 = 0x0000_8000  (upper halfword, zero-ext)
        //   LB  x15, 8(x1)   -> x15 = 0xFFFF_FFFF  (byte 0xFF sign-ext)
        //   LBU x16, 8(x1)   -> x16 = 0x0000_00FF  (zero-ext)
        //   LB  x17, 9(x1)   -> x17 = 0xFFFF_FFFF  (byte[1] 0xFF sign-ext)
        //   LB  x18, 10(x1)  -> x18 = 0xFFFF_FFFF  (byte[2] 0xFF sign-ext)
        //   LB  x19, 11(x1)  -> x19 = 0xFFFF_FFFF  (byte[3] 0xFF sign-ext)
        //   LW  x20, 12(x1)  -> x20 = 0x0000_0000  (zero word)
        //
        // Instruction encodings:
        //   LUI  x1, 0x10         = 0x000100B7
        //   LUI  x5, 0x00008      imm[31:12]=0x00008 -> x5=0x0000_8000 = 0x000082B7
        //   ADDI x6, x0, 255      imm=0xFF, rs1=0, rd=x6 = 0x0FF00313
        //   ADDI x7, x0, 0        = 0x00000393
        //   LUI  x9, 0xFFFFF      -> x9=0xFFFFF000
        //   ADDI x9, x9, -1       -> x9=0xFFFFEFFF ... not what we want
        //   Better: XORI x9, x0, -1  -> x9 = 0xFFFF_FFFF
        //     XORI: opcode=0010011, funct3=100, imm=-1=0xFFF
        //     = {12'hFFF, 5'b00000, 3'b100, 5'b01001, 7'b0010011}
        //     = 32'hFFF04493
        //
        //   SW x9, 0(x1): imm=0, rs2=x9, rs1=x1, funct3=010
        //     = {7'b0,5'b01001,5'b00001,3'b010,5'b0,7'b0100011} = 32'h0090A023
        //
        //   SH x5, 4(x1): imm=4, rs2=x5, rs1=x1, funct3=001
        //     imm[11:5]=0000000, imm[4:0]=00100
        //     = {7'b0,5'b00101,5'b00001,3'b001,5'b00100,7'b0100011} = 32'h00509223
        //
        //   SH x5, 6(x1): imm=6, rs2=x5, rs1=x1, funct3=001
        //     imm[11:5]=0000000, imm[4:0]=00110
        //     = {7'b0,5'b00101,5'b00001,3'b001,5'b00110,7'b0100011} = 32'h00509323
        //
        //   SB x6, 8(x1): imm=8, rs2=x6, rs1=x1, funct3=000
        //     imm[11:5]=0000000, imm[4:0]=01000
        //     = {7'b0,5'b00110,5'b00001,3'b000,5'b01000,7'b0100011} = 32'h00608423
        //
        //   SB x6, 9(x1): imm=9, rs2=x6, rs1=x1, funct3=000
        //     imm[11:5]=0000000, imm[4:0]=01001
        //     = {7'b0,5'b00110,5'b00001,3'b000,5'b01001,7'b0100011} = 32'h006084A3
        //
        //   SB x6, 10(x1): imm=10=0xA, rs2=x6, rs1=x1, funct3=000
        //     imm[11:5]=0000000, imm[4:0]=01010
        //     = {7'b0,5'b00110,5'b00001,3'b000,5'b01010,7'b0100011} = 32'h00608523
        //
        //   SB x6, 11(x1): imm=11=0xB, rs2=x6, rs1=x1, funct3=000
        //     imm[11:5]=0000000, imm[4:0]=01011
        //     = {7'b0,5'b00110,5'b00001,3'b000,5'b01011,7'b0100011} = 32'h006085A3
        //
        //   SW x7, 12(x1): imm=12=0xC, rs2=x7, rs1=x1, funct3=010
        //     imm[11:5]=0000000, imm[4:0]=01100
        //     = {7'b0,5'b00111,5'b00001,3'b010,5'b01100,7'b0100011} = 32'h0070A623
        //
        //   LW  x10, 0(x1):  {12'h000,5'b00001,3'b010,5'b01010,7'b0000011} = 32'h0000A503
        //   LH  x11, 4(x1):  {12'h004,5'b00001,3'b001,5'b01011,7'b0000011} = 32'h00409583
        //   LHU x12, 4(x1):  {12'h004,5'b00001,3'b101,5'b01100,7'b0000011} = 32'h0040D603
        //   LH  x13, 6(x1):  {12'h006,5'b00001,3'b001,5'b01101,7'b0000011} = 32'h00609683
        //   LHU x14, 6(x1):  {12'h006,5'b00001,3'b101,5'b01110,7'b0000011} = 32'h0060D703
        //   LB  x15, 8(x1):  {12'h008,5'b00001,3'b000,5'b01111,7'b0000011} = 32'h00808783
        //   LBU x16, 8(x1):  {12'h008,5'b00001,3'b100,5'b10000,7'b0000011} = 32'h0080C803
        //   LB  x17, 9(x1):  {12'h009,5'b00001,3'b000,5'b10001,7'b0000011} = 32'h00908883
        //   LB  x18,10(x1):  {12'h00A,5'b00001,3'b000,5'b10010,7'b0000011} = 32'h00A08903
        //   LB  x19,11(x1):  {12'h00B,5'b00001,3'b000,5'b10011,7'b0000011} = 32'h00B08983
        //   LW  x20,12(x1):  {12'h00C,5'b00001,3'b010,5'b10100,7'b0000011} = 32'h00C0AA03

        // Load program
        uut.imem.mem[0]  = 32'h000100B7; // LUI  x1, 0x10       -> x1 = 0x0001_0000
        uut.imem.mem[1]  = 32'h000082B7; // LUI  x5, 0x00008    -> x5 = 0x0000_8000
        uut.imem.mem[2]  = 32'h0FF00313; // ADDI x6, x0, 255    -> x6 = 0xFF
        uut.imem.mem[3]  = 32'h00000393; // ADDI x7, x0, 0      -> x7 = 0
        uut.imem.mem[4]  = 32'hFFF04493; // XORI x9, x0, -1     -> x9 = 0xFFFFFFFF
        uut.imem.mem[5]  = 32'h0090A023; // SW   x9,  0(x1)     -> dmem[0] = 0xFFFFFFFF
        uut.imem.mem[6]  = 32'h00509223; // SH   x5,  4(x1)     -> dmem[1][15:0] = 0x8000
        uut.imem.mem[7]  = 32'h00509323; // SH   x5,  6(x1)     -> dmem[1][31:16] = 0x8000
        uut.imem.mem[8]  = 32'h00608423; // SB   x6,  8(x1)     -> dmem[2][7:0] = 0xFF
        uut.imem.mem[9]  = 32'h006084A3; // SB   x6,  9(x1)     -> dmem[2][15:8] = 0xFF
        uut.imem.mem[10] = 32'h00608523; // SB   x6, 10(x1)     -> dmem[2][23:16] = 0xFF
        uut.imem.mem[11] = 32'h006085A3; // SB   x6, 11(x1)     -> dmem[2][31:24] = 0xFF
        uut.imem.mem[12] = 32'h0070A623; // SW   x7, 12(x1)     -> dmem[3] = 0
        uut.imem.mem[13] = 32'h0000A503; // LW   x10,  0(x1)    -> x10 = 0xFFFFFFFF
        uut.imem.mem[14] = 32'h00409583; // LH   x11,  4(x1)    -> x11 = 0xFFFF8000 (sign-ext)
        uut.imem.mem[15] = 32'h0040D603; // LHU  x12,  4(x1)    -> x12 = 0x00008000 (zero-ext)
        uut.imem.mem[16] = 32'h00609683; // LH   x13,  6(x1)    -> x13 = 0xFFFF8000 (upper half, sign-ext)
        uut.imem.mem[17] = 32'h0060D703; // LHU  x14,  6(x1)    -> x14 = 0x00008000 (upper half, zero-ext)
        uut.imem.mem[18] = 32'h00808783; // LB   x15,  8(x1)    -> x15 = 0xFFFFFFFF (0xFF sign-ext)
        uut.imem.mem[19] = 32'h0080C803; // LBU  x16,  8(x1)    -> x16 = 0x000000FF (zero-ext)
        uut.imem.mem[20] = 32'h00908883; // LB   x17,  9(x1)    -> x17 = 0xFFFFFFFF (byte[1] sign-ext)
        uut.imem.mem[21] = 32'h00A08903; // LB   x18, 10(x1)    -> x18 = 0xFFFFFFFF (byte[2] sign-ext)
        uut.imem.mem[22] = 32'h00B08983; // LB   x19, 11(x1)    -> x19 = 0xFFFFFFFF (byte[3] sign-ext)
        uut.imem.mem[23] = 32'h00C0AA03; // LW   x20, 12(x1)    -> x20 = 0
        uut.imem.mem[24] = 32'h00000013; // NOP

        #25;
        rst_n = 1;

        // =====================================================================
        // Phase 1: Register initialization (5 cycles)
        // =====================================================================
        $display("=== Phase E: Full Memory Instruction Coverage ===\n");
        $display("--- [1] Register Initialization ---");
        wait_cycles(6 + 1);   // +1 for the third pipeline stage
        check_reg(1, 32'h00010000,  "LUI  x1=base addr     ");
        check_reg(5, 32'h00008000,  "LUI  x5=0x8000        ");
        check_reg(6, 32'h000000FF,  "ADDI x6=0xFF          ");
        check_reg(7, 32'h00000000,  "ADDI x7=0             ");
        check_reg(9, 32'hFFFFFFFF,  "XORI x9=0xFFFFFFFF    ");

        // =====================================================================
        // Phase 2: Store operations (8 cycles: SW + 2xSH + 4xSB + SW)
        // =====================================================================
        $display("\n--- [2] Store Operations ---");
        wait_cycles(9);
        check_dmem_word(0, 32'hFFFFFFFF, "SW  x9,0(x1) word   ");
        check_dmem_word(1, 32'h80008000, "SH  x5,4+6(x1) both ");
        check_dmem_word(2, 32'hFFFFFFFF, "SB  x6,8-11(x1) all ");
        check_dmem_word(3, 32'h00000000, "SW  x7,12(x1) zero  ");

        // =====================================================================
        // Phase 3: Load operations (12 cycles)
        // =====================================================================
        $display("\n--- [3] Load Operations ---");
        // 11 loads, and every load now costs 2 cycles: both memories have a
        // registered read port so the CPU stalls one cycle waiting for data.
        wait_cycles(13 + 11);
        check_reg(10, 32'hFFFFFFFF,  "LW   x10=0xFFFFFFFF   ");
        check_reg(11, 32'hFFFF8000,  "LH   x11=0xFFFF8000 SE");
        check_reg(12, 32'h00008000,  "LHU  x12=0x00008000 ZE");
        check_reg(13, 32'hFFFF8000,  "LH   x13=upper half SE");
        check_reg(14, 32'h00008000,  "LHU  x14=upper half ZE");
        check_reg(15, 32'hFFFFFFFF,  "LB   x15=0xFF sign-ext");
        check_reg(16, 32'h000000FF,  "LBU  x16=0xFF zero-ext");
        check_reg(17, 32'hFFFFFFFF,  "LB   x17=byte[1] SE   ");
        check_reg(18, 32'hFFFFFFFF,  "LB   x18=byte[2] SE   ");
        check_reg(19, 32'hFFFFFFFF,  "LB   x19=byte[3] SE   ");
        check_reg(20, 32'h00000000,  "LW   x20=0 (zero)     ");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED! Phase E memory coverage complete.");
        else
            $display("SOME TESTS FAILED! Review above output.");

        $finish;
    end

endmodule
