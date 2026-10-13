# pong-chip — Verilog Pong for a ForgeFPGA (Renesas SLG47910V)

A complete, self-contained Pong game in Verilog, small enough to fit the
ForgeFPGA on a Vicharak Shrike Lite, driving a 128x64 SSD1306 OLED over a
400 kHz open-drain I2C bus from five switches.  No CPU, no framebuffer, no
vendor primitives: one clock domain, a streaming renderer that produces one
pixel per clock, and arithmetic sized for a device that has 140 logic
blocks and one 4-bit carry chain per block.

Everything here is meant to be checkable: the RTL is compared tick for tick
against the Python model in `scripts/`, the I2C timing is asserted against
UM10204 and the SSD1306 datasheet over the oscillator's whole tolerance
range, and the FPGA flow produces a real ForgeFPGA bitstream.

```
make            # lint, every simulation, every python check
make fpga       # synthesis + place & route -> bitstream (see fpga/README)
make asic       # Tiny Tapeout wrapper elaborate + lint
```

## Status

| item | state |
| --- | --- |
| RTL + simulations | passing (`make all`) |
| ForgeFPGA bitstream | **builds** — `fpga/ffpga/build/bitstream/FPGA_bitstream_MCU.bin`, 46 408 bytes |
| Fits the device | yes — 91.4% of the 140 logic blocks, 87.7% of LUTs, 48.6% of FFs |
| Static timing at 50 MHz | **not closed** — the vendor placer reports a worst path of 35.1 ns (28.5 MHz) against the 18.5-23 ns the internal oscillator gives. Read [docs/TIMING.md](docs/TIMING.md) before trusting the bitstream on hardware; it has the paths, the reasons and the three ways to close it. |
| Bitstream tooling | proprietary (free) Renesas Go Configure Software Hub; there is no open bitstream path for the SLG47910. The synthesis and verification half of the flow is fully open. |

The honest summary: the design is complete, verified in simulation, and
it fits and produces a bitstream; the vendor place-and-route's static
timing analysis says the slowest path needs 35.1 ns while the FPGA's
internal oscillator gives 18.5-23 ns, so the *worst* paths may capture
late on silicon.  The analysis, the delay budget and the fixes are all
written down rather than hidden.

## What is in here

```
src/           the design (Verilog-2005, no vendor primitives)
  pong_top.v       pins, time base, reset, wiring
  tick_gen.v       one shared 1.31 ms time base (2**16 clocks)
  reset_gen.v      16-tick power-on reset
  btn_debounce.v   synchroniser + 8-tick debounce, one instance per switch
  pong_core.v      game state, integer physics, score, serve
  pong_render.v    one pixel per clock: paddles, ball, centre line, score
  pong_font.v      10 digits x 8x8, one ROM, four score slots share it
  pong_frame.v     pixel -> byte packing, page/column addressing
  ssd1306_ctrl.v   panel init sequence and frame cadence
  i2c_master.v     open-drain 400 kHz byte-level master
sim/           testbenches, plus a behavioural SSD1306 model
scripts/       python: golden model, physics checks, I2C budget, font, frames
fpga/          Makefile + shrike-gen flow -> ForgeFPGA bitstream
asic/          Tiny Tapeout wrapper and info.yaml
docs/          architecture, pin map, timing, verification, physics, fab
```

## Documentation

* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the design works and
  why it is shaped the way it is (the area diet, the streaming renderer).
* [docs/PINMAP.md](docs/PINMAP.md) — Shrike Lite PMOD J3 pin map, I2C
  pull-ups, switch wiring.
* [docs/TIMING.md](docs/TIMING.md) — the timing analysis, the measurements
  behind the `-nocarry` and placer choices, and how to close it.
* [docs/VERIFICATION.md](docs/VERIFICATION.md) — what is tested, with the
  actual output, and what is *not* tested.
* [docs/PHYSICS.md](docs/PHYSICS.md) — the integer physics and the
  textbook results the python checks assert.
* [docs/FAB.md](docs/FAB.md) — the open ASIC path and a survey of cheap
  prototyping shuttles with the date each entry was checked.
* [docs/SOURCES.md](docs/SOURCES.md) — every primary source used.

## Quick start

```sh
make                    # ~10 s: lint, 5 testbenches, physics + I2C checks
make fpga               # needs the Renesas toolchain, see fpga/Makefile
python3 scripts/physics.py --check
python3 scripts/i2c_timing.py --check
```

`GCSW=/path/to/go-configure-sw-hub/bin/external` overrides where `make fpga`
looks for `yosys/v59`, `eda-placer` and `verilator`.

## License

MIT for this repository; `fpga/shrike_gen/` is Vicharak's MIT-licensed
`shrike-gen` flow, kept as a vendored copy so the FPGA build is
reproducible.
