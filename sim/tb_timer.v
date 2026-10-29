`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_timer
// Description: Unit test of timer.v with NUM_HARTS = 2: each hart's msip and
//              mtimecmp sit in their own 32-byte block and drive only that
//              hart's interrupt lines, mtime is one counter shared by every
//              block, and nothing past the last block is claimed.
//
//              DIV = 1, so mtime counts clocks.
//////////////////////////////////////////////////////////////////////////////////

module tb_timer;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [31:0] addr = 32'd0;
    reg  [31:0] write_data = 32'd0;
    reg         write_en = 0;
    wire        sel;
    wire [31:0] read_data;
    wire [63:0] mtime;
    wire [1:0]  irq_timer;
    wire [1:0]  irq_soft;

    timer #(
        .DIV       (1),
        .NUM_HARTS (2)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .addr       (addr),
        .write_data (write_data),
        .write_en   (write_en),
        .sel        (sel),
        .read_data  (read_data),
        .mtime      (mtime),
        .irq_timer  (irq_timer),
        .irq_soft   (irq_soft)
    );

    always #10 clk = ~clk;

    integer errors = 0;

    task check;
        input        cond;
        input [8*64-1:0] what;
        begin
            if (!cond) begin
                $display("FAIL: %0s", what);
                errors = errors + 1;
            end
        end
    endtask

    task write_word;
        input [31:0] a;
        input [31:0] d;
        begin
            addr       = a;
            write_data = d;
            write_en   = 1;
            @(posedge clk);
            #1;
            write_en   = 0;
        end
    endtask

    // Read data is registered: valid one clock after the address.
    task read_word;
        input  [31:0] a;
        output [31:0] d;
        begin
            addr = a;
            @(posedge clk);
            #1;
            d = read_data;
        end
    endtask

    reg [31:0] rd, t0;

    initial begin
        $display("=== Timer (2 harts) Testbench ===");
        #25;
        rst_n = 1;
        @(posedge clk);
        #1;

        // Address window: hart 0 and hart 1 blocks, nothing beyond.
        addr = 32'h8000_0100; #1; check(sel === 1'b1, "hart 0 block selected");
        addr = 32'h8000_0134; #1; check(sel === 1'b1, "hart 1 block selected");
        addr = 32'h8000_0140; #1; check(sel === 1'b0, "hart 2 block not selected");
        addr = 32'h8000_00FC; #1; check(sel === 1'b0, "below the window");

        check(irq_soft  === 2'b00, "msip resets to 0");
        check(irq_timer === 2'b00, "no timer interrupt after reset");

        // msip: each block drives its own hart only.
        write_word(32'h8000_0120, 32'd1);
        check(irq_soft === 2'b10, "hart 1 msip set, hart 0 untouched");
        read_word(32'h8000_0120, rd); check(rd === 32'd1, "hart 1 msip reads back 1");
        read_word(32'h8000_0100, rd); check(rd === 32'd0, "hart 0 msip reads back 0");
        write_word(32'h8000_0100, 32'd1);
        check(irq_soft === 2'b11, "both msip set");
        write_word(32'h8000_0120, 32'd0);
        check(irq_soft === 2'b01, "hart 1 msip cleared, hart 0 still set");
        write_word(32'h8000_0100, 32'd0);

        // mtime is shared: every block shows the same counter.
        read_word(32'h8000_0110, t0);
        read_word(32'h8000_0130, rd);
        check(rd === t0 + 32'd1, "hart 1 block shows the shared mtime");
        write_word(32'h8000_0134, 32'd0);           // via hart 1's block
        write_word(32'h8000_0130, 32'd1000);
        read_word(32'h8000_0110, rd);
        check(rd >= 32'd1000 && rd < 32'd1010, "mtime written via hart 1 seen via hart 0");
        read_word(32'h8000_0114, rd); check(rd === 32'd0, "mtime high word");

        // mtimecmp: separate per hart, reset to all ones.
        read_word(32'h8000_0128, rd); check(rd === 32'hFFFF_FFFF, "hart 1 mtimecmp resets to ones");
        write_word(32'h8000_012C, 32'd0);           // hart 1: mtimecmp = 0 -> fires
        write_word(32'h8000_0128, 32'd0);
        @(posedge clk); #1;
        check(irq_timer === 2'b10, "hart 1 timer fires, hart 0 does not");
        read_word(32'h8000_0108, rd); check(rd === 32'hFFFF_FFFF, "hart 0 mtimecmp untouched");
        read_word(32'h8000_0128, rd); check(rd === 32'd0, "hart 1 mtimecmp low reads back");

        // Hart 0: compare a little in the future, then watch it fire.
        read_word(32'h8000_0110, t0);
        write_word(32'h8000_010C, 32'd0);
        write_word(32'h8000_0108, t0 + 32'd20);
        @(posedge clk); #1;
        check(irq_timer[0] === 1'b0, "hart 0 timer not yet due");
        repeat (25) @(posedge clk);
        #1;
        check(irq_timer === 2'b11, "hart 0 timer fires when due");

        // Moving hart 1's compare forward clears only hart 1.
        write_word(32'h8000_012C, 32'hFFFF_FFFF);
        @(posedge clk); #1;
        check(irq_timer === 2'b01, "hart 1 cleared, hart 0 still pending");

        if (errors == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end

endmodule
