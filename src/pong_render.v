// pong_render.v -- one pixel of the 128x64 frame.
//
// The display is written in horizontal addressing mode, so a byte of GDDRAM
// is eight vertically stacked pixels in one column: bit 0 is the top row of
// the page, bit 7 the bottom row.  The frame serialiser walks all 1024 bytes
// and asks this module for one pixel per clock, which is why the whole game
// needs no frame buffer at all -- only the handful of state registers.
//
// Geometry is passed in from pong_top so there is exactly one definition.
//
// AREA NOTE.  There is one font instance, not four.  The four score digit
// slots are 8 columns apart at 44/52/68/76, so all four bases are congruent
// to 4 modulo 8 and the within-glyph column is
//
//     off = col[2:0] ^ 3'b100
//
// for every slot; bit 4 of the column picks tens or ones, and one 4-way mux
// picks the digit.  Four font instances plus four 7-bit subtractors became
// one font plus a 4-input mux.

`default_nettype none

module pong_render #(
    parameter integer BALL_W   = 4,
    parameter integer BALL_H   = 4,
    parameter integer PAD_W    = 2,
    parameter integer PAD_H    = 12,
    parameter integer PAD_L_X  = 4,
    parameter integer PAD_R_X  = 122,
    parameter integer PF_TOP   = 8,
    parameter integer SC_L_T_X = 44,
    parameter integer SC_R_T_X = 68,
    parameter integer SC_SPAN  = 16,   // two 8-wide glyph slots per player
    parameter integer CENTER_X = 63
) (
    input  wire [2:0] page,
    input  wire [6:0] col,
    input  wire [2:0] pix_row,

    input  wire [7:0] ball_x,
    input  wire [6:0] ball_y,
    input  wire       ball_vis,
    input  wire [5:0] pad_l_y,
    input  wire [5:0] pad_r_y,
    input  wire [3:0] sc_l_t,
    input  wire [3:0] sc_l_o,
    input  wire [3:0] sc_r_t,
    input  wire [3:0] sc_r_o,

    output wire       pix
);

    wire [6:0] y = {page, pix_row};

    // Every test below is "pixel within a span", written as one subtraction
    // plus a small compare: (p - base) is inside [0, n-1] iff the unsigned
    // difference is below n.  A pixel before the span wraps to a large value
    // and fails the test on its own, so one subtractor covers both ends and
    // the wide comparators that would otherwise need carry chains are gone.
    wire [7:0] dx_b = col - ball_x;

    // ---- ball -------------------------------------------------------------
    wire ball_on = ball_vis && (dx_b < BALL_W) && (y - ball_y < BALL_H);

    // ---- paddles ----------------------------------------------------------
    wire pad_l_on = (col >= PAD_L_X) && (col < PAD_L_X + PAD_W) &&
                    (y - pad_l_y < PAD_H);
    wire pad_r_on = (col >= PAD_R_X) && (col < PAD_R_X + PAD_W) &&
                    (y - pad_r_y < PAD_H);

    // ---- dashed centre line ----------------------------------------------
    wire center_on = (col == CENTER_X) && (y >= PF_TOP) && !y[2];

    // ---- scores -----------------------------------------------------------
    // one font, four slots: tens/ones selected by column bit 4, player by
    // which half of the score row the column falls in
    wire score_row = (page == 3'd0);
    wire in_l = score_row && (col >= SC_L_T_X) && (col < SC_L_T_X + SC_SPAN);
    wire in_r = score_row && (col >= SC_R_T_X) && (col < SC_R_T_X + SC_SPAN);

    wire        ones  = col[4];
    wire [3:0]  digit = in_l ? (ones ? sc_l_o : sc_l_t)
                             : (ones ? sc_r_o : sc_r_t);
    wire [2:0]  off   = col[2:0] ^ 3'b100;

    wire g;
    pong_font u_font (.digit(digit), .col(off), .row(pix_row), .pix(g));

    wire score_on = g & (in_l | in_r);

    assign pix = ball_on | pad_l_on | pad_r_on | center_on | score_on;

endmodule

`default_nettype wire
