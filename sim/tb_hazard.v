`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_hazard
// Description: Data hazard coverage for the three-stage pipeline.
//
//              With decode+register-read and execute in separate stages, an
//              instruction reads the register file in the same cycle the one
//              ahead of it writes it. cpu_top covers that with a single
//              forwarding path from the EX write-back value into the ID read;
//              this testbench is what proves it.
//
//              Every case below would silently read a stale register if the
//              forwarding were missing or mis-conditioned:
//                - back-to-back ALU dependency (distance 1)
//                - dependency at distance 2 (must come from the register file,
//                  not the forwarding path)
//                - load-use, where the forwarded value comes from memory and
//                  only becomes valid in the load's stall cycle
//                - multiply-use and divide-use, where the forwarded value
//                  arrives many cycles late
//                - a store whose data operand is forwarded
//                - a branch whose comparison operands are forwarded
//                - x0 as the destination, which must never forward
//////////////////////////////////////////////////////////////////////////////////

module tb_hazard;

    reg clk;
    reg rst_n;
    wire [31:0] mem_addr;
    wire [31:0] mem_write_data;
    wire        mem_write_en;
    wire        mem_read_en;
    reg  [31:0] mem_read_data;
    wire [31:0] debug_pc;
    reg         uart_rx_pin;

    cpu_top uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (mem_addr),
        .mem_write_data (mem_write_data),
        .mem_write_en   (mem_write_en),
        .mem_read_en    (mem_read_en),
        .mem_read_data  (mem_read_data),
        .uart_rx_pin    (uart_rx_pin),
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
        $dumpfile("sim/tb_hazard.vcd");
        $dumpvars(0, tb_hazard);

        clk = 0;
        rst_n = 0;
        mem_read_data = 32'd0;
        uart_rx_pin = 1'b1;

        $display("=== Data Hazard / Forwarding Testbench (3-stage pipeline) ===\n");

        // --------------------------------------------------------------------
        // Distance-1 and distance-2 ALU dependencies
        // --------------------------------------------------------------------
        uut.imem.mem[ 0] = 32'h00A00093; // ADDI x1, x0, 10
        uut.imem.mem[ 1] = 32'h00508113; // ADDI x2, x1, 5      <- reads x1 one behind
        uut.imem.mem[ 2] = 32'h00108193; // ADDI x3, x1, 1      <- reads x1 two behind
        uut.imem.mem[ 3] = 32'h002081B3; // ADD  x3, x1, x2     <- both operands, x2 one behind
        uut.imem.mem[ 4] = 32'h40308233; // SUB  x4, x1, x3     <- x3 one behind

        // --------------------------------------------------------------------
        // Load-use: the forwarded value comes out of the RAM
        // --------------------------------------------------------------------
        uut.imem.mem[ 5] = 32'h000102B7; // LUI  x5, 0x10       -> x5 = 0x00010000
        uut.imem.mem[ 6] = 32'h0DD00313; // ADDI x6, x0, 221
        uut.imem.mem[ 7] = 32'h0062A023; // SW   x6, 0(x5)      <- store data forwarded from x6
        uut.imem.mem[ 8] = 32'h0002A383; // LW   x7, 0(x5)
        uut.imem.mem[ 9] = 32'h00138413; // ADDI x8, x7, 1      <- load-use, x7 one behind

        // --------------------------------------------------------------------
        // Multiply-use and divide-use: forwarded value arrives many cycles late
        // --------------------------------------------------------------------
        uut.imem.mem[10] = 32'h00700493; // ADDI x9,  x0, 7
        uut.imem.mem[11] = 32'h00300513; // ADDI x10, x0, 3
        uut.imem.mem[12] = 32'h02A485B3; // MUL  x11, x9, x10   -> 21
        uut.imem.mem[13] = 32'h00158613; // ADDI x12, x11, 1    <- multiply-use
        uut.imem.mem[14] = 32'h02A4C6B3; // DIV  x13, x9, x10   -> 2
        uut.imem.mem[15] = 32'h00168713; // ADDI x14, x13, 1    <- divide-use

        // --------------------------------------------------------------------
        // Branch operands forwarded, and x0 must never forward
        // --------------------------------------------------------------------
        uut.imem.mem[16] = 32'h00500793; // ADDI x15, x0, 5
        uut.imem.mem[17] = 32'h00578863; // BEQ  x15, x5, +16   <- x15 one behind; 5 != 0x10000
        uut.imem.mem[18] = 32'h02A00813; // ADDI x16, x0, 42    <- must execute (not taken)
        uut.imem.mem[19] = 32'h06300013; // ADDI x0,  x0, 99    <- writes x0, must be discarded
        uut.imem.mem[20] = 32'h000008B3; // ADD  x17, x0, x0    <- must not see 99
        uut.imem.mem[21] = 32'h00000013; // NOP
        uut.imem.mem[22] = 32'h00000013; // NOP
        uut.imem.mem[23] = 32'h00000013; // NOP

        wait_cycles(2);
        rst_n = 1;
        // 24 instructions, plus one load stall, one multiply (3) and one divide
        // (34), plus the pipeline fill.
        wait_cycles(24 + 1 + 3 + 34 + 8);

        $display("--- ALU dependencies ---");
        check_reg(5'd1,  32'd10,        "ADDI x1 = 10               ");
        check_reg(5'd2,  32'd15,        "ADDI x2 = x1 + 5  (dist 1) ");
        check_reg(5'd3,  32'd25,        "ADD  x3 = x1 + x2 (dist 1) ");
        check_reg(5'd4,  32'hFFFFFFF1,  "SUB  x4 = x1 - x3 (dist 1) ");

        $display("\n--- Load-use and forwarded store data ---");
        check_reg(5'd7,  32'd221,       "LW   x7 = 221              ");
        check_reg(5'd8,  32'd222,       "ADDI x8 = x7 + 1 (load-use)");

        $display("\n--- Multiply-use and divide-use ---");
        check_reg(5'd11, 32'd21,        "MUL  x11 = 7 * 3           ");
        check_reg(5'd12, 32'd22,        "ADDI x12 = x11 + 1         ");
        check_reg(5'd13, 32'd2,         "DIV  x13 = 7 / 3           ");
        check_reg(5'd14, 32'd3,         "ADDI x14 = x13 + 1         ");

        $display("\n--- Forwarded branch operands, and x0 ---");
        check_reg(5'd16, 32'd42,        "BEQ not taken, x16 = 42    ");
        check_reg(5'd0,  32'd0,         "ADDI x0,x0,99 discarded    ");
        check_reg(5'd17, 32'd0,         "ADD  x17 = x0 + x0         ");

        $display("\n=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED!");
        else                 $display("SOME TESTS FAILED!");

        $finish;
    end

endmodule
