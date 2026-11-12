`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_othello_mp
// Description: Runs examples/othello_embedded/search_bench.hex on a two-hart
//              cpu_top. The program times the Othello search on hart 0 alone
//              and on both harts, checks that both pick the same moves, and
//              prints "ALL OK" when they do. Its UART output is shown here.
//////////////////////////////////////////////////////////////////////////////////

module tb_othello_mp;

    parameter CLK_PERIOD  = 20;
    parameter BIT_NS      = 1_000_000_000 / 115200;
    parameter BIT_HALF_NS = BIT_NS / 2;

    reg clk = 0;
    reg rst_n = 0;

    always #(CLK_PERIOD/2) clk = ~clk;

    wire uart_tx_pin;

    cpu_top #(
        .INIT_FILE  ("examples/othello_embedded/search_bench.hex"),
        .NUM_HARTS  (2)
    ) uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_addr       (),
        .mem_write_data (),
        .mem_write_en   (),
        .mem_read_en    (),
        .mem_read_data  (32'd0),
        .uart_tx_pin    (uart_tx_pin),
        .uart_rx_pin    (1'b1),
        .debug_pc       (),
        .debug_x1       ()
    );

    // Bus statistics: cycles each hart has a request waiting for the bus
    // (the other hart holds it), and cycles it gets the bus.
    integer cycles = 0, wait0 = 0, wait1 = 0, gnt0 = 0, gnt1 = 0;
    always @(posedge clk) if (rst_n) begin
        cycles = cycles + 1;
        if (uut.dbus0_req && !uut.dbus0_gnt) wait0 = wait0 + 1;
        if (uut.dbus1_req && !uut.dbus1_gnt) wait1 = wait1 + 1;
        if (uut.dbus0_req &&  uut.dbus0_gnt) gnt0 = gnt0 + 1;
        if (uut.dbus1_req &&  uut.dbus1_gnt) gnt1 = gnt1 + 1;
    end

    task show_bus;
        begin
            $display("bus: %0d cycles; hart 0 %0d accesses, %0d cycles waiting; hart 1 %0d accesses, %0d cycles waiting",
                     cycles, gnt0, wait0, gnt1, wait1);
        end
    endtask

    reg [8*16-1:0] tail = 0;
    reg [7:0]      data;
    integer        i;

    initial begin
        $display("=== Othello two-hart search (search_bench.c) ===");
        repeat (5) @(posedge clk);
        rst_n = 1;
    end

    initial begin
        forever begin
            @(negedge uart_tx_pin);
            #(BIT_HALF_NS);
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                data[i] = uart_tx_pin;
            end
            #(BIT_NS + BIT_HALF_NS);
            $write("%c", data);
            $fflush;
            tail = {tail[8*15-1:0], data};
            if (data == 8'h0A) show_bus;
            if (tail[8*6-1:0] == "ALL OK") begin
                #(BIT_NS * 20);
                $display("\nALL TESTS PASSED!");
                $finish;
            end else if (tail[8*6-1:0] == "FAILED") begin
                #(BIT_NS * 20);
                $display("\nFAIL");
                $finish;
            end
        end
    end

    initial begin
        #(64'd20 * 200_000_000);
        $display("\nFAIL: timed out");
        $finish;
    end

endmodule
