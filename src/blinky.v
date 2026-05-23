// =============================================================================
// blinky.v - LED Blink Test for Tang Primer 25K
// =============================================================================
// Purpose: Verify FPGA toolchain setup by blinking LEDs.
//          LED[0] blinks at ~1Hz, LED[1] blinks at ~2Hz.
// Clock:   50 MHz (20 ns period)
// =============================================================================

module blinky (
    input  wire       clk,       // 50 MHz system clock
    input  wire       rst_btn,   // Reset button (active high)
    input  wire       user_btn,  // User button (active high)
    output reg  [1:0] led        // 2x onboard LEDs
);

    // =========================================================================
    // 50 MHz / 2^25 ≈ 1.49 Hz  → LED[0] blinks ~1.5 Hz
    // 50 MHz / 2^24 ≈ 2.98 Hz  → LED[1] blinks ~3 Hz
    // =========================================================================
    reg [25:0] counter;

    always @(posedge clk) begin
        if (rst_btn) begin
            counter <= 26'd0;
            led     <= 2'b00;
        end else begin
            counter <= counter + 26'd1;

            // Normal mode: LEDs blink at different rates
            // Button pressed: both LEDs on (verify button works)
            if (user_btn) begin
                led <= 2'b11;
            end else begin
                led[0] <= counter[25];
                led[1] <= counter[24];
            end
        end
    end

endmodule
