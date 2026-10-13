// pong_frame.v -- turns the current game state into the 1024 byte GDDRAM
// stream, one byte at a time, with no frame buffer.
//
// Byte k of the frame is page k[9:7], column k[6:0].  Each byte needs eight
// pixels (bit 0..7), which are produced serially in eight clocks and shifted
// into the output register.  At 50 MHz and ~148 clocks per I2C byte there is
// an order of magnitude of slack, so the serial form costs almost nothing in
// area (~1 LUT per pixel term) and nothing in frame rate.

`default_nettype none

module pong_frame #(
    parameter integer BALL_W   = 4,
    parameter integer BALL_H   = 4,
    parameter integer PAD_W    = 2,
    parameter integer PAD_H    = 12,
    parameter integer PAD_L_X  = 4,
    parameter integer PAD_R_X  = 122,
    parameter integer PF_TOP   = 8,
    parameter integer SC_L_T_X = 44,
    parameter integer SC_R_T_X = 68,
    parameter integer SC_SPAN  = 16
) (
    input  wire       clk,
    input  wire       rst,

    input  wire       req,        // one-cycle pulse: produce `index`
    input  wire [9:0] index,
    output reg  [7:0] byte_out,
    output reg        valid,      // stays high until the next req

    input  wire [7:0] ball_x,
    input  wire [6:0] ball_y,
    input  wire       ball_vis,
    input  wire [5:0] pad_l_y,
    input  wire [5:0] pad_r_y,
    input  wire [3:0] sc_l_t,
    input  wire [3:0] sc_l_o,
    input  wire [3:0] sc_r_t,
    input  wire [3:0] sc_r_o
);

    reg [9:0] idx;
    reg [2:0] bcnt;      // pixel row within the page
    reg [7:0] acc;
    reg       running;
    wire      pix;

    pong_render #(
        .BALL_W(BALL_W), .BALL_H(BALL_H),
        .PAD_W(PAD_W), .PAD_H(PAD_H),
        .PAD_L_X(PAD_L_X), .PAD_R_X(PAD_R_X),
        .PF_TOP(PF_TOP),
        .SC_L_T_X(SC_L_T_X), .SC_R_T_X(SC_R_T_X),
        .SC_SPAN(SC_SPAN)
    ) u_render (
        .page(idx[9:7]),
        .col(idx[6:0]),
        // rows are walked from 7 down to 0 so the byte can be built with a
        // plain shift register: the variable barrel shifter that turned bcnt
        // into a bit position cost about ten LUTs for no reason
        .pix_row(~bcnt),
        .ball_x(ball_x), .ball_y(ball_y), .ball_vis(ball_vis),
        .pad_l_y(pad_l_y), .pad_r_y(pad_r_y),
        .sc_l_t(sc_l_t), .sc_l_o(sc_l_o),
        .sc_r_t(sc_r_t), .sc_r_o(sc_r_o),
        .pix(pix)
    );

    always @(posedge clk) begin
        if (rst) begin
            idx      <= 10'd0;
            bcnt     <= 3'd0;
            acc      <= 8'h00;
            running  <= 1'b0;
            byte_out <= 8'h00;
            valid    <= 1'b0;
        end else if (req) begin
            idx      <= index;
            bcnt     <= 3'd0;
            acc      <= 8'h00;
            running  <= 1'b1;
            valid    <= 1'b0;
        end else if (running) begin
            if (bcnt == 3'd7) begin
                running  <= 1'b0;
                valid    <= 1'b1;
                byte_out <= {acc[6:0], pix};
            end else begin
                acc  <= {acc[6:0], pix};
                bcnt <= bcnt + 1'b1;
            end
        end else begin
            valid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
