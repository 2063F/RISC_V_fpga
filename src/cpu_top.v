`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cpu_top
// Project Name: RISC-V RV32IM CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Description: Top level CPU: a three-stage pipeline.
//
//   IF  fetch   : PC drives the instruction ROM
//   ID  decode  : decode, immediate generation, register file read
//   EX  execute : ALU / multiplier / divider, memory, write-back
//
// Why three stages
// ----------------
// It used to be two, with decode, register read, ALU, memory and write-back all
// in one cycle. That chain - instruction ROM -> register file 32:1 read mux ->
// ALU - was the critical path once the multiply and divide had been moved into
// their own units, and it left only +0.001 ns of slack against the 50 MHz
// constraint. Splitting the register read away from the ALU gives real margin.
//
// The cost is a data hazard: the instruction in ID reads the register file in
// the same cycle the instruction in EX writes it. A single forwarding path from
// the EX write-back value into the ID read covers every case, because only one
// instruction is ever in flight between them.
//
// Branches and jumps resolve in EX, so a taken one discards the two
// instructions behind it.
//
// Dependencies: riscv_defines.vh, instruction_memory.v, instruction_decoder.v,
//               imm_gen.v, register_file.v, control_unit.v, alu.v,
//               multiplier.v, divider.v, data_memory.v, uart_tx.v, uart_rx.v
//////////////////////////////////////////////////////////////////////////////////

`include "riscv_defines.vh"

module cpu_top #(
    parameter INIT_FILE = ""
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

    localparam [31:0] NOP_INST = 32'h0000_0013;

    // =========================================================================
    // Stage 1: Instruction Fetch
    // =========================================================================
    reg  [31:0] pc;
    wire [31:0] next_pc;

    wire [31:0] fetched_inst;
    wire        fetched_valid;
    wire [31:0] rom_data_read;

    // IF/ID. The ROM's port-A output register holds the instruction itself, so
    // only the PC and the valid bit need registers here.
    reg  [31:0] ifid_pc;
    reg         ifid_valid;

    // One mux on the fetch path, not two: both selects are register outputs, so
    // combining them costs no extra logic on the data path itself.
    wire        id_inst_valid = ifid_valid && fetched_valid;
    wire [31:0] id_inst       = id_inst_valid ? fetched_inst : NOP_INST;

    // =========================================================================
    // Stage 2: Decode and Register Read
    // =========================================================================
    wire [4:0]  id_rs1, id_rs2, id_rd;
    wire        id_reg_write;
    wire [2:0]  id_imm_type;
    wire [4:0]  id_alu_op;
    wire        id_alu_src_b;
    wire        id_branch, id_jump;
    wire        id_mem_read, id_mem_write;
    wire [1:0]  id_wb_sel;
    wire [31:0] id_imm;

    wire [31:0] rf_rd1, rf_rd2;

    // =========================================================================
    // ID/EX pipeline register
    // =========================================================================
    reg  [31:0] ex_pc;
    reg  [31:0] ex_rs1_data, ex_rs2_data;
    reg  [31:0] ex_imm;
    reg  [4:0]  ex_rd;
    reg  [4:0]  ex_alu_op;
    reg         ex_reg_write;
    reg         ex_alu_src_b;
    reg         ex_branch, ex_jump;
    reg         ex_mem_read, ex_mem_write;
    reg  [1:0]  ex_wb_sel;
    reg  [2:0]  ex_funct3;
    reg  [6:0]  ex_opcode;
    reg         ex_valid;

    // Stall bookkeeping
    reg         load_pending;    // 1 during the second (data) cycle of a load
    reg         mcycle_started;  // 1 once the multiplier/divider has this instruction

    // =========================================================================
    // Stage 3: Execute / Memory / Write-back
    // =========================================================================
    wire        alu_src_a;
    wire [1:0]  pc_sel;
    reg  [31:0] alu_in_a, alu_in_b;
    wire [31:0] alu_result;
    wire        alu_zero;
    reg  [31:0] reg_write_data;
    reg  [31:0] next_pc_temp;

    wire [31:0] mul_result;
    wire        mul_done;
    wire [31:0] div_result;
    wire        div_done;

    wire branch_or_jump = ex_valid && (pc_sel != 2'd0);

    // =========================================================================
    // Load stall
    // =========================================================================
    // Both memories have a registered read port (required to map them onto
    // BSRAM - see data_memory.v), so load data is one cycle late. Freeze the
    // pipeline for one cycle and write back in the second cycle. Address,
    // funct3 and the register operands all stay put while frozen, so the
    // memory's combinational sizing/extension logic still sees the load's own
    // controls when the data word arrives.
    wire load_stall = ex_valid && ex_mem_read && !load_pending;

    // =========================================================================
    // RV32M stall (multiply and divide)
    // =========================================================================
    // Both used to be combinational inside the ALU and both took a turn as the
    // critical path of the whole design: the divider held it to 5.031 MHz, and
    // once that moved out the 32x32->64 multiply carry chain held it to
    // 39.377 MHz - against a 50 MHz constraint in both cases. They now run on
    // multiplier.v (3 cycles) and divider.v (34 cycles, or 2 for divide-by-zero
    // and the MIN_INT/-1 overflow) with the pipeline stalled meanwhile.
    //
    // mcycle_started mirrors load_pending: it keeps the start signal a
    // single-cycle pulse even though the instruction sits in EX for the whole
    // operation, and clears as soon as the instruction retires.
    wire is_mul = (ex_alu_op == `ALU_MUL)    || (ex_alu_op == `ALU_MULH) ||
                  (ex_alu_op == `ALU_MULHSU) || (ex_alu_op == `ALU_MULHU);
    wire is_div = (ex_alu_op == `ALU_DIV)    || (ex_alu_op == `ALU_DIVU) ||
                  (ex_alu_op == `ALU_REM)    || (ex_alu_op == `ALU_REMU);

    wire is_mcycle    = ex_valid && (is_mul || is_div);
    wire mcycle_start = is_mcycle && !mcycle_started;
    wire mcycle_done  = is_div ? div_done : mul_done;
    wire mcycle_stall = is_mcycle && !mcycle_done;

    wire stall     = load_stall || mcycle_stall;
    wire wb_enable = ex_valid && ex_reg_write && !stall;

    // =========================================================================
    // Forwarding: EX write-back -> ID register read
    // =========================================================================
    // The instruction in ID reads the register file in the same cycle the one
    // in EX writes it, so the read would miss by exactly one instruction. Only
    // one instruction is ever in flight between the two stages, so a single
    // forwarding path is enough - no hazard can reach further back, because by
    // then the value is already in the register file.
    //
    // wb_enable already accounts for stalls, so while EX is waiting on the
    // memory, multiplier or divider nothing is forwarded and nothing is latched
    // into ID/EX either.
    wire fwd_rs1 = wb_enable && (ex_rd != 5'd0) && (ex_rd == id_rs1);
    wire fwd_rs2 = wb_enable && (ex_rd != 5'd0) && (ex_rd == id_rs2);

    wire [31:0] id_rs1_data = fwd_rs1 ? reg_write_data : rf_rd1;
    wire [31:0] id_rs2_data = fwd_rs2 ? reg_write_data : rf_rd2;

    // =========================================================================
    // Debug assignment
    // =========================================================================
    assign debug_pc = ex_valid ? (ex_pc + 32'd4) : pc;

    // =========================================================================
    // Memory Interface / Address Decoding Outputs
    // =========================================================================
    // The implemented data RAM is 64 KB, so the valid scratch-memory region is
    // 0x0001_0000 - 0x0001_FFFF.
    wire imem_sel = (alu_result < 32'h0000_8000);
    wire dmem_sel = (alu_result >= 32'h0001_0000) && (alu_result <= 32'h0001_FFFF);
    // MMIO: 0x8000_0010 = UART TX data register
    //       0x8000_0014 = UART TX status register (bit0 = busy)
    //       0x8000_0018 = UART RX data register
    //       0x8000_001C = UART RX status register (bit0 = ready)
    wire mmio_uart_tx_sel      = (alu_result == 32'h8000_0010);
    wire mmio_uart_stat_sel    = (alu_result == 32'h8000_0014);
    wire mmio_uart_rx_sel      = (alu_result == 32'h8000_0018);
    wire mmio_uart_rx_stat_sel = (alu_result == 32'h8000_001C);
    wire mmio_sel              = mmio_uart_tx_sel || mmio_uart_stat_sel ||
                                 mmio_uart_rx_sel || mmio_uart_rx_stat_sel;

    wire ex_store = ex_valid && ex_mem_write;
    wire ex_load  = ex_valid && ex_mem_read;

    assign mem_addr       = alu_result;
    assign mem_write_data = ex_rs2_data;
    assign mem_write_en   = ex_store && !dmem_sel && !mmio_sel;
    assign mem_read_en    = ex_load  && !dmem_sel && !mmio_sel;

    // =========================================================================
    // UART TX MMIO
    // =========================================================================
    wire uart_busy;
    // tx_start fires for one clock when the CPU stores to the UART TX address
    wire uart_start = ex_store && mmio_uart_tx_sel;

    uart_tx uart_tx_inst (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (ex_rs2_data[7:0]),
        .tx_start (uart_start),
        .tx_pin   (uart_tx_pin),
        .tx_busy  (uart_busy)
    );

    // =========================================================================
    // UART RX MMIO
    // =========================================================================
    wire [7:0] uart_rx_data;
    wire       uart_rx_ready;
    // rx_clear fires once, in the data cycle of the load that reads RX data
    wire uart_rx_clear = ex_load && mmio_uart_rx_sel && !stall;

    uart_rx uart_rx_inst (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx_pin   (uart_rx_pin),
        .rx_clear (uart_rx_clear),
        .rx_data  (uart_rx_data),
        .rx_ready (uart_rx_ready)
    );

    // =========================================================================
    // Module Instantiations
    // =========================================================================

    // 1. Instruction Memory / .rodata Dual-Port ROM
    instruction_memory #(
        .INIT_FILE (INIT_FILE)
    ) imem (
        .clk        (clk),
        .ce         (!stall),
        .addr       (pc),
        .dout       (fetched_inst),
        .dout_valid (fetched_valid),
        .addr_b     (alu_result),
        .dout_b     (rom_data_read)
    );

    // 2. Instruction Decoder (ID)
    instruction_decoder dec (
        .inst      (id_inst),
        .rs1       (id_rs1),
        .rs2       (id_rs2),
        .rd        (id_rd),
        .reg_write (id_reg_write),
        .imm_type  (id_imm_type),
        .alu_op    (id_alu_op),
        .alu_src_b (id_alu_src_b),
        .branch    (id_branch),
        .jump      (id_jump),
        .mem_read  (id_mem_read),
        .mem_write (id_mem_write),
        .wb_sel    (id_wb_sel)
    );

    // 3. Immediate Generator (ID)
    imm_gen igen (
        .inst     (id_inst),
        .imm_type (id_imm_type),
        .imm      (id_imm)
    );

    // 4. Register File (read in ID, written from EX)
    register_file regfile (
        .clk    (clk),
        .rst    (!rst_n),
        .rs1    (id_rs1),
        .rd1    (rf_rd1),
        .rs2    (id_rs2),
        .rd2    (rf_rd2),
        .rd     (ex_rd),
        .wd     (reg_write_data),
        .we     (wb_enable),
        .dbg_x1 (debug_x1)
    );

    // 5. Control Unit (EX)
    control_unit ctrl (
        .opcode     (ex_opcode),
        .funct3     (ex_funct3),
        .branch     (ex_branch),
        .jump       (ex_jump),
        .alu_zero   (alu_zero),
        .alu_result (alu_result),
        .alu_src_a  (alu_src_a),
        .pc_sel     (pc_sel)
    );

    // 6. ALU (EX)
    alu alu_inst (
        .a      (alu_in_a),
        .b      (alu_in_b),
        .alu_op (ex_alu_op),
        .result (alu_result),
        .zero   (alu_zero)
    );

    // 6b. Multi-cycle Multiplier (RV32M MUL/MULH/MULHSU/MULHU)
    multiplier mul_unit (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (mcycle_start && is_mul),
        .a      (ex_rs1_data),
        .b      (ex_rs2_data),
        .op     (ex_alu_op),
        .result (mul_result),
        .done   (mul_done)
    );

    // 6c. Multi-cycle Divider (RV32M DIV/DIVU/REM/REMU)
    divider div_unit (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (mcycle_start && is_div),
        .a         (ex_rs1_data),
        .b         (ex_rs2_data),
        .is_signed ((ex_alu_op == `ALU_DIV) || (ex_alu_op == `ALU_REM)),
        .want_rem  ((ex_alu_op == `ALU_REM) || (ex_alu_op == `ALU_REMU)),
        .result    (div_result),
        .done      (div_done)
    );

    // Write-back value for ALU-class instructions. alu_result itself still
    // drives address decoding and the branch comparison, which multiplies and
    // divides never use, so only the register write-back needs these answers.
    wire [31:0] exec_result = is_div ? div_result :
                              is_mul ? mul_result : alu_result;

    // 7. Internal Data Memory (RAM)
    wire [31:0] internal_mem_read_data;

    data_memory dmem (
        .clk        (clk),
        .addr       (alu_result),
        .write_data (ex_rs2_data),
        .write_en   (ex_store && dmem_sel),
        .read_en    (ex_load  && dmem_sel),
        .funct3     (ex_funct3),
        .read_data  (internal_mem_read_data)
    );

    // =========================================================================
    // Datapath Multiplexers (EX)
    // =========================================================================

    // ALU Operand A: PC for AUIPC, rs1 otherwise
    always @(*) begin
        if (alu_src_a) alu_in_a = ex_pc;
        else           alu_in_a = ex_rs1_data;
    end

    // ALU Operand B: immediate or rs2
    always @(*) begin
        if (ex_alu_src_b) alu_in_b = ex_imm;
        else              alu_in_b = ex_rs2_data;
    end

    // Load data select
    reg  [31:0] selected_mem_data;
    wire [1:0]  mem_byte_offset = alu_result[1:0];

    always @(*) begin
        if (dmem_sel) begin
            selected_mem_data = internal_mem_read_data;
        end else if (imem_sel) begin
            // Byte/halfword selection for .rodata loads (LBU, LB, LHU, LH, LW)
            case (ex_funct3)
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
        end else if (mmio_uart_stat_sel) begin
            selected_mem_data = {31'd0, uart_busy};
        end else if (mmio_uart_rx_sel) begin
            selected_mem_data = {24'd0, uart_rx_data};
        end else if (mmio_uart_rx_stat_sel) begin
            selected_mem_data = {31'd0, uart_rx_ready};
        end else begin
            selected_mem_data = mem_read_data;
        end
    end

    // Register write-back select
    always @(*) begin
        case (ex_wb_sel)
            2'd0:    reg_write_data = exec_result;
            2'd1:    reg_write_data = selected_mem_data;
            2'd2:    reg_write_data = ex_pc + 32'd4;
            default: reg_write_data = exec_result;
        endcase
    end

    // Next PC select. JALR clears the low bit of the target (RISC-V spec).
    wire [31:0] jalr_target   = (ex_rs1_data + ex_imm) & 32'hFFFF_FFFE;
    wire [31:0] branch_target = ex_pc + ex_imm;

    always @(*) begin
        if (branch_or_jump) begin
            case (pc_sel)
                2'd1:    next_pc_temp = branch_target;
                2'd2:    next_pc_temp = jalr_target;
                default: next_pc_temp = pc + 32'd4;
            endcase
        end else begin
            next_pc_temp = pc + 32'd4;
        end
    end
    assign next_pc = next_pc_temp;

    // =========================================================================
    // Pipeline Registers
    // =========================================================================
    // A taken branch or jump is only known in EX, so the two instructions
    // behind it - one in ID, one being fetched - are discarded by clearing
    // their valid bits. The ID/EX payload is left alone; ex_valid gates
    // everything that could have an effect.
    always @(posedge clk) begin
        if (!rst_n) begin
            pc             <= 32'd0;
            ifid_pc        <= 32'd0;
            ifid_valid     <= 1'b0;
            ex_valid       <= 1'b0;
            ex_pc          <= 32'd0;
            ex_rs1_data    <= 32'd0;
            ex_rs2_data    <= 32'd0;
            ex_imm         <= 32'd0;
            ex_rd          <= 5'd0;
            ex_alu_op      <= `ALU_ADD;
            ex_reg_write   <= 1'b0;
            ex_alu_src_b   <= 1'b0;
            ex_branch      <= 1'b0;
            ex_jump        <= 1'b0;
            ex_mem_read    <= 1'b0;
            ex_mem_write   <= 1'b0;
            ex_wb_sel      <= 2'd0;
            ex_funct3      <= 3'd0;
            ex_opcode      <= 7'd0;
            load_pending   <= 1'b0;
            mcycle_started <= 1'b0;
        end else if (stall) begin
            // Hold every stage until the memory, multiplier or divider answers.
            load_pending   <= 1'b1;
            mcycle_started <= 1'b1;
        end else begin
            load_pending   <= 1'b0;
            mcycle_started <= 1'b0;

            pc <= next_pc;

            if (branch_or_jump) begin
                ifid_pc    <= 32'd0;
                ifid_valid <= 1'b0;
                ex_valid   <= 1'b0;
            end else begin
                ifid_pc    <= pc;
                ifid_valid <= 1'b1;

                ex_valid     <= ifid_valid;
                ex_pc        <= ifid_pc;
                ex_rs1_data  <= id_rs1_data;
                ex_rs2_data  <= id_rs2_data;
                ex_imm       <= id_imm;
                ex_rd        <= id_rd;
                ex_alu_op    <= id_alu_op;
                ex_reg_write <= id_reg_write;
                ex_alu_src_b <= id_alu_src_b;
                ex_branch    <= id_branch;
                ex_jump      <= id_jump;
                ex_mem_read  <= id_mem_read;
                ex_mem_write <= id_mem_write;
                ex_wb_sel    <= id_wb_sel;
                ex_funct3    <= id_inst[14:12];
                ex_opcode    <= id_inst[6:0];
            end
        end
    end

endmodule
