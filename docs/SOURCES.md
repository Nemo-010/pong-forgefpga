# Sources

Every number in this repository that is not a measurement of the code came
from one of the documents below.  Where a claim is a *measurement*, the
command or log file that produced it is named instead - that is the point
of writing this file down: a reader should be able to re-derive any claim
without trusting the prose.

## Primary documents

| document | revision / date | what is taken from it |
| --- | --- | --- |
| Renesas **SLG47910 datasheet** (ForgeFPGA, "GreenPAK"/ForgeFPGA family) | Rev 1.05 | 140 Logic RBBs, 8 five-input LUTs and 8 FFs per block, 1120 LUT5 / 560 LUT6 / 1120 FF, 19 GPIO; one 4-bit carry chain per CLB ("Configurable Logic Block"); internal oscillator **43.495-54.110 MHz** over -40..+85 C at 1.71-1.89 V (sec. 3.3.4); pin assignment table; configuration/OTP description |
| NXP **UM10204**, "I2C-bus specification and user manual" | rev. 6, 4 April 2014 | open-drain requirement (sec. 3.1.1); Fast-mode minima in Table 10: tLOW >= 1.3 us, tHIGH >= 0.6 us, tHD;STA >= 0.6 us, tSU;STO >= 0.6 us, 400 kbit/s, tR <= 300 ns |
| Solomon Systech **SSD1306** datasheet | rev 1.1 | 128x64 GDDRAM organisation and page/column addressing (sec. 8.7), I2C framing and the pull-up requirement (sec. 8.1.5.2), Table 13-6 timing (tcycle >= 2.5 us, tLOW >= 1.3 us, tHIGH >= 0.6 us) |
| Vicharak **Shrike Lite documentation** (`hardware_overview.md`, `verilog_style_guide.md`, `generating_your_first_bitstream.md`) | as published | "The fpga has a internal oscillator connected to the logic fabric and it gives out 50 Mhz clock"; `clk`/`clk_en` map to `OSC_CLK`/`OSC_EN`; the LED is on pin 16; the RP2040 only carries the bitstream |
| Vicharak **shrike-gen** (MIT) and the board's KiCad project `Shrike-lite.kicad_pcb` | vendored under `fpga/shrike_gen/` | the synthesis/place-and-route invocation, the bitstream container format and header, and the header-to-FPGA pin mapping used in `fpga/io_map.pcf` |

The datasheets themselves are not redistributed here.

## Textbooks and papers cited by the python checks

* B. Parhami, *Computer Arithmetic: Algorithms and Hardware Designs*, 2nd
  ed., ch. 4 - exactness of integer add/subtract (why the integer physics
  has no rounding-error term).
* D. Millington, *Game Physics Engine Development*, 2nd ed., sec. 3.2-3.4
  (integration) and sec. 3.5 (discrete vs swept collision detection).
* D. H. Eberly, *Game Physics*, 2nd ed., sec. 3.3-3.4.
* R. A. Serway & J. W. Jewett, *Physics for Scientists and Engineers*, 9th
  ed. - the law of reflection (why reversing only the normal component is
  exact).
* The 5x7 digit bitmaps in `scripts/font_gen.py` are the widely used public
  domain table (the one Adafruit GFX's `font5x7` carries).

## Measurements

Nothing in the repository is a remembered number.  The mechanical ones:

| claim | where it comes from |
| --- | --- |
| bitstream sizes (46 408 / 45 116 / 45 096 bytes) | `fpga/ffpga/build/bitstream/FPGA_bitstream_*.bin` |
| 91.4% logic RBBs, 87.7% LUTs, 48.6% FFs | `fpga/ffpga/build/PNR_STDOUT.log` |
| 985 cells, 342 FFs, 573 LUTs, no carry cells | `fpga/ffpga/build/post_synth_report.txt` |
| 35.1 ns worst path, 28.464 MHz | `fpga/ffpga/build/PNR_TIMING.log` |
| the `-abc9` / `-nocarry` / `-nowidelut` / `-widemux` fit table | measured with `fpga/tryfit.sh`, recorded in docs/TIMING.md and in the comment above `ABC_PASS` in `fpga/Makefile` |
| blink reference at 110.840 MHz | the same flow run on `fpga/shrike_gen/templates/main.v` |
| every I2C and physics number | `make all`, i.e. `scripts/i2c_timing.py --check` and `scripts/physics.py --check` |
| the 60-frame picture check | `scripts/frame_check.py out/frames.hex --all` |

## Tools

| tool | version | used for |
| --- | --- | --- |
| yosys | v59, from the Renesas Go Configure Software Hub package | synthesis (`synth_xilinx -nobram -noiopad -nodsp $(ABC_PASS)`) |
| eda-placer | v22 binary with the v23 support files ("v22c") | ForgeFPGA place and route |
| verilator | 5.034, same package | lint |
| iverilog | 13 (built from source for this container) | all simulation |
| python3 | 3.x | the checks, the golden model, the font and frame tools |

The Renesas package is downloaded from
`https://renesasweb-greenpak.s3.us-west-2.amazonaws.com/v6.55/go-configure-sw-hub-v6.55.001-debian-13-amd64.deb`
(public, no account needed).  `GCSW=` overrides where the Makefiles look for
it.
