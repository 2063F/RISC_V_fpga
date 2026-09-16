`timescale 1ns / 1ps
// =============================================================================
// uart_rx.v - Simple UART Receiver module
// =============================================================================
// Features:
// - Baud Rate: 115200 bps (at 50 MHz clock)
// - Divisor: 50,000,000 / 115,200 = 434 (approx)
// - Protocol: 8 data bits, no parity, 1 stop bit (8N1)
// =============================================================================

module uart_rx (
    input  wire        clk,        // 50 MHz system clock
    input  wire        rst_n,      // Active low asynchronous reset
    input  wire        rx_pin,     // Serial input pin
    input  wire        rx_clear,   // Pulse to clear rx_ready (when CPU reads RX register)
    output reg  [7:0]  rx_data,    // Received byte data
    output reg         rx_ready    // 1 when data is available
);

    // Divisor parameter for baud rate generation
    localparam [15:0] CLK_DIV = 16'd434;
    localparam [15:0] CLK_DIV_HALF = 16'd217;

    // State machine encodings
    localparam [2:0] STATE_IDLE  = 3'b000,
                     STATE_START = 3'b001,
                     STATE_DATA  = 3'b010,
                     STATE_STOP  = 3'b011,
                     STATE_DONE  = 3'b100;

    reg [2:0]  state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  rx_shifter;

    // Double registers to prevent metastability
    reg rx_reg1, rx_reg2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_reg1 <= 1'b1;
            rx_reg2 <= 1'b1;
        end else begin
            rx_reg1 <= rx_pin;
            rx_reg2 <= rx_reg1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= STATE_IDLE;
            clk_count  <= 16'd0;
            bit_index  <= 3'd0;
            rx_shifter <= 8'd0;
            rx_data    <= 8'd0;
            rx_ready   <= 1'b0;
        end else begin
            // Manual clear of rx_ready flag when CPU reads
            if (rx_clear) begin
                rx_ready <= 1'b0;
            end

            case (state)
                STATE_IDLE: begin
                    clk_count <= 16'd0;
                    bit_index <= 3'd0;
                    if (rx_reg2 == 1'b0) begin // Start bit detected (falling edge)
                        state <= STATE_START;
                    end
                end

                STATE_START: begin
                    if (clk_count == CLK_DIV_HALF - 16'd1) begin
                        clk_count <= 16'd0;
                        if (rx_reg2 == 1'b0) begin // Verify start bit is still low
                            state <= STATE_DATA;
                        end else begin
                            state <= STATE_IDLE; // False start
                        end
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                STATE_DATA: begin
                    if (clk_count == CLK_DIV - 16'd1) begin
                        clk_count <= 16'd0;
                        rx_shifter[bit_index] <= rx_reg2;
                        if (bit_index == 3'd7) begin
                            state <= STATE_STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                STATE_STOP: begin
                    if (clk_count == CLK_DIV - 16'd1) begin
                        clk_count <= 16'd0;
                        if (rx_reg2 == 1'b1) begin // Verify stop bit is high
                            rx_data  <= rx_shifter;
                            rx_ready <= 1'b1;
                            state    <= STATE_DONE;
                        end else begin
                            state    <= STATE_IDLE; // Framing error, discard
                        end
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                STATE_DONE: begin
                    // Wait for line to go high before returning to IDLE (safeguard)
                    if (rx_reg2 == 1'b1) begin
                        state <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
