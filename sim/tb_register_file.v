// =============================================================================
// tb_register_file.v - Testbench for RISC-V Register File
// =============================================================================
// Tests:
//   1. Reset clears all registers
//   2. Write and read back arbitrary registers
//   3. x0 always reads 0 (write to x0 is ignored)
//   4. Two simultaneous reads from different registers
// Run: iverilog -I ../src -o tb_regfile.out tb_register_file.v ../src/register_file.v
//      vvp tb_regfile.out
// =============================================================================

`timescale 1ns / 1ps

module tb_register_file;

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg        clk, rst;
    reg  [4:0] rs1, rs2, rd;
    reg  [31:0] wd;
    reg        we;
    wire [31:0] rd1, rd2;

    // =========================================================================
    // Instantiate DUT
    // =========================================================================
    register_file dut (
        .clk (clk),
        .rst (rst),
        .rs1 (rs1),
        .rd1 (rd1),
        .rs2 (rs2),
        .rd2 (rd2),
        .rd  (rd),
        .wd  (wd),
        .we  (we)
    );

    // Clock: 10ns period
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    task check_rd1;
        input [127:0] name;
        input [31:0]  expected;
        begin
            if (rd1 === expected) begin
                $display("  PASS  %s | rs1=x%0d -> rd1=0x%08h", name, rs1, rd1);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %s | rs1=x%0d | expected=0x%08h got=0x%08h",
                         name, rs1, expected, rd1);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        $display("=== RISC-V Register File Testbench ===");

        // Initial state
        clk = 0; rst = 1; we = 0;
        rs1 = 0; rs2 = 0; rd = 0; wd = 0;

        // ------------------------------------------------------------------
        // 1. Reset — all registers should be 0
        // ------------------------------------------------------------------
        $display("\n--- 1. Reset ---");
        @(posedge clk); #1;
        rst = 0;

        rs1 = 5'd1;  #1; check_rd1("x1  after reset", 32'd0);
        rs1 = 5'd15; #1; check_rd1("x15 after reset", 32'd0);
        rs1 = 5'd31; #1; check_rd1("x31 after reset", 32'd0);

        // ------------------------------------------------------------------
        // 2. Write then read back
        // ------------------------------------------------------------------
        $display("\n--- 2. Write & Read ---");

        // Write 0xDEADBEEF to x1
        we = 1; rd = 5'd1; wd = 32'hDEADBEEF;
        @(posedge clk); #1;
        rs1 = 5'd1; #1; check_rd1("x1=0xDEADBEEF", 32'hDEADBEEF);

        // Write 42 to x10
        rd = 5'd10; wd = 32'd42;
        @(posedge clk); #1;
        rs1 = 5'd10; #1; check_rd1("x10=42        ", 32'd42);

        // Write 0x12345678 to x31
        rd = 5'd31; wd = 32'h12345678;
        @(posedge clk); #1;
        rs1 = 5'd31; #1; check_rd1("x31=0x12345678", 32'h12345678);

        we = 0;

        // ------------------------------------------------------------------
        // 3. x0 is hardwired to zero
        // ------------------------------------------------------------------
        $display("\n--- 3. x0 always zero ---");

        // Try to write to x0 (should have no effect)
        we = 1; rd = 5'd0; wd = 32'hFFFFFFFF;
        @(posedge clk); #1;
        we = 0;
        rs1 = 5'd0; #1; check_rd1("x0 write ignored", 32'd0);

        // Read x0 via rs2 port as well
        rs2 = 5'd0; #1;
        if (rd2 === 32'd0) begin
            $display("  PASS  x0 via rs2 port -> rd2=0x%08h", rd2);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  x0 via rs2 port | expected=0 got=0x%08h", rd2);
            fail_count = fail_count + 1;
        end

        // ------------------------------------------------------------------
        // 4. Two simultaneous reads
        // ------------------------------------------------------------------
        $display("\n--- 4. Simultaneous two-port read ---");

        // x1 = 0xDEADBEEF (written above), x10 = 42
        rs1 = 5'd1; rs2 = 5'd10; #1;
        if (rd1 === 32'hDEADBEEF && rd2 === 32'd42) begin
            $display("  PASS  rd1=0x%08h rd2=%0d (simultaneous)", rd1, rd2);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  simultaneous read | rd1=0x%08h rd2=%0d", rd1, rd2);
            fail_count = fail_count + 1;
        end

        // ------------------------------------------------------------------
        // 5. we=0 does not write
        // ------------------------------------------------------------------
        $display("\n--- 5. Write enable = 0 ignored ---");
        we = 0; rd = 5'd1; wd = 32'h00000000;
        @(posedge clk); #1;
        rs1 = 5'd1; #1; check_rd1("x1 unchanged   ", 32'hDEADBEEF);

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        $finish;
    end

endmodule
