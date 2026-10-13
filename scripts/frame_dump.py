#!/usr/bin/env python3
"""Turn the GDDRAM frames dumped by sim/ssd1306_model.v into pictures.

out/frames.hex holds one frame per line: 1024 bytes, page major, column
minor, bit 0 = top row of the page (SSD1306 rev 1.1 section 8.7, "GDDRAM").

    python3 scripts/frame_dump.py out/frames.hex --last --pgm out/last.pgm
    python3 scripts/frame_dump.py out/frames.hex --text --index 10

The PGM is a plain portable graymap: every image tool and every viewer on
the Electrosphere reads it, and it needs no library here.
"""

from __future__ import annotations

import argparse
import sys

W, H = 128, 64


def frame_to_rows(hexline: str) -> list[list[int]]:
    raw = bytes.fromhex(hexline.strip())
    if len(raw) != W * H // 8:
        raise ValueError(f"expected {W*H//8} bytes, got {len(raw)}")
    rows = [[0] * W for _ in range(H)]
    for page in range(8):
        for col in range(W):
            b = raw[page * W + col]
            for bit in range(8):
                rows[page * 8 + bit][col] = (b >> bit) & 1
    return rows


def to_pgm(rows: list[list[int]]) -> bytes:
    out = bytearray(f"P5\n{W} {H}\n255\n".encode())
    for r in rows:
        out.extend(255 if pxl else 0 for pxl in r)
    return bytes(out)


def to_text(rows: list[list[int]]) -> str:
    return "\n".join("".join("#" if p else "." for p in r) for r in rows)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("hexfile")
    ap.add_argument("--index", type=int, default=None)
    ap.add_argument("--last", action="store_true")
    ap.add_argument("--pgm")
    ap.add_argument("--text", action="store_true")
    ap.add_argument("--all-pgm", metavar="PREFIX",
                    help="write every frame as PREFIX-NNN.pgm")
    a = ap.parse_args()

    frames = [l for l in open(a.hexfile) if l.strip()]
    if not frames:
        print("no frames in file")
        return 1

    if a.all_pgm:
        for i, f in enumerate(frames):
            with open(f"{a.all_pgm}-{i:03d}.pgm", "wb") as fh:
                fh.write(to_pgm(frame_to_rows(f)))
        print(f"wrote {len(frames)} frames")
        return 0

    idx = len(frames) - 1 if (a.last or a.index is None) else a.index
    rows = frame_to_rows(frames[idx])
    lit = sum(sum(r) for r in rows)
    print(f"frame {idx}/{len(frames)-1}: {lit} pixels lit")
    if a.pgm:
        with open(a.pgm, "wb") as fh:
            fh.write(to_pgm(rows))
        print(f"wrote {a.pgm}")
    if a.text:
        print(to_text(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
