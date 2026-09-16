`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_branch
// Description: Testbench for Phase 5 - Branch and Jump instructions
//
//  Test 1: BLT loop (1+2+...+10 = 55)
//    PC=0:  ADDI x1, x0, 0     sum=0
//    PC=4:  ADDI x2, x0, 1     i=1
//    PC=8:  ADDI x3, x0, 11    limit=11
//    PC=12: ADD  x1, x1, x2    sum+=i  <loop target>
//    PC=16: ADDI x2, x2, 1     i++
//    PC=20: BLT  x2, x3, -8   if i<11 goto PC=12
//    PC=24: NOP  (done, x1==55)
//
//  Test 2: BEQ / BNE (branch taken / not taken)
//    PC=28: ADDI x4, x0, 5
//    PC=32: ADDI x5, x0, 5
//    PC=36: BEQ  x4, x5, +8   -> should take branch to PC=48
//    PC=40: ADDI x6, x0, 99   -> should be SKIPPED
//    PC=44: NOP                -> should be SKIPPED
//    PC=48: ADDI x6, x0, 42   -> x6 should = 42
//    PC=52: NOP
//
//  Test 3: JAL (jump and link)
//    PC=56: JAL x7, +12        -> x7=PC+4=60, jump to PC=68
//    PC=60: ADDI x8, x0, 1    -> should be SKIPPED
//    PC=64: NOP                -> should be SKIPPED
//    PC=68: ADDI x8, x0, 77   -> x8 should = 77
//    PC=72: NOP
//
//////////////////////////////////////////////////////////////////////////////////

module tb_branch;

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
            if (uut.regfile.regs[reg_num] === expected) begin
                $display("  PASS  %s: x%0d = %0d (0x%h)", name, reg_num, expected, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %s: x%0d = %0d (0x%h) | expected %0d (0x%h)",
                         name, reg_num,
                         $signed(uut.regfile.regs[reg_num]), uut.regfile.regs[reg_num],
                         $signed(expected), expected);
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

    // ========== Python-verified instruction encodings ==========
    // All branch offsets are relative to the instruction's own PC.
    //
    // BLT  rs1, rs2, offset :  B-type, funct3=100
    // BEQ  rs1, rs2, offset :  B-type, funct3=000
    // JAL  rd,  offset      :  J-type
    //
    // Verified with tools/encode.py

    initial begin
        $dumpfile("sim/tb_branch.vcd");
        $dumpvars(0, tb_branch);

        clk = 0;
        rst_n = 0;
        mem_read_data = 32'd0;

        $display("=== Phase 5 Branch/Jump Testbench ===\n");

        // -------------------------------------------------------
        // Test 1: BLT loop  (sum = 1+2+...+10)
        // -------------------------------------------------------
        uut.imem.mem[0]  = 32'h00000093; // ADDI x1, x0, 0     sum=0
        uut.imem.mem[1]  = 32'h00100113; // ADDI x2, x0, 1     i=1
        uut.imem.mem[2]  = 32'h00B00193; // ADDI x3, x0, 11    limit=11
        uut.imem.mem[3]  = 32'h002080B3; // ADD  x1, x1, x2    sum+=i   <loop>
        uut.imem.mem[4]  = 32'h00110113; // ADDI x2, x2, 1     i++
        uut.imem.mem[5]  = 32'hFE314CE3; // BLT  x2, x3, -8   if i<11 goto PC=12
        uut.imem.mem[6]  = 32'h00000013; // NOP  (done)

        // -------------------------------------------------------
        // Test 2: BEQ branch taken  (branch skips ADDI x6,x0,99)
        // -------------------------------------------------------
        // PC=28 (mem[7])
        uut.imem.mem[7]  = 32'h00500213; // ADDI x4, x0, 5
        uut.imem.mem[8]  = 32'h00500293; // ADDI x5, x0, 5
        // BEQ x4, x5, +8  offset=8 -> target = PC+8 = 36+8 = 44... 
        // PC=36 is mem[9]. target should be mem[11]=PC=44.
        // BEQ offset=+8 -> imm bits: imm=8=0b0_0000_1000
        //   b12=0,b11=0,b10_5=000000,b4_1=0100,b0=0(implicit)
        //   inst: 0|000000|00101|00100|000|0100|0|1100011 = 0x00520463
        uut.imem.mem[9]  = 32'h00520463; // BEQ  x4, x5, +8    branch taken -> PC=44
        uut.imem.mem[10] = 32'h06300313; // ADDI x6, x0, 99    SKIPPED
        uut.imem.mem[11] = 32'h00000013; // NOP                 SKIPPED
        uut.imem.mem[12] = 32'h02A00313; // ADDI x6, x0, 42    x6=42
        uut.imem.mem[13] = 32'h00000013; // NOP

        // -------------------------------------------------------
        // Test 3: JAL  (jump and link, skip two instructions)
        // -------------------------------------------------------
        // PC=56 (mem[14])
        // JAL x7, +12  -> x7=60, jump to PC=68 (mem[17])
        // offset=12: imm=12=0b0_0000_0001_1000_0000_0000
        //   b20=0, b10_1=0000000110, b11=0, b19_12=00000000
        //   inst: 0|0000000110|0|00000000|00111|1101111 = 0x00C003EF
        uut.imem.mem[14] = 32'h00C003EF; // JAL  x7, +12   x7=60, jump to PC=68
        uut.imem.mem[15] = 32'h00100413; // ADDI x8, x0, 1   SKIPPED
        uut.imem.mem[16] = 32'h00000013; // NOP              SKIPPED
        uut.imem.mem[17] = 32'h04D00413; // ADDI x8, x0, 77  x8=77
        uut.imem.mem[18] = 32'h00000013; // NOP

        // Reset
        #25;
        rst_n = 1;

        // -------------------------------------------------------
        // Test 1: wait for loop to finish (10 iterations)
        //   3 setup + 10*(ADD+ADDI+BLT taken 9x + fall-through 1x) + NOP
        //   = 3 + 10*2 + 9 + 1 + 1 = 34 cycles (ample margin: 40)
        // -------------------------------------------------------
        $display("--- Test 1: BLT loop (1+2+...+10) ---");
        wait_cycles(42);
        check_reg(1, 32'd55, "sum = 55");
        check_reg(2, 32'd11, "i   = 11 (loop stopped)");

        // -------------------------------------------------------
        // Test 2: BEQ branch taken
        // -------------------------------------------------------
        $display("\n--- Test 2: BEQ branch taken ---");
        wait_cycles(8);
        check_reg(6, 32'd42,  "x6=42 (branch skipped 99)");

        // -------------------------------------------------------
        // Test 3: JAL
        // -------------------------------------------------------
        $display("\n--- Test 3: JAL jump and link ---");
        wait_cycles(7);
        check_reg(7, 32'd60,  "x7=60 (return addr)");
        check_reg(8, 32'd77,  "x8=77 (JAL skipped ADDI 1)");

        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        $finish;
    end

endmodule
