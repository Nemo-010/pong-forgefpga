# Verification

`make all` runs everything below in about ten seconds.  The output pasted
here is the real output of the current tree, not a sketch.

```
$ make all
-- verilator lint
lint: clean
-- tb_i2c_master (UM10204 fast-mode timing)
ok: NACK detected for 0xEE
measured tLOW  min = 1420.0 ns (UM10204 Fm >= 1300)
measured tHIGH min = 1560.0 ns (UM10204 Fm >=  600)
measured tHD;STA    = 700.0 ns (UM10204 Fm >=  600)
measured tSU;STO    = 700.0 ns (UM10204 Fm >=  600)
I2C: ALL CHECKS PASSED
-- tb_tick (one-cycle tick every 2**16 clocks)
tick period = 65536 cycles over 6 ticks
-- tb_core + compare_trace (RTL vs golden model, 2000 ticks)
model trace written: out/model_trace.txt
RTL and model agree on all 2000 ticks (57 velocity changes, 11 state changes)
compare_trace: PASS
-- tb_pong (full design + SSD1306 model, 60 frames of I2C)
frames captured: 60
PONG SIM: 60 frames rendered
frame_check: PASS (60 frames)
-- tb_font (font ROM against scripts/font_gen.py)
font dump written: out/font_dump.txt
font: simulation dump matches the generator (10 digits, 8x8)
== all simulations passed ==
physics: ALL CHECKS PASSED
i2c_timing: ALL CHECKS PASSED
```

## What each test actually proves

| test | what it proves |
| --- | --- |
| `tb_i2c_master` | the bus is legal: START/STOP setup and hold times, SCL low/high times and the whole cycle time are measured from the RTL's own waveform and compared with UM10204 Fast-mode minima; a target that does not acknowledge raises `ack_ok = 0`; a stalled bus trips the watchdog |
| `tb_tick` | the shared time base produces exactly one pulse every 65536 clocks (the split counter did not change the period) |
| `tb_core` + `compare_trace.py` | the RTL and `scripts/physics.py` agree on every one of 2000 game ticks: ball position, both velocities, both paddle rows, the score, the state, and the visibility flag.  This is a whole-design equivalence check against an independent implementation, not a smoke test |
| `tb_pong` | the complete design (buttons, core, renderer, frame builder, panel controller, I2C) renders 60 real frames into a behavioural SSD1306 model over the real serial protocol, including the panel's init sequence and the ACK behaviour |
| `frame_check.py` | those 60 frames *are* a Pong screen: two 2x12 paddle blocks at the right columns, the column-63 centre line with the exact `!y[2]` dash pattern, a 4x4 ball block (through a paddle bounce, where the ball and paddle overlap), and four score cells that are each byte-for-byte one of the font generator's glyphs |
| `tb_font` + `font_gen.py --check` | the ROM in `src/pong_font.v` matches the generator, so hand edits cannot silently corrupt a digit |
| `physics.py --check` | the physics itself: exactness of the integer step, the reflection law, the no-tunnelling windows, the reachable slope set and its quantisation error, and the geometry |
| `i2c_timing.py --check` | every I2C timing value stays inside UM10204 and SSD1306 limits at *both* ends of the oscillator's specified range (43.495 and 54.110 MHz), and the watchdog outlasts one byte at the slowest clock |
| `verilator --lint-only` | no latches, no width or case problems, no unconnected or undriven logic beyond the documented exceptions |

## Deliberately silenced lint warnings

`make lint` passes `-Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-WIDTHEXPAND
-Wno-PINCONNECTEMPTY`.  Each is a conscious choice, not a way to hide a
problem:

* **WIDTHTRUNC** - module parameters are plain `integer`s, so every
  localparam expression is 32-bit and assigning it to a sized `reg` (for
  example `t_lim = T_HIGH_CYC - 1`) is a truncation of a constant whose
  value fits.  Sizing the parameters instead would change Verilog's
  signedness rules in `pong_core`'s comparisons, where an `integer`
  comparison is signed and a sized one might not be - a real bug traded
  for a cosmetic warning, so the parameters stay `integer` and the
  testbenches are what check the values.
* **BLKSEQ** - `pong_core` uses blocking assignments for its combinational
  temporaries inside the clocked block (the style Verilator warns about).
  The alternative, gating the arithmetic on the state, cost 47 more LUTs
  and the design no longer fitted; see docs/ARCHITECTURE.md.
* **WIDTHEXPAND** - widening is the harmless direction and is used
  deliberately for the signed arithmetic.
* **PINCONNECTEMPTY** - a few ports are intentionally unconnected, e.g.
  `pong_top`'s `o_scl` is tied low in the top module because the pad only
  ever pulls low.

## What is *not* verified

* **No hardware was run.**  No bitstream was loaded onto a Shrike Lite, no
  panel was driven, and no switch was pressed.  Everything here is
  simulation plus the vendor's place-and-route report.
* **Static timing is not closed at 50 MHz** - see docs/TIMING.md: the
  vendor placer's worst path is 35.1 ns (28.5 MHz) against an 18.5-23 ns
  clock.  This is the biggest open item and it is a *known* failure of the
  analysis, not an untested corner.
* **The bitstream is not verified as a bitstream.**  It is what the vendor
  flow emits for this netlist; its contents are checked only to the extent
  that the header magic (`11ff22aa`) and the file size are what the flow
  documents.
* **The panel model is behavioural.**  `sim/ssd1306_model.v` implements
  command/parameter framing, the addressing modes and the GDDRAM writes
  that this design uses; it does not model the panel's internal charge
  pump, timing margins or the real bus capacitance and rise times.
* **Real-world button bounce** is modelled as an ideal switch, so
  `btn_debounce`'s 10.5 ms window is verified against the *design's* rule,
  not against a particular switch's bounce profile.
* **The Python model is not a formal proof.**  `compare_trace.py` shows
  that two independent implementations agree for 2000 ticks of one
  deterministic schedule; it is strong evidence, not exhaustive.
