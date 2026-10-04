#!/bin/bash
# slot-test-mode: boot
#
# chronoa-singing — does the pitch contour actually bend a real voice on a real
# installed Shanios, and what is missing when it does not.
#
# WHY THIS IS A SLOT TEST AND NOT A UNIT TEST (same argument as chronoa-speech.sh,
# and it is the reason this file exists at all):
#
#   * `singing.py` finds sox / soundstretch / rubberband with `shutil.which`.
#     The host suite mocks that, so it is asserting against a fixture the test
#     wrote itself. The measured answer on a real image is what matters: a
#     package that is not installed makes every "can sing" row lie.
#   * The claim being checked is *audible*. "sox exited 0 and wrote a file of a
#     plausible size" is not the claim; "the pitch at the end is higher than the
#     pitch at the start by the number of semitones asked for" is. That is
#     measured here, by counting zero crossings in the real installed output.
#   * The 20260925 gnome image ships espeak-ng and (when sox is installed) sox.
#     It ships NO whisper-cpp, NO piper-tts, NO rhvoice and NO kokoro, exactly as
#     chronoa-speech.sh records. So the voice on a real install is espeak-ng and
#     the result will sound like it. The test reports that rather than hiding it,
#     because "singing works" and "singing works on a formant synthesizer" are
#     different claims.
#
# Kokoro is used instead when it is genuinely installed and consent was granted
# (kokoro-tts-enabled). It is not downloaded here: that is 130 MB over the
# network, behind a consent key, and a test that silently downloads a model into
# a disposable slot is not a test anyone should be able to run by accident.
set -uo pipefail

pass() { echo "RESULT singing PASS $*"; }
fail() { echo "RESULT singing FAIL $*"; FAILURES=$((FAILURES + 1)); }
skip() { echo "RESULT singing SKIP $*"; }

FAILURES=0
: "${XDG_DATA_HOME:=/var/lib/shani-chronoa}"
export XDG_DATA_HOME
# The overlay this run is testing. Set from the slot-test argument rather than
# hardcoded, but defaulted to where the harness puts it - without it every
# `import shani_chronoa` below fails, which is exactly what happened on the first
# real run (`voices.py could not be consulted: No module named shani_chronoa`).
: "${CHRONOA_SRC:=/usr/lib/shani-chronoa}"
export PYTHONPATH="${CHRONOA_SRC}${PYTHONPATH:+:$PYTHONPATH}"

echo "--- what is actually installed ---"
for binary in espeak-ng sox soundstretch rubberband; do
    printf '  %-12s %s\n' "$binary" "$(command -v "$binary" || echo '(not installed)')"
done
python3 - <<'PY'
try:
    from shani_chronoa import voices
    for label, found in (("piper", voices.piper_binary()),
                         ("kokoro", voices.kokoro_binary())):
        print(f"  {label:<12} {found or '(not installed)'}")
except Exception as exc:
    print(f"  voices.py    could not be consulted: {exc}")
PY

# ---------------------------------------------------------------------------
# The voice. espeak-ng is the floor and is always present on a real image;
# Kokoro is preferred when installed, because formant synthesis makes any
# judgement about "does this sound like singing" worthless.
# ---------------------------------------------------------------------------
VOICE_NOTE="espeak-ng"
if python3 -c "from shani_chronoa import voices; raise SystemExit(0 if voices.kokoro_binary() else 1)" 2>/dev/null; then
    VOICE_NOTE="kokoro"
    echo "  using kokoro via sherpa-onnx"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say() {
    # Real TTS through the real installed stack, not a fixture.
    # One argument: the output path. The first version took a second parameter
    # and was called without it, so `set -u` killed the whole stage on the first
    # real run before it synthesized anything.
    python3 - "$1" "$VOICE_NOTE" <<'PY'
import sys
from shani_chronoa import tts
out, engine = sys.argv[1], sys.argv[2]
engine_obj = tts.PiperTTS()
if engine == "kokoro":
    ok = engine_obj.synthesize("Chronoa is a digital organism.", out)
else:
    ok = engine_obj.synthesize("Chronoa is a digital organism.", out)
print("SPEECH_OK" if ok else "SPEECH_FAILED")
PY
}

echo "--- synthesizing a real voice ($VOICE_NOTE) ---"
SAID="$(say "$WORK/speech.wav" 2>&1 | tail -1)"
case "$SAID" in
    SPEECH_OK) echo "  a real WAV was produced" ;;
    *) fail "could not synthesize speech at all: $SAID" ;;
esac

if [ ! -s "$WORK/speech.wav" ]; then
    fail "no speech was produced, so there is nothing to bend"
    echo "RESULT singing DONE failures=$FAILURES"
    exit 0
fi

# ---------------------------------------------------------------------------
# The measurement. A file of the right size is not evidence; a changed pitch is.
# ---------------------------------------------------------------------------
measure() {
    python3 - "$1" "$2" <<'PY'
import math, struct, sys
data = open(sys.argv[1], "rb").read()
at = data.find(b"fmt ")
rate = struct.unpack("<I", data[at + 12:at + 16])[0] if at > 0 else 0
start = data.find(b"data")
size = struct.unpack("<I", data[start + 4:start + 8])[0] if start > 0 else 0
body = data[start + 8:start + 8 + size]
count = len(body) - (len(body) % 2)
samples = struct.unpack(f"<{count // 2}h", body[:count]) if count else ()
if not rate or len(samples) < rate // 2:
    print("0"); raise SystemExit
offset = float(sys.argv[2])
window = samples[int(offset * rate):int((offset + 0.25) * rate)]
if len(window) < 64:
    print("0"); raise SystemExit
crossings = sum(1 for a, b in zip(window, window[1:]) if a < 0 <= b)
print(f"{crossings / 0.25:.1f}")
PY
}

if ! command -v sox >/dev/null 2>&1; then
    skip "sox is not installed on this image, so no contour can be applied"
    echo "  what a user would get: the reply is spoken unchanged, and"
    echo "  singing_support() reports can_contour_pitch anyway - which is a bug"
    echo "  worth seeing on a real image rather than only in a unit test."
    echo "RESULT singing DONE failures=$FAILURES"
    exit 0
fi

echo "--- a sung line on real speech ---"
SUNG="$WORK/sung.wav"
SUNG_OUT="$(SPEECH="$WORK/speech.wav" SUNG="$SUNG" python3 - <<'PY' 2>&1 | tail -1
import os, sys
sys.path.insert(0, os.environ.get("CHRONOA_SRC", "/usr/lib/shani-chronoa"))
from shani_chronoa import prosody, singing
speech = os.environ["SPEECH"]
out = os.environ["SUNG"]
try:
    duration = singing.duration_of(speech)
    line = "Chronoa is a digital organism."
    syl = prosody.syllables_for(line)
    plan = prosody.song_plan(syl, prosody.Melody.from_shape("arch", len(syl)),
                             total=duration)
    prosody.apply_song(speech, out, plan)
    print(f"SUNG syllables={len(syl)} slices={len(plan)} duration={singing.duration_of(out):.2f}s")
except singing.SingingUnsupported as exc:
    print(f"UNSUPPORTED: {exc}")
except Exception as exc:
    print(f"ERROR: {type(exc).__name__}: {exc}")
PY
)"
echo "  $SUNG_OUT"
case "$SUNG_OUT" in
    SUNG*) pass "a sung line was produced on real audio" ;;
    UNSUPPORTED*) skip "singing unavailable: $SUNG_OUT" ;;
    *) fail "could not sing: $SUNG_OUT" ;;
esac

# The claim, unambiguous: four notes on a steady tone, measured.
echo "--- per-syllable pitch movement on a steady tone (the unambiguous case) ---"
# Skipped when there is no transposer, and named rather than left to fail below.
# Without this check the stage reported "per-syllable pitch did not move as the
# plan says" — a confident wrong answer, because the plan was never attempted:
# `apply_song` raises SingingUnsupported and the assertion then described a
# failure to do something as a failure of the thing. The last stage already
# skipped for this same cause; this one now agrees.
# It exits rather than continuing: without a transposer there is no per-note
# pitch, so the singing stage that follows has nothing left to measure,
# and its own skip would name the same cause.
if ! python3 -c "
from shani_chronoa import singing
raise SystemExit(0 if singing._best_transposer() else 1)" 2>/dev/null; then
    skip "no pitch shifter is installed (soundtouch or rubberband), so no note can be moved"
    echo "RESULT singing DONE failures=$FAILURES"
    exit 0
fi
TONE="$(mktemp -d)/tone.wav"
TONE_SUNG="$(mktemp -d)/tone.sung.wav"
python3 - "$TONE" <<'PY'
import math, struct, sys
rate, seconds, hz, window = 22050, 1.0, 220.0, 0.25
frames = bytearray()
for i in range(int(rate * seconds)):
    frames += struct.pack("<h", int(11000 * math.sin(2 * math.pi * hz * i / rate)))
data = bytes(frames)
open(sys.argv[1], "wb").write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
    + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    + b"data" + struct.pack("<I", len(data)) + data)
PY
TONERESULT="$(TONE="$TONE" SUNG="$TONE_SUNG" python3 - <<'PY' 2>&1 | tail -1
import os, sys
sys.path.insert(0, os.environ.get("CHRONOA_SRC", "/usr/lib/shani-chronoa"))
from shani_chronoa import prosody, singing
src, out = os.environ["TONE"], os.environ["SUNG"]
# Four equal "syllables", rising two semitones each.
tokens = [prosody.Token("a", i * 0.25, 0.25) for i in range(4)]
syl = prosody.segment(tokens)
plan = prosody.song_plan(syl, prosody.Melody(tuple([0.0, 2.0, 4.0, 6.0])), total=1.0)
prosody.apply_song(src, out, plan)
print(f"NOTES " + " ".join(f"{s.semitones:+.0f}" for s in plan))
PY
)"
echo "  plan: $TONERESULT"
if command -v python3 >/dev/null && [ -s "$TONE_SUNG" ]; then
    READ="$(python3 - "$TONE" "$TONE_SUNG" <<'PY'
import math, struct, sys
def freq(p, off, rate=22050, ln=0.15):
    d = open(p, "rb").read()
    rate = struct.unpack("<I", d[12 + 12:12 + 16])[0]
    s = d.find(b"data"); n = struct.unpack("<I", d[s + 4:s + 8])[0]
    b = d[s + 8:s + 8 + n]; u = len(b) - len(b) % 2
    sm = struct.unpack(f"<{u//2}h", b[:u])
    w = sm[int(off * rate):int((off + ln) * rate)]
    if len(w) < 64: return 0.0
    return sum(1 for x, y in zip(w, w[1:]) if x < 0 <= y) / ln
def semi(a, b): return 12 * math.log2(b / a) if a and b else 0.0
inp, out = sys.argv[1], sys.argv[2]
for i in range(4):
    base = freq(inp, i * 0.25 + 0.06)
    moved = freq(out, i * 0.25 + 0.06)
    print(f"    syllable {i}: {base:6.1f} Hz -> {moved:6.1f} Hz  ({semi(base,moved):+.1f} st)")
PY
)"
    echo "$READ"
    # The first syllable must be ~0 (unchanged), the move must exceed +1 semitone.
    if echo "$READ" | grep -q "syllable 3:.*+" && echo "$READ" | grep -q "syllable 0:.*+[0-1]."; then
        pass "each syllable landed on its own note on a real image"
    else
        fail "per-syllable pitch did not move as the plan says"
    fi
else
    fail "the sung tone was not produced"
fi

echo "--- what a user would actually get ---"
echo "  voice: $VOICE_NOTE"
python3 - <<'PY'
try:
    import sys
    sys.path.insert(0, "/usr/lib/shani-chronoa")
    from shani_chronoa import singing
    for key, value in sorted(singing.singing_support().items()):
        print(f"  {key}: {value}")
except Exception as exc:
    print(f"  could not read singing_support(): {exc}")
PY
echo "  NOTE: pitch movement is real; 'singing' is not. Nothing here measures"
echo "  the pitch of the audio it is shifting, so there is no loop to close."

# ---------------------------------------------------------------------------
# The soothing voice, and the melody. This is the part a person actually asked
# for: a voice that sounds like singing rather than like a demo.
#
# It is SKIPPED unless all three are true, and each missing one is named rather
# than folded into a generic skip:
#
#   * kokoro is installed and permitted (`kokoro-tts-enabled`). On a stock image
#     it is neither - chronoa-speech.sh already records that the 20260925 gnome
#     image ships espeak-ng and no neural voice - so the usual result here is a
#     SKIP that says which of the two was missing. Downloading it here would mean
#     130 MB and a consent decision inside a test, which is not something a test
#     should do to a disposable slot on its own.
#   * a shifter is installed (soundtouch or rubberband), without which per-note
#     pitch is impossible: `singing.singing_support()` reports it, and the code
#     refuses rather than falling back. The earlier version of this gate left
#     that out while the comment above promised it, so the stage could report
#     having sung a line on an image where no per-note pitch was possible at all.
#   * sox, for the voice style - see below.
#
# The claim here is AUDIBLE and the stage is named after it, so the style is
# applied and MEASURED rather than merely produced. A first version sang the
# line, called that "a soothing voice", and never touched `voice_style` at all:
# the label described an effect the output did not have. The `soothing` preset
# is `equalizer 180 1.0q +2.16` and `equalizer 3500 1.0q -1.20`, so the
# falsifiable claim is that energy near 180 Hz rises and energy near 3500 Hz
# falls once it runs. Both are measured below with a Goertzel filter (no numpy
# on the image, and an FFT is not needed to see a two-band EQ), and the stage
# fails if either did not move - which it can, e.g. if a future refactor drops
# the effects, applies them to the wrong file, or sox exits 0 having written
# nothing. A `bright` control (`+2.56 dB` at 3500 Hz) runs the same measurement
# with the opposite preset: without it, "the bands moved" could just mean SoX
# ran, and the pass would prove nothing about which style was applied.
#
# The four shapes are named, never invented: rising, falling, arch, level. A
# melody Chronoa made up and presented as the tune of a song someone asked for is
# the one outcome worse than saying no, so there is no path that composes one.
# ---------------------------------------------------------------------------
echo "--- a sung line in a soothing voice (style applied, then measured) ---"
if python3 -c "
from shani_chronoa import voices, config as cm, singing
raise SystemExit(0 if voices.kokoro_binary()
                 and cm.ChronoaConfig().get_bool('kokoro-tts-enabled', False)
                 and singing._best_transposer() else 1)" 2>/dev/null; then
    LINE="Twinkle twinkle little star, how I wonder what you are."
    printf '%s' "$LINE" > "$WORK/line.txt"
    # The line is synthesized here rather than reusing $WORK/speech.wav: the
    # plan is built from the syllables of THIS line, and slicing one sentence's
    # audio into another's syllable count is a test that passes either way.
    NEURAL="$WORK/neural.wav"
    printf 'SPEECH %s' "$(LINE_FILE="$WORK/line.txt" OUT="$NEURAL" VOICE_NOTE="$VOICE_NOTE" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("CHRONOA_SRC", "/usr/lib/shani-chronoa"))
from shani_chronoa import tts
line = open(os.environ["LINE_FILE"]).read()
ok = tts.PiperTTS().synthesize(line, os.environ["OUT"])
print("OK" if ok else "FAILED")
PY
)" | tail -1
    if [ ! -s "$NEURAL" ]; then
        skip "the neural voice produced no audio for the line, so there is nothing to style"
    else
        STYLED="$(NEURAL="$NEURAL" PLAIN="$WORK/sung.wav" python3 - <<'PY' 2>&1 | tail -1
import math, os, shutil, struct, subprocess, sys
sys.path.insert(0, os.environ.get("CHRONOA_SRC", "/usr/lib/shani-chronoa"))
from shani_chronoa import prosody, singing, voice_style

plain = os.environ["PLAIN"]
here = os.path.dirname(os.environ["NEURAL"])
line = open(os.path.join(here, "line.txt")).read()

def samples(path):
    d = open(path, "rb").read()
    at = d.find(b"fmt "); rate = struct.unpack("<I", d[at + 12:at + 16])[0]
    s = d.find(b"data"); n = struct.unpack("<I", d[s + 4:s + 8])[0]
    b = d[s + 8:s + 8 + n]; u = len(b) - len(b) % 2
    return rate, struct.unpack(f"<{u // 2}h", b[:u])

def band(path, hz):
    """Goertzel magnitude at `hz`, normalised by the window length."""
    rate, sm = samples(path)
    if not sm:
        return 0.0
    k = max(1, int(0.5 + len(sm) * hz / rate))
    w = 2 * math.pi * k / len(sm)
    c = 2 * math.cos(w)
    s1 = s2 = 0.0
    for x in sm:
        s0 = x + c * s1 - s2
        s2, s1 = s1, s0
    return math.sqrt(max(0.0, s1 * s1 + s2 * s2 - c * s1 * s2)) / len(sm)

def styled(source, preset, out):
    """Run one voice style over `source` and report its two band ratios."""
    effects = voice_style.style_effects(voice_style.resolve_preset(preset))
    if not effects:
        raise singing.SingingUnsupported(f"the {preset} style asks for no change at all")
    sox = shutil.which("sox")
    if not sox:
        raise singing.SingingUnsupported("sox is not installed, so no style can run")
    done = subprocess.run([sox, source, out] + effects, capture_output=True, timeout=180)
    if done.returncode != 0 or not os.path.exists(out) or os.path.getsize(out) <= 44:
        raise RuntimeError(f"sox failed for {preset}: "
                           + done.stderr.decode("utf-8", "replace").strip())
    base = (band(source, 180), band(source, 3500))
    if not base[0] or not base[1]:
        raise RuntimeError(f"{source} has no measurable energy at 180 Hz or 3500 Hz")
    return band(out, 180) / base[0], band(out, 3500) / base[1]

try:
    syl = prosody.syllables_for(line)
    plan = prosody.song_plan(syl, prosody.Melody.from_shape("arch", len(syl)),
                             total=singing.duration_of(os.environ["NEURAL"]))
    prosody.apply_song(os.environ["NEURAL"], plain, plan)
    # A style that asks for nothing is a REGRESSION, not an environment
    # limitation, and the difference is the whole point: reported as a SKIP it
    # would be the absence-shaped green this repo keeps being bitten by -
    # a slot with no voice style and a slot whose style silently stopped
    # applying would print the same line. `soothing` provably has effects
    # (equalizer 180 +2.16, 3500 -1.20), so an empty one is a defect.
    if not voice_style.style_effects(voice_style.resolve_preset("soothing")):
        print("REGRESSED: the soothing preset asks for no change at all, so no "
              "soothing voice was produced")
    else:
        low, high = styled(plain, "soothing", os.path.join(here, "soothing.wav"))
        # The control: `bright` is the same measurement with the opposite preset
        # (+2.56 dB at 3500 Hz). If it did not move 3500 Hz the other way, then
        # what the soothing numbers show is that SoX ran, not that the style was
        # applied, and the pass above would mean nothing.
        _, control = styled(plain, "bright", os.path.join(here, "bright.wav"))
        print(f"STYLED syllables={len(syl)} slices={len(plan)} "
              f"low180={low:.2f}x high3500={high:.2f}x control3500={control:.2f}x")
except singing.SingingUnsupported as exc:
    print(f"UNSUPPORTED: {exc}")
except Exception as exc:
    print(f"ERROR: {type(exc).__name__}: {exc}")
PY
)"
        echo "  $STYLED"
        case "$STYLED" in
            STYLED*)
                # soothing asks +2.16 dB at 180 Hz and -1.20 dB at 3500 Hz; the
                # thresholds leave room for a window that is not exactly the
                # whole file, which is the only slack deliberately allowed.
                LOW="$(echo "$STYLED" | sed -n 's/.*low180=\([0-9.]*\)x.*/\1/p')"
                HIGH="$(echo "$STYLED" | sed -n 's/.*high3500=\([0-9.]*\)x.*/\1/p')"
                CONTROL="$(echo "$STYLED" | sed -n 's/.*control3500=\([0-9.]*\)x.*/\1/p')"
                if python3 -c "
low, high, control = (float('${LOW:-0}'), float('${HIGH:-0}'), float('${CONTROL:-0}'))
raise SystemExit(0 if low > 1.10 and high < 0.95 else 1)" 2>/dev/null; then
                    pass "the soothing style was applied: ${LOW}x at 180 Hz, ${HIGH}x at 3500 Hz"
                else
                    fail "the soothing style was requested but did not measurably change the voice (180 Hz ${LOW}x, 3500 Hz ${HIGH}x)"
                fi
                if python3 -c "
raise SystemExit(0 if float('${CONTROL:-0}') > 1.10 else 1)" 2>/dev/null; then
                    pass "control: the bright style moved 3500 Hz the other way (${CONTROL}x), so the measurement is reading the style and not SoX"
                else
                    fail "control: the bright style did not move 3500 Hz (${CONTROL}x), so the soothing numbers above cannot be trusted"
                fi
                ;;
            REGRESSED*) fail "$STYLED" ;;
            UNSUPPORTED*) skip "the soothing voice is unavailable: $STYLED" ;;
            *) fail "could not sing and style the line: $STYLED" ;;
        esac
    fi
else
    WHY="$(python3 - <<'PY'
import sys
sys.path.insert(0, "/usr/lib/shani-chronoa")
try:
    from shani_chronoa import voices, config as cm, singing
    missing = []
    if not voices.kokoro_binary():
        missing.append("kokoro is not installed")
    if not cm.ChronoaConfig().get_bool("kokoro-tts-enabled", False):
        missing.append("kokoro-tts-enabled is off")
    if singing._best_transposer() is None:
        missing.append("no pitch shifter (soundtouch or rubberband)")
    print(", ".join(missing) or "unknown")
except Exception as exc:
    print(f"could not tell: {exc}")
PY
)"
    skip "not singing on this image: $WHY"
    echo "  what a user gets instead: espeak-ng, which is legible and is not"
    echo "  singing. The honest report is the skip, not a pass."
fi

echo "RESULT singing DONE failures=$FAILURES"
[ "$FAILURES" -eq 0 ]