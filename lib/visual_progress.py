#!/usr/bin/env python3
"""Did a GUI action change the screen? A dependency-free framebuffer diff.

The harness drives a VM's desktop over QMP and screendumps the framebuffer as a
P6 PPM (`qmp_client.py screendump`). What it could not do was *verify* a step:
a click that misses, a type into an unfocused window, or a hung app all leave the
screen unchanged, and the harness called the step done anyway.

This compares two PPM captures and says whether the screen actually changed - the
`extra_soul_wait` / stall-breaker idea from AIYantra's "Extra" desktop engine
(perceptual-hash diff plus a pixel-change fraction), reimplemented in the standard
library so it needs no Pillow, numpy or imagehash. A test VM is fully ours, so
there is none of Chronoa's screen-capture consent to weigh here.

The two signals, together:

- **Average hash (aHash).** Both frames are reduced to a `GRID`x`GRID` grayscale
  thumbnail; each cell becomes one bit, set when it is brighter than the frame's
  mean. The Hamming distance between the two hashes is how much the *layout* of
  light and dark moved - robust to a blinking cursor or one-pixel jitter, which
  a raw byte compare is not.
- **Changed-cell fraction.** Of the same thumbnail cells, the share whose
  brightness moved by more than `CELL_DELTA`. This catches a large, uniform
  change (a window that went all white) that barely moves the hash.

Either one over its floor means the screen changed. Both near zero means it did
not - the signal a step did nothing.

Usage:
    visual_progress.py compare BEFORE.ppm AFTER.ppm      # prints a JSON verdict
    visual_progress.py assert-changed BEFORE.ppm AFTER.ppm  # exit 0 changed, 2 same
"""
from __future__ import annotations

import json
import sys

#: Thumbnail edge. 16 gives a 256-bit hash - fine enough to place a change on the
#: screen, coarse enough that a cursor blink or a clock tick does not trip it.
GRID = 16

#: A cell counts as moved when its 0-255 grayscale shifts by more than this.
CELL_DELTA = 24

#: The screen "changed" when the hash moved at least this many bits...
HAMMING_FLOOR = 6
#: ...or at least this fraction of cells moved (a big uniform change the hash misses).
FRACTION_FLOOR = 0.04


class PPMError(ValueError):
    """A file that is not a readable P6 PPM. The message is fit to print."""


def _read_token(data: bytes, pos: int) -> "tuple[bytes, int]":
    """One whitespace-delimited header token from `pos`, skipping '#' comments."""
    n = len(data)
    while pos < n and data[pos:pos + 1].isspace():
        pos += 1
    if pos < n and data[pos:pos + 1] == b"#":
        while pos < n and data[pos:pos + 1] not in (b"\n", b"\r"):
            pos += 1
        return _read_token(data, pos)
    start = pos
    while pos < n and not data[pos:pos + 1].isspace():
        pos += 1
    return data[start:pos], pos


def load_ppm(path: str) -> "tuple[int, int, bytes]":
    """(width, height, rgb_bytes) from a binary P6 PPM; raises PPMError otherwise."""
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(b"P6"):
        raise PPMError(f"{path} is not a P6 PPM (QMP screendump writes P6)")
    pos = 2
    width_tok, pos = _read_token(data, pos)
    height_tok, pos = _read_token(data, pos)
    maxval_tok, pos = _read_token(data, pos)
    try:
        width, height, maxval = int(width_tok), int(height_tok), int(maxval_tok)
    except ValueError:
        raise PPMError(f"{path} has a malformed PPM header")
    if maxval != 255:
        raise PPMError(f"{path} maxval {maxval} unsupported; expected 255")
    pos += 1  # the single whitespace byte after maxval, before the pixels
    pixels = data[pos:pos + width * height * 3]
    if len(pixels) < width * height * 3:
        raise PPMError(f"{path} is truncated: {len(pixels)} of {width * height * 3} pixel bytes")
    return width, height, pixels


def thumbnail(path: str, grid: int = GRID) -> "list[int]":
    """A grid*grid list of 0-255 grayscale cell averages, each the mean luminance
    of the pixels sampled from that cell of the frame."""
    width, height, px = load_ppm(path)
    if width == 0 or height == 0:
        raise PPMError(f"{path} has a zero dimension")
    cells = []
    for gy in range(grid):
        y0, y1 = gy * height // grid, max(gy * height // grid + 1, (gy + 1) * height // grid)
        # Sample a bounded number of rows/cols per cell so a 4K frame stays cheap.
        ys = range(y0, y1, max(1, (y1 - y0) // 4 or 1))
        for gx in range(grid):
            x0, x1 = gx * width // grid, max(gx * width // grid + 1, (gx + 1) * width // grid)
            xs = range(x0, x1, max(1, (x1 - x0) // 4 or 1))
            total = count = 0
            for y in ys:
                row = (y * width) * 3
                for x in xs:
                    i = row + x * 3
                    # Rec. 601 luma, integer: (r*77 + g*150 + b*29) >> 8
                    total += (px[i] * 77 + px[i + 1] * 150 + px[i + 2] * 29) >> 8
                    count += 1
            cells.append(total // count if count else 0)
    return cells


def _ahash(cells: "list[int]") -> int:
    mean = sum(cells) // len(cells)
    bits = 0
    for i, value in enumerate(cells):
        if value > mean:
            bits |= 1 << i
    return bits


def compare(before_path: str, after_path: str, grid: int = GRID) -> dict:
    """How much the screen changed between two PPM frames, and a verdict."""
    a, b = thumbnail(before_path, grid), thumbnail(after_path, grid)
    hamming = bin(_ahash(a) ^ _ahash(b)).count("1")
    moved = sum(1 for x, y in zip(a, b) if abs(x - y) > CELL_DELTA)
    fraction = moved / len(a)
    changed = hamming >= HAMMING_FLOOR or fraction >= FRACTION_FLOOR
    return {
        "verdict": "changed" if changed else "same",
        "hamming": hamming,
        "changed_cells": moved,
        "changed_fraction": round(fraction, 4),
        "grid": grid,
    }


def main(argv: "list[str]") -> int:
    if len(argv) != 3 or argv[0] not in ("compare", "assert-changed"):
        sys.stderr.write(
            "usage: visual_progress.py compare|assert-changed BEFORE.ppm AFTER.ppm\n")
        return 64
    try:
        result = compare(argv[1], argv[2])
    except (OSError, PPMError) as exc:
        sys.stderr.write(f"visual_progress: {exc}\n")
        return 65
    print(json.dumps(result))
    if argv[0] == "assert-changed":
        return 0 if result["verdict"] == "changed" else 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
