// pong_top.v -- Shrike Lite (RP2040 + Renesas SLG47910V) top level.
//
// Pins (see fpga/io_map.pcf and docs/PINMAP.md):
//   clk       -> OSC_CLK    SLG47910 on-chip 50 MHz oscillator
//   clk_en    -> OSC_EN
//   I2C SCL/SDA on the 2x6 header (F_GPIO8 / F_GPIO9), open drain,
//   five switches on F_GPIO10..F_GPIO14 (active low, external pull-ups),
//   status LED on the on-board F_GPIO16 LED.
//
// The ForgeFPGA flow wants one output-enable net per output pin and a
// separate input net for anything read back (see Vicharak's Shrike Verilog
// style guide), so the pins are broken out as o_*_oe / i_* pairs instead of
// `inout`.  SDA/SCL are only ever pulled low or released, which is what an
// I2C bus wants; the output cells may be configured push-pull or open-drain
// in the IO planner, and the design is correct either way.

`default_nettype none

(* top *) module pong_top #(
    // display / playfield -------------------------------------------------
    parameter integer BALL_W   = 4,
    parameter integer BALL_H   = 4,
    parameter integer PAD_W    = 2,
    parameter integer PAD_H    = 12,
    parameter integer PAD_L_X  = 4,
    parameter integer PAD_R_X  = 122,
    parameter integer PF_TOP   = 8,
    parameter integer PF_BOT   = 63,
    // game ----------------------------------------------------------------
    parameter integer TICK_TICKS = 19,         // 19 x 1.31072 ms = 24.9 ms
    parameter integer SPEED_MAX  = 2,          // |vx| cap, px/tick
    // I2C, cycles at 50 MHz (scripts/i2c_timing.py recomputes and checks) --
    parameter integer T_LOW_CYC  = 71,         // 1420 ns
    parameter integer T_HIGH_CYC = 77,         // 1540 ns
    parameter integer T_BUF_CYC  = 71,         // 1420 ns
    parameter integer T_STA_CYC  = 35,         //  700 ns
    parameter integer T_STO_CYC  = 35,         //  700 ns
    // slow logic is counted in tick_gen ticks (1.31072 ms each), never in
    // clocks: a wide cycle counter costs a whole CLB on this device
    parameter integer DIV_BITS     = 16,       // tick = 2**16 clocks
    parameter integer HOLD_TICKS   = 16,       // ~21 ms power-on reset
    parameter integer DEBOUNCE     = 8,        // ~10.5 ms switch debounce
    parameter integer POR_TICKS    = 76,       // ~100 ms before SSD1306 init
    parameter integer AF_TICKS     = 76,       // ~100 ms after display-on
    parameter integer ERR_TICKS    = 8         // ~10 ms bus-error hold-off
) (
    (* iopad_external_pin, clkbuf_inhibit *) input  wire clk,
    (* iopad_external_pin *)                output wire clk_en,

    (* iopad_external_pin *) input  wire i_btn_l_up_n,
    (* iopad_external_pin *) input  wire i_btn_l_dn_n,
    (* iopad_external_pin *) input  wire i_btn_r_up_n,
    (* iopad_external_pin *) input  wire i_btn_r_dn_n,
    (* iopad_external_pin *) input  wire i_btn_start_n,

    (* iopad_external_pin *) input  wire i_scl,
    (* iopad_external_pin *) output wire o_scl,
    (* iopad_external_pin *) output wire o_scl_oe,
    (* iopad_external_pin *) input  wire i_sda,
    (* iopad_external_pin *) output wire o_sda,
    (* iopad_external_pin *) output wire o_sda_oe,

    (* iopad_external_pin *) output wire o_led,
    (* iopad_external_pin *) output wire o_led_oe
);

    assign clk_en = 1'b1;

    // SDA/SCL: never driven high.
    assign o_scl = 1'b0;
    assign o_sda = 1'b0;

    // ------------------------------------------------------------------
    // reset and switches
    // ------------------------------------------------------------------
    wire tick;
    tick_gen #(.DIV_BITS(DIV_BITS)) u_tick (
        .clk(clk),
        .tick(tick)
    );

    wire rst;
    reset_gen #(.HOLD_TICKS(HOLD_TICKS)) u_reset (
        .clk(clk), .tick(tick),
        .rst(rst)
    );

    wire b_l_up, b_l_dn, b_r_up, b_r_dn, b_start, b_start_press;
    wire unused_up, unused_dn, unused_ru, unused_rd;

    btn_debounce #(.STAGES(DEBOUNCE)) u_bt_lu (
        .clk(clk), .rst(rst), .tick(tick), .btn_in(~i_btn_l_up_n),
        .level(b_l_up), .pressed(unused_up));
    btn_debounce #(.STAGES(DEBOUNCE)) u_bt_ld (
        .clk(clk), .rst(rst), .tick(tick), .btn_in(~i_btn_l_dn_n),
        .level(b_l_dn), .pressed(unused_dn));
    btn_debounce #(.STAGES(DEBOUNCE)) u_bt_ru (
        .clk(clk), .rst(rst), .tick(tick), .btn_in(~i_btn_r_up_n),
        .level(b_r_up), .pressed(unused_ru));
    btn_debounce #(.STAGES(DEBOUNCE)) u_bt_rd (
        .clk(clk), .rst(rst), .tick(tick), .btn_in(~i_btn_r_dn_n),
        .level(b_r_dn), .pressed(unused_rd));
    btn_debounce #(.STAGES(DEBOUNCE)) u_bt_st (
        .clk(clk), .rst(rst), .tick(tick), .btn_in(~i_btn_start_n),
        .level(b_start), .pressed(b_start_press));

    // ------------------------------------------------------------------
    // game core
    // ------------------------------------------------------------------
    wire        [7:0]  g_ball_x;
    wire        [6:0]  g_ball_y;
    wire               g_ball_vis;
    wire        [5:0]  g_pad_l, g_pad_r;
    wire        [3:0]  g_slt, g_slo, g_srt, g_sro;
    wire               g_playing;
    wire               g_tick;      // one-cycle game-tick pulse (debug aid)

    pong_core #(
        .TICK_TICKS(TICK_TICKS),
        .BALL_W(BALL_W), .BALL_H(BALL_H),
        .PAD_W(PAD_W), .PAD_H(PAD_H),
        .PAD_L_X(PAD_L_X), .PAD_R_X(PAD_R_X),
        .PF_TOP(PF_TOP), .PF_BOT(PF_BOT),
        .SPEED_MAX(SPEED_MAX)
    ) u_core (
        .clk(clk), .rst(rst), .tick(tick),
        .b_l_up(b_l_up), .b_l_dn(b_l_dn),
        .b_r_up(b_r_up), .b_r_dn(b_r_dn),
        .b_start_press(b_start_press),
        .o_ball_x(g_ball_x), .o_ball_y(g_ball_y), .o_ball_vis(g_ball_vis),
        .o_pad_l_y(g_pad_l), .o_pad_r_y(g_pad_r),
        .o_sc_l_t(g_slt), .o_sc_l_o(g_slo),
        .o_sc_r_t(g_srt), .o_sc_r_o(g_sro),
        .o_playing(g_playing),
        .o_tick(g_tick)
    );

    // ------------------------------------------------------------------
    // frame snapshot: freeze the game state for the duration of a frame so
    // a game tick landing mid-transfer cannot tear the picture.
    // ------------------------------------------------------------------
    wire f_req, f_valid;
    wire [9:0] f_index;
    wire [7:0] f_byte;

    wire frame_start = f_req && (f_index == 10'd0);

    reg [7:0]  s_ball_x;
    reg [6:0]  s_ball_y;
    reg [5:0]  s_pad_l, s_pad_r;
    reg        s_ball_vis;
    reg [3:0]  s_slt, s_slo, s_srt, s_sro;

    always @(posedge clk) begin
        if (frame_start) begin
            s_ball_x   <= g_ball_x;
            s_ball_y   <= g_ball_y;
            s_ball_vis <= g_ball_vis;
            s_pad_l    <= g_pad_l;
            s_pad_r    <= g_pad_r;
            s_slt      <= g_slt;
            s_slo      <= g_slo;
            s_srt      <= g_srt;
            s_sro      <= g_sro;
        end
    end

    pong_frame #(
        .BALL_W(BALL_W), .BALL_H(BALL_H),
        .PAD_W(PAD_W), .PAD_H(PAD_H),
        .PAD_L_X(PAD_L_X), .PAD_R_X(PAD_R_X),
        .PF_TOP(PF_TOP)
    ) u_frame (
        .clk(clk), .rst(rst),
        .req(f_req), .index(f_index),
        .byte_out(f_byte), .valid(f_valid),
        .ball_x(s_ball_x), .ball_y(s_ball_y), .ball_vis(s_ball_vis),
        .pad_l_y(s_pad_l), .pad_r_y(s_pad_r),
        .sc_l_t(s_slt), .sc_l_o(s_slo),
        .sc_r_t(s_srt), .sc_r_o(s_sro)
    );

    // ------------------------------------------------------------------
    // I2C master + SSD1306 sequencer
    // ------------------------------------------------------------------
    wire m_start, m_send, m_stop, m_done, m_ack_ok, m_timeout;
    wire [7:0] m_byte;
    wire frame_active, init_done, bus_error;

    i2c_master #(
        .T_LOW_CYC(T_LOW_CYC), .T_HIGH_CYC(T_HIGH_CYC),
        .T_BUF_CYC(T_BUF_CYC), .T_STA_CYC(T_STA_CYC),
        .T_STO_CYC(T_STO_CYC)
    ) u_i2c (
        .clk(clk), .rst(rst),
        .cmd_start(m_start), .cmd_send(m_send),
        .cmd_byte(m_byte), .cmd_stop(m_stop),
        .busy(), .done(m_done), .ack_ok(m_ack_ok), .timeout(m_timeout),
        .scl_i(i_scl), .sda_i(i_sda),
        .scl_oe(o_scl_oe), .sda_oe(o_sda_oe)
    );

    ssd1306_ctrl #(
        .POR_TICKS(POR_TICKS), .AF_TICKS(AF_TICKS), .ERR_TICKS(ERR_TICKS)
    ) u_ctrl (
        .clk(clk), .rst(rst), .tick(tick),
        .m_start(m_start), .m_send(m_send), .m_byte(m_byte), .m_stop(m_stop),
        .m_done(m_done), .m_ack_ok(m_ack_ok), .m_timeout(m_timeout),
        .f_req(f_req), .f_index(f_index),
        .f_byte(f_byte), .f_valid(f_valid),
        .o_frame_active(frame_active), .o_init_done(init_done),
        .o_bus_error(bus_error)
    );

    // ------------------------------------------------------------------
    assign o_led    = g_playing;
    assign o_led_oe = 1'b1;

    // keep the unused-status nets from being optimised into nothing when a
    // debug build wants them; harmless in synthesis
    wire _unused = &{1'b0, init_done, bus_error, b_start, frame_active,
                     g_tick, unused_up, unused_dn, unused_ru, unused_rd,
                     &{1'b0, i_scl, i_sda}};

endmodule

`default_nettype wire
