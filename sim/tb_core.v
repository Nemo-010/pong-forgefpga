// tb_core.v -- runs pong_core for 400 game ticks and dumps one line of
// state per tick.  The buttons come from a tiny deterministic autoplayer
// (see below) so that paddles, walls, points and the game-over path are
// all exercised.  scripts/compare_trace.py replays exactly the same
// autoplayer through the Python reference model in scripts/physics.py and
// compares the two traces line by line, so RTL and model have to agree
// tick for tick.

`timescale 1ns/1ps

module tb_core;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst = 1'b1;
    reg l_up = 0, l_dn = 0, r_up = 0, r_dn = 0, start = 0;

    wire        [7:0]  ball_x;
    wire        [6:0]  ball_y;
    wire               ball_vis;
    wire        [5:0]  pad_l_y, pad_r_y;
    wire        [3:0]  slt, slo, srt, sro;
    wire               playing;
    wire               tick;

    // the game tick is driven directly: every 4 clocks is one "time-base
    // tick", and TICK_TICKS=1 makes every one of those a game tick, so the
    // trace is one line per game tick exactly as before
    reg tb_tick = 1'b0;
    reg [3:0] div = 4'd0;
    always @(posedge clk) begin
        div <= div + 1'b1;
        tb_tick <= (div == 4'd3);
    end

    pong_core #(
        .TICK_TICKS(1)
    ) dut (
        .clk(clk), .rst(rst), .tick(tb_tick),
        .b_l_up(l_up), .b_l_dn(l_dn), .b_r_up(r_up), .b_r_dn(r_dn),
        .b_start_press(start),
        .o_ball_x(ball_x), .o_ball_y(ball_y), .o_ball_vis(ball_vis),
        .o_pad_l_y(pad_l_y), .o_pad_r_y(pad_r_y),
        .o_sc_l_t(slt), .o_sc_l_o(slo), .o_sc_r_t(srt), .o_sc_r_o(sro),
        .o_playing(playing),
        .o_tick(tick)
    );

    // ---------------------------------------------------------------
    // autoplayer.  Identical in scripts/physics.py: aim the paddle top
    // one pixel above the ball top, i.e. three pixels away from the
    // perfectly centred position, so every paddle contact is off-centre
    // and produces a vertical velocity.  Every 96th..128th tick the
    // player is "distracted" and runs away from the ball, which is what
    // makes points (and eventually a game over) happen at all.
    // ---------------------------------------------------------------
    reg [7:0] tc = 8'd0;
    always @(posedge tick) tc <= tc + 8'd1;

    wire lapse = (tc >= 8'd96) && (tc < 8'd128);

    reg [5:0] tgt;
    always @(*) begin
        tgt = (ball_y > 1) ? ball_y - 1 : 6'd0;
        if (lapse) begin
            // move away from the ball
            l_up = (ball_y > pad_l_y);
            l_dn = (ball_y < pad_l_y);
            r_up = (ball_y > pad_r_y);
            r_dn = (ball_y < pad_r_y);
        end else begin
            l_up = (tgt < pad_l_y);
            l_dn = (tgt > pad_l_y);
            r_up = (tgt < pad_r_y);
            r_dn = (tgt > pad_r_y);
        end
    end

    integer fd;
    integer t;

    initial begin
        fd = $fopen("out/core_trace.txt", "w");
        $fwrite(fd, "# tick ball_x ball_y ball_vis pad_l pad_r slt slo srt sro vx vy speed state playing\n");
        #200;
        rst = 1'b0;

        for (t = 0; t < 2000; t = t + 1) begin
            start = (t == 5);
            @(posedge tick);
            #1;
            $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    t, ball_x, ball_y, ball_vis, pad_l_y, pad_r_y,
                    slt, slo, srt, sro, $signed(dut.vx), $signed(dut.vy),
                    dut.speed, dut.state, playing);
        end
        $fclose(fd);
        $display("core trace written: out/core_trace.txt");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL: core simulation timeout");
        $finish;
    end

endmodule
