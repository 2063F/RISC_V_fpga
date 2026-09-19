`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_rv32m_full
// Description: CPU integration coverage for the RV32M instructions that were
//              previously verified only at the ALU-unit level (tb_alu_m.v) but
//              never decoded/executed end-to-end through cpu_top: MULH, MULHU,
//              MULHSU, DIVU, REM, REMU. (MUL and DIV are already covered by
//              tb_cpu_top.v.)
//
//              Operands are chosen so signed and unsigned interpretations
//              disagree (x1 = -8 / 0xFFFFFFF8), which would catch a decoder
//              bug that mixed up the signed/unsigned MEXT funct3 variants.
//              Expected values were cross-checked with a small Python script.
//////////////////////////////////////////////////////////////////////////////////

module tb_rv32m_full;

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
        $dumpfile("sim/tb_rv32m_full.vcd");
        $dumpvars(0, tb_rv32m_full);

        clk = 0;
        rst_n = 0;
        mem_read_data = 32'd0;

        $display("=== RV32M Remaining Instructions (CPU integration) Testbench ===\n");
        $display("x1 = -8 (0xFFFFFFF8), x2 = 3\n");

        uut.imem.mem[0] = 32'hFF800093; // ADDI   x1, x0, -8  -> x1 = 0xFFFFFFF8 (-8)
        uut.imem.mem[1] = 32'h00300113; // ADDI   x2, x0, 3   -> x2 = 3
        uut.imem.mem[2] = 32'h02209533; // MULH   x10, x1, x2 -> high32(signed(-8)*signed(3))
        uut.imem.mem[3] = 32'h0220B5B3; // MULHU  x11, x1, x2 -> high32(unsigned(0xFFFFFFF8)*unsigned(3))
        uut.imem.mem[4] = 32'h0220A633; // MULHSU x12, x1, x2 -> high32(signed(-8)*unsigned(3))
        uut.imem.mem[5] = 32'h0220D6B3; // DIVU   x13, x1, x2 -> unsigned(0xFFFFFFF8)/unsigned(3)
        uut.imem.mem[6] = 32'h0220E733; // REM    x14, x1, x2 -> signed(-8) rem signed(3)
        uut.imem.mem[7] = 32'h0220F7B3; // REMU   x15, x1, x2 -> unsigned(0xFFFFFFF8) rem unsigned(3)
        uut.imem.mem[8] = 32'h00000013; // NOP

        // Reset
        #25;
        rst_n = 1;

        // 9 straight-line instructions, no branches; ample margin.
        // RV32M is multi-cycle now: the three multiplies (MULH/MULHU/MULHSU)
        // stall 3 cycles each and the three divides (DIVU/REM/REMU) 34 each.
        wait_cycles(20 + 3 * 3 + 3 * 34);

        check_reg(10, 32'hFFFFFFFF, "MULH   x10 = high32(-8 * 3)");
        check_reg(11, 32'h00000002, "MULHU  x11 = high32(0xFFFFFFF8u * 3u)");
        check_reg(12, 32'hFFFFFFFF, "MULHSU x12 = high32(-8 * 3u)");
        check_reg(13, 32'h55555552, "DIVU   x13 = 0xFFFFFFF8u / 3u");
        check_reg(14, 32'hFFFFFFFE, "REM    x14 = -8 rem 3 = -2");
        check_reg(15, 32'd2,        "REMU   x15 = 0xFFFFFFF8u rem 3u = 2");

        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        $finish;
    end

endmodule
