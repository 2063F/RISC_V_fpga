`timescale 1ns / 1ps
// =============================================================================
// uart_tx.v - Simple UART Transmitter module
// =============================================================================
// Features:
// - Baud Rate: 115200 bps (at 50 MHz clock)
// - Divisor: 50,000,000 / 115,200 = 434 (approx)
// - Protocol: 8 data bits, no parity, 1 stop bit (8N1)
// =============================================================================

module uart_tx (
    input  wire        clk,        // 50 MHz system clock
    input  wire        rst_n,      // Active low asynchronous reset
    input  wire [7:0]  tx_data,    // Byte data to send
    input  wire        tx_start,   // Pulse to trigger transmission
    output reg         tx_pin,     // Serial output pin
    output reg         tx_busy     // 1 when transmitting, 0 when idle
);

    // Divisor parameter for baud rate generation
    localparam [15:0] CLK_DIV = 16'd434;

    // State machine encodings
    localparam [1:0] STATE_IDLE  = 2'b00,
                     STATE_START = 2'b01,
                     STATE_DATA  = 2'b10,
                     STATE_STOP  = 2'b11;

    reg [1:0]  state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  data_buffer;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= STATE_IDLE;
            clk_count   <= 16'd0;
            bit_index   <= 3'd0;
            data_buffer <= 8'd0;
            tx_pin      <= 1'b1; // Idle high
            tx_busy     <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    tx_pin  <= 1'b1;
                    tx_busy <= 1'b0;
                    if (tx_start) begin
                        data_buffer <= tx_data;
                        state       <= STATE_START;
                        clk_count   <= 16'd0;
                        tx_busy     <= 1'b1;
                    end
                end

                STATE_START: begin
                    tx_pin <= 1'b0; // Start bit
                    if (clk_count == CLK_DIV - 16'd1) begin
                        clk_count <= 16'd0;
                        state     <= STATE_DATA;
                        bit_index <= 3'd0;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                STATE_DATA: begin
                    tx_pin <= data_buffer[bit_index];
                    if (clk_count == CLK_DIV - 16'd1) begin
                        clk_count <= 16'd0;
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
                    tx_pin <= 1'b1; // Stop bit
                    if (clk_count == CLK_DIV - 16'd1) begin
                        clk_count <= 16'd0;
                        state     <= STATE_IDLE;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
