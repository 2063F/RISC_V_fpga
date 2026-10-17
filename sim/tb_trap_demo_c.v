`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_trap_demo_c
// Description: Runs examples/trap_demo.hex (built from trap_demo.c) and checks
//              its UART output: the ECALL and illegal-instruction traps are
//              reported with the right mcause, the timer interrupt ticks, and
//              a byte sent to UART RX comes back through the external
//              interrupt.
//
//              TIMER_DIV = 1, so the demo's 500 000-tick period is 10 ms of
//              simulated time instead of 500 ms.
//////////////////////////////////////////////////////////////////////////////////

module tb_trap_demo_c;

    parameter CLK_PERIOD  = 20;
    parameter BIT_NS      = 1_000_000_000 / 115200;
    parameter BIT_HALF_NS = BIT_NS / 2;

    reg clk = 0;
    reg rst_n = 0;
    reg uart_rx_pin = 1;
    wire uart_tx_pin;
    wire [31:0] debug_pc, debug_x1;

    cpu_top #(
        .INIT_FILE ("examples/trap_demo.hex"),
        .TIMER_DIV (1)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (),
        .mem_write_data (),
        .mem_write_en   (),
        .mem_read_en    (),
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

    // Everything the CPU prints is kept here for the checks below.
    reg [7:0] log [0:4095];
    integer   log_len = 0;

    task recv_byte;
        output [7:0] data;
        integer i;
        begin
            @(negedge uart_tx_pin);
            #(BIT_HALF_NS);
            data = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                data[i] = uart_tx_pin;
            end
            #(BIT_NS + BIT_HALF_NS);
        end
    endtask

    reg [7:0] rx_val;
    initial begin
        forever begin
            recv_byte(rx_val);
            $write("%c", rx_val);
            if (log_len < 4096) begin
                log[log_len] = rx_val;
                log_len = log_len + 1;
            end
        end
    end

    // 1 if the captured output contains the string (packed, NUL-free).
    function contains;
        input [8*48-1:0] needle;
        input integer    n;      // length of needle in characters
        integer i, j, ok;
        begin
            contains = 0;
            for (i = 0; i + n <= log_len && !contains; i = i + 1) begin
                ok = 1;
                for (j = 0; j < n && ok; j = j + 1)
                    if (log[i + j] !== needle[8*(n-1-j) +: 8])
                        ok = 0;
                if (ok) contains = 1;
            end
        end
    endfunction

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input [8*48-1:0] needle;
        input integer    n;
        begin
            if (contains(needle, n)) begin
                pass_count = pass_count + 1;
                $display("  PASS  output contains \"%0s\"", needle);
            end else begin
                fail_count = fail_count + 1;
                $display("  FAIL  output lacks \"%0s\"", needle);
            end
        end
    endtask

    initial begin
        $display("=== trap_demo.c Testbench ===");
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Startup messages plus two timer ticks.
        while (!contains("tick 2", 6))
            #100_000;
        send_byte("Q");
        #3_000_000;

        $display("\n--- checks ---");
        check("misa=0x40001100", 15);
        check("trap: mcause=11 ", 16);
        check("trap: mcause=2 ", 15);
        check("mtval=0x0", 9);
        check("tick 1", 6);
        check("tick 2", 6);
        check("rx 'Q'", 6);

        $display("=== Summary: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED!");
        $finish;
    end

    initial begin
        #80_000_000;
        $display("\nFAIL: timed out");
        $finish;
    end

endmodule
