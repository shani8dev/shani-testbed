#!/bin/bash
# chronoa-whisper-prompt-results — proves slot-tests/chronoa-whisper-prompt.sh can
# go red, on the host, with no slot and no docker.
#
# WHY THIS FILE EXISTS. chronoa-singing-results.sh established the argument and
# chronoa-cli-formats-results.sh repeated it: a slot-test that has only ever
# printed PASS proves the check ran, not that it can say no. Every assertion
# here is driven through the seam the slot-test reads captures from
# ($CHRONOA_WHISPER_CAPTURE_DIR), which is the path a real run takes too - so the
# assertions exercised here are the assertions that run on a slot.
#
# The doctored captures are the three failures that matter, and each is a real
# claim rather than a hypothetical:
#
#   - **the two conditions identical** - whisper ignoring `--prompt` entirely. A
#     vocabulary feature would then be silently dead on every ShaniOS machine,
#     and nothing in the tree would say so. This is the check's reason to exist:
#     the WER *direction* is deliberately NOT asserted, because the 2026-10-12
#     finding came from espeak-ng synthetic audio and cannot settle a
#     recognition question for the distribution we ship.
#   - **an empty transcript** - a prompt that suppresses output is a different
#     failure from one that changes it, and "both conditions transcribed
#     something" has to tell them apart.
#   - **a capture directory that does not exist** - the seam silently yielding
#     nothing must not read as a pass. An absence presented as a pass is the
#     failure this repository records most often.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SLOT_TEST="$ROOT/slot-tests/chronoa-whisper-prompt.sh"

pass=0; fail=0
ok() { printf 'ok %d - %s\n' "$((++pass))" "$1"; }
no() { printf 'not ok %d - %s\n' "$((++fail))" "$1"; }

# Verdicts are matched by NAME and VERDICT, never by the RESULT line's spacing:
# the name field is `%-46s`, so an assertion written against a counted run of
# spaces fails when the name length changes.
# **The name is every field between `RESULT` and the verdict, joined.**
# `res()` prints `RESULT %-46s %s`, and these names are several words long, so
# awk's `$2` is only the first of them - and every lookup below silently missed,
# reporting six assertions failing against a slot-test that was answering them.
# The other self-tests avoid this by using single-word names; these cannot.
verdict() { # verdict <output> <name> <PASS|FAIL|SKIP>
  printf '%s\n' "$1" | awk -v n="$2" -v want="$3" '
    $1 == "RESULT" {
      v = $NF
      name = $2
      for (i = 3; i < NF; i++) name = name " " $i
      gsub(/[ 	]+/, " ", name)
      if (name == n && v == want) { found = 1 }
    }
    END { exit(found ? 0 : 1) }'
}

run_capture() { # run_capture <dir> -> slot-test output
  CHRONOA_WHISPER_CAPTURE_DIR="$1" \
  CHRONOA_WHISPER_MODEL=/nonexistent/so/the/availability/branch/is/reached \
  bash "$SLOT_TEST" 2>/dev/null
}

echo "# 1.1 whisper-cli is absent here, so it says so and settles nothing"
out="$(CHRONOA_WHISPER_CAPTURE_DIR=/dev/null bash "$SLOT_TEST" 2>/dev/null)"
if command -v whisper-cli >/dev/null 2>&1; then
  ok "whisper-cli exists on this host, so the absent-tool branch is not exercised"
else
  if verdict "$out" "whisper-cli is installed" "SKIP"; then
    ok "no whisper-cli reports SKIP rather than PASS"
  else
    no "no whisper-cli reports SKIP rather than PASS"
  fi
fi

echo "# 1.2 a real capture: both conditions transcribed, and --prompt was honoured"
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
i=0
while IFS='|' read -r _pop text; do
  i=$((i + 1)); n=$(printf '%02d' "$i")
  : > "$d/s$n.wav"
  # The good case: the prompt genuinely changes the transcript, and the prompt
  # condition is WORSE - the 2026-10-12 direction, kept here because the point is
  # that the slot-test measures it rather than asserting it.
  printf 'extract the archive into my downloads folder\n' > "$d/s$n.txt"
  printf 'extract archive in to my download folder.\n'    > "$d/s$n-prompt.txt"
done <<'CORPUS'
domain|Extract the archive into my downloads folder
domain|Check the btrfs snapshots for the boot slot
domain|Dismiss the screen reader for a moment
domain|List the broken symbolic links in my home
domain|Search the web for the weather in Pune
ordinary|What is the battery level right now
ordinary|Convert fifty euros to rupees
ordinary|Remind me to buy milk at six
ordinary|Lock the screen now
ordinary|Set a timer for ten minutes
CORPUS

out="$(run_capture "$d")"
if verdict "$out" "both conditions transcribed something" "PASS"; then
  ok "a full capture PASSes 'both conditions transcribed something'"
else
  no "a full capture PASSes 'both conditions transcribed something'"
fi
if verdict "$out" "the prompt changes what is transcribed" "PASS"; then
  ok "a capture where the prompt changes the text PASSes"
else
  no "a capture where the prompt changes the text PASSes"
fi
if printf '%s' "$out" | grep -q "no prompt *mean WER"; then
  ok "both word error rates are printed, so the direction is visible"
else
  no "both word error rates are printed, so the direction is visible"
fi

echo "# 1.3 DOCTORED: identical transcripts - whisper ignoring --prompt"
d2="$(mktemp -d)"
i=0
while IFS='|' read -r _pop text; do
  i=$((i + 1)); n=$(printf '%02d' "$i")
  : > "$d2/s$n.wav"
  printf 'the same transcript either way\n' > "$d2/s$n.txt"
  cp "$d2/s$n.txt" "$d2/s$n-prompt.txt"
done <<'CORPUS'
domain|Extract the archive into my downloads folder
domain|Check the btrfs snapshots for the boot slot
domain|Dismiss the screen reader for a moment
domain|List the broken symbolic links in my home
domain|Search the web for the weather in Pune
ordinary|What is the battery level right now
ordinary|Convert fifty euros to rupees
ordinary|Remind me to buy milk at six
ordinary|Lock the screen now
ordinary|Set a timer for ten minutes
CORPUS

out="$(run_capture "$d2")"
if verdict "$out" "the prompt changes what is transcribed" "FAIL"; then
  ok "identical transcripts FAIL 'the prompt changes what is transcribed'"
else
  no "identical transcripts FAIL 'the prompt changes what is transcribed'"
fi

echo "# 1.4 DOCTORED: one condition silent"
d3="$(mktemp -d)"
i=0
while IFS='|' read -r _pop text; do
  i=$((i + 1)); n=$(printf '%02d' "$i")
  : > "$d3/s$n.wav"
  printf 'something audible was said here\n' > "$d3/s$n.txt"
  [ "$i" -eq 4 ] && : > "$d3/s$n-prompt.txt" || cp "$d3/s$n.txt" "$d3/s$n-prompt.txt"
done <<'CORPUS'
domain|Extract the archive into my downloads folder
domain|Check the btrfs snapshots for the boot slot
domain|Dismiss the screen reader for a moment
domain|List the broken symbolic links in my home
domain|Search the web for the weather in Pune
ordinary|What is the battery level right now
ordinary|Convert fifty euros to rupees
ordinary|Remind me to buy milk at six
ordinary|Lock the screen now
ordinary|Set a timer for ten minutes
CORPUS

out="$(run_capture "$d3")"
if verdict "$out" "both conditions transcribed something" "FAIL"; then
  ok "one silent condition FAILs 'both conditions transcribed something'"
else
  no "one silent condition FAILs 'both conditions transcribed something'"
fi

echo "# 1.5 DOCTORED: the capture directory does not exist at all"
out="$(run_capture "$d/no/such/place")"
if verdict "$out" "both conditions transcribed something" "FAIL"; then
  ok "an absent capture directory FAILS rather than passing quietly"
else
  no "an absent capture directory FAILS rather than passing quietly"
fi

echo "# 1.6 the shell parses (bash -n catches what running does not)"
if bash -n "$SLOT_TEST" 2>/dev/null; then
  ok "the slot-test parses"
else
  no "the slot-test parses"
fi

echo "# 1.7 a capture run is CLEAN - stderr free of shell errors"
#
# **This is the check whose absence let a real defect through every other
# assertion above.** `VOCAB` was only assigned in the live branch, and the
# summary prints it under `set -u`, so a capture-mode run died with
# `VOCAB: unbound variable` - and 1.2 to 1.5 still reported PASS, because
# `bash -n` parses without executing and the RESULT lines are printed before the
# summary runs. Eight green checks over a broken run.
#
# It is a real control, not a formality: reverting the declaration puts it back.
err="$(mktemp)"
d5="$(mktemp -d)"
i=0
while IFS='|' read -r _pop _text; do
  i=$((i + 1)); n=$(printf '%02d' "$i")
  : > "$d5/s$n.wav"
  printf 'something audible was said here\n' > "$d5/s$n.txt"
  printf 'something audible was said here\n' > "$d5/s$n-prompt.txt"
done <<'CORPUS'
domain|Extract the archive into my downloads folder
domain|Check the btrfs snapshots for the boot slot
domain|Dismiss the screen reader for a moment
domain|List the broken symbolic links in my home
domain|Search the web for the weather in Pune
ordinary|What is the battery level right now
ordinary|Convert fifty euros to rupees
ordinary|Remind me to buy milk at six
ordinary|Lock the screen now
ordinary|Set a timer for ten minutes
CORPUS
CHRONOA_WHISPER_CAPTURE_DIR="$d5" \
CHRONOA_WHISPER_MODEL=/nonexistent \
  bash "$SLOT_TEST" >/dev/null 2>"$err"
if grep -qE 'unbound variable|: line [0-9]+:' "$err"; then
  no "a capture run is free of shell errors" 
  sed 's/^/    # /' "$err" | head -4
else
  ok "a capture run is free of shell errors"
fi
rm -rf "$d5" "$err"

rm -rf "$d2" "$d3"
printf '\n1..%d\n' "$((pass + fail))"
printf '# passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]