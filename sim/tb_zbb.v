`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_zbb
// Description: CPU integration test for the Zbb CPOP / CTZ instructions
//              (src/bitmanip.v). Covers the corner values (0, -1, MSB only),
//              forwarding into and out of them, SLLI still decoding as a shift
//              on the shared funct3, and one being discarded in a JAL shadow.
//              Encodings: OP-IMM, funct3 = 001, imm = 0x601 (CTZ) / 0x602 (CPOP).
//////////////////////////////////////////////////////////////////////////////////

module tb_zbb;

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
        $dumpfile("sim/tb_zbb.vcd");
        $dumpvars(0, tb_zbb);

        clk = 0;
        rst_n = 0;
        mem_read_data = 32'd0;

        $display("=== Zbb CPOP / CTZ (CPU integration) Testbench ===\n");

        uut.imem.mem[0]  = 32'hF0F0F0B7; // LUI   x1,  0xF0F0F
        uut.imem.mem[1]  = 32'h0F008093; // ADDI  x1,  x1, 240     -> 0xF0F0F0F0
        uut.imem.mem[2]  = 32'h60209293; // CPOP  x5,  x1          (x1 forwarded from EX)
        uut.imem.mem[3]  = 32'h60109313; // CTZ   x6,  x1
        uut.imem.mem[4]  = 32'h00130393; // ADDI  x7,  x6, 1       (CTZ result forwarded)
        uut.imem.mem[5]  = 32'h60201413; // CPOP  x8,  x0
        uut.imem.mem[6]  = 32'h60101493; // CTZ   x9,  x0
        uut.imem.mem[7]  = 32'hFFF00193; // ADDI  x3,  x0, -1
        uut.imem.mem[8]  = 32'h60219513; // CPOP  x10, x3
        uut.imem.mem[9]  = 32'h60119593; // CTZ   x11, x3
        uut.imem.mem[10] = 32'h80000237; // LUI   x4,  0x80000
        uut.imem.mem[11] = 32'h60121613; // CTZ   x12, x4
        uut.imem.mem[12] = 32'h60221693; // CPOP  x13, x4
        uut.imem.mem[13] = 32'h00409713; // SLLI  x14, x1, 4       (must still be a shift)
        uut.imem.mem[14] = 32'h10000113; // ADDI  x2,  x0, 256
        uut.imem.mem[15] = 32'h60111793; // CTZ   x15, x2
        uut.imem.mem[16] = 32'h60211813; // CPOP  x16, x2
        uut.imem.mem[17] = 32'h60229893; // CPOP  x17, x5
        uut.imem.mem[18] = 32'h0080006F; // JAL   x0,  +8
        uut.imem.mem[19] = 32'h60219913; // CPOP  x18, x3          (in the shadow - must be discarded)
        uut.imem.mem[20] = 32'h60111993; // CTZ   x19, x2
        uut.imem.mem[21] = 32'h00000013; // NOP
        uut.imem.mem[22] = 32'h00000013; // NOP
        uut.imem.mem[23] = 32'h00000013; // NOP

        wait_cycles(2);
        rst_n = 1;
        wait_cycles(32);

        $display("--- x1 = 0xF0F0F0F0 ---");
        check_reg(5'd5,  32'd16,         "CPOP  x5  = cpop(x1)       ");
        check_reg(5'd6,  32'd4,          "CTZ   x6  = ctz(x1)        ");
        check_reg(5'd7,  32'd5,          "ADDI  x7  = x6 + 1         ");

        $display("\n--- corner values ---");
        check_reg(5'd8,  32'd0,          "CPOP  x8  = cpop(0)        ");
        check_reg(5'd9,  32'd32,         "CTZ   x9  = ctz(0)         ");
        check_reg(5'd10, 32'd32,         "CPOP  x10 = cpop(-1)       ");
        check_reg(5'd11, 32'd0,          "CTZ   x11 = ctz(-1)        ");
        check_reg(5'd12, 32'd31,         "CTZ   x12 = ctz(0x80000000)");
        check_reg(5'd13, 32'd1,          "CPOP  x13 = cpop(0x80000000)");
        check_reg(5'd15, 32'd8,          "CTZ   x15 = ctz(256)       ");
        check_reg(5'd16, 32'd1,          "CPOP  x16 = cpop(256)      ");
        check_reg(5'd17, 32'd1,          "CPOP  x17 = cpop(16)       ");

        $display("\n--- decode / pipeline ---");
        check_reg(5'd14, 32'h0F0F0F00,   "SLLI  x14 = x1 << 4        ");
        check_reg(5'd18, 32'd0,          "CPOP  x18 discarded by JAL ");
        check_reg(5'd19, 32'd8,          "CTZ   x19 = ctz(256)       ");

        $display("\n=== Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
