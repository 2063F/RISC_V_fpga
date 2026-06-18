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
//              Handles single cycle execution of basic instructions.
// 
// Dependencies: riscv_defines.vh, program_counter.v, instruction_memory.v,
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
    
    // Debug ports
    output wire [31:0] debug_pc,
    output wire [31:0] debug_x1
);

    // =========================================================================
    // Internal Signals
    // =========================================================================
    wire [31:0] pc;
    wire [31:0] next_pc;
    wire [31:0] inst;
    
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

    // =========================================================================
    // Debug assignment
    // =========================================================================
    assign debug_pc = pc;

    // =========================================================================
    // Memory Interface / Address Decoding Outputs
    // =========================================================================
    wire dmem_sel  = (alu_result >= 32'h0001_0000) && (alu_result <= 32'h0001_3FFF);
    // MMIO: 0x8000_0010 = UART TX data register
    //       0x8000_0014 = UART TX status register (bit0 = busy)
    wire mmio_uart_tx_sel    = (alu_result == 32'h8000_0010);
    wire mmio_uart_stat_sel  = (alu_result == 32'h8000_0014);
    wire mmio_sel            = mmio_uart_tx_sel || mmio_uart_stat_sel;

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
    // Module Instantiations
    // =========================================================================
    
    // 1. Program Counter
    program_counter pc_reg (
        .clk    (clk),
        .rst_n  (rst_n),
        .pc_in  (next_pc),
        .pc_out (pc)
    );
    
    // 2. Instruction Memory
    instruction_memory #(
        .INIT_FILE (INIT_FILE)
    ) imem (
        .addr (pc),
        .dout (inst)
    );
    
    // 3. Instruction Decoder
    instruction_decoder dec (
        .inst      (inst),
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
    
    // 4. Immediate Generator
    imm_gen igen (
        .inst     (inst),
        .imm_type (imm_type),
        .imm      (imm)
    );
    
    // 5. Register File
    register_file regfile (
        .clk        (clk),
        .rst        (!rst_n),
        .rs1        (rs1),
        .rd1        (rs1_data),
        .rs2        (rs2),
        .rd2        (rs2_data),
        .rd         (rd),
        .wd         (reg_write_data),
        .we         (reg_write),
        .dbg_x1     (debug_x1)
    );
    
    // 6. Control Unit
    control_unit ctrl (
        .opcode     (inst[6:0]),
        .funct3     (inst[14:12]),
        .branch     (branch),
        .jump       (jump),
        .alu_zero   (alu_zero),
        .alu_result (alu_result),
        .alu_src_a  (alu_src_a),
        .pc_sel     (pc_sel)
    );
    
    // 7. ALU
    alu alu_inst (
        .a      (alu_in_a),
        .b      (alu_in_b),
        .alu_op (alu_op),
        .result (alu_result),
        .zero   (alu_zero)
    );

    // 8. Internal Data Memory (RAM)
    wire [31:0] internal_mem_read_data;

    data_memory dmem (
        .clk        (clk),
        .addr       (alu_result),
        .write_data (rs2_data),
        .write_en   (mem_write && dmem_sel),
        .read_en    (mem_read && dmem_sel),
        .funct3     (inst[14:12]),
        .read_data  (internal_mem_read_data)
    );

    // =========================================================================
    // Datapath Multiplexers
    // =========================================================================
    
    // ALU Operand A Select MUX
    always @(*) begin
        if (alu_src_a) begin
            alu_in_a = pc;
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
    always @(*) begin
        if (dmem_sel) begin
            selected_mem_data = internal_mem_read_data;
        end else if (mmio_uart_stat_sel) begin
            selected_mem_data = {31'd0, uart_busy};
        end else begin
            selected_mem_data = mem_read_data;
        end
    end

    always @(*) begin
        case (wb_sel)
            2'd0:    reg_write_data = alu_result;
            2'd1:    reg_write_data = selected_mem_data;
            2'd2:    reg_write_data = pc + 32'd4;
            default: reg_write_data = alu_result;
        endcase
    end
    
    // Next PC Select MUX
    // JALR target address lower bit must be cleared to 0 (RISC-V spec)
    wire [31:0] jalr_target = (rs1_data + imm) & 32'hFFFF_FFFE;
    wire [31:0] branch_target = pc + imm;
    wire [31:0] pc_plus_4 = pc + 32'd4;
    
    reg [31:0] next_pc_temp;
    always @(*) begin
        case (pc_sel)
            2'd0:    next_pc_temp = pc_plus_4;
            2'd1:    next_pc_temp = branch_target;
            2'd2:    next_pc_temp = jalr_target;
            default: next_pc_temp = pc_plus_4;
        endcase
    end
    assign next_pc = next_pc_temp;

endmodule
