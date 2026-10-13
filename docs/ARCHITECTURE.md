# Architecture

## Target

Vicharak Shrike Lite: an RP2040 (which only carries the bitstream) plus a
Renesas ForgeFPGA **SLG47910V**, "Vicharak Lite / RP2040 version".  The
parts of the datasheet this design depends on, all from SLG47910
datasheet Rev 1.05:

| fact | where |
| --- | --- |
| 140 "Logic RBB" blocks, each with 8 five-input LUTs (usable as 4 six-input LUTs) and 8 flip-flops | "Logic/Memory Tile", resource table |
| 1120 LUT5 / 560 LUT6 / 1120 FF total, 19 GPIO | same |
| one 4-bit carry chain per configurable logic block | "Configurable Logic Block" |
| internal oscillator, 43.495-54.110 MHz over -40..+85 C at 1.71-1.89 V | sec. 3.3.4 |
| configuration is retained in OTP/flash and loaded by the RP2040 over SPI | "Configuration" |

`floorplanspec.fp` is `1K`, which the vendor flow reports as the entire
device (`184 IOBs, 140 Logic 6-LUT RBBs, 40 RBBs support RAM/SR`), so there
is no larger tile to move to: the design must fit in 140 blocks.

## Data path

```
                 tick_gen  (2**16 clocks -> 1 cycle tick, 1.31072 ms)
                     |
                     v
   buttons --> btn_debounce x5 --.
   (5)                           |
                                 v
                              pong_core   (game state, integer physics)
                                 |
                                 v
                              pong_render (1 pixel / clock)
                                 |
                                 v
                              pong_frame  (byte packing, page/col addressing)
                                 |
                                 v
                            ssd1306_ctrl  (init sequence, frame cadence)
                                 |
                                 v
                              i2c_master  (START/byte/ACK/STOP, 400 kHz)
                                 |
                              SCL/SDA (open drain)
```

One clock domain, one reset, no FIFOs, no RAM (the whole dot matrix is
streamed to the panel and never stored), and no vendor-specific
primitives: `src/` is stock Verilog-2005 that also elaborates for the
Tiny Tapeout ASIC wrapper in `asic/`.

## Why there is no framebuffer

The panel holds 128x64 = 1024 bytes.  Storing a frame would cost 1024
flip-flops of the device's 1120 - the entire budget - plus the read port
to send it.  Instead `pong_render` evaluates every drawing primitive at
each pixel as it is produced, one pixel per clock:

* two paddles: `(column - pad_x < 2) && (row - pad_y < 12)`,
* the ball: `(column - ball_x < 4) && (row - ball_y < 4)`,
* the centre line: a dashed pattern on the middle columns,
* four score digits: one shared 8x8 font ROM, addressed by
  `row[2:0]`/`col[2:0]` (all four slots are 4 (mod 8), so the low three
  bits are the glyph coordinate and `col[4]` picks the digit).

Each episode is one subtraction and a small compare, which is what makes
1024 evaluated pixels per frame affordable on this device.  A frame is
sent as 5 command bytes plus 128 column bytes per page, 8 pages = 1029
bytes = 27.4 ms at 337.8 kHz, i.e. 36.5 frames/s at a nominal 50 MHz
oscillator (`scripts/i2c_timing.py`).

## Time base

Every slow event in the design is a count of a single 1.31072 ms tick
(`tick_gen`, 2**16 clocks): the power-on reset (16 ticks, ~21 ms), the
five switch debouncers (8 ticks, ~10.5 ms), the game step (19 ticks,
24.9 ms), the point freeze (40 ticks), the game-over freeze (80 ticks),
and the panel's power-up and wake-up delays (76 ticks each).  One counter
and one comparator instead of eight, which on a device where a 20-bit
comparator is a whole logic block is the difference between fitting and
not fitting.

The tick is *not* reset, deliberately: configuration logic comes up
holding zero, and keeping `reset_gen`'s output out of `tick_gen`'s input
cone removes a combinational loop between the two.

Stated as counts of ticks rather than nanoseconds, the game keeps its
timing when the untrimmed oscillator drifts: 19 ticks is 24.9 ms at a
nominal 50 MHz, 28.6 ms at the 43.495 MHz end and 23.0 ms at 54.110 MHz,
i.e. 35-43 game steps per second.

## I2C

`i2c_master` is byte level: START, one byte plus ACK, STOP, with a
watchdog.  It never drives a line high - it either pulls it low or
releases it (`o_scl_oe`/`o_sda_oe`), which is what an open-drain bus needs
(UM10204 sec. 3.1.1, SSD1306 sec. 8.1.5.2).  SCL is held low for 71
clocks and high for 77, so at the fastest oscillator end the bus is 365.6
kHz with tLOW = 1312 ns, and at the slowest end 293.9 kHz with tLOW =
1632 ns: every value stays inside the Fast-mode minima and inside the
SSD1306's 2.5 us cycle-time limit across the whole oscillator tolerance
(`scripts/i2c_timing.py --check` asserts this at both ends).

The design runs the bus at 337.8 kHz nominal rather than the full 400 kHz
so that the worst-case oscillator still leaves the Fast-mode minimums
satisfied with margin; the panel is addressed in horizontal mode, so a
frame is a linear byte stream with no per-byte address overhead.

## The area diet

The device has 140 logic blocks, and the first complete version of this
design did not fit.  What changed, in order of how much it bought:

1. **Integer physics instead of Q8.4 sub-pixel.**  A 13-bit adder or
   comparator costs a whole block once mapped to carry chains; the
   sub-pixel arithmetic alone used 95 of 140.  Integer positions and
   velocities made the design placeable for the first time, at the cost
   of a four-slope trajectory set (0, 26.6, 45, 63.4 degrees) and a
   quantised bounce angle, both quantified in docs/PHYSICS.md.
2. **One font ROM, not four.**  `off = col[2:0] ^ 3'b100`, `ones =
   col[4]`, one 4-way digit mux: 26 LUTs total for all four scores.
3. **Shared arithmetic.**  One 7-bit subtractor serves both paddles'
   impact offsets, one period comparator serves all eleven I2C states.
4. **Span tests as one subtraction.**  `(col - x < W)` instead of
   `col >= x && col < x+W`.
5. **Blocking-assignment style with unconditional arithmetic.**  The core
   computes every candidate and only gates the register writes; wrapping
   the arithmetic in `if (state == ...)` made the synthesiser duplicate
   the state term into every mux and cost 47 LUTs.

Final synthesis (`fpga/ffpga/build/post_synth_report.txt`): 985 cells,
342 flip-flops, 573 LUTs (2 LUT1, 142 LUT2, 84 LUT3, 61 LUT4, 86 LUT5,
198 LUT6), 48 MUXF7, 10 MUXF8, 7 inverters, **no carry cells at all**.
Place and route: 91.4% of the logic blocks, 87.7% of the LUTs, 48.6% of
the flip-flops.

## The FPGA flow

`fpga/` is the shrike-gen flow (Vicharak, MIT) with three deliberate
changes, each of which is a measurement rather than a preference:

* `ABC_PASS ?= -nocarry` - carry chains do not fit (docs/TIMING.md).
* `PLACER_VER ?= v22c` - use the v22 placer binary with the v23 support
  files; the v23 binary's MinPlacer aborts on the 1K tile, and the v22
  directory ships no `sdf_dly/`.
* `TMPDIR ?= $(CURDIR)/tmp` - `eda-placer` writes large scratch logs.

`make -C fpga update` regenerates `io_spec_in.txt` and `Pong.ffpga` from
the pin map; `make -C fpga build` runs yosys v59 from the Renesas
package, the placer, and `gen_bitstreams.py`, leaving
`FPGA_bitstream_MCU.bin` (46 408 bytes), `_OTP.bin` and `_FLASH_MEM.bin`
in `fpga/ffpga/build/bitstream/`.

**Honest limitation:** ForgeFPGA place-and-route is proprietary.  The
synthesis, simulation, lint and Python verification half of this flow is
open source and reproducible, but the bitstream itself comes from the
free-of-charge Renesas Go Configure Software Hub, which is available as a
public Debian package and can be run headless.  There is no open
bitstream path for the SLG47910, and this repository does not claim one.
The open-process path, for a *different* chip, is in docs/FAB.md.
