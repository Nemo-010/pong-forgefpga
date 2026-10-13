`timescale 1ns/1ps
// tb_tick.v -- the time base must be one-cycle pulses spaced exactly
// 2**DIV_BITS clocks apart (the first pulse arrives early, at 2**(DIV_BITS-1),
// because the split counter starts from zero; nothing downstream cares, since
// reset_gen waits 16 of them before releasing reset).
module tb_tick;
  reg clk=0; wire tick; integer n=0, period=0, prev=0, seen=0;
  tick_gen #(.DIV_BITS(16)) dut(.clk(clk), .tick(tick));
  always #10 clk = ~clk;
  always @(posedge clk) begin
    n = n + 1;
    if (tick) begin
      seen = seen + 1;
      if (seen > 1) begin
        period = n - prev;
        if (period != 65536) begin $display("FAIL: period %0d", period); $finish; end
      end
      prev = n;
    end
    if (n > 400000) begin $display("tick period = %0d cycles over %0d ticks", period, seen); $finish; end
  end
endmodule
