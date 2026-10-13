// tick_gen.v -- one slow time base for the whole design.
//
// Everything that used to keep its own wide cycle counter (five switch
// debouncers, the power-on reset, the game tick, the panel power-up and
// wake-up delays) now shares this single 2**DIV_BITS cycle counter and its
// 1-cycle tick.  On the ForgeFPGA that is the difference between fitting and
// not: the SLG47910 has 140 CLBs with one 4-bit carry chain each (SLG47910
// datasheet Rev 1.05, "Configurable Logic Block" section), so every wide
// counter or comparator costs a CLB outright.
//
// At 50 MHz the default DIV_BITS = 16 gives a tick every 1.31072 ms; the
// nominal oscillator tolerance (43.495-54.110 MHz over -40..+85 C) moves
// that to 1.21-1.51 ms, which is why the constants below are written as
// counts of ticks rather than of nanoseconds.
//
// DEPTH
// =====
// A single 16-bit up-counter plus a 16-bit equality decode is the deepest
// structure in the design when the arithmetic is mapped to LUTs: the
// vendor place-and-route reports the decode as five LUT levels (see
// docs/TIMING.md), i.e. about 20 ns, and that tick reaches every enable in
// the design.  Splitting the counter in two bytes and taking the tick from
// the top bit's rising edge instead of from a full equality keeps every
// cone at three LUT levels:
//
//   * the low byte wraps every 2**LO_BITS cycles and is one 8-bit
//     increment (two levels) with an 8-input AND for the wrap (two levels);
//   * the high byte only advances when the low byte wraps, so its
//     increment has a whole low-byte period to settle;
//   * the top bit of the high byte rises once every 2**DIV_BITS cycles,
//     and one delayed copy of it detects the edge in a single LUT.
//
// The period is unchanged: 2**DIV_BITS cycles, one-cycle pulse.

`default_nettype none

module tick_gen #(
    parameter integer DIV_BITS = 16     // 2**16 / 50 MHz = 1.31072 ms
) (
    input  wire clk,
    output reg  tick
);

    localparam integer LO_BITS = (DIV_BITS + 1) / 2;   // 8 for DIV_BITS=16
    localparam integer HI_BITS = DIV_BITS - LO_BITS;   // 8

    // Deliberately not reset: configuration logic comes up holding zero, so
    // the counter free-runs from configuration time.  Keeping the reset out
    // also keeps reset_gen from depending on the tick it depends on.
    reg [LO_BITS-1:0] lo = {LO_BITS{1'b0}};
    reg [HI_BITS-1:0] hi = {HI_BITS{1'b0}};
    reg               top_d = 1'b0;

    wire lo_wrap = &lo;
    wire top     = hi[HI_BITS-1];

    always @(posedge clk) begin
        lo <= lo + 1'b1;
        if (lo_wrap)
            hi <= hi + 1'b1;
        top_d <= top;
        tick  <= top & ~top_d;
    end

endmodule

`default_nettype wire
