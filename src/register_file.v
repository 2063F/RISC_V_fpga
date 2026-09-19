// =============================================================================
// register_file.v - 32x32-bit Register File for RISC-V RV32I CPU
// =============================================================================
// - 32 registers, each 32 bits wide (x0 through x31)
// - x0 is hardwired to zero (reads always return 0, writes are ignored)
// - 2 asynchronous read ports (combinational)
// - 1 synchronous write port (on rising clock edge)
// =============================================================================

module register_file (
    input  wire        clk,       // Clock
    input  wire        rst,       // Synchronous reset (active high)

    // Read port A (rs1)
    input  wire [4:0]  rs1,       // Register address for read port A
    output wire [31:0] rd1,       // Read data A

    // Read port B (rs2)
    input  wire [4:0]  rs2,       // Register address for read port B
    output wire [31:0] rd2,       // Read data B

    // Write port
    input  wire [4:0]  rd,        // Destination register address
    input  wire [31:0] wd,        // Write data
    input  wire        we,        // Write enable

    // Debug read port (always outputs x1 for FPGA monitoring)
    output wire [31:0] dbg_x1
);

    // =========================================================================
    // Register array: 32 registers × 32 bits
    // =========================================================================
    reg [31:0] regs [31:0];

    integer i;

    // =========================================================================
    // Synchronous write (with reset)
    // x0 write is silently ignored by the hardware (we && rd != 0 check)
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'd0;
        end else if (we && rd != 5'd0) begin
            regs[rd] <= wd;
        end
    end

    // =========================================================================
    // Asynchronous read
    // =========================================================================
    // regs[0] is held at zero by construction: reset clears it and the write
    // port above refuses to write x0, so nothing can ever disturb it. Reading
    // it out directly is therefore already correct, and it keeps a second mux
    // off the read path - the register file read sits on the critical path of
    // the design (instruction ROM -> register file -> ALU), so that mux cost
    // real frequency.
    //
    // The `rd != 5'd0` guard on the write is what actually protects x0. Do not
    // remove it.
    assign rd1    = regs[rs1];
    assign rd2    = regs[rs2];
    assign dbg_x1 = regs[1]; // Debug: always expose x1 for FPGA LED display

endmodule
