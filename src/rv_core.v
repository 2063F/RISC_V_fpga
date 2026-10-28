`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: rv_core
// Project Name: RISC-V RV32IM CPU
// Target Devices: Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
// Description: One RV32IM hart: a three-stage pipeline with its CSRs. Memory
//              and devices live outside, in the SoC (cpu_top.v), behind an
//              instruction fetch port and a data bus.
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
// Traps
// -----
// Exceptions and interrupts are both taken in EX, on the instruction sitting
// there: it is cancelled (no register, memory, CSR or MMIO write), mepc gets
// its PC, and the two instructions behind it are discarded exactly as for a
// taken branch. Everything the trap decision needs is either registered in
// ID/EX or derived from the low two address bits, so it never waits on the
// full ALU result - except for a taken branch to a misaligned target, which
// only redirects the PC (branches write nothing else).
//
// An interrupt is only taken on an instruction's first cycle in EX. Once a
// load or store has been sent to the data bus or the multiplier/divider has
// started, the instruction runs to completion and the interrupt waits for the
// next one.
//
// Instruction fetch port
// ----------------------
// ibus_addr is the PC. The ROM answers with a registered read, and that output
// register IS the IF/ID instruction register, so ibus_ce must freeze it while
// the pipeline stalls. ibus_valid = 0 marks a fetch outside the ROM.
//
// Data bus
// --------
// The hart drives one request at a time from EX and holds dbus_addr,
// dbus_wdata, dbus_we and dbus_funct3 steady until it completes (EX is frozen
// meanwhile):
//
//   - dbus_req is high while a load or store is waiting to be accepted.
//   - dbus_gnt accepts it at the next clock edge. A store is then done; a load
//     has issued its read.
//   - dbus_rvalid answers an accepted load with dbus_rdata, already sized and
//     sign-extended for dbus_funct3. dbus_req stays low until then.
//
// With a single hart dbus_gnt is tied high and dbus_rvalid follows one cycle
// after, which is exactly the old fixed timing: stores take one cycle, loads
// two. The handshake is there so the bus can be shared and slaves can be slow.
//
// Dependencies: riscv_defines.vh, instruction_decoder.v, imm_gen.v,
//               register_file.v, control_unit.v, alu.v, multiplier.v,
//               divider.v, csr_file.v
//////////////////////////////////////////////////////////////////////////////////

`include "riscv_defines.vh"

module rv_core #(
    parameter [31:0] HART_ID = 32'd0   // mhartid
) (
    input  wire        clk,
    input  wire        rst_n,

    // Instruction fetch port
    output wire [31:0] ibus_addr,
    output wire        ibus_ce,       // 0 = hold the fetched instruction
    input  wire [31:0] ibus_rdata,
    input  wire        ibus_valid,    // 0 = the fetch was outside the ROM

    // Data bus
    output wire        dbus_req,
    output wire        dbus_we,
    output wire [31:0] dbus_addr,
    output wire [31:0] dbus_wdata,
    output wire [2:0]  dbus_funct3,
    input  wire        dbus_gnt,
    input  wire        dbus_rvalid,
    input  wire [31:0] dbus_rdata,

    // Interrupt lines and the machine timer (for the time CSR)
    input  wire        irq_ext,
    input  wire        irq_timer,
    input  wire        irq_soft,
    input  wire [63:0] mtime,

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

    wire [31:0] fetched_inst  = ibus_rdata;
    wire        fetched_valid = ibus_valid;

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
    wire        id_dec_illegal, id_ecall, id_ebreak, id_mret;
    wire        id_csr, id_csr_write;
    wire        id_csr_illegal;
    // An unknown CSR address, or a write to a read-only one, is an illegal
    // instruction just like a bad opcode.
    wire        id_illegal = id_dec_illegal || (id_csr && id_csr_illegal);

    wire [31:0] rf_rd1, rf_rd2;

    // =========================================================================
    // ID/EX pipeline register
    // =========================================================================
    reg  [31:0] ex_pc;
    reg  [31:0] ex_rs1_data, ex_rs2_data;
    reg  [31:0] ex_alu_a, ex_alu_b;  // ALU operands, already selected in ID
    reg  [31:0] ex_imm;
    reg  [4:0]  ex_rd;
    reg  [4:0]  ex_alu_op;
    reg         ex_reg_write;
    reg         ex_branch, ex_jump;
    reg         ex_mem_read, ex_mem_write;
    reg  [1:0]  ex_wb_sel;
    reg  [2:0]  ex_funct3;
    reg  [6:0]  ex_opcode;
    reg         ex_valid;
    reg         ex_fetch_fault;  // the fetch was outside the instruction ROM
    reg         ex_illegal;
    reg         ex_ecall, ex_ebreak, ex_mret;
    reg         ex_csr, ex_csr_write;
    reg  [4:0]  ex_rs1_idx;      // uimm of the CSR immediate forms
    reg  [31:0] ex_inst;         // for mtval on an illegal instruction

    // Stall bookkeeping
    reg         load_pending;    // 1 once the bus has taken a load, until its data
    reg         mcycle_started;  // 1 once the multiplier/divider has this instruction

    // =========================================================================
    // Stage 3: Execute / Memory / Write-back
    // =========================================================================
    wire [1:0]  pc_sel;
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
    // Traps (EX)
    // =========================================================================
    // The low two bits of rs1 + imm, computed on their own. Loads, stores and
    // JALR all form their address this way, and the alignment checks below only
    // need these bits - not the 32-bit carry chain behind alu_result.
    wire [1:0] addr_lo = ex_rs1_data[1:0] + ex_imm[1:0];

    // funct3[1:0]: 00 byte, 01 halfword, 10 word (same for loads and stores)
    wire ls_misaligned = ((ex_funct3[1:0] == 2'b10) && (addr_lo != 2'b00)) ||
                         ((ex_funct3[1:0] == 2'b01) &&  addr_lo[0]);

    // PCs are always word aligned, so a JAL or branch target is misaligned
    // exactly when imm[1] is set. JALR clears bit 0 of its target itself.
    wire is_jalr          = (ex_opcode == `OP_JALR);
    wire exc_jump_mis     = ex_jump && (is_jalr ? addr_lo[1] : ex_imm[1]);
    wire exc_load_mis     = ex_mem_read  && ls_misaligned;
    wire exc_store_mis    = ex_mem_write && ls_misaligned;

    wire exc_early = ex_valid && (ex_fetch_fault || ex_illegal || ex_ecall ||
                                  ex_ebreak || exc_jump_mis ||
                                  exc_load_mis || exc_store_mis);

    wire        irq_pending;
    wire [3:0]  irq_code;
    wire        irq_take = ex_valid && irq_pending && !load_pending && !mcycle_started;

    // trap_early is everything except a taken branch to a misaligned target.
    // It gates the register, memory, CSR and MMIO writes and the stalls. The
    // branch case depends on the branch comparison, so it is kept off those
    // paths; a branch writes none of them anyway.
    wire trap_early     = irq_take || exc_early;
    wire exc_branch_mis = ex_valid && ex_branch && ex_imm[1] && (pc_sel != 2'd0);
    wire trap           = trap_early || exc_branch_mis;

    wire mret_take = ex_valid && ex_mret && !trap_early;

    reg  [3:0]  trap_code;
    reg  [31:0] trap_val;
    wire [31:0] jalr_target;
    wire [31:0] branch_target;

    always @(*) begin
        trap_val = 32'd0;
        if (irq_take) begin
            trap_code = irq_code;
        end else if (ex_fetch_fault) begin
            trap_code = `EXC_INST_ACCESS;
            trap_val  = ex_pc;
        end else if (ex_illegal) begin
            trap_code = `EXC_ILLEGAL_INST;
            trap_val  = ex_inst;
        end else if (ex_ebreak) begin
            trap_code = `EXC_BREAKPOINT;
        end else if (ex_ecall) begin
            trap_code = `EXC_ECALL_M;
        end else if (exc_jump_mis || exc_branch_mis) begin
            trap_code = `EXC_INST_MISALIGNED;
            trap_val  = is_jalr ? jalr_target : branch_target;
        end else if (exc_load_mis) begin
            trap_code = `EXC_LOAD_MISALIGNED;
            trap_val  = alu_result;
        end else begin
            trap_code = `EXC_STORE_MISALIGNED;
            trap_val  = alu_result;
        end
    end

    wire [31:0] csr_rdata;
    wire [31:0] exc_vector, irq_vector, mepc;
    wire [31:0] trap_vector = irq_take ? irq_vector : exc_vector;

    // A taken branch or jump, a trap, or MRET: the two younger instructions go.
    wire redirect = branch_or_jump || trap || mret_take;

    // minstret counts an instruction one cycle after it retires, so that its
    // increment does not hang off the trap decision.
    reg instret_pulse;

    // =========================================================================
    // Memory stall
    // =========================================================================
    // A load or store waits in EX until the bus accepts it, and a load then
    // waits again for its data (the memories have a registered read port -
    // required to map them onto BSRAM, see data_memory.v - so that is at least
    // one more cycle). Address, funct3 and the register operands all stay put
    // while frozen, which is what the bus protocol above relies on.
    //
    // load_pending is set once the bus has taken the load, and the load writes
    // back in the cycle dbus_rvalid arrives.
    wire ex_mem    = ex_valid && (ex_mem_read || ex_mem_write) && !trap_early;
    wire mem_req   = ex_mem && !load_pending;
    wire mem_stall = mem_req ? (ex_mem_read || !dbus_gnt)
                             : (ex_mem && !dbus_rvalid);

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
    wire mcycle_start = is_mcycle && !mcycle_started && !trap_early;
    wire mcycle_done  = is_div ? div_done : mul_done;
    wire mcycle_stall = is_mcycle && !mcycle_done && !trap_early;

    wire stall     = mem_stall || mcycle_stall;
    wire wb_enable = ex_valid && ex_reg_write && !stall && !trap_early;

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

    // ALU operands are chosen here rather than in EX: A is the PC for AUIPC and
    // rs1 otherwise, B is the immediate or rs2. Done in EX, that mux sat between
    // the ID/EX register and the ALU adder on every ALU path, behind a select
    // line fanning out to 64 bits. Here it comes off the decode instead.
    //
    // reg_write_data is the late arrival (it is the end of the EX path), so it
    // is kept to a single mux level: the forward select is folded with the
    // operand select, and everything else is muxed beforehand.
    wire        id_is_auipc = (id_inst[6:0] == `OP_AUIPC);
    wire        fwd_alu_a   = fwd_rs1 && !id_is_auipc;
    wire        fwd_alu_b   = fwd_rs2 && !id_alu_src_b;
    wire [31:0] id_alu_a_rf = id_is_auipc  ? ifid_pc : rf_rd1;
    wire [31:0] id_alu_b_rf = id_alu_src_b ? id_imm  : rf_rd2;
    wire [31:0] id_alu_a    = fwd_alu_a ? reg_write_data : id_alu_a_rf;
    wire [31:0] id_alu_b    = fwd_alu_b ? reg_write_data : id_alu_b_rf;

    // =========================================================================
    // Debug assignment
    // =========================================================================
    assign debug_pc = ex_valid ? (ex_pc + 32'd4) : pc;

    // =========================================================================
    // Data bus
    // =========================================================================
    // The address is the ALU result itself; the SoC decodes it.
    assign dbus_req    = mem_req;
    assign dbus_we     = ex_mem_write;
    assign dbus_addr   = alu_result;
    assign dbus_wdata  = ex_rs2_data;
    assign dbus_funct3 = ex_funct3;

    assign ibus_addr = pc;
    assign ibus_ce   = !stall;

    // =========================================================================
    // CSRs and trap state
    // =========================================================================
    csr_file #(
        .HART_ID (HART_ID)
    ) csrs (
        .clk         (clk),
        .rst_n       (rst_n),
        .chk_addr    (id_inst[31:20]),
        .chk_write   (id_csr_write),
        .chk_illegal (id_csr_illegal),
        .addr        (ex_imm[11:0]),
        .rdata       (csr_rdata),
        .we          (ex_valid && ex_csr && ex_csr_write && !trap_early && !stall),
        .op          (ex_funct3[1:0]),
        .operand     (ex_funct3[2] ? {27'd0, ex_rs1_idx} : ex_rs1_data),
        .trap        (trap),
        .trap_irq    (irq_take),
        .trap_code   (trap_code),
        .trap_pc     (ex_pc),
        .trap_val    (trap_val),
        .mret        (mret_take),
        .instret     (instret_pulse),
        .irq_ext     (irq_ext),
        .irq_timer   (irq_timer),
        .irq_soft    (irq_soft),
        .mtime       (mtime),
        .irq_pending (irq_pending),
        .irq_code    (irq_code),
        .exc_vector  (exc_vector),
        .irq_vector  (irq_vector),
        .mepc        (mepc)
    );

    // =========================================================================
    // Module Instantiations
    // =========================================================================

    // 1. Instruction Decoder (ID)
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
        .wb_sel    (id_wb_sel),
        .illegal   (id_dec_illegal),
        .ecall     (id_ecall),
        .ebreak    (id_ebreak),
        .mret      (id_mret),
        .csr       (id_csr),
        .csr_write (id_csr_write)
    );

    // 2. Immediate Generator (ID)
    imm_gen igen (
        .inst     (id_inst),
        .imm_type (id_imm_type),
        .imm      (id_imm)
    );

    // 3. Register File (read in ID, written from EX)
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

    // 4. Control Unit (EX)
    control_unit ctrl (
        .opcode     (ex_opcode),
        .funct3     (ex_funct3),
        .branch     (ex_branch),
        .jump       (ex_jump),
        .alu_zero   (alu_zero),
        .alu_result (alu_result),
        .pc_sel     (pc_sel)
    );

    // 5. ALU (EX)
    alu alu_inst (
        .a      (ex_alu_a),
        .b      (ex_alu_b),
        .alu_op (ex_alu_op),
        .result (alu_result),
        .zero   (alu_zero)
    );

    // 5b. Multi-cycle Multiplier (RV32M MUL/MULH/MULHSU/MULHU)
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

    // 5c. Multi-cycle Divider (RV32M DIV/DIVU/REM/REMU)
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

    // =========================================================================
    // Datapath Multiplexers (EX)
    // =========================================================================

    // Load data arrives already sized and sign-extended by the SoC.
    wire [31:0] selected_mem_data = dbus_rdata;


    // Register write-back select
    always @(*) begin
        case (ex_wb_sel)
            `WB_ALU: reg_write_data = exec_result;
            `WB_MEM: reg_write_data = selected_mem_data;
            `WB_PC4: reg_write_data = ex_pc + 32'd4;
            `WB_CSR: reg_write_data = csr_rdata;
        endcase
    end

    // Next PC select. JALR clears the low bit of the target (RISC-V spec).
    assign jalr_target   = (ex_rs1_data + ex_imm) & 32'hFFFF_FFFE;
    assign branch_target = ex_pc + ex_imm;

    always @(*) begin
        if (trap) begin
            next_pc_temp = trap_vector;
        end else if (mret_take) begin
            next_pc_temp = mepc;
        end else if (branch_or_jump) begin
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
    // A taken branch or jump (or a trap, or MRET) is only known in EX, so the
    // two instructions behind it - one in ID, one being fetched - are discarded
    // by clearing their valid bits. The ID/EX payload is left alone; ex_valid
    // gates everything that could have an effect.
    always @(posedge clk) begin
        if (!rst_n) begin
            pc             <= 32'd0;
            ifid_pc        <= 32'd0;
            ifid_valid     <= 1'b0;
            ex_valid       <= 1'b0;
            ex_pc          <= 32'd0;
            ex_rs1_data    <= 32'd0;
            ex_rs2_data    <= 32'd0;
            ex_alu_a       <= 32'd0;
            ex_alu_b       <= 32'd0;
            ex_imm         <= 32'd0;
            ex_rd          <= 5'd0;
            ex_alu_op      <= `ALU_ADD;
            ex_reg_write   <= 1'b0;
            ex_branch      <= 1'b0;
            ex_jump        <= 1'b0;
            ex_mem_read    <= 1'b0;
            ex_mem_write   <= 1'b0;
            ex_wb_sel      <= 2'd0;
            ex_funct3      <= 3'd0;
            ex_opcode      <= 7'd0;
            load_pending   <= 1'b0;
            mcycle_started <= 1'b0;
            instret_pulse  <= 1'b0;
            ex_fetch_fault <= 1'b0;
            ex_illegal     <= 1'b0;
            ex_ecall       <= 1'b0;
            ex_ebreak      <= 1'b0;
            ex_mret        <= 1'b0;
            ex_csr         <= 1'b0;
            ex_csr_write   <= 1'b0;
            ex_rs1_idx     <= 5'd0;
            ex_inst        <= 32'd0;
        end else if (stall) begin
            // Hold every stage until the memory, multiplier or divider answers.
            if (mem_req && dbus_gnt && !dbus_we)
                load_pending <= 1'b1;
            mcycle_started <= 1'b1;
            instret_pulse  <= 1'b0;
        end else begin
            load_pending   <= 1'b0;
            mcycle_started <= 1'b0;
            instret_pulse  <= ex_valid && !trap;

            pc <= next_pc;

            if (redirect) begin
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
                ex_alu_a     <= id_alu_a;
                ex_alu_b     <= id_alu_b;
                ex_imm       <= id_imm;
                ex_rd        <= id_rd;
                ex_alu_op    <= id_alu_op;
                ex_reg_write <= id_reg_write;
                ex_branch    <= id_branch;
                ex_jump      <= id_jump;
                ex_mem_read  <= id_mem_read;
                ex_mem_write <= id_mem_write;
                ex_wb_sel    <= id_wb_sel;
                ex_funct3    <= id_inst[14:12];
                ex_opcode    <= id_inst[6:0];

                ex_fetch_fault <= ifid_valid && !fetched_valid;
                ex_illegal     <= id_illegal;
                ex_ecall       <= id_ecall;
                ex_ebreak      <= id_ebreak;
                ex_mret        <= id_mret;
                ex_csr         <= id_csr;
                ex_csr_write   <= id_csr_write;
                ex_rs1_idx     <= id_rs1;
                ex_inst        <= id_inst;
            end
        end
    end

endmodule