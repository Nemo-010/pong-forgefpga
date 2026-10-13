#!/usr/bin/env python3
"""Diff the RTL tick trace (sim/tb_core.v) against the Python model.

Both sides replay the same deterministic autoplayer, so every column of
every tick has to match exactly -- there is no tolerance here, the two are
supposed to be the same integer arithmetic.

    iverilog -g2005 -o out/tb_core.vvp src/pong_core.v sim/tb_core.v
    vvp out/tb_core.vvp
    python3 scripts/compare_trace.py
"""

from __future__ import annotations

import sys

import physics

RTL = "out/core_trace.txt"
COLS = ["tick", "ball_x", "ball_y", "ball_vis", "pad_l", "pad_r",
        "slt", "slo", "srt", "sro", "vx", "vy", "speed", "state", "playing"]


def load(path: str) -> list[list[int]]:
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            rows.append([int(x) for x in line.split()])
    return rows


def main() -> int:
    try:
        rtl = load(RTL)
    except FileNotFoundError:
        print(f"missing {RTL}: run the simulation first")
        return 2
    mdl = [[r[0]] + list(r[1:]) for r in physics.run(len(rtl))]

    if len(rtl) != len(mdl):
        print(f"FAIL: {len(rtl)} RTL rows vs {len(mdl)} model rows")
        return 1

    bad = 0
    for i, (a, b) in enumerate(zip(rtl, mdl)):
        if a != b:
            bad += 1
            if bad <= 10:
                print(f"line {i} ({COLS[0]}={a[0]}):")
                for j, (x, y) in enumerate(zip(a, b)):
                    if x != y:
                        print(f"   {COLS[j]:9s} rtl={x:6d} model={y:6d}")
    if bad:
        print(f"FAIL: {bad}/{len(rtl)} ticks differ")
        return 1

    hits = sum(1 for a, b in zip(rtl[1:], rtl[:-1])
               if a[11] != b[11] or a[10] != b[10])
    points = sum(1 for a, b in zip(rtl[1:], rtl[:-1]) if a[13] != b[13])
    print(f"RTL and model agree on all {len(rtl)} ticks "
          f"({hits} velocity changes, {points} state changes)")
    print("compare_trace: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
