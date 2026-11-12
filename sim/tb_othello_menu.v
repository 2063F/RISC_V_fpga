`timescale 1ns / 1ps
// =============================================================================
// tb_othello_menu.v - Drives the Othello menu and a few moves through the 8x8
// matrix keyboard and checks the UART output
// =============================================================================
// Runs examples/othello_embedded/othello.hex on fpga_top with a model of the
// key matrix (kbd_row drives a row low, a pressed key pulls its column low):
//
//   1. key 9: sides become Black / White
//   2. key 8: you move second
//   3. key 1: level 1 - the AI (Black) moves first, then it is your turn
//   4. reset, key 7: two players (Red / Green again, the defaults); Red
//      plays d3 (key 20) and it is Green's turn
//
// Each step waits for a line of the UART output; a missing one times out.
// =============================================================================

module tb_othello_menu;

    parameter CLK_PERIOD  = 20;    // 50 MHz
    parameter BIT_NS      = 1_000_000_000 / 115200;
    parameter BIT_HALF_NS = BIT_NS / 2;

    reg        clk = 0;
    reg        rst_btn = 1;
    wire [1:0] led;
    wire       uart_tx_pin;
    wire [7:0] kbd_row;
    reg  [6:0] key = 0;            // pressed matrix key 1-64, 0 = none

    always #(CLK_PERIOD/2) clk = ~clk;

    // Key N sits at row (N-1)/8, column (N-1)%8; both lines are active-low.
    wire [2:0] key_row = (key - 7'd1) >> 3;
    wire [2:0] key_col = (key - 7'd1);
    wire [7:0] kbd_col = (key != 0 && !kbd_row[key_row]) ? ~(8'd1 << key_col) : 8'hFF;

    fpga_top #(
        .INIT_FILE("examples/othello_embedded/othello.hex")
    ) uut (
        .clk      (clk),
        .rst_btn  (rst_btn),
        .user_btn (1'b0),
        .led      (led),
        .uart_tx  (uart_tx_pin),
        .uart_rx  (1'b1),
        .kbd_row  (kbd_row),
        .kbd_col  (kbd_col)
    );

    // -------------------------------------------------------------------------
    // UART capture: the last 48 characters, newest in the low byte
    // -------------------------------------------------------------------------
    reg [8*48-1:0] tail = 0;
    reg [7:0]      data;
    event          got_char;
    integer        i;

    initial begin
        forever begin
            @(negedge uart_tx_pin);
            #(BIT_HALF_NS);
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                data[i] = uart_tx_pin;
            end
            #(BIT_NS + BIT_HALF_NS);
            $write("%c", data);
            tail = {tail[8*47-1:0], data};
            -> got_char;
        end
    end

    // Waits until the output ends with the n-character string s
    task wait_text(input [8*48-1:0] s, input integer n);
        reg [8*48-1:0] mask;
        begin
            mask = ({(8*48){1'b1}} >> (8*(48 - n)));
            while ((tail & mask) !== (s & mask))
                @(got_char);
        end
    endtask

    // Holds a matrix key for 4 ms. Done by a process of its own, so that the
    // caller can wait for the answer straight away and not miss lines printed
    // while the key is still down.
    reg [6:0] press_key = 0;
    event     do_press;

    initial forever begin
        @(do_press);
        key = press_key;
        #4_000_000;
        key = 0;
    end

    task press(input [6:0] k);
        begin
            press_key = k;
            -> do_press;
        end
    endtask

    integer step = 0;

    initial begin
        $display("=== Othello menu testbench ===");
        repeat (5) @(posedge clk);
        rst_btn = 0;

        step = 1;
        wait_text("a USB keyboard.\n", 16);
        press(9);
        wait_text("Sides: Black / White\n", 21);

        step = 2;
        wait_text("a USB keyboard.\n", 16);
        press(8);
        wait_text("you move: second\n", 17);

        step = 3;
        wait_text("a USB keyboard.\n", 16);
        press(1);
        wait_text("You are White and move second.\n", 31);
        wait_text("AI (Black) is thinking...\n", 26);
        wait_text("Black: 4  White: 1\n", 19);
        wait_text("Your move (White). Press a key (1-64) or type a square (e.g. d3).\n"
                 , 48);   // the last 48 characters of that line

        step = 4;
        rst_btn = 1;
        repeat (5) @(posedge clk);
        rst_btn = 0;
        wait_text("a USB keyboard.\n", 16);
        press(7);
        wait_text("Two players: Red moves first.\n", 30);
        wait_text("Red: 2  Green: 2\n", 17);
        wait_text("Red to move. Press a key (1-64) or type a square (e.g. d3).\n"
                 , 48);
        press(20);                                  // d3
        wait_text("Red played d3\n", 14);
        wait_text("Red: 4  Green: 1\n", 17);
        wait_text("Green to move. Press a key (1-64) or type a square (e.g. d3).\n"
                 , 48);

        #1_000_000;
        $display("\nALL TESTS PASSED!");
        $finish;
    end

    initial begin
        #2_000_000_000;     // 2 s
        $display("\nFAIL: timed out at step %0d", step);
        $finish;
    end

endmodule
