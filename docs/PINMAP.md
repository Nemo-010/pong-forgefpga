# Pin map

The authoritative file is [`fpga/io_map.pcf`](../fpga/io_map.pcf); the
comments there derive every assignment from the board's KiCad layout
(`Shrike-lite.kicad_pcb`) and the SLG47910 datasheet Rev 1.05 pin table.
`make -C fpga update` turns it into the flow's `io_spec_in.txt`, so the
table below and the pcf cannot drift apart without the build noticing.

| signal | ForgeFPGA | SLG47910 pin | board | notes |
| --- | --- | --- | --- | --- |
| `clk` | `OSC_CLK` | - | internal | the device's own oscillator, ~50 MHz, 43.495-54.110 MHz over -40..+85 C (datasheet Rev 1.05 sec. 3.3.4) |
| `clk_en` | `OSC_EN` | - | internal | tied high in `pong_top`; the oscillator output is off without it |
| `i_btn_l_up_n` | `PIN_1_IN` | 1 (F_GPIO10) | J3 pin 8 | left paddle up |
| `i_btn_l_dn_n` | `PIN_2_IN` | 2 (F_GPIO11) | J3 pin 7 | left paddle down |
| `i_btn_r_up_n` | `PIN_3_IN` | 3 (F_GPIO12) | J3 pin 10 | right paddle up |
| `i_btn_r_dn_n` | `PIN_4_IN` | 4 (F_GPIO13) | J3 pin 9 | right paddle down |
| `i_btn_start_n` | `PIN_5_IN` | 5 (F_GPIO14) | J3 pin 12 | start / reset the match |
| `o_scl` / `o_scl_oe` / `i_scl` | `PIN_23` / `_OE` / `_IN` | 23 (F_GPIO8) | J3 pin 6 | I2C clock, open drain |
| `o_sda` / `o_sda_oe` / `i_sda` | `PIN_24` / `_OE` / `_IN` | 24 (F_GPIO9) | J3 pin 5 | I2C data, open drain |
| `o_led` / `o_led_oe` | `PIN_7` / `_OE` | 7 (F_GPIO16) | on-board LED D2 | lit while a match is running |

The unused F_GPIO15 (pin 6, J3 pin 11) is left free.

## Switches

Each switch goes from the header pin to ground, so the pad reads low when
pressed and `pong_top` inverts it (`i_btn_*_n`).  The design does not rely
on the FPGA's internal pull-up being enabled: the board's headers and the
switch wiring are what they are, and `btn_debounce` only needs the level to
be stable for 8 time-base ticks (~10.5 ms) to accept it.  Because the
switch is the only thing pulling the pad, an *unconnected* input floats and
will look like a stuck button; that is a wiring problem, not a design one.

## I2C bus

The SSD1306 breakout is the only other device on the bus.  `o_scl` and
`o_sda` are permanently 0 and the output-enable pins decide whether that 0
reaches the pad, so the FPGA only ever pulls a line **low** or lets it go;
the high level comes from pull-up resistors.  That is what UM10204
sec. 3.1.1 and the SSD1306 datasheet sec. 8.1.5.2 require, and it is also
why the `_OE` pins exist at all: the ForgeFPGA's output cells can be
configured push-pull, which would fight the panel.

**Requirement, not an assumption:** the bus needs pull-ups to 3.3 V.
The common 0.96" SSD1306 modules fit 4.7 kOhm, which gives tR of a few tens
of nanoseconds - comfortably inside the 300 ns Fast-mode rise-time limit
(UM10204 Table 10) - and `scripts/i2c_timing.py` checks the resulting
periods.  If the module has no pull-ups (some do not), add 4.7 kOhm from
each line to 3.3 V, or the bus will never rise and the panel will stay
blank.

Only 3.3 V logic is used on these two lines.  A 5 V module with a
regulator and level shifters (the usual "0.96 inch I2C OLED") works if its
pull-ups go to 3.3 V.

## LED

`o_led` is the on-board LED D2 through `o_led_oe`, driven by
`o_playing` (high while a match is in progress).  It is the only way to
tell "the FPGA is configured and running" from "the panel is not
answering" without a scope.
