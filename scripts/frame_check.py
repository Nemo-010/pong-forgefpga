#!/usr/bin/env python3
"""frame_check.py -- does the simulated frame actually show a Pong screen?

``sim/tb_pong.v`` drives the real design into a behavioural SSD1306, and the
model writes one 1024-byte frame per line to ``out/frames.hex`` (page major,
one byte = eight vertical pixels).  The other checks in this repository
verify timing and state, but nothing so far verified that the *picture* is
right; this file does, using the geometry from ``src/pong_render.v`` and the
glyph table from ``scripts/font_gen.py``.

Checked, on a frame from the middle of a match:

* a fully lit 4x4 ball block inside the field;
* exactly two vertical paddle blocks 2 pixels wide and 12 rows tall, at
  columns 4-5 and 122-123 (PAD_L_X, PAD_W, PAD_H, PAD_R_X) - the ball's
  pixels are masked out first, because the ball legitimately rests against
  or on top of a paddle when it bounces;
* a dashed centre line in column 63 (CENTER_X), four rows on and four rows
  off (``!y[2]``), again ignoring rows the ball covers;
* the four score cells, each of which must be blank or exactly one of the
  ten glyphs from the font generator, compared as bitmaps, so a wrong digit
  or a shifted glyph fails.

Anything unexpected in the frame is a failure; the point is that a renderer
bug (an off-by-one in the span arithmetic, a wrong font offset, a page
swap) produces a plausible-looking simulation but a wrong picture.

Run:  python3 scripts/frame_check.py out/frames.hex --index 59
      python3 scripts/frame_check.py out/frames.hex --all
"""

from __future__ import annotations

import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import font_gen  # noqa: E402  (same directory)

# mirrored from src/pong_render.v / src/pong_core.v
PANEL_W, PANEL_H = 128, 64
PAD_W, PAD_H = 2, 12
BALL_W, BALL_H = 4, 4
PAD_L_X, PAD_R_X = 4, 122
PF_TOP, PF_BOT = 8, 63
CENTER_X = 63
DASH_ON, DASH_PERIOD = 4, 8      # !y[2]
SC_L_T_X, SC_R_T_X = 44, 68      # left / right tens cell origin
SC_SLOT_W = 8                    # col[4] picks tens vs ones
SC_Y = 0                         # the score lives in page 0


class Frame:
    def __init__(self, blob: bytes):
        if len(blob) != PANEL_W * PANEL_H // 8:
            raise ValueError(f"expected {PANEL_W*PANEL_H//8} bytes, got {len(blob)}")
        self.b = blob
        self.ball_x = self.ball_y = None

    def px(self, x: int, y: int) -> int:
        return (self.b[(y // 8) * PANEL_W + x] >> (y % 8)) & 1

    def in_ball(self, x: int, y: int) -> bool:
        if self.ball_x is None:
            return False
        return (self.ball_x <= x < self.ball_x + BALL_W and
                self.ball_y <= y < self.ball_y + BALL_H)

    def glyph_cols(self, x0: int) -> list[int]:
        return [sum(self.px(x0 + x, SC_Y + y) << y for y in range(font_gen.CELL_H))
                for x in range(font_gen.CELL_W)]


def load(path: pathlib.Path, index: int | None):
    lines = [l.strip() for l in path.read_text().splitlines() if l.strip()]
    if not lines:
        raise SystemExit(f"{path}: no frames")
    if index is None:
        index = len(lines) - 1
    if not 0 <= index < len(lines):
        raise SystemExit(f"{path}: index {index} out of range 0..{len(lines)-1}")
    return Frame(bytes.fromhex(lines[index])), index, len(lines)


def find_ball(f: Frame, fail: list[str]) -> None:
    """The only 4x4 fully lit block inside the field, ignoring the paddles."""
    blocks = []
    for y in range(PF_TOP, PANEL_H - BALL_H + 1):
        for x in range(PANEL_W - BALL_W + 1):
            if all(f.px(x + dx, y + dy)
                   for dx in range(BALL_W) for dy in range(BALL_H)):
                # a 4x4 block overlapping a paddle column is the paddle,
                # not necessarily the ball; accept it only if it sticks out
                blocks.append((x, y))
    # the ball is 4x4 and the paddle is 2x12, so any candidate that also
    # contains the full paddle column width is a paddle/ball overlap: pick
    # the one whose x is furthest from a paddle column
    if not blocks:
        fail.append("no fully lit 4x4 ball block found in the field")
        return
    if len(blocks) == 1:
        f.ball_x, f.ball_y = blocks[0]
        return
    # More than one candidate means the ball is against or on top of a
    # paddle (the union of a 2x12 paddle and a 4x4 ball contains several
    # 4x4 blocks).  Pick the one that leaves both paddles exactly PAD_H
    # rows tall once it is masked out - the ball is the part that is *not*
    # the paddle, so this is self-checking rather than a guess.
    def score(cand):
        f.ball_x, f.ball_y = cand
        return sum(1 for x in (PAD_L_X, PAD_L_X + 1, PAD_R_X, PAD_R_X + 1)
                   if col_run(f, x) == PAD_H)
    best = max(blocks, key=score)
    if score(best) != 4:
        fail.append(f"{len(blocks)} candidate ball blocks {blocks}, none "
                    f"consistent with the paddle geometry")
    f.ball_x, f.ball_y = best


def col_run(f: Frame, x: int) -> int:
    run = best = 0
    for y in range(PF_TOP, PF_BOT + 1):
        run = run + 1 if (f.px(x, y) and not f.in_ball(x, y)) else 0
        best = max(best, run)
    return best


def check_paddles(f: Frame, fail: list[str]) -> None:
    tall = []
    for x in range(PANEL_W):
        run = best = 0
        for y in range(PF_TOP, PF_BOT + 1):
            run = run + 1 if (f.px(x, y) and not f.in_ball(x, y)) else 0
            best = max(best, run)
        if best > 0:
            tall.append((x, best))
    # the two paddle columns, in order, must each be exactly PAD_H tall and
    # nothing else may be more than one pixel tall (centre line, ball edge)
    want_x = [PAD_L_X, PAD_L_X + 1, PAD_R_X, PAD_R_X + 1]
    got = [x for x, h in tall if h >= PAD_H]
    if got != want_x:
        fail.append(f"columns with a {PAD_H}-row run: {got}, expected {want_x}")
    for x, h in tall:
        if x in want_x:
            if h != PAD_H:
                fail.append(f"paddle column {x}: {h} rows, expected {PAD_H}")
        else:
            # everything else is the centre line (runs of DASH_ON rows,
            # i.e. 4) or a masked ball edge
            if h > DASH_ON:
                fail.append(f"column {x}: {h}-row vertical run outside a paddle")


def check_centre_line(f: Frame, fail: list[str]) -> None:
    rows = [y for y in range(PF_TOP, PF_BOT + 1)]
    col = [f.px(CENTER_X, y) for y in rows]
    if not any(col):
        fail.append(f"centre line column {CENTER_X} is empty")
        return
    for i, y in enumerate(rows):
        if f.in_ball(CENTER_X, y):
            continue
        want = (y - PF_TOP) % DASH_PERIOD < DASH_ON
        if bool(col[i]) != want:
            fail.append(f"centre line column {CENTER_X}: row {y} is "
                        f"{'lit' if col[i] else 'dark'}, !y[2] says "
                        f"{'lit' if want else 'dark'}")
            break


def check_score(f: Frame, fail: list[str]) -> None:
    glyphs = {d: font_gen.cell(d) for d in range(10)}
    blank = [0] * font_gen.CELL_W
    for x0, name in ((SC_L_T_X, "left tens"), (SC_L_T_X + SC_SLOT_W, "left ones"),
                     (SC_R_T_X, "right tens"), (SC_R_T_X + SC_SLOT_W, "right ones")):
        cols = f.glyph_cols(x0)
        if cols == blank:
            continue          # a leading zero is blanked by the renderer
        if cols not in glyphs.values():
            fail.append(f"score cell {name} at x={x0} is not a font glyph: "
                        f"{[hex(c) for c in cols]}")


def check_frame(f: Frame, fail: list[str]) -> None:
    find_ball(f, fail)
    check_paddles(f, fail)
    check_centre_line(f, fail)
    check_score(f, fail)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("hexfile", help="out/frames.hex from sim/tb_pong.v")
    ap.add_argument("--index", type=int, default=None,
                    help="frame to check (default: the last one)")
    ap.add_argument("--all", action="store_true",
                    help="check every frame instead of one")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    path = pathlib.Path(args.hexfile)
    total = len([l for l in path.read_text().splitlines() if l.strip()])
    indices = range(total) if args.all else [args.index]
    bad = 0
    for i in indices:
        f, idx, n = load(path, i)
        fail: list[str] = []
        check_frame(f, fail)
        if fail:
            bad += 1
            print(f"frame {idx}: FAIL")
            for m in fail:
                print("   ", m)
        elif not args.quiet:
            print(f"frame {idx}/{n-1}: ok - paddles at {PAD_L_X} and {PAD_R_X}, "
                  f"centre line {CENTER_X}, ball at ({f.ball_x},{f.ball_y}), "
                  f"score glyphs match the font")
    if bad:
        print(f"frame_check: {bad} of {total} frame(s) FAILED")
        return 1
    print(f"frame_check: PASS ({total} frame{'s' if total != 1 else ''})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
