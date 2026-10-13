// btn_debounce.v -- synchroniser plus shift-register debounce.
//
// A mechanical contact bounces for 0.1 ms .. 10 ms (Horowitz & Hill, "The Art
// of Electronics", 3rd ed., sec. 9.6).  The pin is synchronised to clk first
// (metastability window: Harris & Harris, "Digital Design and Computer
// Architecture", ch. 3), then sampled once per time-base tick into a shift
// register.  The output only follows the input when every stage agrees, which
// takes STAGES ticks -- 8 ticks = 10.5 ms by default, longer than the
// worst-case bounce of the switches used here.
//
// The earlier integrator version needed a 20-bit counter and a 20-bit
// comparator per switch; this one is a shift register and a wide NOR, so all
// five switches together are cheaper than one of the old ones.
//
// scripts/debounce.py re-derives these numbers and asserts the margin.

`default_nettype none

module btn_debounce #(
    parameter integer STAGES = 8           // ticks of agreement required
) (
    input  wire clk,
    input  wire rst,
    input  wire tick,        // time-base tick
    input  wire btn_in,      // raw pin, active high (pressed = 1)
    output reg  level,       // debounced level
    output reg  pressed      // one-cycle pulse on a rising edge of `level`
);

    reg [1:0]            sync;
    reg [STAGES-1:0]     sr;
    reg                  level_d;

    always @(posedge clk) begin
        if (rst) begin
            sync    <= 2'b00;
            sr      <= {STAGES{1'b0}};
            level   <= 1'b0;
            level_d <= 1'b0;
            pressed <= 1'b0;
        end else begin
            sync <= {sync[0], btn_in};

            if (tick) begin
                sr <= {sr[STAGES-2:0], sync[1]};
                if (&sr)      level <= 1'b1;   // all stages high
                else if (!(|sr)) level <= 1'b0; // all stages low
            end

            level_d <= level;
            pressed <= level & ~level_d;
        end
    end

endmodule

`default_nettype wire
