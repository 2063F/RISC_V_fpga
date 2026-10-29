`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cpu_top
// Project Name: RISC-V RV32IM CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Description: The CPU as the rest of the board sees it: one or two harts
//              (rv_core.v) plus the memories and devices they reach over a
//              shared data bus.
//
//   0x0000_0000 - 0x0000_7FFF  instruction ROM (see "Second hart" below)
//   0x0001_0000 - 0x0001_7FFF  data RAM
//   0x8000_0010 - 0x8000_001C  UART
//   0x8000_0100 - 0x8000_013F  machine timer, 0x20 bytes per hart (timer.v)
//   0x8000_0200                hart run control (see "Second hart" below)
//   anything else              mem_* port (board_io in fpga_top.v)
//
// Data bus
// --------
// The harts' bus protocol is described in rv_core.v. Every slave here answers
// a load exactly one cycle after accepting it, and reads its address and
// funct3 again in that data cycle (data_memory sizes the word with funct3, and
// the read select below is registered from the address). So the bus is shared
// by holding it for the whole of a load: one request is accepted per cycle,
// none while a load is waiting for its data, and the address mux stays on the
// load's owner until the data has been handed over. A store takes one cycle,
// a load two, whichever hart issues it.
//
// When both harts ask in the same cycle, the one that did not win last time
// goes first (round robin), so neither can starve the other.
//
// With no other memory traffic in between, two requests from different harts
// are performed in the order the bus accepts them, and each hart's own
// accesses in program order: memory is sequentially consistent, so FENCE has
// nothing to do.
//
// Second hart
// -----------
// The ROM has two ports. Port A always fetches for hart 0; port B reads
// .rodata for both harts at first, and is handed to hart 1 as its fetch port
// when hart 1 starts. Hart 1 is held in reset until hart 0 sets bit 1 of the
// run control register at 0x8000_0200 (bit 0, hart 0, always reads 1), and is
// put back in reset if the bit is cleared again.
//
// While hart 1 runs, data loads from the ROM read as 0. A program that starts
// hart 1 must therefore not keep constants in the ROM: tools/link_mp.ld puts
// .rodata in RAM, and tools/crt0.S copies it there, from the ROM, before main
// runs - that is, before hart 1 can have been started. A program that never
// starts hart 1 sees no difference from a single-hart CPU.
//
// Dependencies: riscv_defines.vh, rv_core.v, instruction_memory.v,
//               data_memory.v, uart_tx.v, uart_rx.v, timer.v
//////////////////////////////////////////////////////////////////////////////////

`include "riscv_defines.vh"

module cpu_top #(
    parameter INIT_FILE = "",
    parameter integer TIMER_DIV = 50,   // clocks per mtime tick (50 MHz -> 1 us)
    parameter integer NUM_HARTS = 1,    // 1 or 2
    parameter integer BUS_STRESS = 0    // simulation only: random bus wait states
) (
    input  wire        clk,
    input  wire        rst_n,

    // External Memory / IO interface
    output wire [31:0] mem_addr,
    output wire [31:0] mem_write_data,
    output wire        mem_write_en,
    output wire        mem_read_en,
    input  wire [31:0] mem_read_data,

    // UART
    output wire        uart_tx_pin,
    input  wire        uart_rx_pin,

    // Debug ports (hart 0)
    output wire [31:0] debug_pc,
    output wire [31:0] debug_x1
);

    localparam integer HARTS = (NUM_HARTS > 1) ? 2 : 1;

    // =========================================================================
    // Harts
    // =========================================================================
    // Hart 0's fetch port
    wire [31:0] ibus0_addr;
    wire        ibus0_ce;
    wire [31:0] ibus0_rdata;
    wire        ibus0_valid;

    // Each hart's side of the data bus
    wire        dbus0_req,    dbus1_req;
    wire        dbus0_we,     dbus1_we;
    wire [31:0] dbus0_addr,   dbus1_addr;
    wire [31:0] dbus0_wdata,  dbus1_wdata;
    wire [2:0]  dbus0_funct3, dbus1_funct3;
    wire        dbus0_amo,    dbus1_amo;
    wire [4:0]  dbus0_amo_op, dbus1_amo_op;
    wire        dbus0_gnt,    dbus1_gnt;
    wire        dbus0_rvalid, dbus1_rvalid;

    // The shared bus, as the slaves see it
    wire        dbus_we;
    wire [31:0] dbus_addr;
    wire [31:0] dbus_wdata;
    wire [2:0]  dbus_funct3;
    wire        dbus_rvalid;
    wire [31:0] dbus_rdata;

    wire              uart_rx_ready;
    wire [63:0]       mtime;
    wire [HARTS-1:0]  irq_timer, irq_soft;

    rv_core #(
        .HART_ID (0)
    ) core0 (
        .clk         (clk),
        .rst_n       (rst_n),
        .ibus_addr   (ibus0_addr),
        .ibus_ce     (ibus0_ce),
        .ibus_rdata  (ibus0_rdata),
        .ibus_valid  (ibus0_valid),
        .dbus_req    (dbus0_req),
        .dbus_we     (dbus0_we),
        .dbus_addr   (dbus0_addr),
        .dbus_wdata  (dbus0_wdata),
        .dbus_funct3 (dbus0_funct3),
        .dbus_amo    (dbus0_amo),
        .dbus_amo_op (dbus0_amo_op),
        .dbus_gnt    (dbus0_gnt),
        .dbus_rvalid (dbus0_rvalid),
        .dbus_rdata  (dbus_rdata),
        // The machine external interrupt is the UART receiver: it is pending
        // while a received byte is waiting, and reading UART RX data clears it.
        // It goes to hart 0 only.
        .irq_ext     (uart_rx_ready),
        .irq_timer   (irq_timer[0]),
        .irq_soft    (irq_soft[0]),
        .mtime       (mtime),
        .debug_pc    (debug_pc),
        .debug_x1    (debug_x1)
    );

    // Run control: hart 1 is held in reset while hart1_run is 0.
    reg  hart1_run;
    wire [31:0] rom_b_dout;
    wire        rom_b_valid;
    wire [31:0] ibus1_addr;
    wire        ibus1_ce;

    generate
        if (HARTS > 1) begin : g_hart1
            rv_core #(
                .HART_ID (1)
            ) core1 (
                .clk         (clk),
                .rst_n       (rst_n && hart1_run),
                .ibus_addr   (ibus1_addr),
                .ibus_ce     (ibus1_ce),
                .ibus_rdata  (rom_b_dout),
                .ibus_valid  (rom_b_valid),
                .dbus_req    (dbus1_req),
                .dbus_we     (dbus1_we),
                .dbus_addr   (dbus1_addr),
                .dbus_wdata  (dbus1_wdata),
                .dbus_funct3 (dbus1_funct3),
                .dbus_amo    (dbus1_amo),
                .dbus_amo_op (dbus1_amo_op),
                .dbus_gnt    (dbus1_gnt),
                .dbus_rvalid (dbus1_rvalid),
                .dbus_rdata  (dbus_rdata),
                .irq_ext     (1'b0),
                .irq_timer   (irq_timer[HARTS-1]),
                .irq_soft    (irq_soft[HARTS-1]),
                .mtime       (mtime),
                .debug_pc    (),
                .debug_x1    ()
            );
        end else begin : g_no_hart1
            assign ibus1_addr   = 32'd0;
            assign ibus1_ce     = 1'b1;
            assign dbus1_req    = 1'b0;
            assign dbus1_we     = 1'b0;
            assign dbus1_addr   = 32'd0;
            assign dbus1_wdata  = 32'd0;
            assign dbus1_funct3 = 3'd0;
            assign dbus1_amo    = 1'b0;
            assign dbus1_amo_op = 5'd0;
        end
    endgenerate

    // =========================================================================
    // Data bus arbitration and handshake
    // =========================================================================
    // BUS_STRESS (testbenches only) accepts requests and releases load data on
    // pseudo-random cycles on top of the arbitration. That works with the
    // slaves as they are: they read every cycle while rd_active holds, and the
    // owner keeps the address steady, so the data is still right whenever it
    // is let through.
    wire gnt_ok, rsp_ok;

    generate
        if (BUS_STRESS != 0) begin : g_stress
            reg [15:0] lfsr;
            always @(posedge clk) begin
                if (!rst_n) lfsr <= 16'hACE1;
                else        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            end
            assign gnt_ok = lfsr[0];
            assign rsp_ok = lfsr[3];
        end else begin : g_direct
            assign gnt_ok = 1'b1;
            assign rsp_ok = 1'b1;
        end
    endgenerate

    // A load is outstanding from the cycle after it is accepted until its data
    // is handed over; rd_owner1 says whose it is. Nothing else is accepted
    // meanwhile.
    reg rd_outstanding;
    reg rd_owner1;
    reg last_win1;      // the last accepted request was hart 1's

    // Hart 1 wins when it asks alone, or when both ask and it is its turn.
    wire win1     = dbus1_req && (!dbus0_req || !last_win1);
    wire bus_free = !rd_outstanding && gnt_ok;

    // The grants need not include the hart's own request: a hart only looks
    // at its grant while it is asking.
    assign dbus0_gnt = bus_free && !win1;
    assign dbus1_gnt = bus_free &&  win1;

    // While a load waits for its data the mux stays on its owner.
    wire sel1 = rd_outstanding ? rd_owner1 : win1;

    wire dbus_req    = (dbus0_req || dbus1_req) && bus_free;  // accepted this cycle
    assign dbus_we     = sel1 ? dbus1_we     : dbus0_we;
    assign dbus_addr   = sel1 ? dbus1_addr   : dbus0_addr;
    assign dbus_wdata  = sel1 ? dbus1_wdata  : dbus0_wdata;
    assign dbus_funct3 = sel1 ? dbus1_funct3 : dbus0_funct3;
    wire        dbus_amo    = sel1 ? dbus1_amo    : dbus0_amo;
    wire [4:0]  dbus_amo_op = sel1 ? dbus1_amo_op : dbus0_amo_op;

    wire bus_wr = dbus_req &&  dbus_we;
    wire bus_rd = dbus_req && !dbus_we;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_outstanding <= 1'b0;
            rd_owner1      <= 1'b0;
            last_win1      <= 1'b0;
        end else begin
            if (bus_rd)           rd_outstanding <= 1'b1;
            else if (dbus_rvalid) rd_outstanding <= 1'b0;

            if (bus_rd)   rd_owner1 <= win1;
            if (dbus_req) last_win1 <= win1;
        end
    end

    // An SC or AMO answers once its read-modify-write has got to the write.
    reg [1:0] rmw_step;

    assign dbus_rvalid  = rd_outstanding && rsp_ok && (rmw_step == 2'd0 || rmw_step[1]);
    assign dbus0_rvalid = dbus_rvalid && !rd_owner1;
    assign dbus1_rvalid = dbus_rvalid &&  rd_owner1;
    wire   rd_active    = bus_rd || rd_outstanding;

    // =========================================================================
    // Atomics (LR.W / SC.W / AMO*.W)
    // =========================================================================
    // An atomic request is accepted like a load and holds the bus like one, so
    // nothing else reaches any slave until it has been answered. LR is a plain
    // load that also sets the hart's reservation. SC and the AMOs take two
    // more steps, so that no step has to fit a memory read, an operation and a
    // memory write into one cycle:
    //
    //   accept   : the read is issued; for SC, whether the reservation holds
    //              is registered (sc_ok)
    //   step 1   : the old word arrives and is registered (rmw_old)
    //   step 2   : the new word is written - for SC only if sc_ok - and the
    //              answer may go back from here on
    //   step 3   : written; waiting for the answer to be let through
    //
    // The answer is the old word, or for SC 0 (stored) / 1 (failed).
    //
    // A reservation covers one word. It is lost when the other hart writes
    // that word, and when the hart's own SC runs, whether or not it stores.
    wire is_lr   = dbus_amo && (dbus_amo_op == `AMO_LR);
    wire is_sc   = dbus_amo && (dbus_amo_op == `AMO_SC);
    wire rmw_acc = bus_rd && dbus_amo && !is_lr;

    reg  [31:0] rmw_old;
    reg         sc_ok;

    always @(posedge clk) begin
        if (!rst_n)           rmw_step <= 2'd0;
        else if (rmw_acc)     rmw_step <= 2'd1;
        else if (dbus_rvalid) rmw_step <= 2'd0;
        else if (rmw_step == 2'd1) rmw_step <= 2'd2;
        else if (rmw_step == 2'd2) rmw_step <= 2'd3;
    end

    reg  [31:0] rmw_new;
    always @(*) begin
        case (dbus_amo_op)
            `AMO_ADD:  rmw_new = rmw_old + dbus_wdata;
            `AMO_XOR:  rmw_new = rmw_old ^ dbus_wdata;
            `AMO_OR:   rmw_new = rmw_old | dbus_wdata;
            `AMO_AND:  rmw_new = rmw_old & dbus_wdata;
            `AMO_MIN:  rmw_new = ($signed(rmw_old) < $signed(dbus_wdata)) ? rmw_old : dbus_wdata;
            `AMO_MAX:  rmw_new = ($signed(rmw_old) < $signed(dbus_wdata)) ? dbus_wdata : rmw_old;
            `AMO_MINU: rmw_new = (rmw_old < dbus_wdata) ? rmw_old : dbus_wdata;
            `AMO_MAXU: rmw_new = (rmw_old < dbus_wdata) ? dbus_wdata : rmw_old;
            default:   rmw_new = dbus_wdata;            // SWAP, SC
        endcase
    end

    wire rmw_wr = (rmw_step == 2'd2) && (!is_sc || sc_ok);

    // Every write a slave sees: an accepted store, or the write step of an
    // SC / AMO. The address is the bus address either way.
    wire        wr_en   = bus_wr || rmw_wr;
    wire [31:0] wr_data = rmw_step[1] ? rmw_new : dbus_wdata;

    // Reservations, one per hart
    reg         res0_valid, res1_valid;
    reg  [29:0] res0_addr,  res1_addr;
    wire        res0_hit = res0_valid && (res0_addr == dbus_addr[31:2]);
    wire        res1_hit = res1_valid && (res1_addr == dbus_addr[31:2]);

    always @(posedge clk) begin
        if (rmw_acc)
            sc_ok <= sel1 ? res1_hit : res0_hit;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            res0_valid <= 1'b0;
            res1_valid <= 1'b0;
        end else begin
            // A write by one hart breaks the other's reservation on that word.
            if (wr_en &&  sel1 && res0_hit) res0_valid <= 1'b0;
            if (wr_en && !sel1 && res1_hit) res1_valid <= 1'b0;

            if (bus_rd && is_lr) begin
                if (sel1) begin
                    res1_valid <= 1'b1;
                    res1_addr  <= dbus_addr[31:2];
                end else begin
                    res0_valid <= 1'b1;
                    res0_addr  <= dbus_addr[31:2];
                end
            end

            if (rmw_acc && is_sc) begin
                if (sel1) res1_valid <= 1'b0;
                else      res0_valid <= 1'b0;
            end

            if (!hart1_run)
                res1_valid <= 1'b0;
        end
    end

    // =========================================================================
    // Memory Interface / Address Decoding Outputs
    // =========================================================================
    // The data RAM is 32 KB (0x0001_0000 - 0x0001_7FFF). The decode still
    // claims the whole 64 KB window, so 0x0001_8000 - 0x0001_FFFF aliases it.
    wire imem_sel = (dbus_addr < 32'h0000_8000);
    wire dmem_sel = (dbus_addr >= 32'h0001_0000) && (dbus_addr <= 32'h0001_FFFF);
    // MMIO: 0x8000_0010 = UART TX data register
    //       0x8000_0014 = UART TX status register (bit0 = busy)
    //       0x8000_0018 = UART RX data register
    //       0x8000_001C = UART RX status register (bit0 = ready)
    wire mmio_uart_tx_sel      = (dbus_addr == 32'h8000_0010);
    wire mmio_uart_stat_sel    = (dbus_addr == 32'h8000_0014);
    wire mmio_uart_rx_sel      = (dbus_addr == 32'h8000_0018);
    wire mmio_uart_rx_stat_sel = (dbus_addr == 32'h8000_001C);
    //       0x8000_0100 - 0x8000_013F = machine timer (see timer.v)
    wire mmio_timer_sel;
    //       0x8000_0200 = hart run control
    wire mmio_hartctl_sel      = (dbus_addr == 32'h8000_0200);
    wire mmio_sel              = mmio_uart_tx_sel || mmio_uart_stat_sel ||
                                 mmio_uart_rx_sel || mmio_uart_rx_stat_sel ||
                                 mmio_timer_sel   || mmio_hartctl_sel;

    // Load data is used one cycle after the address is formed (the load's data
    // cycle), and the hart holds the address in between, so the address decode
    // can be registered in the first cycle and the load-data mux driven from
    // the registers. That takes the ALU adder and the 32-bit address compares
    // off the path into the hart's write-back, which was the critical path of
    // the design. Nothing reads selected_mem_data in a load's first cycle (the
    // write-back waits for dbus_rvalid), so these can simply register every
    // cycle.
    reg       ld_dmem_q, ld_imem_q;
    reg       ld_uart_stat_q, ld_uart_rx_q, ld_uart_rx_stat_q, ld_timer_q;
    reg       ld_hartctl_q;
    reg [1:0] ld_offset_q;

    always @(posedge clk) begin
        ld_dmem_q         <= dmem_sel;
        ld_imem_q         <= imem_sel;
        ld_uart_stat_q    <= mmio_uart_stat_sel;
        ld_uart_rx_q      <= mmio_uart_rx_sel;
        ld_uart_rx_stat_q <= mmio_uart_rx_stat_sel;
        ld_timer_q        <= mmio_timer_sel;
        ld_hartctl_q      <= mmio_hartctl_sel;
        ld_offset_q       <= dbus_addr[1:0];
    end

    // A hart never puts a trapping load or store on the bus, so everything
    // below can act on wr_en / bus_rd as they are.
    assign mem_addr       = dbus_addr;
    assign mem_write_data = wr_data;
    assign mem_write_en   = wr_en && !dmem_sel && !mmio_sel;
    assign mem_read_en    = rd_active && !dmem_sel && !mmio_sel;

    // =========================================================================
    // UART TX MMIO
    // =========================================================================
    wire uart_busy;
    // tx_start fires for one clock when the CPU stores to the UART TX address
    wire uart_start = wr_en && mmio_uart_tx_sel;

    uart_tx uart_tx_inst (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (wr_data[7:0]),
        .tx_start (uart_start),
        .tx_pin   (uart_tx_pin),
        .tx_busy  (uart_busy)
    );

    // =========================================================================
    // UART RX MMIO
    // =========================================================================
    wire [7:0] uart_rx_data;
    // rx_clear fires once, in the data cycle of the load that reads RX data
    wire uart_rx_clear = dbus_rvalid && ld_uart_rx_q;

    uart_rx uart_rx_inst (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx_pin   (uart_rx_pin),
        .rx_clear (uart_rx_clear),
        .rx_data  (uart_rx_data),
        .rx_ready (uart_rx_ready)
    );

    // =========================================================================
    // Hart run control MMIO
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n)
            hart1_run <= 1'b0;
        else if (wr_en && mmio_hartctl_sel)
            hart1_run <= (HARTS > 1) && wr_data[1];
    end

    // =========================================================================
    // Machine timer MMIO
    // =========================================================================
    wire [31:0] timer_read_data;

    timer #(
        .DIV       (TIMER_DIV),
        .NUM_HARTS (HARTS)
    ) timer_inst (
        .clk        (clk),
        .rst_n      (rst_n),
        .addr       (dbus_addr),
        .write_data (wr_data),
        .write_en   (wr_en && mmio_timer_sel),
        .sel        (mmio_timer_sel),
        .read_data  (timer_read_data),
        .mtime      (mtime),
        .irq_timer  (irq_timer),
        .irq_soft   (irq_soft)
    );

    // =========================================================================
    // Memories
    // =========================================================================

    // Instruction ROM. Port A fetches for hart 0. Port B reads .rodata, or
    // fetches for hart 1 while it runs (see the top of this file).
    instruction_memory #(
        .INIT_FILE (INIT_FILE)
    ) imem (
        .clk          (clk),
        .ce           (ibus0_ce),
        .addr         (ibus0_addr),
        .dout         (ibus0_rdata),
        .dout_valid   (ibus0_valid),
        .ce_b         (hart1_run ? ibus1_ce   : 1'b1),
        .addr_b       (hart1_run ? ibus1_addr : dbus_addr),
        .dout_b       (rom_b_dout),
        .dout_b_valid (rom_b_valid)
    );

    wire [31:0] rom_data_read = (rom_b_valid && !hart1_run) ? rom_b_dout : 32'd0;

    // Data RAM
    wire [31:0] internal_mem_read_data;

    data_memory dmem (
        .clk        (clk),
        .addr       (dbus_addr),
        .write_data (wr_data),
        .write_en   (wr_en && dmem_sel),
        .read_en    (rd_active && dmem_sel),
        .funct3     (dbus_funct3),
        .read_data  (internal_mem_read_data)
    );

    // =========================================================================
    // Load data select
    // =========================================================================

    // Registered address decode, see above
    reg  [31:0] selected_mem_data;
    wire [1:0]  mem_byte_offset = ld_offset_q;

    always @(*) begin
        if (rmw_step[1]) begin
            selected_mem_data = rmw_old;            // SC / AMO answer
        end else if (ld_dmem_q) begin
            selected_mem_data = internal_mem_read_data;
        end else if (ld_imem_q) begin
            // Byte/halfword selection for .rodata loads (LBU, LB, LHU, LH, LW)
            case (dbus_funct3)
                3'b000: begin // LB - signed byte
                    case (mem_byte_offset)
                        2'b00: selected_mem_data = {{24{rom_data_read[7]}},  rom_data_read[7:0]};
                        2'b01: selected_mem_data = {{24{rom_data_read[15]}}, rom_data_read[15:8]};
                        2'b10: selected_mem_data = {{24{rom_data_read[23]}}, rom_data_read[23:16]};
                        2'b11: selected_mem_data = {{24{rom_data_read[31]}}, rom_data_read[31:24]};
                    endcase
                end
                3'b100: begin // LBU - unsigned byte
                    case (mem_byte_offset)
                        2'b00: selected_mem_data = {24'd0, rom_data_read[7:0]};
                        2'b01: selected_mem_data = {24'd0, rom_data_read[15:8]};
                        2'b10: selected_mem_data = {24'd0, rom_data_read[23:16]};
                        2'b11: selected_mem_data = {24'd0, rom_data_read[31:24]};
                    endcase
                end
                3'b001: begin // LH - signed halfword
                    if (mem_byte_offset[1] == 1'b0)
                        selected_mem_data = {{16{rom_data_read[15]}}, rom_data_read[15:0]};
                    else
                        selected_mem_data = {{16{rom_data_read[31]}}, rom_data_read[31:16]};
                end
                3'b101: begin // LHU - unsigned halfword
                    if (mem_byte_offset[1] == 1'b0)
                        selected_mem_data = {16'd0, rom_data_read[15:0]};
                    else
                        selected_mem_data = {16'd0, rom_data_read[31:16]};
                end
                default: selected_mem_data = rom_data_read; // LW
            endcase
        end else if (ld_uart_stat_q) begin
            selected_mem_data = {31'd0, uart_busy};
        end else if (ld_uart_rx_q) begin
            selected_mem_data = {24'd0, uart_rx_data};
        end else if (ld_uart_rx_stat_q) begin
            selected_mem_data = {31'd0, uart_rx_ready};
        end else if (ld_timer_q) begin
            selected_mem_data = timer_read_data;
        end else if (ld_hartctl_q) begin
            selected_mem_data = {30'd0, hart1_run, 1'b1};
        end else begin
            selected_mem_data = mem_read_data;
        end
    end

    assign dbus_rdata = selected_mem_data;

    // SC / AMO step 1: keep the old word (the AMO's operand and answer), or
    // for SC the answer itself.
    always @(posedge clk) begin
        if (rmw_step == 2'd1)
            rmw_old <= is_sc ? {31'd0, !sc_ok} : selected_mem_data;
    end

endmodule
