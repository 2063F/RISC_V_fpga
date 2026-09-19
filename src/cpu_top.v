`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/23
// Design Name: 
// Module Name: cpu_top
// Project Name: RISC-V RV32I CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Tool Versions: 
// Description: Top level CPU module connecting datapath and control unit.
//              Handles a two-stage pipeline (fetch + execute/writeback).
// 
// Dependencies: riscv_defines.vh, instruction_memory.v,
//               instruction_decoder.v, imm_gen.v, register_file.v,
//               control_unit.v, alu.v
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
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
    // Internal Signals
    // =========================================================================
    reg  [31:0] pc;
    reg  [31:0] ifid_pc;
    reg         ifid_valid;
    reg         load_pending;   // 1 during the second (data) cycle of a load
    reg         mcycle_started; // 1 once the multiplier/divider has been handed this instruction
    wire [31:0] next_pc;

    // The instruction ROM's port-A output register IS the IF/ID instruction
    // register: the address is applied in the fetch cycle and the instruction
    // comes out in the execute cycle. A flushed slot is masked to a NOP here
    // rather than by clearing the register, which lives inside the BSRAM.
    wire [31:0] fetched_inst;
    wire        fetched_valid;

    // One mux on the fetch path, not two: both selects are register outputs, so
    // combining them costs no extra logic on the data path itself.
    wire        inst_valid = ifid_valid && fetched_valid;
    wire [31:0] ifid_inst  = inst_valid ? fetched_inst : NOP_INST;
    
    // Decoder outputs
    wire [4:0]  rs1;
    wire [4:0]  rs2;
    wire [4:0]  rd;
    wire        reg_write;
    wire [2:0]  imm_type;
    wire [4:0]  alu_op;
    wire        alu_src_b;
    wire        branch;
    wire        jump;
    wire        mem_read;
    wire        mem_write;
    wire [1:0]  wb_sel;
    
    // Imm Gen output
    wire [31:0] imm;
    
    // Register File outputs / inputs
    wire [31:0] rs1_data;
    wire [31:0] rs2_data;
    reg  [31:0] reg_write_data;
    
    // Control Unit outputs
    wire        alu_src_a;
    wire [1:0]  pc_sel;
    
    // ALU inputs / outputs
    reg  [31:0] alu_in_a;
    reg  [31:0] alu_in_b;
    wire [31:0] alu_result;
    wire        alu_zero;
    reg  [31:0] next_pc_temp;

    wire execute_valid = ifid_valid;
    wire branch_or_jump = (pc_sel != 2'd0);

    // =========================================================================
    // Load stall
    // =========================================================================
    // Both memories have a registered read port (required to map them onto
    // BSRAM - see data_memory.v), so load data is one cycle late. Freeze the
    // fetch for one cycle and write back in the second cycle. Address, funct3
    // and the register operands all stay put while frozen, so the memory's
    // combinational sizing/extension logic still sees the load's own controls
    // when the data word arrives.
    wire load_stall = mem_read && !load_pending;

    // =========================================================================
    // RV32M stall (multiply and divide)
    // =========================================================================
    // Both used to be combinational inside the ALU and both took a turn as the
    // critical path of the whole design: the divider held it to 5.031 MHz, and
    // once that moved out the 32x32->64 multiply carry chain held it to
    // 39.377 MHz - against a 50 MHz constraint in both cases. They now run on
    // multiplier.v (3 cycles) and divider.v (34 cycles, or 2 for divide-by-zero
    // and the MIN_INT/-1 overflow) with the CPU stalled meanwhile.
    //
    // mcycle_started mirrors load_pending: it keeps the start signal a
    // single-cycle pulse even though the instruction sits in the execute stage
    // for the whole operation, and clears as soon as the instruction retires.
    wire is_mul = (alu_op == `ALU_MUL)  || (alu_op == `ALU_MULH) ||
                  (alu_op == `ALU_MULHSU) || (alu_op == `ALU_MULHU);
    wire is_div = (alu_op == `ALU_DIV)  || (alu_op == `ALU_DIVU) ||
                  (alu_op == `ALU_REM)  || (alu_op == `ALU_REMU);

    wire is_mcycle     = is_mul || is_div;
    wire mcycle_start  = is_mcycle && !mcycle_started;
    wire mcycle_done   = is_div ? div_done : mul_done;
    wire mcycle_stall  = is_mcycle && !mcycle_done;

    wire stall     = load_stall || mcycle_stall;
    wire wb_enable = reg_write && !stall;

    // =========================================================================
    // Debug assignment
    // =========================================================================
    assign debug_pc = execute_valid ? (ifid_pc + 32'd4) : pc;

    // =========================================================================
    // Memory Interface / Address Decoding Outputs
    // =========================================================================
    // The implemented data RAM is 64 KB, so the valid scratch-memory region is
    // 0x0001_0000 - 0x0001_FFFF.
    wire imem_sel  = (alu_result < 32'h0000_8000);
    wire dmem_sel  = (alu_result >= 32'h0001_0000) && (alu_result <= 32'h0001_FFFF);
    // MMIO: 0x8000_0010 = UART TX data register
    //       0x8000_0014 = UART TX status register (bit0 = busy)
    //       0x8000_0018 = UART RX data register
    //       0x8000_001C = UART RX status register (bit0 = ready)
    wire mmio_uart_tx_sel    = (alu_result == 32'h8000_0010);
    wire mmio_uart_stat_sel  = (alu_result == 32'h8000_0014);
    wire mmio_uart_rx_sel    = (alu_result == 32'h8000_0018);
    wire mmio_uart_rx_stat_sel = (alu_result == 32'h8000_001C);
    wire mmio_sel            = mmio_uart_tx_sel || mmio_uart_stat_sel || 
                               mmio_uart_rx_sel || mmio_uart_rx_stat_sel;

    assign mem_addr       = alu_result;
    assign mem_write_data = rs2_data;
    assign mem_write_en   = mem_write && !dmem_sel && !mmio_sel;
    assign mem_read_en    = mem_read && !dmem_sel && !mmio_sel;

    // =========================================================================
    // UART TX MMIO
    // =========================================================================
    wire uart_busy;
    // tx_start fires for one clock when CPU does SW to UART TX address
    wire uart_start = mem_write && mmio_uart_tx_sel;

    uart_tx uart_tx_inst (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (rs2_data[7:0]),
        .tx_start (uart_start),
        .tx_pin   (uart_tx_pin),
        .tx_busy  (uart_busy)
    );

    // =========================================================================
    // UART RX MMIO
    // =========================================================================
    wire [7:0] uart_rx_data;
    wire       uart_rx_ready;
    // rx_clear fires when CPU reads UART RX data register (LW to 0x8000_0018)
    wire uart_rx_clear = mem_read && mmio_uart_rx_sel && !stall;

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
    wire [31:0] rom_data_read;
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
    
    // 2. Instruction Decoder
    instruction_decoder dec (
        .inst      (ifid_inst),
        .rs1       (rs1),
        .rs2       (rs2),
        .rd        (rd),
        .reg_write (reg_write),
        .imm_type  (imm_type),
        .alu_op    (alu_op),
        .alu_src_b (alu_src_b),
        .branch    (branch),
        .jump      (jump),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .wb_sel    (wb_sel)
    );
    
    // 3. Immediate Generator
    imm_gen igen (
        .inst     (ifid_inst),
        .imm_type (imm_type),
        .imm      (imm)
    );
    
    // 4. Register File
    register_file regfile (
        .clk        (clk),
        .rst        (!rst_n),
        .rs1        (rs1),
        .rd1        (rs1_data),
        .rs2        (rs2),
        .rd2        (rs2_data),
        .rd         (rd),
        .wd         (reg_write_data),
        .we         (wb_enable),
        .dbg_x1     (debug_x1)
    );
    
    // 5. Control Unit
    control_unit ctrl (
        .opcode     (ifid_inst[6:0]),
        .funct3     (ifid_inst[14:12]),
        .branch     (branch),
        .jump       (jump),
        .alu_zero   (alu_zero),
        .alu_result (alu_result),
        .alu_src_a  (alu_src_a),
        .pc_sel     (pc_sel)
    );
    
    // 6. ALU
    alu alu_inst (
        .a      (alu_in_a),
        .b      (alu_in_b),
        .alu_op (alu_op),
        .result (alu_result),
        .zero   (alu_zero)
    );

    // 6b. Multi-cycle Multiplier (RV32M MUL/MULH/MULHSU/MULHU)
    wire [31:0] mul_result;
    wire        mul_done;

    multiplier mul_unit (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (mcycle_start && is_mul),
        .a      (rs1_data),
        .b      (rs2_data),
        .op     (alu_op),
        .result (mul_result),
        .done   (mul_done)
    );

    // 6c. Multi-cycle Divider (RV32M DIV/DIVU/REM/REMU)
    wire [31:0] div_result;
    wire        div_done;

    divider div_unit (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (mcycle_start && is_div),
        .a         (rs1_data),
        .b         (rs2_data),
        .is_signed ((alu_op == `ALU_DIV) || (alu_op == `ALU_REM)),
        .want_rem  ((alu_op == `ALU_REM) || (alu_op == `ALU_REMU)),
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
        .write_data (rs2_data),
        .write_en   (mem_write && dmem_sel),
        .read_en    (mem_read && dmem_sel),
        .funct3     (ifid_inst[14:12]),
        .read_data  (internal_mem_read_data)
    );

    // =========================================================================
    // Datapath Multiplexers
    // =========================================================================
    
    // ALU Operand A Select MUX
    always @(*) begin
        if (alu_src_a) begin
            alu_in_a = ifid_pc;
        end else begin
            alu_in_a = rs1_data;
        end
    end
    
    // ALU Operand B Select MUX
    always @(*) begin
        if (alu_src_b) begin
            alu_in_b = imm;
        end else begin
            alu_in_b = rs2_data;
        end
    end
    
    // Register Write-back Select MUX
    reg [31:0] selected_mem_data;
    wire [1:0] mem_byte_offset = alu_result[1:0];
    always @(*) begin
        if (dmem_sel) begin
            selected_mem_data = internal_mem_read_data;
        end else if (imem_sel) begin
            // Byte/halfword selection for .rodata loads (LBU, LB, LHU, LH, LW)
            case (ifid_inst[14:12])
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

    always @(*) begin
        case (wb_sel)
            2'd0:    reg_write_data = exec_result;
            2'd1:    reg_write_data = selected_mem_data;
            2'd2:    reg_write_data = ifid_pc + 32'd4;
            default: reg_write_data = exec_result;
        endcase
    end

    // Next PC Select MUX
    // JALR target address lower bit must be cleared to 0 (RISC-V spec)
    wire [31:0] jalr_target = (rs1_data + imm) & 32'hFFFF_FFFE;
    wire [31:0] branch_target = ifid_pc + imm;

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

    // =============x============================================================
    // Pipeline Registers
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            pc           <= 32'd0;
            ifid_pc      <= 32'd0;
            ifid_valid   <= 1'b0;
            load_pending   <= 1'b0;
            mcycle_started <= 1'b0;
        end else if (stall) begin
            // Hold everything until the memory, multiplier or divider answers.
            load_pending   <= 1'b1;
            mcycle_started <= 1'b1;
        end else begin
            load_pending   <= 1'b0;
            mcycle_started <= 1'b0;
            pc           <= next_pc;

            if (branch_or_jump) begin
                ifid_pc    <= 32'd0;
                ifid_valid <= 1'b0;
            end else begin
                ifid_pc    <= pc;
                ifid_valid <= 1'b1;
            end
        end
    end

endmodule
