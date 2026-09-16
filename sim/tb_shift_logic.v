`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_shift_logic
// Description: CPU integration coverage for the shift and logical/compare
//              instructions that were verified only at the ALU-unit level
//              (tb_alu.v) and the decoder level (tb_decoder.v), but never
//              decoded/executed end-to-end through cpu_top:
//                I-type: SLLI SRLI SRAI XORI ORI ANDI SLTI SLTIU
//                R-type: SLL  SRL  SRA  XOR  OR  AND  SLT  SLTU
//
//              x1 = 0xF0F0F0F0 is used throughout so that a logical/arithmetic
//              shift mix-up and a signed/unsigned compare mix-up both show up.
//              The SLL with shamt = 36 checks that the ALU masks the shift
//              amount down to b[4:0] as the RISC-V spec requires.
//              Machine code was produced by riscv-none-elf-gcc -march=rv32i.
//////////////////////////////////////////////////////////////////////////////////

module tb_shift_logic;

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
                $display("  PASS  %s: x%0d = 0x%h", name, reg_num, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %s: x%0d = 0x%h (expected 0x%h)",
                         name, reg_num, uut.regfile.regs[reg_num], expected);
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

    initial begin
        $dumpfile("sim/tb_shift_logic.vcd");
        $dumpvars(0, tb_shift_logic);

        clk = 0;
        rst_n = 0;
        mem_read_data = 32'd0;

        $display("=== Shift / Logical / Compare (CPU integration) Testbench ===\n");
        $display("x1 = 0xF0F0F0F0, x2 = 4, x3 = 0xFFFFFFFF, x4 = 36\n");

        uut.imem.mem[0]  = 32'hF0F0F0B7; // LUI   x1, 0xF0F0F
        uut.imem.mem[1]  = 32'h0F008093; // ADDI  x1, x1, 240    -> 0xF0F0F0F0
        uut.imem.mem[2]  = 32'h00400113; // ADDI  x2, x0, 4
        uut.imem.mem[3]  = 32'hFFF00193; // ADDI  x3, x0, -1
        uut.imem.mem[4]  = 32'h00409293; // SLLI  x5,  x1, 4
        uut.imem.mem[5]  = 32'h0040D313; // SRLI  x6,  x1, 4
        uut.imem.mem[6]  = 32'h4040D393; // SRAI  x7,  x1, 4
        uut.imem.mem[7]  = 32'h40115413; // SRAI  x8,  x2, 1
        uut.imem.mem[8]  = 32'h002094B3; // SLL   x9,  x1, x2
        uut.imem.mem[9]  = 32'h0020D533; // SRL   x10, x1, x2
        uut.imem.mem[10] = 32'h4020D5B3; // SRA   x11, x1, x2
        uut.imem.mem[11] = 32'h02400213; // ADDI  x4,  x0, 36
        uut.imem.mem[12] = 32'h00409633; // SLL   x12, x1, x4    (shamt = 36 & 31 = 4)
        uut.imem.mem[13] = 32'hFFF0C693; // XORI  x13, x1, -1
        uut.imem.mem[14] = 32'h00F0E713; // ORI   x14, x1, 15
        uut.imem.mem[15] = 32'h0FF0F793; // ANDI  x15, x1, 255
        uut.imem.mem[16] = 32'h0000A813; // SLTI  x16, x1, 0
        uut.imem.mem[17] = 32'h0000B893; // SLTIU x17, x1, 0
        uut.imem.mem[18] = 32'hFFF1B913; // SLTIU x18, x3, -1
        uut.imem.mem[19] = 32'h0030C9B3; // XOR   x19, x1, x3
        uut.imem.mem[20] = 32'h0030EA33; // OR    x20, x1, x3
        uut.imem.mem[21] = 32'h0030FAB3; // AND   x21, x1, x3
        uut.imem.mem[22] = 32'h0000AB33; // SLT   x22, x1, x0
        uut.imem.mem[23] = 32'h0000BBB3; // SLTU  x23, x1, x0
        uut.imem.mem[24] = 32'h06300013; // ADDI  x0,  x0, 99    (must be discarded)
        uut.imem.mem[25] = 32'h00000C33; // ADD   x24, x0, x0
        uut.imem.mem[26] = 32'h00000013; // NOP
        uut.imem.mem[27] = 32'h00000013; // NOP

        wait_cycles(2);
        rst_n = 1;
        wait_cycles(32);

        $display("--- I-type shifts ---");
        check_reg(5'd5,  32'h0F0F0F00, "SLLI  x5  = x1 << 4        ");
        check_reg(5'd6,  32'h0F0F0F0F, "SRLI  x6  = x1 >>  4       ");
        check_reg(5'd7,  32'hFF0F0F0F, "SRAI  x7  = x1 >>> 4       ");
        check_reg(5'd8,  32'h00000002, "SRAI  x8  = 4 >>> 1        ");

        $display("\n--- R-type shifts ---");
        check_reg(5'd9,  32'h0F0F0F00, "SLL   x9  = x1 << x2       ");
        check_reg(5'd10, 32'h0F0F0F0F, "SRL   x10 = x1 >>  x2      ");
        check_reg(5'd11, 32'hFF0F0F0F, "SRA   x11 = x1 >>> x2      ");
        check_reg(5'd12, 32'h0F0F0F00, "SLL   x12 shamt 36 -> 4    ");

        $display("\n--- I-type logical / compare ---");
        check_reg(5'd13, 32'h0F0F0F0F, "XORI  x13 = x1 ^ -1        ");
        check_reg(5'd14, 32'hF0F0F0FF, "ORI   x14 = x1 | 15        ");
        check_reg(5'd15, 32'h000000F0, "ANDI  x15 = x1 & 255       ");
        check_reg(5'd16, 32'h00000001, "SLTI  x16 = (x1 <s 0)      ");
        check_reg(5'd17, 32'h00000000, "SLTIU x17 = (x1 <u 0)      ");
        check_reg(5'd18, 32'h00000000, "SLTIU x18 = (-1 <u -1)     ");

        $display("\n--- R-type logical / compare ---");
        check_reg(5'd19, 32'h0F0F0F0F, "XOR   x19 = x1 ^ x3        ");
        check_reg(5'd20, 32'hFFFFFFFF, "OR    x20 = x1 | x3        ");
        check_reg(5'd21, 32'hF0F0F0F0, "AND   x21 = x1 & x3        ");
        check_reg(5'd22, 32'h00000001, "SLT   x22 = (x1 <s 0)      ");
        check_reg(5'd23, 32'h00000000, "SLTU  x23 = (x1 <u 0)      ");

        $display("\n--- x0 is hardwired to zero ---");
        check_reg(5'd0,  32'h00000000, "ADDI x0,x0,99 discarded    ");
        check_reg(5'd24, 32'h00000000, "ADD   x24 = x0 + x0        ");

        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        $finish;
    end

endmodule
