`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_arch_test
// Description: Runs one riscv-arch-test program on a one-hart cpu_top and
//              writes its signature, one word per line, for
//              sim/arch_test/run_arch_test.py to compare with the reference.
//
// Plusargs (all addresses in hex):
//   +hex=<file>     program image, loaded into the ROM
//   +halt=<addr>    address of rvmodel_halt
//   +begin=<addr>   begin_signature
//   +end=<addr>     end_signature
//   +sig=<file>     where to write the signature
//////////////////////////////////////////////////////////////////////////////////

module tb_arch_test;

    parameter CLK_PERIOD = 20;
    parameter MAX_CYCLES = 2_000_000;

    reg clk = 0;
    reg rst_n = 0;

    always #(CLK_PERIOD/2) clk = ~clk;

    wire [31:0] debug_pc;

    cpu_top #(
        .INIT_FILE  (""),
        .NUM_HARTS  (1)
    ) uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (),
        .mem_write_data (),
        .mem_write_en   (),
        .mem_read_en    (),
        .mem_read_data  (32'd0),
        .uart_tx_pin    (),
        .uart_rx_pin    (1'b1),
        .debug_pc       (debug_pc),
        .debug_x1       ()
    );

    reg [8*512-1:0] hex_file, sig_file;
    reg [31:0]      halt_pc, sig_begin, sig_end, addr, word;
    integer         fd, cycles, at_halt, idx;

    initial begin
        if (!$value$plusargs("hex=%s", hex_file) ||
            !$value$plusargs("halt=%h", halt_pc) ||
            !$value$plusargs("begin=%h", sig_begin) ||
            !$value$plusargs("end=%h", sig_end) ||
            !$value$plusargs("sig=%s", sig_file)) begin
            $display("ERROR: missing plusargs");
            $finish;
        end
        #1 $readmemh(hex_file, uut.imem.mem);   // after the ROM's own NOP fill

        repeat (5) @(posedge clk);
        rst_n = 1;

        cycles  = 0;
        at_halt = 0;
        while (at_halt < 16 && cycles < MAX_CYCLES) begin
            @(posedge clk);
            cycles  = cycles + 1;
            // The jump-to-self keeps fetching the next word too, so count
            // visits rather than consecutive cycles.
            if (debug_pc == halt_pc)
                at_halt = at_halt + 1;
        end
        if (at_halt < 16) begin
            $display("TIMEOUT pc=%08h", debug_pc);
            $finish;
        end

        fd = $fopen(sig_file, "w");
        for (addr = sig_begin; addr < sig_end; addr = addr + 4) begin
            idx  = (addr - 32'h0001_0000) >> 2;
            word = {uut.dmem.mem3[idx], uut.dmem.mem2[idx],
                    uut.dmem.mem1[idx], uut.dmem.mem0[idx]};
            $fdisplay(fd, "%08h", word);
        end
        $fclose(fd);
        $display("HALTED after %0d cycles", cycles);
        $finish;
    end

endmodule
