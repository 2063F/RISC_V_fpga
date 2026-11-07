`timescale 1ns / 1ps
// =============================================================================
// timer.v - Machine timer and software interrupts (a minimal CLINT)
// =============================================================================
// Reads are registered like the BSRAMs: the data for an address appears one
// clock later, which the CPU's one-cycle load stall already allows for.
//
// Every hart gets a 32-byte block of its own, hart h at 0x8000_0100 + 0x20*h
// (NUM_HARTS up to 8, so the whole timer fits in 0x8000_0100 - 0x8000_01FF).
// Hart 0's block is where the single-hart timer always was, so existing
// programs keep working. Inside a block (word access only):
//
//   +0x00 : msip      bit 0 drives hart h's machine software interrupt
//   +0x08 : mtimecmp  low word   } hart h's machine timer interrupt
//   +0x0C : mtimecmp  high word  }
//   +0x10 : mtime     low word   } one shared counter, visible (and
//   +0x14 : mtime     high word  } writable) through every block
//
// Any hart may write any block: setting another hart's msip is how one hart
// interrupts another.
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
    parameter integer DIV       = 50,
    parameter integer NUM_HARTS = 1     // 1 - 8
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] addr,
    input  wire [31:0] write_data,
    input  wire        write_en,
    output wire        sel,         // addr falls in the timer's window
    output reg  [31:0] read_data,   // valid one clock after addr

    output reg  [63:0]          mtime,
    output wire [NUM_HARTS-1:0] irq_timer,
    output wire [NUM_HARTS-1:0] irq_soft
);

    localparam [31:0] BASE_ADDR     = 32'h8000_0100;
    localparam [4:0]  MSIP_OFS      = 5'h00;
    localparam [4:0]  MTIMECMP_OFS  = 5'h08;
    localparam [4:0]  MTIMECMPH_OFS = 5'h0C;
    localparam [4:0]  MTIME_OFS     = 5'h10;
    localparam [4:0]  MTIMEH_OFS    = 5'h14;

    wire [2:0] hart = addr[7:5];
    wire [4:0] ofs  = addr[4:0];

    // 0x8000_0100 up to the end of the last hart's block
    assign sel = (addr[31:8] == BASE_ADDR[31:8]) && (hart < NUM_HARTS);

    localparam integer PRESCALE_W = (DIV > 1) ? $clog2(DIV) : 1;
    reg [PRESCALE_W-1:0] prescale;
    wire tick = (DIV <= 1) || (prescale == DIV - 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            prescale <= 0;
            mtime    <= 64'd0;
        end else begin
            prescale <= tick ? 0 : prescale + 1'b1;
            if (tick)
                mtime <= mtime + 64'd1;

            if (write_en) begin
                case (ofs)
                    MTIME_OFS:  mtime[31:0]  <= write_data;
                    MTIMEH_OFS: mtime[63:32] <= write_data;
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // Per-hart msip and mtimecmp
    // =========================================================================
    wire [64*NUM_HARTS-1:0] mtimecmp_all;

    genvar h;
    generate
        for (h = 0; h < NUM_HARTS; h = h + 1) begin : g_hart
            reg [63:0] mtimecmp;
            reg        msip;
            reg        mtip;

            wire hit = write_en && (hart == h);

            always @(posedge clk) begin
                if (!rst_n) begin
                    mtimecmp <= {64{1'b1}};
                    msip     <= 1'b0;
                    mtip     <= 1'b0;
                end else begin
                    if (hit) begin
                        case (ofs)
                            MSIP_OFS:      msip            <= write_data[0];
                            MTIMECMP_OFS:  mtimecmp[31:0]  <= write_data;
                            MTIMECMPH_OFS: mtimecmp[63:32] <= write_data;
                            default: ;
                        endcase
                    end

                    // Registered so the 64-bit compare gets a whole cycle to itself.
                    mtip <= (mtime >= mtimecmp);
                end
            end

            assign irq_soft[h]              = msip;
            assign irq_timer[h]             = mtip;
            assign mtimecmp_all[64*h +: 64] = mtimecmp;
        end
    endgenerate

    always @(posedge clk) begin
        if (!sel) begin
            read_data <= 32'd0;
        end else begin
            case (ofs)
                MSIP_OFS:      read_data <= {31'd0, irq_soft[hart]};
                MTIMECMP_OFS:  read_data <= mtimecmp_all[64*hart      +: 32];
                MTIMECMPH_OFS: read_data <= mtimecmp_all[64*hart + 32 +: 32];
                MTIME_OFS:     read_data <= mtime[31:0];
                MTIMEH_OFS:    read_data <= mtime[63:32];
                default:       read_data <= 32'd0;
            endcase
        end
    end

endmodule
