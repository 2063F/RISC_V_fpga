`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_hartid
// Description: Two rv_core instances with HART_ID 0 and 3, each running
//                  csrr x1, mhartid
//                  j    .
//              from a small ROM model of its own. Each must read back its own
//              HART_ID in x1.
//////////////////////////////////////////////////////////////////////////////////

module tb_hartid;

    reg clk = 0;
    reg rst_n = 0;

    always #10 clk = ~clk;

    wire [31:0] x1_a, x1_b;

    hart_with_rom #(.HART_ID(0)) hart_a (.clk(clk), .rst_n(rst_n), .x1(x1_a));
    hart_with_rom #(.HART_ID(3)) hart_b (.clk(clk), .rst_n(rst_n), .x1(x1_b));

    initial begin
        $display("=== mhartid Testbench ===");
        #45;
        rst_n = 1;
        repeat (20) @(posedge clk);
        #1;
        $display("hart A: x1 = %0d, hart B: x1 = %0d", x1_a, x1_b);
        if (x1_a === 32'd0 && x1_b === 32'd3)
            $display("ALL TESTS PASSED!");
        else
            $display("FAIL: expected x1 = 0 and 3");
        $finish;
    end

endmodule

// One hart and a registered-read ROM, with nothing on the data bus.
module hart_with_rom #(
    parameter [31:0] HART_ID = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    output wire [31:0] x1
);

    wire [31:0] ibus_addr;
    wire        ibus_ce;
    reg  [31:0] ibus_rdata = 32'h0000_0013;

    always @(posedge clk) begin
        if (ibus_ce) begin
            case (ibus_addr)
                32'h0000_0000: ibus_rdata <= 32'hF140_20F3;  // csrr x1, mhartid
                32'h0000_0004: ibus_rdata <= 32'h0000_006F;  // j .
                default:       ibus_rdata <= 32'h0000_0013;  // nop
            endcase
        end
    end

    rv_core #(
        .HART_ID (HART_ID)
    ) core (
        .clk         (clk),
        .rst_n       (rst_n),
        .ibus_addr   (ibus_addr),
        .ibus_ce     (ibus_ce),
        .ibus_rdata  (ibus_rdata),
        .ibus_valid  (1'b1),
        .dbus_req    (),
        .dbus_we     (),
        .dbus_addr   (),
        .dbus_wdata  (),
        .dbus_funct3 (),
        .dbus_gnt    (1'b1),
        .dbus_rvalid (1'b0),
        .dbus_rdata  (32'd0),
        .irq_ext     (1'b0),
        .irq_timer   (1'b0),
        .irq_soft    (1'b0),
        .mtime       (64'd0),
        .debug_pc    (),
        .debug_x1    (x1)
    );

endmodule
