`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cpu_top
// Project Name: RISC-V RV32IM CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Description: The CPU as the rest of the board sees it: one hart (rv_core.v)
//              plus the memories and devices it reaches over its buses.
//
//   0x0000_0000 - 0x0000_7FFF  instruction ROM (fetch on port A, .rodata on B)
//   0x0001_0000 - 0x0001_7FFF  data RAM
//   0x8000_0010 - 0x8000_001C  UART
//   0x8000_0100 - 0x8000_011F  machine timer (hart 0's block, see timer.v)
//   anything else              mem_* port (board_io in fpga_top.v)
//
// The hart's data bus protocol is described in rv_core.v. Every slave here
// answers a load exactly one cycle after accepting it, so the bus accepts
// every request at once (dbus_gnt = 1) and dbus_rvalid is that request
// delayed by a cycle. The hart holds the address and funct3 through the load's
// data cycle, and the slaves use them there: data_memory sizes the word with
// funct3, and the read select below is registered from the address.
//
// Dependencies: riscv_defines.vh, rv_core.v, instruction_memory.v,
//               data_memory.v, uart_tx.v, uart_rx.v, timer.v
//////////////////////////////////////////////////////////////////////////////////

`include "riscv_defines.vh"

module cpu_top #(
    parameter INIT_FILE = "",
    parameter integer TIMER_DIV = 50,   // clocks per mtime tick (50 MHz -> 1 us)
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

    // Debug ports
    output wire [31:0] debug_pc,
    output wire [31:0] debug_x1
);

    // =========================================================================
    // Hart
    // =========================================================================
    wire [31:0] ibus_addr;
    wire        ibus_ce;
    wire [31:0] ibus_rdata;
    wire        ibus_valid;

    wire        dbus_req;
    wire        dbus_we;
    wire [31:0] dbus_addr;
    wire [31:0] dbus_wdata;
    wire [2:0]  dbus_funct3;
    wire        dbus_gnt;
    wire        dbus_rvalid;
    wire [31:0] dbus_rdata;

    wire        uart_rx_ready;
    wire [63:0] mtime;
    wire        irq_timer, irq_soft;

    rv_core #(
        .HART_ID (0)
    ) core0 (
        .clk         (clk),
        .rst_n       (rst_n),
        .ibus_addr   (ibus_addr),
        .ibus_ce     (ibus_ce),
        .ibus_rdata  (ibus_rdata),
        .ibus_valid  (ibus_valid),
        .dbus_req    (dbus_req),
        .dbus_we     (dbus_we),
        .dbus_addr   (dbus_addr),
        .dbus_wdata  (dbus_wdata),
        .dbus_funct3 (dbus_funct3),
        .dbus_gnt    (dbus_gnt),
        .dbus_rvalid (dbus_rvalid),
        .dbus_rdata  (dbus_rdata),
        // The machine external interrupt is the UART receiver: it is pending
        // while a received byte is waiting, and reading UART RX data clears it.
        .irq_ext     (uart_rx_ready),
        .irq_timer   (irq_timer),
        .irq_soft    (irq_soft),
        .mtime       (mtime),
        .debug_pc    (debug_pc),
        .debug_x1    (debug_x1)
    );

    // =========================================================================
    // Data bus handshake
    // =========================================================================
    // A single master and fixed-latency slaves: accept at once, answer loads
    // one cycle later.
    //
    // BUS_STRESS (testbenches only) instead accepts requests and releases load
    // data on pseudo-random cycles. That works with the slaves as they are:
    // they read every cycle while rd_active holds, and the hart keeps the
    // address steady, so the data is still right whenever it is let through.
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

    assign dbus_gnt = gnt_ok;

    wire bus_wr = dbus_req && dbus_gnt &&  dbus_we;
    wire bus_rd = dbus_req && dbus_gnt && !dbus_we;

    // A load is outstanding from the cycle after it is accepted until its data
    // is handed over.
    reg rd_outstanding;
    always @(posedge clk) begin
        if (!rst_n)           rd_outstanding <= 1'b0;
        else if (bus_rd)      rd_outstanding <= 1'b1;
        else if (dbus_rvalid) rd_outstanding <= 1'b0;
    end

    assign dbus_rvalid = rd_outstanding && rsp_ok;
    wire   rd_active   = bus_rd || rd_outstanding;

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
    //       0x8000_0100 - 0x8000_011F = machine timer (see timer.v)
    wire mmio_timer_sel;
    wire mmio_sel              = mmio_uart_tx_sel || mmio_uart_stat_sel ||
                                 mmio_uart_rx_sel || mmio_uart_rx_stat_sel ||
                                 mmio_timer_sel;

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
    reg [1:0] ld_offset_q;

    always @(posedge clk) begin
        ld_dmem_q         <= dmem_sel;
        ld_imem_q         <= imem_sel;
        ld_uart_stat_q    <= mmio_uart_stat_sel;
        ld_uart_rx_q      <= mmio_uart_rx_sel;
        ld_uart_rx_stat_q <= mmio_uart_rx_stat_sel;
        ld_timer_q        <= mmio_timer_sel;
        ld_offset_q       <= dbus_addr[1:0];
    end

    // The hart never puts a trapping load or store on the bus, so everything
    // below can act on bus_wr / bus_rd as they are.
    assign mem_addr       = dbus_addr;
    assign mem_write_data = dbus_wdata;
    assign mem_write_en   = bus_wr && !dmem_sel && !mmio_sel;
    assign mem_read_en    = rd_active && !dmem_sel && !mmio_sel;

    // =========================================================================
    // UART TX MMIO
    // =========================================================================
    wire uart_busy;
    // tx_start fires for one clock when the CPU stores to the UART TX address
    wire uart_start = bus_wr && mmio_uart_tx_sel;

    uart_tx uart_tx_inst (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (dbus_wdata[7:0]),
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
    // Machine timer MMIO
    // =========================================================================
    wire [31:0] timer_read_data;

    timer #(
        .DIV       (TIMER_DIV),
        .NUM_HARTS (1)
    ) timer_inst (
        .clk        (clk),
        .rst_n      (rst_n),
        .addr       (dbus_addr),
        .write_data (dbus_wdata),
        .write_en   (bus_wr && mmio_timer_sel),
        .sel        (mmio_timer_sel),
        .read_data  (timer_read_data),
        .mtime      (mtime),
        .irq_timer  (irq_timer),
        .irq_soft   (irq_soft)
    );

    // =========================================================================
    // Memories
    // =========================================================================

    // Instruction ROM. Port A fetches for the hart, port B reads .rodata.
    wire [31:0] rom_data_read;

    instruction_memory #(
        .INIT_FILE (INIT_FILE)
    ) imem (
        .clk        (clk),
        .ce         (ibus_ce),
        .addr       (ibus_addr),
        .dout       (ibus_rdata),
        .dout_valid (ibus_valid),
        .addr_b     (dbus_addr),
        .dout_b     (rom_data_read)
    );

    // Data RAM
    wire [31:0] internal_mem_read_data;

    data_memory dmem (
        .clk        (clk),
        .addr       (dbus_addr),
        .write_data (dbus_wdata),
        .write_en   (bus_wr && dmem_sel),
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
        if (ld_dmem_q) begin
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
        end else begin
            selected_mem_data = mem_read_data;
        end
    end

    assign dbus_rdata = selected_mem_data;

endmodule
