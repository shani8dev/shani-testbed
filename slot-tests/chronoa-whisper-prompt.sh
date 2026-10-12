#!/bin/bash
# slot-test-mode: boot
#
# chronoa-whisper-prompt — does whisper.cpp's `--prompt` help this system's
# vocabulary, measured on the REAL ShaniOS image.
#
# WHY THIS FILE EXISTS. shani-chronoa's AGENTS.md records a 2026-10-12
# measurement on the dev box: a 77-word vocabulary derived from the skill
# registry made transcription **worse**, helping 1 sentence, harming 4 and tying
# 5, and turning a perfectly-transcribed sentence ("Remind me to buy milk at
# six", 0% WER) into 29% wrong. The mechanism is that whisper mirrors the
# prompt's *shape* as well as its words — 77 period-separated fragments produced
# `extract. archive in to my download folder.` on the very sentence the prompt
# was built to help.
#
# **That is the finding; this file does not re-assert it, and the reason is
# worth stating.** That corpus was espeak-ng synthetic audio on an Ubuntu box,
# which cannot settle a speech-recognition question for the distribution we
# actually ship. Asserting a *direction* here would encode a synthetic result as
# a platform fact — the confident wrong answer. So this measures on the real
# image and **prints** both word error rates; the slot run's value is putting a
# human-voice number beside a synthetic one.
#
# What it DOES assert is the thing synthetic audio cannot contaminate, and it is
# a real product claim: **whisper.cpp honours `--prompt` at all.** If the flag is
# ignored — an older build, a renamed option, a model loaded without it — the
# two conditions return identical text, a vocabulary feature would be silently
# dead on every ShaniOS machine, and nothing anywhere would say so. That is
# checkable here and nowhere else.
#
# The seam is $CHRONOA_WHISPER_CAPTURE_DIR. Set it and the transcriptions are
# read from there instead of running whisper, which is how
# tests/chronoa-whisper-prompt-results.sh drives these same assertions with good
# and doctored input, on the host, with no slot. It is not a test-only back door:
# it is the path the assertions read from in a real run too.
set -u

res() { printf 'RESULT %-46s %s\n' "$1" "$2"; }
pass() { res "$1" PASS; }
fail() { res "$1" FAIL; }
skip() { res "$1" SKIP; }

MODEL="${CHRONOA_WHISPER_MODEL:-}"
CAPTURE="${CHRONOA_WHISPER_CAPTURE_DIR:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- the corpus
#
# Two populations on purpose. `domain` sentences carry this system's own
# catalogue words; `ordinary` carry nothing to teach. A vocabulary prompt that
# works should lift the first and leave the second alone - one that lifts both is
# changing the decoding rather than recognising anything, and a single average
# hides exactly that.
CORPUS=(
  "domain|Extract the archive into my downloads folder"
  "domain|Check the btrfs snapshots for the boot slot"
  "domain|Dismiss the screen reader for a moment"
  "domain|List the broken symbolic links in my home"
  "domain|Search the web for the weather in Pune"
  "ordinary|What is the battery level right now"
  "ordinary|Convert fifty euros to rupees"
  "ordinary|Remind me to buy milk at six"
  "ordinary|Lock the screen now"
  "ordinary|Set a timer for ten minutes"
)

# The vocabulary is derived from the live registry, never hand-typed: the point
# is the machine's own words, and a plausible sample of them would test the test.
registry_vocabulary() {
  python3 - <<'PY' 2>/dev/null || return 1
import sys
sys.path.insert(0, "/usr/lib/shani-chronoa")
try:
    from shani_chronoa.skills import discover_skills
except Exception:
    raise SystemExit(1)
schemas, _handlers = discover_skills()
names = sorted(s["function"]["name"] for s in schemas)
# Period-separated, which is the shape the 2026-10-12 finding blames for
# mirroring into the transcript. The separator is the period; the spaces *inside*
# an entry stay, so `apply_patch` contributes two words.
joined = ". ".join(n.replace("_", " ") for n in names[:40])
print(joined, end="")
PY
}

# ---------------------------------------------------------------- word error rate
wer() { # wer <reference> <hypothesis>
  python3 - "$1" "$2" <<'PY'
import re, sys
words = lambda s: re.findall(r"[a-z0-9']+", s.lower())
ref, hyp = words(sys.argv[1]), words(sys.argv[2])
if not ref:
    print("0.000"); raise SystemExit
row = list(range(len(hyp) + 1))
for i, r in enumerate(ref, 1):
    new = [i]
    for j, h in enumerate(hyp, 1):
        new.append(min(new[-1] + 1, row[j] + 1, row[j - 1] + (r != h)))
    row = new
print(f"{row[-1] / len(ref):.3f}")
PY
}

# ---------------------------------------------------------------- availability
if ! have whisper-cli; then
  skip "whisper-cli is installed"
  skip "a whisper model is on this machine"
  skip "the prompt changes what is transcribed"
  skip "both conditions transcribed something"
  # **The skip has to carry the reason it is not worth working around.**
  # whisper-cpp is an optdepend and *no image profile installs it*, on purpose:
  # shani-chronoa's AGENTS.md records "no ggml-*.bin exists on any install. Do
  # not 'fix' this by hard-depending whisper-cpp: a user without it must get a
  # working assistant that says so, not a half-configured one whose microphone
  # silently cannot work." So on a slot this is a SKIP by design, and the only
  # way to change it is to change what every ShaniOS install ships.
  cat >&2 <<'MSG'
no whisper-cli here, so this image cannot settle the question.

  This is a SKIP by design, not a missing package. `whisper-cpp` is an
  optdepend and no image profile installs it, deliberately: shani-chronoa's
  AGENTS.md records that a user without it must get a working assistant that
  says so, rather than a half-configured one whose microphone silently cannot
  work. Installing it to make this test run would change what every install
  ships, which is a product decision and not a measurement.

  The dev-box numbers in that file (29.0% against 37.0%) came from espeak-ng
  synthetic audio and are recorded as such. A slot run would add a number for a
  real image; it cannot be had without that decision first.
MSG
  exit 0
fi
pass "whisper-cli is installed"

if [ -z "$MODEL" ] && [ -z "$CAPTURE" ]; then
  for candidate in /var/cache/shani-chronoa/models/ggml-*.bin \
                   /usr/share/shani-chronoa/stt/ggml-*.bin \
                   /usr/local/share/shani-chronoa/ggml-*.bin; do
    [ -r "$candidate" ] && { MODEL="$candidate"; break; }
  done
fi
# **The seam bypasses the model requirement.** With captures supplied there is no
# audio to run a model over, so demanding a model made the self-test skip its way
# out before measuring anything - six failures that were the harness refusing to
# start, reported as six assertions failing.
if [ -z "$MODEL" ] || [ ! -r "$MODEL" ]; then
  if [ -n "$CAPTURE" ]; then
    # **The seam supplies the transcriptions, so no model is needed.** My first
    # fix here was a no-op line (`[ -n "$CAPTURE" ] || true`) that left the skip
    # and the exit in place, so the self-test skipped its way out before
    # measuring anything and reported six assertions failing. An absence
    # presented as a failure, which is the same shape as the one it is guarding.
    :
  else
    skip "a whisper model is on this machine"
    skip "the prompt changes what is transcribed"
    skip "both conditions transcribed something"
    cat >&2 <<'MSG'
a whisper binary is present but no ggml model is readable, so there is no audio
to compare. On a slot this follows from the same recorded boundary: no image
profile installs whisper-cpp, deliberately. Bind a model in with
SHANIOS_TEST_EXTRA_BINDS only if you have already decided that.
MSG
    exit 0
  fi
else
  pass "a whisper model is on this machine"
fi

# **In capture mode there is no vocabulary to derive.** The `-prompt.txt` files
# ARE the prompt condition, and that is what the assertions below compare. The
# first version asked the *installed* package for the registry regardless, got
# nothing on a checkout rather than an install, and SKIPped the one assertion the
# check exists to make - while still emitting its name, so the self-test read the
# SKIP and the later FAIL as two answers to one question.
VOCAB=""            # declared for `set -u`: capture mode never assigns it and the
                    # summary prints it, so an undeclared reference killed the run
PROMPT_APPLIED=0
# In capture mode the prompt's *content* is irrelevant - the `-prompt.txt` file is
# the condition - but the flag still has to be non-empty, or both lookups resolve
# to `sNN.txt` and every sentence compares equal. That made `differing` 0 in
# every run, good and doctored alike, which is why the polarity fix above looked
# like it had broken the good case too.
if [ -n "$CAPTURE" ]; then
  PROMPT_APPLIED=1
  PROMPT_ARG="prompt"
else
  VOCAB="$(registry_vocabulary || true)"
  PROMPT_ARG="$VOCAB"
  [ -n "$VOCAB" ] && PROMPT_APPLIED=1
  [ -n "$VOCAB" ] || echo "the installed package did not yield a vocabulary; measured without it" >&2
fi

# ---------------------------------------------------------------- measure
# **The stem carries the `s`.** The capture branch names files `s01.wav`, and the
# live branch rendered `01.wav` and then looked for `s01.wav` - so whisper was
# handed a path that did not exist, every condition returned nothing, and both
# scored a clean 100% WER. Nothing errored; the harness measured its own silence.
render() { # render <stem> <text> -> writes $WORK/<stem>.wav
  have espeak-ng || return 1
  espeak-ng -v en-us -s 150 -p 40 -w "$WORK/$1.wav" "$2" 2>/dev/null
}

transcribe() { # transcribe <wav> <prompt> -> transcript on stdout
  local wav="$1" prompt="$2"
  if [ -n "$CAPTURE" ]; then
    cat "$CAPTURE/$(basename "$wav" .wav)${prompt:+-$prompt}.txt" 2>/dev/null
    return 0
  fi
  # **`-oj` or nothing comes back.** Without it whisper-cli prints to stdout -
  # which this function sends to /dev/null - and no `<wav>.json` is written, so
  # the parser reads nothing and every sentence scores 100% WER. The live run
  # reported a clean 100.0% on both conditions, which is the shape of a harness
  # that measured its own silence.
  local args=(-m "$MODEL" -l en -t 4 -nt -oj -f "$wav")
  [ -n "$prompt" ] && args+=(--prompt "$prompt")
  ( cd "$WORK" && whisper-cli "${args[@]}" >/dev/null 2>&1 )
  # **`-oj` writes `<input>.json`, extension included** - `s00.wav.json`, not
  # `s00.json`. `with_suffix(".json")` is the wrong call and looks right.
  python3 -c "
import json, sys
try:
    segs = json.load(open(sys.argv[1]))['transcription']
except Exception:
    raise SystemExit(1)
if isinstance(segs, str):
    print(segs.strip(), end='')
else:
    print(' '.join(s.get('text', '') for s in segs).strip(), end='')
" "$wav.json" 2>/dev/null
}

base_wer=0; prompt_wer=0; base_n=0; prompt_n=0
base_text=""; prompt_text=""
# **`differing` counts sentences whose two conditions DISAGREE.** The first
# version called this `identical` and incremented it on inequality, then asserted
# `identical -eq 0` meant "the prompt did something" - so a run where whisper
# ignored `--prompt` entirely, every transcript identical, reported PASS. A green
# line meaning the opposite of what it says, which is the failure this repository
# records for `test_gated_unguarded` and for an `assert 0 == 1`.
differing=0; produced=0

i=0
for entry in "${CORPUS[@]}"; do
  text="${entry#*|}"
  i=$((i + 1))
  if [ -n "$CAPTURE" ]; then
    wav="$WORK/s$(printf '%02d' "$i").wav"; : > "$wav"
  elif ! render "s$(printf '%02d' "$i")" "$text"; then
    skip "the corpus could be rendered"
    skip "the prompt changes what is transcribed"
    skip "both conditions transcribed something"
    echo "espeak-ng is unavailable, so no audio could be made" >&2
    exit 0
  else
    wav="$WORK/s$(printf '%02d' "$i").wav"
  fi

  a="$(transcribe "$wav" "")"
  b="$(transcribe "$wav" "$PROMPT_ARG")"
  base_text="$base_text$a|"; prompt_text="$prompt_text$b|"
  [ -n "$a" ] && [ -n "$b" ] && produced=$((produced + 1))
  [ "$a" = "$b" ] || differing=$((differing + 1))

  base_wer=$(python3 -c "print($base_wer + $(wer "$text" "$a"))")
  prompt_wer=$(python3 -c "print($prompt_wer + $(wer "$text" "$b"))")
  base_n=$((base_n + 1)); prompt_n=$((prompt_n + 1))
done

[ -n "$CAPTURE" ] || rm -f "$WORK"/*.wav "$WORK"/*.json

echo
echo "  measured over $base_n sentence(s), model $(basename "$MODEL")"
echo "  no prompt            mean WER $(python3 -c "print(f'{$base_wer/$base_n:.1%}')")"
echo "  registry vocabulary  mean WER $(python3 -c "print(f'{$prompt_wer/$prompt_n:.1%}')") ($(echo "$VOCAB" | wc -w) words)"
echo "  the dev box measured 29.0% against 37.0% on espeak-ng audio - synthetic"
echo "  speech cannot settle a recognition question; this run is the number for"
echo "  this image, not a verdict."
echo

if [ "$produced" -eq "$base_n" ] && [ "$produced" -gt 0 ]; then
  pass "both conditions transcribed something"
else
  fail "both conditions transcribed something"
fi

# **One emission per name.** A RESULT name emitted twice makes every verdict
# lookup ambiguous - the harness's awk marks the name found on *either* line, so
# a SKIP followed by a FAIL satisfies both a SKIP assertion and a FAIL one.
if [ "$PROMPT_APPLIED" -eq 0 ]; then
  skip "the prompt changes what is transcribed"
elif [ "$differing" -eq 0 ]; then
  fail "the prompt changes what is transcribed"
else
  pass "the prompt changes what is transcribed"
fi