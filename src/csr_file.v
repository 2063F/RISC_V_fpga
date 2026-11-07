`timescale 1ns / 1ps
// =============================================================================
// csr_file.v - Machine-mode CSRs, trap state and counters (Zicsr)
// =============================================================================
// The core only has machine mode, so this is the whole privileged
// architecture it needs:
//
//   mstatus   MIE (bit 3), MPIE (bit 7); MPP (bits 12:11) reads as 11
//   misa      RV32IMA, read-only (writes are ignored, which WARL allows)
//   mie/mip   MSIE/MSIP (3), MTIE/MTIP (7), MEIE/MEIP (11). mip is read-only:
//             its bits follow the interrupt lines and are cleared at the source
//   mtvec     BASE[31:2] + MODE bit 0 (0 = direct, 1 = vectored)
//   mscratch, mepc, mcause, mtval
//   mcycle/minstret (+ h) and the read-only cycle/time/instret (+ h) shadows
//   mvendorid/marchid/mimpid, all 0; mhartid = HART_ID
//
// Any other address is an illegal instruction, as is writing a read-only CSR
// (address bits [11:10] = 11). That check is a separate port, used by cpu_top
// in ID so the answer is already registered by the time the instruction
// reaches EX - the trap decision feeds the next-PC mux and every write enable,
// and none of them can afford a 12-bit address compare in front of them.
//
// Reads have no side effects, so CSRRW with rd = x0 needs no special case.
// =============================================================================

`include "riscv_defines.vh"

module csr_file #(
    parameter [31:0] HART_ID = 32'd0
) (
    input  wire        clk,
    input  wire        rst_n,

    // ID stage: legality check for the instruction being decoded
    input  wire [11:0] chk_addr,
    input  wire        chk_write,
    output reg         chk_illegal,

    // EX stage: CSRRW / CSRRS / CSRRC and their immediate forms
    input  wire [11:0] addr,
    output reg  [31:0] rdata,
    input  wire        we,
    input  wire [1:0]  op,          // funct3[1:0]
    input  wire [31:0] operand,     // rs1 value or zero-extended uimm

    // Trap entry and return
    input  wire        trap,
    input  wire        trap_irq,    // 1 = interrupt, 0 = exception
    input  wire [3:0]  trap_code,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_val,
    input  wire        mret,
    input  wire        instret,     // one instruction retired

    // Interrupt lines (level sensitive) and the timer value for time/timeh
    input  wire        irq_ext,
    input  wire        irq_timer,
    input  wire        irq_soft,
    input  wire [63:0] mtime,

    output wire        irq_pending, // an enabled interrupt is waiting
    output reg  [3:0]  irq_code,
    output wire [31:0] exc_vector,  // trap target for an exception
    output wire [31:0] irq_vector,  // trap target for the pending interrupt
    output wire [31:0] mepc
);

    localparam [31:0] MISA_VALUE = 32'h4000_1101;  // MXL = 32, I, M, A

    reg        mstatus_mie, mstatus_mpie;
    reg        mie_msie, mie_mtie, mie_meie;
    reg [29:0] mtvec_base;
    reg        mtvec_vectored;
    reg [31:0] mscratch;
    reg [29:0] mepc_word;           // no C extension, so mepc[1:0] is always 0
    reg        mcause_irq;
    reg [3:0]  mcause_code;
    reg [31:0] mtval;
    reg [63:0] mcycle;
    reg [63:0] minstret;

    wire [31:0] mstatus_value = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
    wire [31:0] mie_value     = {20'd0, mie_meie, 3'd0, mie_mtie, 3'd0, mie_msie, 3'd0};
    wire [31:0] mip_value     = {20'd0, irq_ext,  3'd0, irq_timer, 3'd0, irq_soft, 3'd0};

    assign mepc = {mepc_word, 2'b00};

    // =========================================================================
    // Legality check (ID)
    // =========================================================================
    always @(*) begin
        case (chk_addr)
            `CSR_MSTATUS, `CSR_MISA, `CSR_MIE, `CSR_MTVEC, `CSR_MSTATUSH,
            `CSR_MSCRATCH, `CSR_MEPC, `CSR_MCAUSE, `CSR_MTVAL, `CSR_MIP,
            `CSR_MCYCLE, `CSR_MINSTRET, `CSR_MCYCLEH, `CSR_MINSTRETH,
            `CSR_CYCLE, `CSR_TIME, `CSR_INSTRET,
            `CSR_CYCLEH, `CSR_TIMEH, `CSR_INSTRETH,
            `CSR_MVENDORID, `CSR_MARCHID, `CSR_MIMPID, `CSR_MHARTID:
                chk_illegal = chk_write && (chk_addr[11:10] == 2'b11);
            default:
                chk_illegal = 1'b1;
        endcase
    end

    // =========================================================================
    // Read (EX)
    // =========================================================================
    always @(*) begin
        case (addr)
            `CSR_MSTATUS:   rdata = mstatus_value;
            `CSR_MISA:      rdata = MISA_VALUE;
            `CSR_MIE:       rdata = mie_value;
            `CSR_MTVEC:     rdata = {mtvec_base, 1'b0, mtvec_vectored};
            `CSR_MSCRATCH:  rdata = mscratch;
            `CSR_MEPC:      rdata = mepc;
            `CSR_MCAUSE:    rdata = {mcause_irq, 27'd0, mcause_code};
            `CSR_MTVAL:     rdata = mtval;
            `CSR_MIP:       rdata = mip_value;
            `CSR_MCYCLE,
            `CSR_CYCLE:     rdata = mcycle[31:0];
            `CSR_MCYCLEH,
            `CSR_CYCLEH:    rdata = mcycle[63:32];
            `CSR_MINSTRET,
            `CSR_INSTRET:   rdata = minstret[31:0];
            `CSR_MINSTRETH,
            `CSR_INSTRETH:  rdata = minstret[63:32];
            `CSR_TIME:      rdata = mtime[31:0];
            `CSR_TIMEH:     rdata = mtime[63:32];
            `CSR_MHARTID:   rdata = HART_ID;
            default:        rdata = 32'd0;  // mstatush, other IDs, unreachable
        endcase
    end

    reg [31:0] wdata;
    always @(*) begin
        case (op)
            `CSR_OP_RS: wdata = rdata | operand;
            `CSR_OP_RC: wdata = rdata & ~operand;
            default:    wdata = operand;
        endcase
    end

    // =========================================================================
    // Interrupt arbitration
    // =========================================================================
    // Fixed priority from the privileged spec: external > software > timer.
    wire pend_ext   = irq_ext   && mie_meie;
    wire pend_soft  = irq_soft  && mie_msie;
    wire pend_timer = irq_timer && mie_mtie;

    assign irq_pending = mstatus_mie && (pend_ext || pend_soft || pend_timer);

    always @(*) begin
        if (pend_ext)       irq_code = `IRQ_M_EXT;
        else if (pend_soft) irq_code = `IRQ_M_SOFT;
        else                irq_code = `IRQ_M_TIMER;
    end

    // Vectored mode sends interrupt N to BASE + 4*N; exceptions always use BASE.
    assign exc_vector = {mtvec_base, 2'b00};
    assign irq_vector = mtvec_vectored ? {mtvec_base + {26'd0, irq_code}, 2'b00}
                                       : {mtvec_base, 2'b00};

    // =========================================================================
    // Update
    // =========================================================================
    // trap, mret and we are mutually exclusive (cpu_top only asserts one of
    // them per cycle). Only mstatus, mepc, mcause and mtval are written by a
    // trap or mret, so only they sit behind the trap/mret priority chain. The
    // other CSRs take instruction writes straight from we: the trap decision
    // comes off the branch compare at the end of EX, and putting it in front
    // of every write enable made it the critical path.
    //
    // The counters run underneath; an explicit write to one of them comes
    // later in the block and wins.
    always @(posedge clk) begin
        if (!rst_n) begin
            mstatus_mie    <= 1'b0;
            mstatus_mpie   <= 1'b0;
            mie_msie       <= 1'b0;
            mie_mtie       <= 1'b0;
            mie_meie       <= 1'b0;
            mtvec_base     <= 30'd0;
            mtvec_vectored <= 1'b0;
            mscratch       <= 32'd0;
            mepc_word      <= 30'd0;
            mcause_irq     <= 1'b0;
            mcause_code    <= 4'd0;
            mtval          <= 32'd0;
            mcycle         <= 64'd0;
            minstret       <= 64'd0;
        end else begin
            mcycle <= mcycle + 64'd1;
            if (instret)
                minstret <= minstret + 64'd1;

            if (trap) begin
                mepc_word    <= trap_pc[31:2];
                mcause_irq   <= trap_irq;
                mcause_code  <= trap_code;
                mtval        <= trap_val;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (mret) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (we) begin
                case (addr)
                    `CSR_MSTATUS: begin
                        mstatus_mie  <= wdata[3];
                        mstatus_mpie <= wdata[7];
                    end
                    `CSR_MEPC:      mepc_word       <= wdata[31:2];
                    `CSR_MCAUSE: begin
                        mcause_irq  <= wdata[31];
                        mcause_code <= wdata[3:0];
                    end
                    `CSR_MTVAL:     mtval           <= wdata;
                    default: ;
                endcase
            end

            if (we) begin
                case (addr)
                    `CSR_MIE: begin
                        mie_msie <= wdata[3];
                        mie_mtie <= wdata[7];
                        mie_meie <= wdata[11];
                    end
                    `CSR_MTVEC: begin
                        mtvec_base     <= wdata[31:2];
                        mtvec_vectored <= (wdata[1:0] == 2'b01);
                    end
                    `CSR_MSCRATCH:  mscratch        <= wdata;
                    `CSR_MCYCLE:    mcycle[31:0]    <= wdata;
                    `CSR_MCYCLEH:   mcycle[63:32]   <= wdata;
                    `CSR_MINSTRET:  minstret[31:0]  <= wdata;
                    `CSR_MINSTRETH: minstret[63:32] <= wdata;
                    default: ;  // misa, mip, mstatush: writes ignored; the rest are above
                endcase
            end
        end
    end

endmodule
