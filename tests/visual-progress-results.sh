#!/bin/bash
# A check of the harness itself: lib/visual_progress.py, run against synthetic
# P6 PPM frames, requiring its verdict to go both ways - "same" when the screen
# did not change (and when only a cursor-sized dot moved), "changed" when a
# window-sized region did.
#
# WHY THIS FILE EXISTS. `visual_progress.py` is what lets a GUI slot-test assert
# that a click or a keystroke actually changed the screen, instead of calling a
# step done when nothing happened. A comparator that always says "changed" would
# pass every such assertion while proving nothing, and one that always says
# "same" would fail every real step. "The control must be seen going both ways"
# is the rule this repo keeps paying for, so this drives it to each verdict.
#
# WHAT IS REAL AND WHAT IS SYNTHETIC. The MODULE is not stubbed: `compare()` and
# the CLI run unmodified. The PPMs are synthetic, because a host cannot be made
# to screendump a VM here - and the point being proved is that the *comparison*
# discriminates, not that QMP captures a frame (that is the slot/gui.sh job).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VP="$ROOT/lib/visual_progress.py"

[[ -f "$VP" ]] || { echo "FAIL: no $VP" >&2; exit 1; }

pass_n=0 fail_n=0
ok() { printf 'ok   %s\n' "$1"; pass_n=$((pass_n + 1)); }
no() { printf 'FAIL %s -- %s\n' "$1" "$2"; fail_n=$((fail_n + 1)); }

TMP=$(mktemp -d /tmp/visual-progress-selftest.XXXXXX)
trap '[[ ${KEEP_TMP:-0} == 1 ]] || rm -rf "$TMP"' EXIT

# Synthetic frames: a dark base, a byte-identical copy, a 4x4 "cursor" dot, and a
# window-sized bright block. Written with the standard library, the same P6 the
# QMP screendump writes.
python3 - "$TMP" <<'PY'
import sys
d = sys.argv[1]
W, H = 320, 240

def ppm(name, patch=None):
    px = bytearray(bytes((10, 10, 10)) * (W * H))
    if patch:
        x0, y0, x1, y1, c = patch
        for y in range(y0, y1):
            for x in range(x0, x1):
                i = (y * W + x) * 3
                px[i:i + 3] = bytes(c)
    with open(f"{d}/{name}", "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (W, H))
        f.write(bytes(px))

ppm("base.ppm")
ppm("same.ppm")
ppm("cursor.ppm", (5, 5, 9, 9, (240, 240, 240)))
ppm("window.ppm", (40, 40, 280, 200, (240, 240, 240)))
ppm("right.ppm", (180, 90, 300, 150, (240, 240, 240)))  # a 320-wide frame's right half
open(f"{d}/bad.ppm", "wb").write(b"not a ppm at all")
PY

field() { python3 "$VP" compare "$1" "$2" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"$3\"])"; }
verdict() { field "$1" "$2" verdict; }

# 1. Identical frames -> same.
[[ "$(verdict "$TMP/base.ppm" "$TMP/same.ppm")" == same ]] \
  && ok "identical frames read as 'same'" \
  || no "identical frames" "comparator did not say 'same'"

# 2. A cursor-sized dot -> same (the perceptual tolerance; a raw byte compare fails here).
[[ "$(verdict "$TMP/base.ppm" "$TMP/cursor.ppm")" == same ]] \
  && ok "a cursor-sized dot still reads as 'same'" \
  || no "cursor dot" "a 4x4 change tripped the verdict - too sensitive to be useful"

# 3. A window-sized change -> changed (the control, seen going green).
[[ "$(verdict "$TMP/base.ppm" "$TMP/window.ppm")" == changed ]] \
  && ok "a window-sized change reads as 'changed'" \
  || no "window change" "a large change did not register - the check cannot pass"

# 4. The changed region is reported, and lands where the change is (right half).
center="$(field "$TMP/base.ppm" "$TMP/right.ppm" center)"   # e.g. [240, 120]
cx="$(printf '%s' "$center" | python3 -c 'import sys,ast;print(ast.literal_eval(sys.stdin.read())[0])' 2>/dev/null)"
if [[ -n "$cx" && "$cx" -gt 160 ]]; then
  ok "the changed region's centre ($center) is in the right half"
else
  no "changed region" "a change in the right half was not localised there (centre $center)"
fi
[[ "$(field "$TMP/base.ppm" "$TMP/same.ppm" region)" == None ]] \
  && ok "an unchanged frame reports no region" \
  || no "no-change region" "a same frame reported a changed region"

# 5. assert-changed exit codes: 2 for 'same', 0 for 'changed'.
python3 "$VP" assert-changed "$TMP/base.ppm" "$TMP/same.ppm" >/dev/null; [[ $? -eq 2 ]] \
  && ok "assert-changed exits 2 on no change" \
  || no "assert-changed same" "did not exit 2 on an unchanged screen"
python3 "$VP" assert-changed "$TMP/base.ppm" "$TMP/window.ppm" >/dev/null; [[ $? -eq 0 ]] \
  && ok "assert-changed exits 0 on a real change" \
  || no "assert-changed changed" "did not exit 0 on a changed screen"

# 5. A malformed frame is an error (exit 65), not a silent 'changed'/'same'.
python3 "$VP" compare "$TMP/bad.ppm" "$TMP/base.ppm" >/dev/null 2>&1; [[ $? -eq 65 ]] \
  && ok "a non-PPM input is a clean error, not a verdict" \
  || no "bad input" "a malformed PPM did not exit 65"

printf '\n%d ok, %d failed\n' "$pass_n" "$fail_n"
[[ $fail_n -eq 0 ]]
