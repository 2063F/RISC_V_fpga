`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_bus_stress
// Description: tb_trap again, with cpu_top's BUS_STRESS switched on: the data
//              bus refuses requests and holds back load data for pseudo-random
//              numbers of cycles. Every load, store and MMIO access in the
//              program then sees wait states that the real SoC never produces,
//              which checks that the hart's handshake does not depend on the
//              fixed one-cycle timing.
//
//              The program is sim/trap_test.hex, a self-checking program
//              covering the CSR instructions, every implemented exception,
//              the timer, software and UART interrupts, vectored mtvec, and
//              interrupts landing on loads, stores, multiplies and divides.
//
//              The program keeps its own pass/fail counts (s0/s1) and the
//              number of the first failing check (s3); the source has the
//              checks in order, so s3 points straight at the one that broke.
//              It sets gp = 0xD0E when it has run to the end.
//
//              TIMER_DIV = 1 makes mtime count clocks, so the timer tests
//              finish in microseconds of simulated time.
//////////////////////////////////////////////////////////////////////////////////

module tb_bus_stress;

    parameter CLK_PERIOD = 20;                         // 50 MHz
    parameter BIT_NS     = 1_000_000_000 / 115200;     // ~8680 ns

    reg clk = 0;
    reg rst_n = 0;
    reg uart_rx_pin = 1;  // idle high

    wire [31:0] mem_addr, mem_write_data, debug_pc, debug_x1;
    wire        mem_write_en, mem_read_en, uart_tx_pin;

    cpu_top #(
        .INIT_FILE ("sim/trap_test.hex"),
        .TIMER_DIV (1),
        .BUS_STRESS (1)
    ) uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (mem_addr),
        .mem_write_data (mem_write_data),
        .mem_write_en   (mem_write_en),
        .mem_read_en    (mem_read_en),
        .mem_read_data  (32'd0),
        .uart_tx_pin    (uart_tx_pin),
        .uart_rx_pin    (uart_rx_pin),
        .debug_pc       (debug_pc),
        .debug_x1       (debug_x1)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    task send_byte;
        input [7:0] data;
        integer i;
        begin
            uart_rx_pin = 0;
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_pin = data[i];
                #(BIT_NS);
            end
            uart_rx_pin = 1;
            #(BIT_NS);
        end
    endtask

    wire [31:0] passed     = uut.core0.regfile.regs[8];
    wire [31:0] failed     = uut.core0.regfile.regs[9];
    wire [31:0] first_fail = uut.core0.regfile.regs[19];
    wire [31:0] done_flag  = uut.core0.regfile.regs[3];

    initial begin
        $display("=== Bus wait-state stress (trap_test.hex) ===");
        #(CLK_PERIOD * 5);
        rst_n = 1;

        // RAM word 6 (0x0001_0018): the program asks for the UART byte here.
        // Polled, because a wait on a function of a memory never wakes up.
        while (uut.dmem.peek_word(6) != 32'd1)
            #(CLK_PERIOD * 100);
        $display("[TB] program waiting for UART byte, sending 'K'");
        send_byte(8'h4B);
    end

    initial begin
        #(CLK_PERIOD * 4_000_000);
        $display("FAIL: timed out (pc = 0x%h, passed = %0d, failed = %0d, first failing check = %0d)",
                 debug_pc, passed, failed, first_fail);
        $finish;
    end

    initial begin
        wait (rst_n);
        wait (done_flag == 32'hD0E);
        #(CLK_PERIOD * 2);
        $display("=== Summary: %0d passed, %0d failed ===", passed, failed);
        if (failed == 0 && passed > 0)
            $display("ALL TESTS PASSED!");
        else
            $display("FAIL: first failing check = %0d", first_fail);
        $finish;
    end

endmodule
