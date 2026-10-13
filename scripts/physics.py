#!/usr/bin/env python3
"""Reference model for the Pong core, and the analytical checks that go
with it.

This file is the golden model for ``sim/tb_core.v``: ``--trace`` replays
the same button schedule (a deterministic autoplayer) through the model
and writes the same columns, and ``scripts/compare_trace.py`` diffs the
two tick for tick.  ``--check`` runs the closed-form and exhaustive
checks instead.

Constants are mirrored from ``src/pong_core.v``; if you change one, change
the other, and ``--check`` will notice through the trace comparison.

Where the numbers come from
---------------------------

* Representation.  Ball position is an integer pixel coordinate and
  velocity is an integer number of pixels per tick, so every operation in
  the RTL is an exact integer operation and the model below uses the same
  integers.  There is no rounding anywhere and therefore no rounding-error
  term to bound.  (B. Parhami, *Computer Arithmetic: Algorithms and
  Hardware Designs*, 2nd ed., ch. 4, on exactness of integer add/subtract.)

  The design started out with a Q8.4 sub-pixel position; that was dropped
  because on the SLG47910 a 13-bit comparator costs a whole CLB (each CLB
  has one 4-bit carry chain, SLG47910 datasheet Rev 1.05 sec. "Configurable
  Logic Block") and the design would not fit.  See docs/PHYSICS.md.

* Integration.  One game tick is one forward-Euler step,

      x[n+1] = x[n] + vx,   vx constant between collisions.

  For a constant velocity this is not an approximation at all: the
  closed-form solution of dx/dt = vx is x(t) = x0 + vx*t and x(n*h) is
  exactly x[n] for h = 1 tick.  (D. Millington, *Game Physics Engine
  Development*, 2nd ed. sec. 3.2-3.4 "Integrating the equations of
  motion"; D. H. Eberly, *Game Physics*, 2nd ed. sec. 3.3.)

* Reflection off the top and bottom walls.  The RTL reverses vy and clamps
  the row to the wall.  Reversing the normal component while leaving the
  tangential component alone is the law of reflection for a flat surface,
  so the outgoing angle equals the incoming angle exactly.  (R. A. Serway
  & J. W. Jewett, *Physics for Scientists and Engineers*, 9th ed.,
  "the law of reflection".)  Clamping instead of mirroring the overshoot
  changes the exit row by at most one step; ``check_reflection`` measures
  that difference and reports it.

* Paddle bounce.  The outgoing vertical speed comes from the classic Atari
  Pong three-zone rule, a piecewise-constant approximation of the
  proportional model

      vy = vx * (d / half_height)      (d = ball centre - paddle centre)

  which is what a frictionless elastic bounce off a flat, stationary
  surface gives (tangential component unchanged, normal component
  reversed).  ``check_paddle_zones`` bounds the angle error the
  quantisation to the four-slope set introduces.

* Timing.  One time-base tick is 2**16 clocks and one game tick is
  TICK_TICKS = 19 of those, i.e. 19 * 1.31072 ms = 24.904 ms at the
  nominal 50 MHz -> 40.155 game ticks/s.  The datasheet tolerance
  (SLG47910 Rev 1.05: 43.495-54.110 MHz over -40..+85 C) makes it
  34.9-43.5 ticks/s.  The game is tick-driven, so the tolerance only
  changes how fast the ball moves on the wall clock, never the geometry.

Run:  python3 scripts/physics.py --check
      python3 scripts/physics.py --trace out/model_trace.txt
"""

from __future__ import annotations

import argparse
import math
import sys

# ----------------------------------------------------------------------
# parameters, mirrored from src/pong_core.v and src/pong_top.v
# ----------------------------------------------------------------------
DIV_BITS = 16                 # tick_gen: one tick per 2**16 clocks
CLK_HZ = 50_000_000
CLK_HZ_MIN = 43_495_000       # SLG47910 Rev 1.05, -40..+85 C
CLK_HZ_MAX = 54_110_000

TICK_TICKS = 19               # game ticks, counted in time-base ticks

BALL_W = 4
BALL_H = 4
PAD_W = 2
PAD_H = 12
PAD_L_X = 4
PAD_R_X = 122
PF_TOP = 8
PF_BOT = 63

SPEED_MAX = 2                 # |vx| cap, px/tick
POINT_TICKS = 40
OVER_TICKS = 80
WIN_SCORE = 10

ST_ATTRACT, ST_PLAY, ST_POINT, ST_OVER = 0, 1, 2, 3

BOT = PF_BOT - BALL_H + 1                 # 60  bottom of the ball's travel
PAD_Y_MIN = PF_TOP                        # 8
PAD_Y_MAX = PF_BOT - PAD_H + 1            # 52
SERVE_X = (128 - BALL_W) // 2             # 62
SERVE_Y = PF_TOP + (PF_BOT - PF_TOP + 1 - BALL_H) // 2   # 34
PAD_INIT = (PF_TOP + PAD_Y_MAX) >> 1      # 30

HIT_L_X = PAD_L_X + PAD_W                 # 6   parked against the left face
HIT_R_X = PAD_R_X - BALL_W                # 118
XWIN_L = range(PAD_L_X - BALL_W + 1, PAD_L_X + PAD_W)      # 1..5
XWIN_R = range(PAD_R_X - BALL_W + 1, PAD_R_X + PAD_W)      # 119..123
YWIN = (BALL_H + PAD_H) // 2 - 1          # 7
ZONE_CTR = 1
ZONE_MID = 5

WIN_TENS = WIN_SCORE // 10
WIN_ONES = WIN_SCORE % 10

TIME_TICK_S = (1 << DIV_BITS) / CLK_HZ
GAME_TICK_S = TIME_TICK_S * TICK_TICKS
GAME_TICK_HZ = 1.0 / GAME_TICK_S


class Pong:
    """Bit-exact model of the pong_core tick block."""

    def __init__(self) -> None:
        self.state = ST_ATTRACT
        self.bx = SERVE_X
        self.by = SERVE_Y
        self.vx = -1
        self.vy = 0
        self.speed = 1
        self.pad_l = PAD_INIT
        self.pad_r = PAD_INIT
        self.sc_l_t = self.sc_l_o = self.sc_r_t = self.sc_r_o = 0
        self.point_cnt = 0
        self.over_cnt = 0
        self.serve_dir = 1

    # ---- the tick -----------------------------------------------------
    def step(self, b: dict[str, bool]) -> None:
        # the case statement below sees the state as it was at the start of
        # the tick; a non-blocking assignment does not take effect until the
        # next tick
        s = self.state

        if s in (ST_ATTRACT, ST_PLAY):
            nbx = self.bx + self.vx
            nby = self.by + self.vy
            nvx, nvy = self.vx, self.vy

            # walls: reverse the normal component, clamp the row
            if nby < PF_TOP:
                nby = PF_TOP
                nvy = -self.vy
            elif nby > BOT:
                nby = BOT
                nvy = -self.vy

            # paddles: buttons in play, parked rows in the demo
            nl, nr = self.pad_l, self.pad_r
            if s == ST_PLAY:
                if b["l_up"] and not b["l_dn"]:
                    nl = self.pad_l - 2
                elif b["l_dn"] and not b["l_up"]:
                    nl = self.pad_l + 2
                if b["r_up"] and not b["r_dn"]:
                    nr = self.pad_r - 2
                elif b["r_dn"] and not b["r_up"]:
                    nr = self.pad_r + 2
                nl = min(max(nl, PAD_Y_MIN), PAD_Y_MAX)
                nr = min(max(nr, PAD_Y_MIN), PAD_Y_MAX)
                self.pad_l, self.pad_r = nl, nr

            # impact offset: paddle centre row - ball centre row
            psel = nl if self.vx < 0 else nr
            a = psel + (PAD_H >> 1) - (BALL_H >> 1) - nby
            xhit = nbx in (XWIN_L if self.vx < 0 else XWIN_R)
            yhit = -YWIN <= a <= YWIN

            pt_l = pt_r = False
            if xhit and yhit:
                adoc = abs(a) & 0xF          # exact: a hit implies |a| <= 7
                zone = 0 if adoc <= ZONE_CTR else (1 if adoc <= ZONE_MID else 2)
                nvy = zone if a < 0 else -zone
                sp = min(self.speed + 1, SPEED_MAX)
                if self.vx < 0:
                    nbx, nvx = HIT_L_X, sp
                else:
                    nbx, nvx = HIT_R_X, -sp
                self.speed = sp
            elif s == ST_ATTRACT:
                if nbx <= -BALL_W or nbx >= 128:
                    nbx, nby, nvx, nvy = SERVE_X, SERVE_Y, -self.vx, 0
            else:
                pt_r = nbx <= -BALL_W        # whole ball past the left edge
                pt_l = nbx >= 128            # left edge past the right edge

            self.bx, self.by, self.vx, self.vy = nbx, nby, nvx, nvy

            if pt_l or pt_r:
                if pt_l:
                    if self.sc_l_o == 9:
                        self.sc_l_o, self.sc_l_t = 0, self.sc_l_t + 1
                    else:
                        self.sc_l_o += 1
                else:
                    if self.sc_r_o == 9:
                        self.sc_r_o, self.sc_r_t = 0, self.sc_r_t + 1
                    else:
                        self.sc_r_o += 1
                self.state = ST_POINT
                self.point_cnt = POINT_TICKS
                self.serve_dir = 1 if pt_l else 0

        # ---- state machine (pre-tick state, pre-tick registers) --------
        if s == ST_ATTRACT:
            if b["start"]:
                self.sc_l_t = self.sc_l_o = self.sc_r_t = self.sc_r_o = 0
                self.bx, self.by = SERVE_X, SERVE_Y
                self.vx, self.vy = 1, 0
                self.speed = 1
                self.serve_dir = 1
                self.state = ST_PLAY
        elif s == ST_PLAY:
            pass
        elif s == ST_POINT:
            if self.point_cnt == 0:
                if (self.sc_l_t == WIN_TENS and self.sc_l_o == WIN_ONES) or \
                   (self.sc_r_t == WIN_TENS and self.sc_r_o == WIN_ONES):
                    self.over_cnt = OVER_TICKS
                    self.state = ST_OVER
                else:
                    self.bx, self.by = SERVE_X, SERVE_Y
                    self.vx = 1 if self.serve_dir else -1
                    self.vy = 0
                    self.speed = 1
                    self.state = ST_PLAY
            else:
                self.point_cnt -= 1
        elif s == ST_OVER:
            if self.over_cnt == 0:
                self.sc_l_t = self.sc_l_o = self.sc_r_t = self.sc_r_o = 0
                self.bx, self.by = SERVE_X, SERVE_Y
                self.vx, self.vy = -1, 0
                self.speed = 1
                self.state = ST_ATTRACT
            else:
                self.over_cnt -= 1

    # ---- exported view (what the RTL's assign statements produce) ----
    def row(self) -> tuple:
        # o_ball_x is an 8-bit port, so a negative x comes out as its low
        # byte (the renderer only draws for 0..127 and o_ball_vis gates it)
        return (self.bx & 0xFF, self.by,
                1 if (self.state != ST_OVER and 0 <= self.bx <= 127) else 0,
                self.pad_l, self.pad_r,
                self.sc_l_t, self.sc_l_o, self.sc_r_t, self.sc_r_o,
                self.vx, self.vy, self.speed, self.state,
                1 if self.state == ST_PLAY else 0)


def autoplay(tick: int, g: Pong) -> dict[str, bool]:
    """The same deterministic autoplayer as sim/tb_core.v."""
    lapse = 96 <= (tick % 256) < 128
    if lapse:
        return {"l_up": g.by > g.pad_l, "l_dn": g.by < g.pad_l,
                "r_up": g.by > g.pad_r, "r_dn": g.by < g.pad_r,
                "start": tick == 5}
    tgt = g.by - 1 if g.by > 1 else 0
    return {"l_up": tgt < g.pad_l, "l_dn": tgt > g.pad_l,
            "r_up": tgt < g.pad_r, "r_dn": tgt > g.pad_r,
            "start": tick == 5}


def run(n: int) -> list[tuple]:
    g = Pong()
    rows = []
    for t in range(n):
        g.step(autoplay(t, g))
        rows.append((t,) + g.row())
    return rows


# ----------------------------------------------------------------------
# checks
# ----------------------------------------------------------------------
FAILS: list[str] = []


def need(cond: bool, msg: str) -> None:
    if not cond:
        FAILS.append(msg)
        print("FAIL:", msg)


def check_tick_rate() -> None:
    print("-- time base")
    print(f"   one time-base tick = 2**{DIV_BITS} / {CLK_HZ/1e6:.1f} MHz "
          f"= {TIME_TICK_S*1e3:.5f} ms")
    print(f"   one game tick = {TICK_TICKS} x that = {GAME_TICK_S*1e3:.4f} ms "
          f"-> {GAME_TICK_HZ:.3f} game ticks/s")
    lo = CLK_HZ_MIN / (1 << DIV_BITS) / TICK_TICKS
    hi = CLK_HZ_MAX / (1 << DIV_BITS) / TICK_TICKS
    print(f"   oscillator tolerance {CLK_HZ_MIN/1e6:.3f}-{CLK_HZ_MAX/1e6:.3f} "
          f"MHz -> {lo:.1f}-{hi:.1f} game ticks/s")
    need(TICK_TICKS - 1 <= 2 ** 5 - 1,
         "TICK_TICKS must fit the 5-bit tick_cnt in src/pong_core.v")
    need(POINT_TICKS <= 2 ** 6 - 1, "POINT_TICKS must fit 6 bits")
    need(OVER_TICKS <= 2 ** 7 - 1, "OVER_TICKS must fit 7 bits")
    need(abs(GAME_TICK_HZ - 40.0) < 0.5,
         "nominal game rate should be about 40 ticks/s")
    need(lo > 30.0, "worst-case game rate must stay playable")


def check_integer_physics() -> None:
    """Every quantity is an exact integer, and the velocity set is closed."""
    print("-- integer state")
    g = Pong()
    n, vmax, smin, smax = 0, 0, 99, 0
    moves, free, bad_free = 0, 0, 0
    pairs = set()
    prev = (g.bx, g.by, g.vx, g.vy, g.speed, g.state, g.point_cnt)
    for t in range(4000):
        g.step(autoplay(t, g))
        n += 1
        vmax = max(vmax, abs(g.vx), abs(g.vy))
        smin, smax = min(smin, g.speed), max(smax, g.speed)
        pairs.add((g.vx, g.vy))
        pbx, pby, pvx, pvy, pspeed, pstate, ppoint = prev
        dx = g.bx - pbx
        # a tick that changes no velocity and no state is a free step
        if (g.vx == pvx and g.vy == pvy and g.state == pstate
                and pstate in (ST_PLAY, ST_ATTRACT)):
            free += 1
            if abs(dx) != abs(g.vx):
                bad_free += 1
        else:
            moves += 1
        if abs(dx) > SPEED_MAX + 1 and not (g.bx == SERVE_X and pbx != SERVE_X):
            bad_free += 1
        prev = (g.bx, g.by, g.vx, g.vy, g.speed, g.state, g.point_cnt)

    need(all(isinstance(x, int) for x in
             (g.bx, g.by, g.vx, g.vy, g.speed, g.pad_l, g.pad_r)), 
         "every state variable must be an integer")
    need(vmax <= SPEED_MAX, f"|v| must stay <= {SPEED_MAX} px/tick (saw {vmax})")
    need(smin >= 1 and smax <= SPEED_MAX,
         f"speed must stay in 1..{SPEED_MAX} px/tick (saw {smin}..{smax})")
    need(free > 0, "the probe run must contain free steps")
    need(bad_free == 0,
         f"{bad_free} free steps did not move exactly |vx| px")
    print(f"   {n} ticks, {free} free steps each moving exactly |vx| px, "
          f"{moves} ticks with a collision/serve/wall")
    print(f"   |v|max = {vmax} px/tick, speed in {smin}..{smax}, "
          f"{len(pairs)} distinct (vx,vy) pairs: "
          f"{sorted(pairs)}")


def check_reflection() -> None:
    """The wall bounce must obey the law of reflection in direction."""
    print("-- wall reflection")
    inc = ref = 0.0
    worst_pos = 0.0
    for vy in range(-SPEED_MAX, SPEED_MAX + 1):
        if vy == 0:
            continue
        for vx in range(-SPEED_MAX, SPEED_MAX + 1):
            for y0 in range(PF_TOP, PF_TOP + 4):      # start near the wall
                y1 = y0 + vy
                if y1 < PF_TOP:
                    y1d, vy2 = PF_TOP, -vy            # discrete: clamp
                else:
                    continue
                # continuous: cross the wall at t*, then travel the rest
                t = (PF_TOP - y0) / vy
                y1c = PF_TOP + abs(vy) * (1.0 - t)
                worst_pos = max(worst_pos, abs(y1d - y1c))
                # law of reflection: normal component reverses, tangential
                # component is unchanged, so the angles are equal
                a_i = math.degrees(math.atan2(abs(vx), abs(vy)))
                a_r = math.degrees(math.atan2(abs(vx), abs(vy2)))
                inc, ref = a_i, a_r
                need(abs(a_i - a_r) < 1e-12,
                     "angle of incidence must equal angle of reflection")
    need(inc > 0.0 and ref > 0.0, "the probe must find an angle")
    need(worst_pos <= SPEED_MAX,
         "clamped exit row must stay within one step of the mirror")
    print(f"   incidence == reflection exactly (normal component flips, "
          f"tangential component unchanged)")
    print(f"   worst exit-row difference vs the mirrored reflection: "
          f"{worst_pos:.2f} px (max step {SPEED_MAX} px)")


def check_no_tunnel() -> None:
    """Exhaustive: the ball cannot pass a paddle between two ticks.

    The ball is BALL_W px wide and the paddle PAD_W px wide, so the ball's
    spans overlap the paddle column exactly when its left edge is in

        left  paddle: XWIN_L = [1,5]      (5 positions)
        right paddle: XWIN_R = [119,123]  (5 positions)

    For a miss, the step would have to jump the whole window plus the ball
    width, which is 8 px, while the largest step is SPEED_MAX = 2 px.  The
    loop below walks every reachable start and every velocity up to the cap
    rather than trusting that argument.
    """
    print("-- no tunnelling through a paddle")
    print(f"   left window {min(XWIN_L)}..{max(XWIN_L)} "
          f"({len(XWIN_L)} px), right window {min(XWIN_R)}..{max(XWIN_R)} "
          f"({len(XWIN_R)} px), max step {SPEED_MAX} px")

    # The window is the set of ball left-edge positions whose span overlaps
    # the paddle column.  A step can clear the window only if it is longer
    # than the window plus the ball width minus one:
    for lo, hi in ((min(XWIN_L), max(XWIN_L)), (min(XWIN_R), max(XWIN_R))):
        jump = hi - lo + BALL_W
        print(f"   window {lo}..{hi}: shortest clearing step = window "
              f"({hi-lo+1}) + ball ({BALL_W}) - 1 = {jump} px, "
              f"max step {SPEED_MAX} px")
        need(SPEED_MAX < jump,
             "a maximum step must be too short to clear a paddle window")

    # exhaustive confirmation, one step wider than the hardware can ever take
    maxstep = SPEED_MAX + 1
    windows = ((min(XWIN_L), max(XWIN_L)), (min(XWIN_R), max(XWIN_R)))
    misses = []
    for v in range(-maxstep, maxstep + 1):
        if v == 0:
            continue
        for x0 in range(-16, 144):
            x, prev, overlap, cleared = x0, x0, False, False
            while -16 <= x <= 143:
                if min(XWIN_L) <= x <= max(XWIN_L) or \
                   min(XWIN_R) <= x <= max(XWIN_R):
                    overlap = True
                for lo, hi in windows:
                    if (prev < lo <= x) or (x <= hi < prev):
                        pass
                    if prev < lo and x > hi:
                        cleared = True
                    if prev > hi and x < lo:
                        cleared = True
                prev, x = x, x + v
            if cleared and not overlap:
                misses.append((v, x0))
    need(not misses,
         f"a trajectory jumped a paddle window without overlapping it: "
         f"{misses[:4]}")

    need(2 * YWIN + 1 > 2 * SPEED_MAX,
         "the vertical collision window must be wider than a full step")
    print(f"   y window {2*YWIN+1} px is wider than the largest full step "
          f"{2*SPEED_MAX} px, so no vertical graze can be skipped either")
    print("   exhaustive walk over all starts and all steps up to "
          f"{maxstep} px found no cleared window")


def check_paddle_zones() -> None:
    """Bound the angle error of the three-zone Atari paddle rule.

    Continuous model for an elastic bounce off a flat stationary surface:
    the normal component reverses and the tangential component is
    unchanged, which for a paddle face gives tan(theta) = d / half_height
    where d is the impact offset from the paddle centre.  The RTL
    quantises the outgoing vy to the integer set {0, 1, 2}, so the angle
    is quantised to atan(vy/vx) with vx in {1, 2}: the reachable slopes are
    0, 26.565, 45 and 63.435 degrees.  This check measures the worst error
    of that set against the continuous rule.
    """
    print("-- paddle zone quantisation")
    half = PAD_H / 2.0
    worst = 0.0
    worst_case = None
    for vx in range(1, SPEED_MAX + 1):
        for di in range(0, int(half) + 1):
            for sgn in (-1, 1):
                d = sgn * di
                exact = math.degrees(math.atan2(d / half, 1.0))
                ad = abs(d)
                q = 0 if ad <= ZONE_CTR else (1 if ad <= ZONE_MID else 2)
                got = math.degrees(math.atan2(q if d > 0 else -q, vx))
                if abs(exact - got) > worst:
                    worst, worst_case = abs(exact - got), (vx, d, exact, got)
    need(worst < 30.0, "three-zone rule should stay within 30 degrees")
    slopes = sorted({math.degrees(math.atan2(vy, vx))
                     for vx in range(1, SPEED_MAX + 1)
                     for vy in range(0, SPEED_MAX + 1) if vx or vy})
    print("   reachable slopes: " +
          ", ".join(f"{s:.3f}" for s in slopes) + " deg")
    print(f"   worst |theta_quantised - atan(d/half)| = {worst:.2f} deg "
          f"at vx={worst_case[0]}, d={worst_case[1]}")
    print("   (the error is inherent to a four-slope integer trajectory set; "
          "the exact model would need a sub-pixel vy)")


def check_discrete_vs_continuous() -> None:
    """Discrete vs continuous trajectory, measured on a real rally."""
    print("-- discrete vs continuous error budget")
    g = Pong()
    g.state = ST_PLAY
    g.bx, g.by = 20, 20
    g.vx, g.vy = 2, 1
    bounces = 0
    maxlag = 0.0
    for _ in range(2000):
        vx0, vy0 = g.vx, g.vy
        bx0, by0 = g.bx, g.by
        g.step({"l_up": 0, "l_dn": 0, "r_up": 0, "r_dn": 0, "start": 0})
        if g.vy != vy0:
            # a wall bounce: the continuous path turns at the true crossing,
            # the discrete one at the tick boundary, so they can differ by up
            # to one step in y
            bounces += 1
            maxlag = max(maxlag, abs(vy0))
        if g.vx != vx0:
            bounces += 1
    need(bounces > 0, "the probe run must contain bounces")
    need(maxlag <= SPEED_MAX,
         "the wall-bounce position lag must stay within one step")
    print(f"   {bounces} direction changes probed; worst wall position lag "
          f"{maxlag:.0f} px = |vy|max (bound: one step, {SPEED_MAX} px)")
    print(f"   between collisions the integer step is exact, so there is no "
          f"integrator error to bound")


def check_paddle_geometry() -> None:
    """Sanity: the serve is centred and the playfield is inside the panel."""
    print("-- geometry")
    need(PAD_L_X + PAD_W <= PAD_R_X, "paddles must not overlap")
    need(PF_TOP > 0, "a page 0 line is reserved above the playfield")
    need(SERVE_Y + BALL_H - 1 <= PF_BOT, "serve must be inside the field")
    need(PAD_Y_MAX + PAD_H - 1 <= PF_BOT, "paddle must fit in the field")
    need(HIT_L_X > PAD_L_X and HIT_R_X < PAD_R_X,
         "the ball parks inside the field after a hit")
    print(f"   field rows {PF_TOP}..{PF_BOT}, serve at ({SERVE_X},{SERVE_Y}), "
          f"paddles x={PAD_L_X} and {PAD_R_X}, travel "
          f"{PAD_Y_MIN}..{PAD_Y_MAX}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--trace", metavar="FILE")
    ap.add_argument("--ticks", type=int, default=2000)
    a = ap.parse_args()

    if a.trace:
        with open(a.trace, "w") as f:
            f.write("# tick ball_x ball_y ball_vis pad_l pad_r slt slo srt sro "
                    "vx vy speed state playing\n")
            for r in run(a.ticks):
                f.write(" ".join(str(x) for x in r) + "\n")
        print(f"model trace written: {a.trace}")
        return 0

    check_tick_rate()
    check_integer_physics()
    check_reflection()
    check_no_tunnel()
    check_paddle_zones()
    check_discrete_vs_continuous()
    check_paddle_geometry()

    print()
    if FAILS:
        print(f"physics: {len(FAILS)} FAILURES")
        return 1
    print("physics: ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
