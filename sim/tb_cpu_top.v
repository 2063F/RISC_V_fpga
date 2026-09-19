`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/23
// Design Name: 
// Module Name: tb_cpu_top
// Project Name: RISK-V RV32I CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Tool Versions: 
// Description: Testbench for the top level RISC-V CPU.
//              Loads a short sequence of computational instructions
//              and verifies the correct execution and write-back into registers.
// 
// Dependencies: cpu_top.v
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module tb_cpu_top;

    reg clk;
    reg rst_n;
    
    // Memory interface (stubbed)
    wire [31:0] mem_addr;
    wire [31:0] mem_write_data;
    wire        mem_write_en;
    wire        mem_read_en;
    reg  [31:0] mem_read_data;
    
    // Debug output
    wire [31:0] debug_pc;

    // Instantiate CPU
    cpu_top uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (mem_addr),
        .mem_write_data (mem_write_data),
        .mem_write_en   (mem_write_en),
        .mem_read_en    (mem_read_en),
        .mem_read_data  (mem_read_data),
        .uart_tx_pin    (),
        .debug_pc       (debug_pc),
        .debug_x1       ()
    );

    // Clock generation: 50 MHz (20ns period)
    always #10 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    // Helper task to verify register contents
    task check_reg;
        input [4:0] reg_num;
        input [31:0] expected_val;
        input [127:0] name;
        begin
            if (uut.regfile.regs[reg_num] === expected_val) begin
                $display("  PASS  %s: x%0d = %0d (0x%h)", name, reg_num, expected_val, expected_val);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %s: x%0d = %0d (0x%h) | expected: %0d (0x%h)", 
                         name, reg_num, uut.regfile.regs[reg_num], uut.regfile.regs[reg_num], 
                         expected_val, expected_val);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        // Generate wave dump file for GTKWave
        $dumpfile("sim/tb_cpu.vcd");
        $dumpvars(0, tb_cpu_top);

        clk = 0;
        rst_n = 0;
        mem_read_data = 32'd0;

        $display("=== RISC-V CPU Top Level Testbench ===");

        // Load instructions directly into Instruction Memory (ROM)
        // 0: ADDI x1, x0, 10      -> 32'h00A00093
        // 1: ADDI x2, x0, 20      -> 32'h01400113
        // 2: ADD  x3, x1, x2      -> 32'h002081B3 (x3 = 30)
        // 3: SUB  x4, x3, x1      -> 32'h40118233 (x4 = 20)
        // 4: LUI  x5, 0x12345     -> 32'h123452B7 (x5 = 0x12345000)
        // 5: MUL  x6, x1, x2      -> 32'h02208333 (x6 = 10 * 20 = 200)
        // 6: DIV  x7, x2, x1      -> 32'h021143b3 (x7 = 20 / 10 = 2)
        // 7: NOP                  -> 32'h00000013
        uut.imem.mem[0] = 32'h00A00093;
        uut.imem.mem[1] = 32'h01400113;
        uut.imem.mem[2] = 32'h002081B3;
        uut.imem.mem[3] = 32'h40118233;
        uut.imem.mem[4] = 32'h123452B7;
        uut.imem.mem[5] = 32'h02208333;
        uut.imem.mem[6] = 32'h021143b3;
        uut.imem.mem[7] = 32'h00000013;

        // Apply reset
        #25;
        rst_n = 1;

        // Run CPU cycles
        // Each cycle is 20ns. 
        // Wait for instructions to execute.
        
        // Cycle 1: ADDI x1, x0, 10 (PC=0)
        #40;
        $display("[PC=%0d] Executed ADDI x1, x0, 10", debug_pc - 4);
        check_reg(1, 32'd10, "x1 initialization");

        // Cycle 2: ADDI x2, x0, 20 (PC=4)
        #20;
        $display("[PC=%0d] Executed ADDI x2, x0, 20", debug_pc - 4);
        check_reg(2, 32'd20, "x2 initialization");

        // Cycle 3: ADD x3, x1, x2 (PC=8)
        #20;
        $display("[PC=%0d] Executed ADD x3, x1, x2", debug_pc - 4);
        check_reg(3, 32'd30, "x3 = x1 + x2");

        // Cycle 4: SUB x4, x3, x1 (PC=12)
        #20;
        $display("[PC=%0d] Executed SUB x4, x3, x1", debug_pc - 4);
        check_reg(4, 32'd20, "x4 = x3 - x1");

        // Cycle 5: LUI x5, 0x12345 (PC=16)
        #20;
        $display("[PC=%0d] Executed LUI x5, 0x12345", debug_pc - 4);
        check_reg(5, 32'h12345000, "x5 = 0x12345000");

        // Cycle 6: MUL x6, x1, x2 (PC=20)
        #20;
        $display("[PC=%0d] Executed MUL x6, x1, x2", debug_pc - 4);
        check_reg(6, 32'd200, "x6 = x1 * x2");

        // DIV x7, x2, x1 (PC=24)
        // DIV now runs on the multi-cycle divider: 34 cycles of stall, so this
        // instruction takes 35 clocks instead of 1 (20ns per clock).
        #20;
        #(34 * 20);
        $display("[PC=%0d] Executed DIV x7, x2, x1", debug_pc - 4);
        check_reg(7, 32'd2, "x7 = x2 / x1");

        // Cycle 8: NOP (PC=28)
        #20;
        
        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        $finish;
    end

endmodule
