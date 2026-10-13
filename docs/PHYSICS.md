# Physics

The game is 128x64 pixels and a ball 4 pixels across, so the interesting
question is not "how do I write a physics engine" but "how do I keep the
arithmetic small enough for 140 logic blocks".  `scripts/physics.py` is the
golden model, the checker, and the place where every model decision is
written down with the textbook it comes from.  It is not a description of
the RTL; it is an independent implementation that `sim/tb_core.v` is
compared against tick for tick.

## The model

Ball position is an integer pixel coordinate, velocity an integer number
of pixels per game tick:

```
x[n+1] = x[n] + vx        vx in {-2,-1,+1,+2} px/tick
y[n+1] = y[n] + vy        vy in {-2,-1,0,+1,+2} px/tick
```

One game tick is 19 time-base ticks = 24.9037 ms at the nominal 50 MHz
oscillator, i.e. 40.16 steps/s.

### Why integers

The first version carried a Q8.4 sub-pixel position and a Q4.4 velocity.
On the SLG47910 that is unaffordable: each CLB has exactly one 4-bit carry
chain (datasheet Rev 1.05, "Configurable Logic Block"), so a 13-bit
comparator costs the LUT capacity of a whole CLB, and the sub-pixel
arithmetic alone used 95 of the device's 140 carry chains.  The design
could not be placed at all.  Integer positions need one 9-bit and one
8-bit adder, and they make every operation in the RTL exact.

The cost of that decision is the *trajectory set*: with `vx` and `vy` from
small integer sets, the ball can only leave a paddle at

```
0 degrees, atan(1/2) = 26.565 degrees, 45 degrees, atan(2/1) = 63.435 degrees
```

and the exact outgoing angle depends on where the ball hit the paddle
(centre / middle / edge zone).  That rule is a piecewise-constant
approximation of the proportional model `tan(theta) = offset /
half_height`; `physics.py` bounds the error over every reachable impact and
finds a worst case of 26.57 degrees at `vx = 1, d = -2`, which is inherent
to a four-slope set rather than a bug.  Getting it below that needs a
sub-pixel `vy`, and the device does not have room for it.  This is stated
plainly rather than hidden behind "arcade feel".

## The checks, and where they come from

`python3 scripts/physics.py --check` prints all of them; the summary lines
are:

| check | result | basis |
| --- | --- | --- |
| time base | 19 x 1.31072 ms = 24.9037 ms -> 40.155 steps/s; 34.9-43.5 steps/s across the oscillator tolerance | SLG47910 Rev 1.05 sec. 3.3.4 for the oscillator range |
| integer state | 4000 ticks, 3474 free steps each moving exactly `|vx|` px, 526 collision/serve/wall ticks, 8 distinct `(vx, vy)` pairs | exactness of integer add/subtract: B. Parhami, *Computer Arithmetic: Algorithms and Hardware Designs*, 2nd ed., ch. 4 |
| integration | between collisions the step is exact, so there is no integrator error to bound; one forward-Euler step per tick reproduces `x(t) = x0 + vx*t` exactly at the tick boundaries | D. Millington, *Game Physics Engine Development*, 2nd ed. sec. 3.2-3.4; D. H. Eberly, *Game Physics*, 2nd ed. sec. 3.3 |
| reflection | incidence == reflection exactly, because the RTL reverses the normal component and leaves the tangential one alone; the worst *exit row* difference against a mirrored reflection is 2.00 px, one step, because the RTL clamps to the wall instead of mirroring the overshoot | R. A. Serway & J. W. Jewett, *Physics for Scientists and Engineers*, 9th ed., law of reflection |
| no tunnelling | the x window where the ball's span overlaps a paddle is `[1,5]` and `[119,123]`, 5 px wide, and the largest x step is 2 px, so the shortest step that could clear a window is `5 + 4 - 1 = 8` px; an exhaustive walk over every start and every step up to 3 px finds no cleared window, and the 15 px y window is wider than the largest 4 px full step | discrete collision detection; the same argument as swept-vs-discrete collision in Millington sec. 3.5 and Eberly sec. 3.4 |
| zone quantisation | reachable slopes 0 / 26.565 / 45 / 63.435 degrees, worst error 26.57 degrees | the four-slope set above |
| discrete vs continuous | 36 direction changes probed, worst wall position lag 1 px, bounded by one step | as above |
| geometry | field rows 8..63, serve at (62,34), paddles at x=4 and x=122, paddle travel rows 8..52 | `src/pong_core.v` constants |

## The constants

Mirrored from `src/pong_core.v`, and the trace comparison is what keeps the
two copies honest:

```
TICK_TICKS = 19      SPEED_MAX = 2       POINT_TICKS = 40   OVER_TICKS = 80
WIN_SCORE  = 10      BOT       = 60      PAD_Y_MIN   = 8    PAD_Y_MAX  = 52
SERVE_X    = 62      SERVE_Y   = 34      PAD_INIT    = 30   BALL 4x4, PAD 2x12
HIT_L_X    = 6       HIT_R_X   = 118     XWIN_L = [1,5]     XWIN_R = [119,123]
YWIN = 7             ZONE_CTR = 1        ZONE_MID = 5
PAD_L_X = 4          PAD_R_X   = 122     PF_TOP = 8         PF_BOT = 63
```

## Two functions that were removed

* **Sub-pixel positions and velocities** (see above).
* **An attract-mode AI.**  The first version moved the paddles towards the
  ball while in attract mode; it cost comparator logic and, more
  importantly, made the demo depend on a second copy of the ball's
  position.  Attract mode now leaves the paddles at their initial rows and
  the demo ball bounces off them, which is what the 1972 cabinet's demo
  did anyway, and it removed a whole build of the ball's top and bottom
  edge from the paddle logic.
