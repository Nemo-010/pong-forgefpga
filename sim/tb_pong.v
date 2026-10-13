// tb_pong.v -- full-system simulation: game + I2C + SSD1306 model.
//
// The I2C timing parameters are shortened so the simulation runs in seconds
// rather than hours; the real 50 MHz timing constants are exercised by
// tb_i2c_master.v.  The SSD1306 model dumps every complete frame it receives
// to out/frames.hex, which scripts/frame_dump.py turns into images.

`timescale 1ns/1ps

module tb_pong;

    reg clk = 1'b0;
    always #10 clk = ~clk;          // 50 MHz

    // active-low switches, pulled up on the board
    reg btn_l_up = 1'b1, btn_l_dn = 1'b1;
    reg btn_r_up = 1'b1, btn_r_dn = 1'b1;
    reg btn_start = 1'b1;

    wire o_scl_oe, o_sda_oe, o_led, o_led_oe;

    wire scl_bus = o_scl_oe ? 1'b0 : 1'b1;

    wire sda_low_m;
    wire sda_bus = (o_sda_oe | sda_low_m) ? 1'b0 : 1'b1;

    pong_top #(
        .T_LOW_CYC(6), .T_HIGH_CYC(6), .T_BUF_CYC(6),
        .T_STA_CYC(4), .T_STO_CYC(4),
        // short time base for simulation: 8 clocks per tick, 4 ticks per
        // game tick, and short init delays.  The real constants are checked
        // by scripts/i2c_timing.py and scripts/display_bandwidth.py.
        .DIV_BITS(3), .TICK_TICKS(4),
        .HOLD_TICKS(2), .DEBOUNCE(3),
        .POR_TICKS(4), .AF_TICKS(4), .ERR_TICKS(2)
    ) dut (
        .clk(clk), .clk_en(),
        .i_btn_l_up_n(btn_l_up), .i_btn_l_dn_n(btn_l_dn),
        .i_btn_r_up_n(btn_r_up), .i_btn_r_dn_n(btn_r_dn),
        .i_btn_start_n(btn_start),
        .i_scl(scl_bus), .o_scl(), .o_scl_oe(o_scl_oe),
        .i_sda(sda_bus), .o_sda(), .o_sda_oe(o_sda_oe),
        .o_led(o_led), .o_led_oe(o_led_oe)
    );

    wire [15:0] frame_count;
    wire        display_on;

    ssd1306_model #(
        .DUMP_FRAMES(64),
        .DUMP_FILE("out/frames.hex")
    ) u_panel (
        .scl(scl_bus), .sda(sda_bus),
        .sda_low(sda_low_m),
        .frame_count(frame_count),

        .display_on(display_on)
    );

    integer errors = 0;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("out/tb_pong.vcd");
            $dumpvars(1, tb_pong);
        end

        // wait for the controller to have initialised the panel
        wait (display_on == 1'b1);
        wait (frame_count >= 2);

        // press start -> match
        btn_start = 1'b0;
        #2000;
        btn_start = 1'b1;

        // pull the left paddle to the top so the ball gets past it
        wait (frame_count >= 4);
        btn_l_up = 1'b0;
        wait (frame_count >= 10);
        btn_l_up = 1'b1;

        // and the right paddle down for the next rally
        wait (frame_count >= 12);
        btn_r_dn = 1'b0;
        wait (frame_count >= 18);
        btn_r_dn = 1'b1;

        wait (frame_count >= 20);
        btn_l_dn = 1'b0;
        wait (frame_count >= 26);
        btn_l_dn = 1'b1;

        wait (frame_count >= 40);
        btn_r_up = 1'b0;
        wait (frame_count >= 48);
        btn_r_up = 1'b1;

        wait (frame_count >= 60);
        $display("frames captured: %0d", frame_count);
        if (frame_count < 40) begin
            $display("FAIL: too few frames");
            errors = errors + 1;
        end
        if (errors == 0) $display("PONG SIM: %0d frames rendered", frame_count);
        $finish;
    end

    initial begin
        #2_000_000_000;  // 2 s of simulated time is plenty
        $display("FAIL: simulation timeout (frames=%0d)", frame_count);
        $finish;
    end

endmodule
