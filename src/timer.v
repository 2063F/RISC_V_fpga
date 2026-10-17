`timescale 1ns / 1ps
// =============================================================================
// timer.v - Machine timer and software interrupt (a minimal CLINT)
// =============================================================================
// Memory map (word access only):
//   0x8000_0100 : msip      bit 0 drives the machine software interrupt
//   0x8000_0108 : mtimecmp  low word
//   0x8000_010C : mtimecmp  high word
//   0x8000_0110 : mtime     low word
//   0x8000_0114 : mtime     high word
//
// mtime advances once every DIV clocks; the default of 50 makes it a
// microsecond counter at the board's 50 MHz. The machine timer interrupt is
// pending while mtime >= mtimecmp, so software clears it by moving mtimecmp
// forward. mtimecmp resets to all ones so nothing fires before it is set.
//
// Updating the 64-bit mtimecmp takes two stores. To avoid a spurious interrupt
// in between, write 0xFFFF_FFFF to the low word first, then the high word,
// then the real low word (the sequence the privileged spec recommends).
// =============================================================================

module timer #(
    parameter integer DIV = 50
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] addr,
    input  wire [31:0] write_data,
    input  wire        write_en,
    output wire        sel,         // addr falls in the timer's window
    output reg  [31:0] read_data,

    output reg  [63:0] mtime,
    output reg         irq_timer,
    output reg         irq_soft
);

    localparam [31:0] MSIP_ADDR      = 32'h8000_0100;
    localparam [31:0] MTIMECMP_ADDR  = 32'h8000_0108;
    localparam [31:0] MTIMECMPH_ADDR = 32'h8000_010C;
    localparam [31:0] MTIME_ADDR     = 32'h8000_0110;
    localparam [31:0] MTIMEH_ADDR    = 32'h8000_0114;

    // 0x8000_0100 - 0x8000_011F
    assign sel = (addr[31:5] == MSIP_ADDR[31:5]);

    reg [63:0] mtimecmp;

    localparam integer PRESCALE_W = (DIV > 1) ? $clog2(DIV) : 1;
    reg [PRESCALE_W-1:0] prescale;
    wire tick = (DIV <= 1) || (prescale == DIV - 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            prescale  <= 0;
            mtime     <= 64'd0;
            mtimecmp  <= {64{1'b1}};
            irq_soft  <= 1'b0;
            irq_timer <= 1'b0;
        end else begin
            prescale <= tick ? 0 : prescale + 1'b1;
            if (tick)
                mtime <= mtime + 64'd1;

            if (write_en) begin
                case (addr)
                    MSIP_ADDR:      irq_soft         <= write_data[0];
                    MTIMECMP_ADDR:  mtimecmp[31:0]   <= write_data;
                    MTIMECMPH_ADDR: mtimecmp[63:32]  <= write_data;
                    MTIME_ADDR:     mtime[31:0]      <= write_data;
                    MTIMEH_ADDR:    mtime[63:32]     <= write_data;
                    default: ;
                endcase
            end

            // Registered so the 64-bit compare gets a whole cycle to itself.
            irq_timer <= (mtime >= mtimecmp);
        end
    end

    always @(*) begin
        case (addr)
            MSIP_ADDR:      read_data = {31'd0, irq_soft};
            MTIMECMP_ADDR:  read_data = mtimecmp[31:0];
            MTIMECMPH_ADDR: read_data = mtimecmp[63:32];
            MTIME_ADDR:     read_data = mtime[31:0];
            MTIMEH_ADDR:    read_data = mtime[63:32];
            default:        read_data = 32'd0;
        endcase
    end

endmodule
