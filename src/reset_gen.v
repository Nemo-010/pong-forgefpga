// reset_gen.v -- power-on reset, counted in time-base ticks.
//
// The SLG47910 has an internal POR, but the Yosys->eda-placer flow used here
// does not expose a reset net to the fabric, so the design makes its own.
// Configuration-logic FFs come out of configuration holding their `initial`
// value, so `rst` is high from configuration until HOLD_TICKS time-base
// ticks have gone by (16 ticks = 21 ms with the default 1.31 ms tick).
//
// For ASIC targets (see src/asic/) the wrapper uses the real reset pin and
// this module is not instantiated.

`default_nettype none

module reset_gen #(
    parameter integer HOLD_TICKS = 16      // 16 x 1.31072 ms = 21 ms
) (
    input  wire clk,
    input  wire tick,
    output reg  rst
);

    localparam integer CW = $clog2(HOLD_TICKS);
    localparam [CW-1:0] LAST = HOLD_TICKS - 1;

    reg [CW-1:0] cnt  = {CW{1'b0}};
    reg          done = 1'b0;

    initial rst = 1'b1;

    always @(posedge clk) begin
        if (!done) begin
            if (tick) begin
                if (cnt == LAST) begin
                    done <= 1'b1;
                    rst  <= 1'b0;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
