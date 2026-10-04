#!/bin/bash
# A check of the harness itself: slot-tests/chronoa-singing.sh — run against a
# STUBBED slot, to prove the voice-style assertions can actually fail.
#
# WHY THIS FILE EXISTS. The style stage of chronoa-singing.sh claims something
# audible — "a soothing voice" — and its first version did not deserve the name:
# it sang a line, printed PASS, and never touched `voice_style` at all. Adding
# the measurement fixed that claim, and introduced the opposite risk: a check
# whose thresholds could not be reached, or that accepted any file at all. This
# file runs the real slot-test against deliberately broken soxes and requires
# the stage to go RED, which is the only way to know the numbers it prints are
# being read rather than assumed. Same rule as tests/chronoa-speech-results.sh
# ("a negative control that cannot fail is not a control") and the same split:
# that file proves chronoa-speech's assertions discriminate, this one proves the
# singing style's do.
#
# WHAT IS REAL AND WHAT IS STUBBED, precisely — this distinction is the whole
# caveat on the file:
#
#   * The Python package is NOT stubbed. CHRONOA_SRC points at the real
#     ../shani-chronoa checkout, so the real prosody / singing / voice_style /
#     tts / sherpa code runs, with its real argv.
#   * sox IS stubbed, because this host has no sox and the slot-test's claim is
#     about *which* file the style was applied to and *whether the result moved*,
#     not about SoX's DSP. The `apply` stub is a real RBJ peaking-EQ biquad per
#     `equalizer <hz> <q> <dB>` pair, so the signal is genuinely reshaped and the
#     Goertzel measurement independently discovers it; it does not write the
#     expected answer. That SoX itself produces these numbers on a real image
#     is proven by the live run recorded in slot-tests/chronoa-singing.sh's
#     sibling (1.28x at 180 Hz, 0.87x at 3500 Hz, control 1.40x) — not here.
#   * The consent gate is read through a REAL compiled GSettings schema (the
#     checkout's own XML, compiled with glib-compile-schemas, with the one key's
#     default flipped to turn consent on), because that is the honest seam: it
#     reads the same way the slot does rather than through a gsettings stub.
#   * Every stub appends to $STUB_LOG, and the log is asserted below. A stub
#     nobody can prove ran is a control that proves nothing.
#
# Skips, loudly, when the host lacks what it needs — a silently skipped
# self-test reads as a passing one.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
SLOT_TEST="$ROOT/slot-tests/chronoa-singing.sh"
CHRONOA_SRC="$ROOT/../shani-chronoa/usr/lib/shani-chronoa"
SCHEMA_XML="$ROOT/../shani-chronoa/usr/share/glib-2.0/schemas/org.shani.chronoa.gschema.xml"

pass_n=0 fail_n=0
ok() { printf 'ok   %s\n' "$1"; pass_n=$((pass_n + 1)); }
no() { printf 'FAIL %s -- %s\n' "$1" "$2"; fail_n=$((fail_n + 1)); }

TMP=$(mktemp -d /tmp/chronoa-singing-selftest.XXXXXX)
# KEEP_TMP=1 leaves the per-scenario directories behind, which is how a failing
# scenario gets inspected instead of guessed at; the default still cleans up.
trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "$TMP"' EXIT
[[ -n "${KEEP_TMP:-}" ]] && echo "(keeping $TMP)"

for needed in python3 glib-compile-schemas; do
  command -v "$needed" >/dev/null 2>&1 || {
    echo "SKIP: $needed is not available here"; exit 0; }
done
[[ -f "$SLOT_TEST" ]] || { echo "SKIP: no slot-test at $SLOT_TEST"; exit 0; }
if [[ ! -f "$CHRONOA_SRC/shani_chronoa/voice_style.py" ]]; then
  echo "SKIP: no Chronoa checkout beside this repo (looked for $CHRONOA_SRC)."
  echo "      This self-test runs the real prosody/singing/voice_style against"
  echo "      stubbed binaries; with the package stubbed it would prove nothing."
  exit 0
fi
if ! python3 -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null; then
  echo "SKIP: PyGObject is not importable here, so the real consent gate cannot be read"
  exit 0
fi
CHRONOA_SRC="$(cd "$CHRONOA_SRC" && pwd)"

# `tail` is here because the slot-test pipes its stage output through it; it
# was missing from the first version of this list, and every stage then
# reported an empty verdict and four FAILs that had nothing to do with the
# stub under test. A missing tool in the harness reads exactly like a broken
# product, which is this workspace's most repeated lesson.
TOOLS="bash python3 grep sed tr head stat ls awk mktemp rm timeout cat env tail"
declare -A TOOLPATH=()
for t in $TOOLS; do
  p=$(command -v "$t" 2>/dev/null || true)
  [[ -n "$p" ]] && TOOLPATH[$t]="$p"
done
missing=""
for t in $TOOLS; do [[ -n "${TOOLPATH[$t]:-}" ]] || missing+=" $t"; done
[[ -z "$missing" ]] || { echo "SKIP: this host is missing tools:$missing"; exit 0; }

STUB_LOG="$TMP/stub-invocations.log"
: > "$STUB_LOG"

# --- stubs -------------------------------------------------------------------

# espeak-ng is called two ways by the real code: `-q -x --ipa=1` with the text on
# stdin (prosody.estimate_durations) and `-w <out>` (the tts engine chain). The
# phoneme mode prints one IPA word per input word, which is what the real thing
# does and what the syllable count is derived from.
write_espeak_stub() {
  cat > "$1" <<'STUB'
#!/usr/bin/env python3
import os, subprocess, sys
print("espeak-ng " + " ".join(sys.argv[1:]), file=open(os.environ["STUB_LOG"], "a"))
out, phonemes = "", "-q" in sys.argv and "-x" in sys.argv
prev = ""
for a in sys.argv[1:]:
    if prev == "-w":
        out = a
    prev = a
if phonemes:
    text = sys.stdin.read()
    for word in text.split():
        # three vowel nuclei per word: enough that segment() has real syllables
        print("ˈ".join([]) + "".join(["t", "w", "ɪ", "ŋ", "k", "ə", "l"])[:7])
    sys.exit(0)
if not out:
    sys.exit(1)
subprocess.run([sys.executable, os.path.join(os.environ["STUB_LIB"], "tone.py"), out])
STUB
  chmod 755 "$1"
}

# The tone generator both stubs call. Real energy at 180 Hz AND 3500 Hz on
# purpose: the style stage refuses to report ratios against a file with no
# measurable energy in a band, so a silent or single-tone fixture would make
# every style scenario skip for the wrong reason.
write_tone_gen() {
  cat > "$1" <<'STUB'
#!/usr/bin/env python3
import math, struct, sys
RATE = 22050
def build(path, seconds=1.6):
    frames = bytearray()
    for i in range(int(RATE * seconds)):
        v = (0.32 * math.sin(2 * math.pi * 180 * i / RATE)
             + 0.18 * math.sin(2 * math.pi * 900 * i / RATE)
             + 0.10 * math.sin(2 * math.pi * 3500 * i / RATE)
             + 0.05 * math.sin(2 * math.pi * 8000 * i / RATE))
        frames += struct.pack("<h", int(11000 * v))
    data = bytes(frames)
    open(path, "wb").write(
        b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16)
        + b"data" + struct.pack("<I", len(data)) + data)
build(sys.argv[1])
STUB
  chmod 755 "$1"
}

# sherpa-onnx-offline-tts is a real subprocess the shipped code runs, so it is
# the right seam for the neural voice. It is given `--output-filename=<path>`.
write_sherpa_stub() {
  cat > "$1" <<'STUB'
#!/usr/bin/env python3
import os, subprocess, sys
print("sherpa-offline-tts " + " ".join(sys.argv[1:]), file=open(os.environ["STUB_LOG"], "a"))
out = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--output-filename=")), "")
if not out:
    sys.exit(1)
subprocess.run([sys.executable, os.path.join(os.environ["STUB_LIB"], "tone.py"), out])
STUB
  chmod 755 "$1"
}

# sox, in three deliberately different behaviours. `apply` is a real peaking EQ
# (RBJ cookbook coefficients) applied per `equalizer <hz> <q> <gain-dB>` pair,
# so the measurement has to discover the change rather than being handed it.
write_sox_stub() {  # <path> <apply|passthrough|silent>
  cat > "$1" <<STUB
#!/usr/bin/env python3
import cmath, math, os, struct, sys
print("sox " + " ".join(sys.argv[1:]), file=open(os.environ["STUB_LOG"], "a"))
mode = "$2"
src, dst = sys.argv[1], sys.argv[2]
def read(p):
    d = open(p, "rb").read()
    at = d.find(b"fmt "); rate = struct.unpack("<I", d[at + 12:at + 16])[0]
    s = d.find(b"data"); n = struct.unpack("<I", d[s + 4:s + 8])[0]
    b = d[s + 8:s + 8 + n]; u = len(b) - len(b) % 2
    return rate, list(struct.unpack("<%dh" % (u // 2), b[:u]))
def write(p, rate, sm):
    data = struct.pack("<%dh" % len(sm), *sm)
    open(p, "wb").write(
        b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
        + b"data" + struct.pack("<I", len(data)) + data)
rate, samples = read(src)
if mode == "silent":
    sys.exit(0)                       # exit 0, wrote nothing: the shape of a lying tool
if mode == "passthrough":
    write(dst, rate, samples); sys.exit(0)
stages = []
argv = sys.argv[3:]
while argv:
    if argv[0] == "equalizer":
        # SoX spells Q with a width suffix ("1.0q"), and voice_style emits it that
        # way, so the stub parses what the product actually sends.
        stages.append((float(argv[1]), float(argv[2].rstrip("qo")), float(argv[3])))
        argv = argv[4:]
    else:
        argv = argv[1:]
# One stage per equalizer pair, applied in the frequency domain:
# (no backticks in this heredoc on purpose - it is unquoted, because it has
# to interpolate $2, and a backtick comment makes bash run a command
# substitution here. The same trap that once ran pacstrap and gnome-shell
# from this repo's usage text.)
# a forward FFT, a Gaussian-weighted gain around the centre frequency whose
# width is f0/Q, and an inverse FFT. The weighting is 1 + (G-1)*w(f), so the
# gain at f0 is exactly G = 10**(dB/20) and it decays away from the centre.
#
# A biquad was tried first and was wrong in a way worth recording: written from
# the cookbook it produced -39 dB at 30 Hz and +2.6 dB at 3500 Hz for a
# "peaking" EQ at 180 Hz, i.e. a high-pass. The stage then reported the soothing
# style as ineffective at 180 Hz - a true statement about the stub and a false
# one about the product. Doing the arithmetic in the frequency domain removes the
# temptation to trust the coefficient formula, and it shares no code with the
# Goertzel measurement, so the check still has to discover the change.
N = 1
while N < len(samples):
    N *= 2

def fft(values, inverse=False):
    n = len(values)
    if n > 1:
        even = fft(values[0::2], inverse)
        odd = fft(values[1::2], inverse)
        factor = (1 if inverse else -1) * 2j * math.pi / n
        for k in range(n // 2):
            t = cmath.exp(factor * k) * odd[k]
            odd[k] = even[k] - t
            even[k] = even[k] + t
        return even + odd
    return [complex(values[0])]

spectrum = fft([complex(v, 0.0) for v in samples] + [0j] * (N - len(samples)))
for hz, q, gain_db in stages:
    centre = hz
    width = max(centre / q, 1.0)
    gain = 10 ** (gain_db / 20.0)
    for k in range(N):
        f = k * rate / N
        weight = math.exp(-(((f - centre) / width) ** 2)) if abs(f - centre) < 3 * width else 0.0
        if weight > 1e-9:
            scale = 1.0 + (gain - 1.0) * weight
            spectrum[k] *= scale
            if k:
                spectrum[N - k] *= scale
restored = fft(spectrum, inverse=True)
scale = 1.0 / N
out = [max(-32768, min(32767, int(round(v.real * scale)))) for v in restored[:len(samples)]]
write(dst, rate, out or samples)
STUB
  chmod 755 "$1"
}

# soundstretch is handed `<raw> <shifted> -pitch=<n> -speech`. A pitch shift is
# a resample (moves pitch AND duration) followed by a time-stretch (moves the
# duration back), so the stub does both: overlap-add with a Hann window, then
# divide by the accumulated window sum.
#
# The duration half is not optional detail. Decimation alone shortens every
# shifted note, and the slot-test measures each note at the time it was *asked*
# for, so the last note of a rising run then falls in silence and reads -19
# semitones against a +6 plan. That was the stub being unfaithful, not the
# product being wrong - the real run on the image reads +6.1 there - and a
# control that fails for its own reasons is worse than no control.
write_soundstretch_stub() {
  cat > "$1" <<'STUB'
#!/usr/bin/env python3
import math, os, struct, sys
print("soundstretch " + " ".join(sys.argv[1:]), file=open(os.environ["STUB_LOG"], "a"))
src, dst = sys.argv[1], sys.argv[2]
semitones = 0.0
for a in sys.argv[1:]:
    if a.startswith("-pitch="):
        semitones = float(a.split("=", 1)[1])
d = open(src, "rb").read()
at = d.find(b"fmt "); rate = struct.unpack("<I", d[at + 12:at + 16])[0]
s = d.find(b"data"); n = struct.unpack("<I", d[s + 4:s + 8])[0]
b = d[s + 8:s + 8 + n]; u = len(b) - len(b) % 2
samples = list(struct.unpack("<%dh" % (u // 2), b[:u]))
ratio = 2 ** (semitones / 12.0)

# 1. resample by `ratio`, boxcar-filtered first so decimation does not alias
width = max(1, int(ratio))
smoothed = []
for i in range(len(samples)):
    lo, hi = max(0, i - width // 2), min(len(samples), i + width // 2 + 1)
    smoothed.append(sum(samples[lo:hi]) / len(samples[lo:hi]))
count = max(1, int(len(smoothed) / ratio))
resampled = [smoothed[min(len(smoothed) - 1, int(i * ratio))] for i in range(count)]

# 2. time-stretch back to the original length by overlap-add
target = len(samples)
out = [0.0] * (target + 8192)
weight = [0.0] * (target + 8192)
frame, hop = 1024, 512
in_hop = max(1.0, hop * len(resampled) / target)
pos = 0.0
while pos < target:
    start = int(pos)
    for k in range(frame):
        index = start + k
        if index >= len(out):
            break
        w = 0.5 - 0.5 * math.cos(2 * math.pi * k / frame)
        sample = resampled[index] if index < len(resampled) else 0.0
        out[index] += sample * w
        weight[index] += w * w
    pos += in_hop
stretched = [out[i] / weight[i] if weight[i] > 1e-6 else 0.0 for i in range(target)]
peak = max((abs(v) for v in stretched), default=0.0)
scale = (11000.0 / peak) if peak else 1.0
data = struct.pack("<%dh" % len(stretched),
                   *[max(-32768, min(32767, int(v * scale))) for v in stretched])
open(dst, "wb").write(
    b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
    + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    + b"data" + struct.pack("<I", len(data)) + data)
STUB
  chmod 755 "$1"
}

# --- run one scenario --------------------------------------------------------
# scenario <name> <sox-mode> <kokoro: yes|no> <consent: on|off> <shifter: yes|no>
#             <voice_style: real|neutral>
# Prints nothing. Output lands in $TMP/<name>/out.
scenario() {
  local name="$1" soxmode="$2" kokoro="$3" consent="$4" shifter="$5" vstyle="${6:-real}"
  local sd="$TMP/$name"
  rm -rf "$sd"; mkdir -p "$sd/bin" "$sd/home" "$sd/xdg" "$sd/lib"
  for t in "${!TOOLPATH[@]}"; do ln -sf "${TOOLPATH[$t]}" "$sd/bin/$t"; done
  write_tone_gen "$sd/lib/tone.py"
  write_espeak_stub "$sd/bin/espeak-ng"
  write_sox_stub "$sd/bin/sox" "$soxmode"
  [[ "$shifter" == yes ]] && write_soundstretch_stub "$sd/bin/soundstretch"
  # rubberband is the other candidate _best_transposer() looks for; leaving it
  # absent is what makes the "no shifter" scenario real rather than a fiction.
  [[ "$kokoro" == yes ]] && {
    local kok="$sd/xdg/shani-chronoa"
    mkdir -p "$kok/sherpa-onnx/sherpa-onnx-v1.13.8-linux-x64-shared/bin"
    write_sherpa_stub "$kok/sherpa-onnx/sherpa-onnx-v1.13.8-linux-x64-shared/bin/sherpa-onnx-offline-tts"
    # kokoro_dir() is data_home()/kokoro - NOT data_home()/shani-chronoa/kokoro,
    # which is where sherpa's release lives. Getting that wrong leaves the model
    # invisible, and `_kokoro_reason()` then falls through to espeak-ng with a
    # perfectly plausible reason string, so the scenario would quietly test the
    # formant voice while claiming to test the neural one.
    local model="$sd/xdg/kokoro/kokoro-int8-en-v0_19"
    mkdir -p "$model/espeak-ng-data"
    for f in model.int8.onnx voices.bin tokens.txt; do
      [[ -s "$model/$f" ]] || printf 'stub\n' > "$model/$f"
    done
  }

  # A real compiled schema, with the one consent key's default flipped. Reading
  # it through Gio.Settings is the honest seam — a gsettings stub would test the
  # stub.
  local sch="$sd/schemas"
  mkdir -p "$sch"
  sed 's|<key name="kokoro-tts-enabled" type="b">\n|&|' "$SCHEMA_XML" > "$sch/org.shani.chronoa.gschema.xml"
  if [[ "$consent" == on ]]; then
    python3 - "$sch/org.shani.chronoa.gschema.xml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
new, n = re.subn(
    r'(<key name="kokoro-tts-enabled" type="b">\s*<default>)false(</default>)',
    r"\1true\2", text)
if n != 1:
    raise SystemExit("consent mutation applied to %d keys, expected exactly 1" % n)
open(path, "w").write(new)
PY
  fi
  glib-compile-schemas "$sch" 2>/dev/null
  [[ -f "$sch/gschemas.compiled" ]] || {
    echo "  (scenario $name: schema did not compile)" >&2; return 1; }

  # A doctored package for the regression scenario: `soothing` deleted from the
  # preset table, so the stage must report a FAIL rather than a quiet SKIP. The
  # mutation is asserted below, because a copy that silently failed to change
  # would make this scenario pass for the wrong reason.
  local src="$CHRONOA_SRC"
  if [[ "$vstyle" == neutral ]]; then
    src="$sd/chronoa"
    mkdir -p "$src"
    cp -a "$CHRONOA_SRC/shani_chronoa" "$src/shani_chronoa"
    # Neutralise `soothing` rather than deleting it: the branch under test is
    # "a style that resolves but asks for nothing", which a deleted preset
    # cannot reach - that one raises KeyError and is a different regression.
    python3 - "$src/shani_chronoa/voice_style.py" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
new, n = re.subn(r'"soothing":\s*VoiceStyle\([^)]*\),\n',
                 '"soothing": VoiceStyle(),\n', text)
if n < 1:
    raise SystemExit("the soothing preset was not found, so the mutation changed nothing")
open(path, "w").write(new)
PY
    python3 -c "
import sys
sys.path.insert(0, '$src')
from shani_chronoa import voice_style
assert voice_style.style_effects(voice_style.resolve_preset('soothing')) == [], \
    'the control did not actually neutralise the preset'"
  fi

  env -i PATH="$sd/bin" HOME="$sd/home" TMPDIR=/tmp \
      XDG_DATA_HOME="$sd/xdg" XDG_CONFIG_HOME="$sd/home/.config" \
      XDG_STATE_HOME="$sd/home/.state" \
      GSETTINGS_SCHEMA_DIR="$sch" GSETTINGS_BACKEND=memory \
      CHRONOA_SRC="$src" STUB_LOG="$STUB_LOG" STUB_LIB="$sd/lib" \
      bash "$SLOT_TEST" > "$sd/out" 2>&1
  return 0
}

style_lines() { grep -E "soothing|bright style|could not sing and style" "$TMP/$1/out"; }

# --- 1. the working slot -----------------------------------------------------
if scenario works apply yes on yes; then
  if grep -q "^RESULT singing DONE failures=0$" "$TMP/works/out"; then
    ok "works: a real style run is green (soothing 1.28x/0.87x, control 1.40x class of result)"
  else
    no "works: expected failures=0" "$(grep -E '^RESULT singing (FAIL|DONE)' "$TMP/works/out" | tr '\n' ';')"
  fi
  grep -q "the soothing style was applied" "$TMP/works/out" \
    && ok "works: the soothing measurement is reported" \
    || no "works: the soothing measurement is reported" "not in $(style_lines works)"
  grep -q "control: the bright style moved 3500 Hz the other way" "$TMP/works/out" \
    && ok "works: the bright control agrees" \
    || no "works: the bright control agrees" "not in $(style_lines works)"
  grep -q "^sox .*equalizer 180 1.0q 2.16 .*equalizer 3500 1.0q -1.20" "$STUB_LOG" \
    && ok "works: sox was handed the soothing preset's real EQ, in order" \
    || no "works: sox was handed the soothing preset's real EQ" "$(grep -c '^sox' "$STUB_LOG") sox calls"
else
  no "works: scenario could not run" "schema did not compile"
fi

# --- 2. sox exits 0 and changes nothing --------------------------------------
if scenario sox-noop passthrough yes on yes; then
  if grep -q "^RESULT singing FAIL the soothing style was requested but did not measurably change" "$TMP/sox-noop/out"; then
    ok "sox-noop: a pass-through sox makes the soothing check FAIL, not PASS"
  else
    no "sox-noop: the soothing check went red" "$(style_lines sox-noop | tr '\n' ';')"
  fi
  grep -q "^RESULT singing FAIL control: the bright style did not move 3500 Hz" "$TMP/sox-noop/out" \
    && ok "sox-noop: the bright control goes red too, so it is not a rubber stamp" \
    || no "sox-noop: the bright control goes red too" "$(style_lines sox-noop | tr '\n' ';')"
else
  no "sox-noop: scenario could not run" "schema did not compile"
fi

# --- 3. sox exits 0 and writes nothing ---------------------------------------
if scenario sox-silent silent yes on yes; then
  if grep -qE "^RESULT singing FAIL (could not sing and style the line|.*sox wrote no audio)" "$TMP/sox-silent/out"; then
    ok "sox-silent: an exit-0 sox that wrote nothing is a FAIL"
  else
    no "sox-silent: an exit-0 sox that wrote nothing is a FAIL" "$(style_lines sox-silent | tr '\n' ';')"
  fi
else
  no "sox-silent: scenario could not run" "schema did not compile"
fi

# --- 4. no neural voice on the image -----------------------------------------
if scenario no-kokoro apply no off yes; then
  if grep -q "^RESULT singing SKIP not singing on this image: kokoro is not installed" "$TMP/no-kokoro/out"; then
    ok "no-kokoro: the skip names the real cause (kokoro is not installed)"
  else
    no "no-kokoro: the skip names the real cause" "$(grep -E '^RESULT singing SKIP' "$TMP/no-kokoro/out" | tr '\n' ';')"
  fi
  if grep -q "^RESULT singing FAIL" "$TMP/no-kokoro/out"; then
    no "no-kokoro: a stock image must not FAIL the file" "$(grep -E '^RESULT singing FAIL' "$TMP/no-kokoro/out" | tr '\n' ';')"
  else
    ok "no-kokoro: a stock image emits no FAIL (so cmd_slot_test's pass==0 rule cannot fire)"
  fi
  # cmd_slot_test counts `RESULT <name> PASS|FAIL|SKIP`; a file that emitted
  # only SKIPs is reported FAILED by the harness, so the stock-image run has to
  # still contain a real PASS. The tone stage is that PASS.
  grep -qE "^RESULT singing PASS " "$TMP/no-kokoro/out" \
    && ok "no-kokoro: the pitch-movement PASS still runs without a neural voice" \
    || no "no-kokoa: the pitch-movement PASS still runs" "no PASS line at all"
else
  no "no-kokoro: scenario could not run" "schema did not compile"
fi

# --- 5. consent withheld -----------------------------------------------------
if scenario consent-off apply yes off yes; then
  grep -q "^RESULT singing SKIP not singing on this image: .*kokoro-tts-enabled is off" "$TMP/consent-off/out" \
    && ok "consent-off: an installed-but-unpermitted voice is skipped, not used" \
    || no "consent-off: an installed-but-unpermitted voice is skipped" "$(grep -E '^RESULT singing SKIP' "$TMP/consent-off/out" | tr '\n' ';')"
else
  no "consent-off: scenario could not run" "schema did not compile"
fi

# --- 6. no pitch shifter -----------------------------------------------------
if scenario no-shifter apply yes on no; then
  grep -q "^RESULT singing SKIP no pitch shifter is installed" "$TMP/no-shifter/out" \
    && ok "no-shifter: the tone stage skips on the missing transposer, naming it" \
    || no "no-shifter: the tone stage skips on the missing transposer" "$(grep -E '^RESULT singing (FAIL|SKIP)' "$TMP/no-shifter/out" | tr '\n' ';')"
  # And it must SKIP, not FAIL: "per-syllable pitch did not move as the plan
  # says" describes a failure to do something as a failure of the thing, which is
  # the confident-wrong-answer shape this repo keeps being bitten by.
  if grep -q "^RESULT singing FAIL" "$TMP/no-shifter/out"; then
    no "no-shifter: a missing transposer is never reported as a wrong pitch" "$(grep -E '^RESULT singing FAIL' "$TMP/no-shifter/out" | tr '\n' ';')"
  else
    ok "no-shifter: a missing transposer is never reported as a wrong pitch"
  fi
else
  no "no-shifter: scenario could not run" "schema did not compile"
fi

# --- 7. the style itself regresses -------------------------------------------
if scenario style-gone apply yes on yes neutral; then
  if grep -qE "^RESULT singing FAIL .*soothing preset asks for no change" "$TMP/style-gone/out"; then
    ok "style-gone: a preset that stopped asking for anything is a FAIL, not a SKIP"
  else
    no "style-gone: a preset that stopped asking for anything is a FAIL" "$(style_lines style-gone | tr '\n' ';')"
  fi
else
  no "style-gone: scenario could not run" "schema did not compile"
fi

# --- the harness's own contract ----------------------------------------------
if bash -n "$SLOT_TEST" 2>/dev/null; then
  ok "bash -n is clean on the slot-test"
else
  no "bash -n is clean on the slot-test" "syntax error"
fi

bad=""
for name in works sox-noop sox-silent no-kokoro consent-off no-shifter style-gone; do
  [[ -f "$TMP/$name/out" ]] || continue
  while IFS= read -r line; do
    # The trailing `RESULT singing DONE failures=N` summary is not a verdict and
    # cmd_slot_test counts neither PASS nor FAIL on it (boot.sh greps '^RESULT .
    # * PASS' / '^RESULT .* FAIL'), so it is not what this check is about.
    case "$line" in
      "RESULT singing DONE failures="*) continue ;;
    esac
    [[ "$line" =~ ^RESULT\ singing\ (PASS|FAIL|SKIP)\  ]] || bad+="$name: $line"$'\n'
  done < <(grep '^RESULT singing ' "$TMP/$name/out")
done
if [[ -z "$bad" ]]; then
  ok "every emitted line is RESULT singing (PASS|FAIL|SKIP), so the harness counts them"
else
  no "every emitted line is RESULT singing (PASS|FAIL|SKIP)" "$bad"
fi

# Each stub has to have run where the scenario claims to use it, or the
# scenario's verdict is about something else entirely.
declare -A WANT=( [works]="sox soundstretch espeak-ng sherpa-offline-tts"
                  [sox-noop]="sox soundstretch"
                  [style-gone]="sox soundstretch" )
# no-shifter and no-kokoro are deliberately absent: their soundstretch and
# sherpa stubs must NOT run, which is the point of those scenarios. A stub log
# that shows them running would mean the scenario tested nothing.
for name in "${!WANT[@]}"; do
  for who in ${WANT[$name]}; do
    grep -q "^$who " "$STUB_LOG" \
      && ok "$name: the $who stub really ran" \
      || no "$name: the $who stub really ran" "no invocation in the log"
  done
done

echo
echo "pass $pass_n / fail $fail_n"
[ "$fail_n" -eq 0 ]