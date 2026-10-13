// tt_um_pong.v -- Tiny Tapeout wrapper around the same Pong RTL.
//
// The FPGA build drives an SSD1306 panel over I2C and reads five switches
// from the Shrike Lite's PMOD header.  A Tiny Tapeout tile has 8 dedicated
// inputs, 8 dedicated outputs and 8 bidirectional pins, which is enough for
// the same interface: five switches, the open-drain I2C pair, the LED and a
// spare.  Nothing in src/ changes; this file only renames and inverts.
//
//   ui_in[0]   left paddle up      (active high here; on the board the
//   ui_in[1]   left paddle down     switches short to ground, so the RTL
//   ui_in[2]   right paddle up      takes them active low and this wrapper
//   ui_in[3]   right paddle down    inverts them back)
//   ui_in[4]   start
//   ui_in[7:5] unused
//
//   uio_in[0]  SCL readback
//   uio_in[1]  SDA readback
//   uio_oe     bit set = that uio is an output
//   uio_out    SCL/SDA pull-down; the external pull-ups do the rest
//              (UM10204 sec. 3.1.1, SSD1306 sec. 8.1.5.2)
//
//   uo_out[0]  LED, uo_out[1] spare, uo_out[7:2] unused
//
// ENA AND RST_N
// -------------
// pong_top has no reset or enable pin: it is a self-contained game whose
// reset_gen holds everything for the first 16 time-base ticks after
// configuration, which is the correct power-on behaviour on both targets.
// Tiny Tapeout nevertheless requires ena to be honoured, so ena and rst_n
// are folded into the switch inputs (both low = all switches released, the
// design sits in attract mode) and into the output enables.  That keeps the
// design's clocks un-gated, which is what a fabric-independent RTL file
// should do: no AND-gated clock, no second unsynchronised reset.

`default_nettype none

module tt_um_pong #(
    parameter integer DIV_BITS = 16
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire       live  = ena & rst_n;
    wire       scl_i = uio_in[0];
    wire       sda_i = uio_in[1];
    wire [4:0] btn_n = live ? ~ui_in[4:0] : 5'b11111;

    wire scl_oe, sda_oe, led;

    pong_top #(
        .DIV_BITS(DIV_BITS)
    ) u_pong (
        .clk          (clk),
        .clk_en       (),
        .i_btn_l_up_n (btn_n[0]),
        .i_btn_l_dn_n (btn_n[1]),
        .i_btn_r_up_n (btn_n[2]),
        .i_btn_r_dn_n (btn_n[3]),
        .i_btn_start_n(btn_n[4]),
        .i_scl        (scl_i),
        .o_scl        (),
        .o_scl_oe     (scl_oe),
        .i_sda        (sda_i),
        .o_sda        (),
        .o_sda_oe     (sda_oe),
        .o_led        (led),
        .o_led_oe     ()
    );

    // Never driven high: these are open-drain pulls, so the pad always
    // drives zero and uio_oe decides whether that zero reaches the pin
    // (the Tiny Tapeout convention for an open-drain bus).
    assign uio_out = {6'b0, 1'b0, 1'b0};
    assign uio_oe  = {6'b0, sda_oe & live, scl_oe & live};
    assign uo_out  = {6'b0, 1'b0, led & live};

endmodule

`default_nettype wire
