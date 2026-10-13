# Timing

`make fpga` finishes, the bitstream is real, and the vendor
place-and-route prints this:

```
              clk          clk   <UDEF_clk>           (auto) 2000            (0,1000)                  35132                     28.464
   - Propagation time:                      35133ps (64.8% logic, 35.2% route, logic stage 10)
   u_core.vy_FDRE_Q_D_LUT6_O_1/CLK                       (launch)
   u_core.serve_dir_LUT3_I0_O_LUT6_O_I3_LUT6_I3_O_LUT3_I1/CLK   (capture, 35133 ps later)
```

The FPGA's clock is not a design choice: the Shrike Lite's ForgeFPGA runs
from its internal oscillator, which Vicharak's documentation puts at
50 MHz ("The fpga has a internal oscillator connected to the logic fabric
and it gives out 50 Mhz clock", `verilog_style_guide.md`) and which the
SLG47910 datasheet Rev 1.05 sec. 3.3.4 specifies over temperature as
43.495-54.110 MHz.  That is a period of 18.5-23.0 ns.  **35.1 ns does not
fit in it.**  Ten logic levels at roughly 3 ns each is the whole story.

This file records what was measured, why the design is deep, what was
tried, and what will actually close it.  Nothing here is an estimate: every
number is copied from `fpga/ffpga/build/PNR_TIMING.log`,
`PNR_STDOUT.log` or `post_synth_report.txt` of a build that produced a
bitstream.

## Calibration: what one logic level costs on this fabric

| design | path | reported |
| --- | --- | --- |
| Vicharak `blink` sample (`shrike_gen/templates/main.v`) | 32-bit counter + 26-bit compare, mapped with carry chains | 110.840 MHz = 9.02 ns |
| this design, `-nocarry` | 10 LUT levels in the core | 28.464 MHz = 35.13 ns |

A carry-chain step costs about 0.5 ns; a LUT level costs about 1.8 ns plus
about 1.2 ns of interconnect, and there is about 5 ns of flip-flop
launch/capture overhead in the model.  Fitting 20 ns therefore allows
about five LUT levels between flip-flops, and 35.1 ns is ten levels plus
that overhead, so the vendor's numbers are internally consistent.
Whether its cell delays are worst-case or typical cannot be established
from the package, and no silicon was available; treat 28 MHz as the
analysed number and nothing better.

The corner selection flag made no difference: on the netlist from before
the time-base fix below, `-TIMING_ANALYSIS_CORNER` 0 through 5 all
reported the same 37 898 ps, even though `sdf_dly/T40ULP/` ships six
distinct libraries (tt/ss/ff x hot/cold).  The report is therefore one
delay model, not a corner sweep.

## Where the depth comes from

The design is deep because of a deliberate area decision.  On the
SLG47910 every CLB has exactly one 4-bit carry chain (datasheet Rev 1.05,
"Configurable Logic Block"), and the packer cannot put other logic into a
block that holds a carry chain.  Measured on this netlist:

| ABC options | logic RBBs | LUTs | fits? |
| --- | --- | --- | --- |
| `-abc9` (carry chains on) | 111.4% | 106.1% | no |
| `-abc9 -nocarry` | 104.3% | 87.9% | no |
| `-nocarry` (default) | **91.4%** | 87.7% | yes |
| `-nocarry -nowidelut` | 104.3% | 86.1% | no |
| `-nocarry -widemux 5` | 105.0% | 102.7% | no |

Carry chains make arithmetic fast but cost whole blocks, and there is no
room for them: the design needs the LUT-mapped form to fit, and the
LUT-mapped form is what makes a 7-bit subtractor three levels deep
instead of half a level.  `fpga/Makefile` has `ABC_PASS ?= -nocarry`
with this table in a comment, so the trade is visible where it is made.

The worst path itself is the ball physics chained through one clock:

```
vy (ball row velocity) -> nby = by+vy (with wall clamp) -> a = paddle+4-nby
   -> |a|/zone -> hvy -> vx -> and on into the serve direction
```

`scripts/physics.py` computes the same quantities in Python, which is why
the same structure is easy to read; the RTL simply does it all in one
clock because the game only advances once every 19 clocks, and that is
exactly the lever below.

## Fixes applied

1. **Time base split (applied).** `tick_gen` used a 16-bit up-counter and
   a 16-bit equality decode, which the vendor placer reported as five LUT
   levels feeding every enable in the design.  It is now two byte-wide
   counters with the tick taken from the top bit's rising edge, which is
   one level, and the period is unchanged.  Achievable frequency went
   26.387 -> 27.299 MHz and logic RBB usage 92.9% -> 90.0%.
2. **One period comparator in the I2C master (applied).** Eight per-state
   7-bit comparators became one, and the watchdog is now the top bit of a
   free-running counter instead of a 12-bit compare.  Together with the
   time-base fix that is 37 898 -> 35 133 ps and 92.9% -> 91.4% logic
   blocks, i.e. the ~7% of the clock period that came from structures
   which had nothing to do with the game.
3. **Integer physics (applied earlier).** The original Q8.4 sub-pixel
   position needed 95 of the device's 140 carry chains for the arithmetic
   alone and the design could not be placed at all.  Integer physics is
   what made the design fit in the first place; see docs/PHYSICS.md.
4. **`PLACER_VER=v22c` (applied).** The flow must use the v22 placer
   *binary* (v23's MinPlacer aborts on the 1K tile with `Nnet index 2 has
   duplicates clk and clk_ADJN`) inside a copy of the v23 *support*
   directory, because v22's own directory has no `sdf_dly/`.  Without
   that, the placer prints "WARNING! SDF Delay directory not found!" and
   falls back to its own default delays.

## What will actually close it

None of these are done; they are the next steps, in the order I would try
them.

1. **Split the core's step into phases.** The core advances once every 19
   clocks (`TICK_TICKS = 19`), so it does not need to compute everything in
   one clock.  Computing the next ball row and next paddle rows in one
   clock, the impact offset and zone in the next, and the write-back in a
   third keeps every stage at four or five levels, which is exactly the
   budget.  Cost: about 50 more flip-flops (47.7% used now) and a re-run of
   everything in `sim/`, since the golden model compares per game tick and
   the pipeline still finishes inside one tick.  The risk is that more
   flip-flops cost logic blocks: 91.4% is tight, not comfortable.
2. **Multi-cycle path exceptions.** The placer accepts `-sdc` with
   `set_multicycle_path` (the option is listed in its usage text and the
   parser has "Created MCP(%d) exception:" messages), and the claim is
   true rather than a fiction here: `pong_core`'s registers only take a
   new value when `tick` is asserted, so 19 clocks are genuinely
   available.  It is not done because SDC objects have to be named in the
   packed netlist (the parser tries net, pin, then instance, and my probe
   with `u_core.*` matched pre-nets and produced 156 warnings), which
   makes the constraint fragile: every RTL edit renames the objects.  This
   is the cheapest route to a green number and the least durable.
3. **Carry chains for the three hot adders only.** Nine `CARRY4` cells is
   about 6% more logic blocks, which does not fit today (91.4% + 6%) but
   might after (1).  It has to be done with vendor primitives behind an
   `ifdef`, which is why it is last: it breaks the fabric-independent RTL
   that the Tiny Tapeout port wants.

## What the numbers do *not* say

* No silicon was measured; there is no oscilloscope trace, no on-board
  test and no vendor timing report on the real oscillator.
* The vendor delay model is not documented in the shipped package, so
  "35.1 ns" is only as good as the tool, and the tool's own default
  constraint is 2000 ps (500 MHz), which nothing on this fabric can meet.
* Timing closure is not the same as the design working: at 27 MHz the game
  runs at 21 frames/s and the I2C bus at 183 kHz, both legal, so a
  *single* violated path would show up as a glitch (a missed bounce, a
  wrong score) rather than as a dead panel.  That is a guess about the
  failure mode, and it is labelled as one: at 27.3 MHz the same design
  would run at roughly 20 frames/s on a 184 kHz bus, both legal.
