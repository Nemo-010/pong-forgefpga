// pong_core.v -- game state, paddle control and ball physics.
//
// INTEGER PHYSICS
// ===============
// Ball position is an integer pixel coordinate and velocity is an integer
// number of pixels per game tick:
//
//     x[n+1] = x[n] + vx          (one forward-Euler step per game tick)
//
// An earlier revision carried a Q8.4 sub-pixel position and a Q4.4 velocity.
// On the SLG47910 that is unaffordable: each CLB has exactly one 4-bit carry
// chain (SLG47910 datasheet Rev 1.05, "Configurable Logic Block"), so a
// 13-bit comparator or adder costs the LUT capacity of a whole CLB.  The
// sub-pixel arithmetic alone used 95 of the 140 carry chains in the device
// and the design could not be placed.  Integer positions need one 9-bit and
// one 8-bit adder and leave the classic Pong trajectory set:
//
//     vx in {-2,-1,+1,+2} px/tick,   vy in {-2,-1,0,+1,+2} px/tick
//
// so the ball leaves a paddle at one of four slopes: 0, atan(1/2) = 26.6,
// atan(1/1) = 45, atan(2/1) = 63.4 degrees.  The outgoing vy comes from
// where the ball struck the paddle (centre / middle / edge zone); that rule
// is a piecewise-constant approximation of the proportional model
// tan(theta) = offset / half_height and scripts/physics.py bounds the angle
// error over every reachable impact.
//
// REFLECTION
// ----------
// The top and bottom walls reverse vy and clamp the position to the wall.
// Clamping keeps the reflected direction exact and removes the one-pixel
// penetration a mirrored overshoot allows; the exit row then differs from
// the geometric reflection by at most one step, which scripts/physics.py
// reports.  The angle itself is untouched, so the law of reflection holds
// exactly in direction.
//
// NO TUNNELLING
// -------------
// The ball is BALL_W pixels wide and the paddle PAD_W pixels wide, so the
// set of ball positions whose span overlaps the paddle column is
//
//     left  paddle: nbx in [PAD_L_X-BALL_W+1, PAD_L_X+PAD_W-1] = [1,5]
//     right paddle: nbx in [PAD_R_X-BALL_W+1, PAD_R_X+PAD_W-1] = [119,123]
//
// Both windows are wider than the largest x step (SPEED_MAX = 2 px/tick),
// so the ball cannot cross a paddle plane between two ticks undetected.
// Vertically |vy| <= 2 < BALL_H, so the same holds for the walls.
// scripts/physics.py checks both exhaustively over the reachable grid.

`default_nettype none

module pong_core #(
    // 19 time-base ticks of 1.31072 ms = 24.9 ms -> 40.15 Hz at 50 MHz.
    parameter integer TICK_TICKS = 19,
    parameter integer BALL_W    = 4,
    parameter integer BALL_H    = 4,
    parameter integer PAD_W     = 2,
    parameter integer PAD_H     = 12,
    parameter integer PAD_L_X   = 4,
    parameter integer PAD_R_X   = 122,
    parameter integer PF_TOP    = 8,
    parameter integer PF_BOT    = 63,
    parameter integer SPEED_MAX   = 2,   // |vx| cap, px/tick
    parameter integer POINT_TICKS = 40,  // 1 s freeze after a point
    parameter integer OVER_TICKS  = 80,  // 2 s freeze at game over
    parameter integer WIN_SCORE   = 10
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,      // time-base tick from tick_gen

    input  wire        b_l_up,
    input  wire        b_l_dn,
    input  wire        b_r_up,
    input  wire        b_r_dn,
    input  wire        b_start_press,

    output wire [7:0]  o_ball_x,   // pixel, left edge of the ball
    output wire [6:0]  o_ball_y,   // pixel, top edge of the ball
    output wire        o_ball_vis,
    output wire [5:0]  o_pad_l_y,
    output wire [5:0]  o_pad_r_y,
    output wire [3:0]  o_sc_l_t,
    output wire [3:0]  o_sc_l_o,
    output wire [3:0]  o_sc_r_t,
    output wire [3:0]  o_sc_r_o,
    output wire        o_playing,
    output reg         o_tick
);

    localparam [1:0] ST_ATTRACT = 2'd0,
                     ST_PLAY    = 2'd1,
                     ST_POINT   = 2'd2,
                     ST_OVER    = 2'd3;

    localparam integer BOT       = PF_BOT - BALL_H + 1;      // 60
    localparam integer PAD_Y_MIN = PF_TOP;                   // 8
    localparam integer PAD_Y_MAX = PF_BOT - PAD_H + 1;       // 52
    localparam integer SERVE_X   = (128 - BALL_W) / 2;       // 62
    localparam integer SERVE_Y   = PF_TOP + ((PF_BOT - PF_TOP + 1 - BALL_H) / 2);
    localparam integer WIN_TENS  = WIN_SCORE / 10;
    localparam integer WIN_ONES  = WIN_SCORE % 10;
    localparam integer HIT_L_X   = PAD_L_X + PAD_W;          // 6
    localparam integer HIT_R_X   = PAD_R_X - BALL_W;         // 118
    // x windows where the ball span overlaps a paddle column (see above)
    localparam integer XWIN_L_LO = PAD_L_X - BALL_W + 1;     // 1
    localparam integer XWIN_L_HI = PAD_L_X + PAD_W - 1;      // 5
    localparam integer XWIN_R_LO = PAD_R_X - BALL_W + 1;     // 119
    localparam integer XWIN_R_HI = PAD_R_X + PAD_W - 1;      // 123
    // the y spans overlap iff |a| <= YWIN, a = paddle centre - ball centre
    localparam integer YWIN      = (BALL_H + PAD_H) / 2 - 1; // 7
    localparam integer ZONE_CTR  = 1;
    localparam integer ZONE_MID  = 5;

    reg [4:0]        tick_cnt;
    reg [1:0]        state;

    reg signed [8:0] bx, nbx;    // ball left edge, pixels (may be a little
                                 // outside the field just as it scores)
    reg [6:0]        by;         // ball top edge, always inside the field
    reg signed [7:0] nby;        // step result, signed until clamped
    reg signed [2:0] vx, nvx;    // px/tick, -SPEED_MAX..+SPEED_MAX
    reg signed [2:0] vy, nvy;
    reg [1:0]        speed;      // |vx|, 1..SPEED_MAX

    reg [5:0] pad_l, pad_r, nl, nr;
    reg [3:0] sc_l_t, sc_l_o, sc_r_t, sc_r_o;
    reg [5:0] point_cnt;
    reg [6:0] over_cnt;
    reg       serve_dir;         // 1 -> serve to the right
    reg       pt_l, pt_r;

    // One shared impact offset.  The ball can only meet the paddle it is
    // travelling towards, so a single 7-bit subtractor serves both ends.
    reg [5:0]        psel;       // new row of the paddle facing the ball
    reg signed [6:0] a;          // paddle centre row - ball centre row
    reg        [3:0] adoc;       // |a|, exact because a hit implies |a| <= 7
    reg signed [2:0] zone;
    reg              xhit, yhit;
    reg [8:0]        hnx;        // hit response: park row
    reg signed [2:0] hvx, hvy;   // hit response: outgoing velocity
    reg [1:0]        hsp;        // hit response: next speed

    always @(posedge clk) begin
        if (rst) begin
            tick_cnt  <= 5'd0;
            state     <= ST_ATTRACT;
            bx        <= SERVE_X;
            by        <= SERVE_Y[6:0];
            vx        <= -3'sd1;
            vy        <= 3'sd0;
            speed     <= 2'd1;
            pad_l     <= (PF_TOP + PAD_Y_MAX) >> 1;
            pad_r     <= (PF_TOP + PAD_Y_MAX) >> 1;
            sc_l_t    <= 4'd0;
            sc_l_o    <= 4'd0;
            sc_r_t    <= 4'd0;
            sc_r_o    <= 4'd0;
            point_cnt <= 6'd0;
            over_cnt  <= 7'd0;
            serve_dir <= 1'b1;
            o_tick    <= 1'b0;
        end else begin
            o_tick <= 1'b0;

            // the game advances one step per TICK_TICKS time-base ticks
            if (tick && (tick_cnt == TICK_TICKS - 1)) begin
                tick_cnt <= 5'd0;
                o_tick   <= 1'b1;

                // ----------------------------------------------------------
                // 1..3. ball step, paddles, collision and scoring
                // ----------------------------------------------------------
                // Everything below is computed unconditionally and only the
                // register writes are gated.  Putting the state test around
                // the arithmetic instead made the synthesiser duplicate the
                // state term into every mux inside and cost 47 LUTs.

                // --- ball step, walls ---------------------------------
                nbx = bx + vx;                            // 9-bit signed
                nby = $signed({1'b0, by}) + $signed(vy);  // 8-bit signed
                nvx = vx;
                nvy = vy;
                if (nby < PF_TOP) begin
                    nby = PF_TOP;
                    nvy = -vy;
                end else if (nby > BOT) begin
                    nby = BOT;
                    nvy = -vy;
                end

                // --- paddles ------------------------------------------
                nl = pad_l;
                nr = pad_r;
                if (b_l_up && !b_l_dn)      nl = pad_l - 2;
                else if (b_l_dn && !b_l_up) nl = pad_l + 2;
                if (b_r_up && !b_r_dn)      nr = pad_r - 2;
                else if (b_r_dn && !b_r_up) nr = pad_r + 2;
                if (nl < PAD_Y_MIN)  nl = PAD_Y_MIN[5:0];
                if (nl > PAD_Y_MAX)  nl = PAD_Y_MAX[5:0];
                if (nr < PAD_Y_MIN)  nr = PAD_Y_MIN[5:0];
                if (nr > PAD_Y_MAX)  nr = PAD_Y_MAX[5:0];

                // --- collision with the paddle the ball is heading for --
                psel = (vx < 3'sd0) ? nl : nr;
                // nby is in [PF_TOP, BOT] by now, so it is a plain 7-bit row
                // and a fits 7 bits signed
                a = $signed({1'b0, psel}) + 7'sd4
                    - $signed({1'b0, nby[6:0]});

                if (vx < 3'sd0)
                    xhit = (nbx >= XWIN_L_LO) && (nbx <= XWIN_L_HI);
                else
                    xhit = (nbx >= XWIN_R_LO) && (nbx <= XWIN_R_HI);
                yhit = (a >= -YWIN) && (a <= YWIN);

                // |a| <= YWIN = 7 when the spans overlap, so the low four
                // bits of a are the magnitude
                adoc = a[6] ? -a[3:0] : a[3:0];
                zone = (adoc <= ZONE_CTR) ? 3'sd0 :
                       (adoc <= ZONE_MID) ? 3'sd1 : 3'sd2;
                // the offset's sign picks the direction: a > 0 means the ball
                // struck above the paddle centre and leaves upwards
                hnx = (vx < 3'sd0) ? HIT_L_X : HIT_R_X;
                hvy = a[6] ? zone : -zone;
                hsp = (speed + 1'b1 > SPEED_MAX[1:0])
                      ? SPEED_MAX[1:0] : speed + 1'b1;
                hvx = (vx < 3'sd0) ? hsp : -$signed({1'b0, hsp});

                // --- score / demo reset -------------------------------
                pt_r = (nbx <= -BALL_W);      // whole ball past the left edge
                pt_l = (nbx >= 128);          // left edge past the right edge

                // ------------------------------------------------------
                if (state == ST_ATTRACT || state == ST_PLAY) begin
                    if (xhit && yhit) begin
                        // park on the paddle face and bounce off it
                        bx    <= hnx;
                        by    <= nby[6:0];
                        vx    <= hvx;
                        vy    <= hvy;
                        speed <= hsp;
                    end else if (state == ST_ATTRACT && (pt_l || pt_r)) begin
                        // demo: bounce back into the field, no score
                        bx <= SERVE_X;
                        by <= SERVE_Y[6:0];
                        vx <= -vx;
                        vy <= 3'sd0;
                    end else begin
                        bx <= nbx;
                        by <= nby[6:0];
                        vx <= nvx;
                        vy <= nvy;
                    end

                    if (state == ST_PLAY && (pt_l || pt_r)) begin
                        // BCD score increment (two digits, 0..99)
                        if (pt_l) begin
                            if (sc_l_o == 4'd9) begin
                                sc_l_o <= 4'd0;
                                sc_l_t <= sc_l_t + 1'b1;
                            end else begin
                                sc_l_o <= sc_l_o + 1'b1;
                            end
                        end else begin
                            if (sc_r_o == 4'd9) begin
                                sc_r_o <= 4'd0;
                                sc_r_t <= sc_r_t + 1'b1;
                            end else begin
                                sc_r_o <= sc_r_o + 1'b1;
                            end
                        end
                        state     <= ST_POINT;
                        point_cnt <= POINT_TICKS[5:0];
                        // next serve goes to the player who lost the point
                        serve_dir <= pt_l;
                    end
                end

                if (state == ST_PLAY) begin
                    pad_l <= nl;
                    pad_r <= nr;
                end

                // ----------------------------------------------------------
                // 4. state machine
                // ----------------------------------------------------------
                case (state)
                    ST_ATTRACT: begin
                        if (b_start_press) begin
                            sc_l_t <= 4'd0;
                            sc_l_o <= 4'd0;
                            sc_r_t <= 4'd0;
                            sc_r_o <= 4'd0;
                            bx     <= SERVE_X;
                            by     <= SERVE_Y[6:0];
                            vx     <= 3'sd1;
                            vy     <= 3'sd0;
                            speed  <= 2'd1;
                            serve_dir <= 1'b1;
                            state  <= ST_PLAY;
                        end
                    end

                    ST_PLAY: ;

                    ST_POINT: begin
                        if (point_cnt == 6'd0) begin
                            if ((sc_l_t == WIN_TENS[3:0] && sc_l_o == WIN_ONES[3:0]) ||
                                (sc_r_t == WIN_TENS[3:0] && sc_r_o == WIN_ONES[3:0])) begin
                                over_cnt <= OVER_TICKS[6:0];
                                state    <= ST_OVER;
                            end else begin
                                bx    <= SERVE_X;
                                by    <= SERVE_Y[6:0];
                                vx    <= serve_dir ? 3'sd1 : -3'sd1;
                                vy    <= 3'sd0;
                                speed <= 2'd1;
                                state <= ST_PLAY;
                            end
                        end else begin
                            point_cnt <= point_cnt - 1'b1;
                        end
                    end

                    ST_OVER: begin
                        if (over_cnt == 7'd0) begin
                            sc_l_t <= 4'd0;
                            sc_l_o <= 4'd0;
                            sc_r_t <= 4'd0;
                            sc_r_o <= 4'd0;
                            bx     <= SERVE_X;
                            by     <= SERVE_Y[6:0];
                            vx     <= -3'sd1;
                            vy     <= 3'sd0;
                            speed  <= 2'd1;
                            state  <= ST_ATTRACT;
                        end else begin
                            over_cnt <= over_cnt - 1'b1;
                        end
                    end

                    default: state <= ST_ATTRACT;
                endcase

            end else if (tick) begin
                tick_cnt <= tick_cnt + 1'b1;
            end
        end
    end

    assign o_ball_x   = bx[7:0];
    assign o_ball_y   = by;
    assign o_ball_vis = (state != ST_OVER) && (bx >= 0) && (bx <= 127);
    assign o_pad_l_y  = pad_l;
    assign o_pad_r_y  = pad_r;
    assign o_sc_l_t   = sc_l_t;
    assign o_sc_l_o   = sc_l_o;
    assign o_sc_r_t   = sc_r_t;
    assign o_sc_r_o   = sc_r_o;
    assign o_playing  = (state == ST_PLAY);

endmodule

`default_nettype wire
