#!/bin/bash
# chronoa-cli-formats-results — proves slot-tests/chronoa-cli-formats.sh can go
# red, on the host, with no slot and no docker.
#
# WHY THIS FILE EXISTS. chronoa-singing-results.sh established the argument: a
# slot-test that has only ever printed PASS proves the check ran, not that it
# can say no. This one drives the same assertions through the seam
# slot-tests/chronoa-cli-formats.sh reads captures from ($CLI_FORMATS_CAPTURE_DIR)
# and feeds them both good and doctored captures.
#
# The seam is not a test-only back door: it is the same path a real slot run
# takes, minus the binaries. Anything the assertions do not read from the
# capture directory (the `present-*` lines, the `ip neigh` shape) runs live and
# is skipped here rather than faked.
#
# The doctored captures are not hypothetical. Three of them are the exact
# measurements this session got wrong on the dev box:
#   - an exit code read through a pipe, so a non-PDF looked like rc=0;
#   - a fontless PDF (really rc=0, empty table) confused with an unreadable
#     file (really rc=1) — the product's docstring recorded the wrong shape;
#   - stderr prose counted as table rows, because the capture merges streams.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SLOT_TEST="$ROOT/slot-tests/chronoa-cli-formats.sh"

pass=0; fail=0
ok()   { printf 'ok %d - %s\n' "$((++pass))" "$1"; }
no()   { printf 'not ok %d - %s\n' "$((++fail))" "$1"; }
# Verdicts are matched by NAME and VERDICT, never by the RESULT line's exact
# spacing: the name field is `%-46s`, so an assertion written against a counted
# run of spaces fails when the name length changes - the same trap as pinning a
# whole command line, recorded in this repo's AGENTS.md for the espeak argv.
verdict() { # verdict <haystack> <name> <PASS|FAIL|SKIP>
  grep -qE "RESULT ${2} +${3}\b" <<<"$1"
}
check() { # check <desc> <haystack> <name> <verdict>
  if verdict "$2" "$3" "$4"; then ok "$1"; else
    no "$1"; printf '#   %s expected %s, got: %s\n' "$3" "$4" \
      "$(grep -oE "RESULT ${3} +\S+" <<<"$2" | head -1)"
  fi
}
absent() { # absent <desc> <haystack> <name> <verdict>
  if verdict "$2" "$3" "$4"; then no "$1"; else ok "$1"; fi
}

T=$(mktemp -d /tmp/chronoa-cli-formats-XXXXXX)
trap 'rm -rf "$T"' EXIT

# A good capture set: real pdffonts output shape, a service-type token, an
# arping that answered without privilege, and the sane banner.
GOOD="$T/good"; mkdir -p "$GOOD"
cat >"$GOOD/pdffonts.out" <<'EOF'
name                                 type              encoding         emb sub uni object ID
------------------------------------ ----------------- ---------------- --- --- --- ---------
Helvetica                            Type 1            Standard         no  no  no       4  0
FakeFont                             TrueType          WinAnsi          yes no  no       5  0
EOF
echo 0 >"$GOOD/pdffonts.rc"
printf 'Syntax Error: Couldn'"'"'t find trailer dictionary\n' >"$GOOD/pdffonts-notpdf.out"
echo 1 >"$GOOD/pdffonts-notpdf.rc"
printf '\n= wlp0s20f3 IPv4 Chromecast-8f2a              _googlecast._tcp     local\n' >"$GOOD/avahi.out"
echo 0 >"$GOOD/avahi.rc"
printf 'ARPING 192.0.2.1\n60 packets transmitted, 0 packets received, 100%% unanswered\n' >"$GOOD/arping-unused.out"
echo 1 >"$GOOD/arping-unused.rc"
printf '\n  # No SCSI scanners found.\n' >"$GOOD/sane.out"
echo 0 >"$GOOD/sane.rc"

out=$(CLI_FORMATS_CAPTURE_DIR="$GOOD" bash "$SLOT_TEST" 2>&1)
check "good captures: table shape passes" "$out" pdffonts-table-shape PASS
if grep -qE "RESULT [a-z0-9-]+ +FAIL" <<<"$out"; then no "good captures: no assertion fails"; else ok "good captures: no assertion fails"; fi

# --- the controls -------------------------------------------------------------
# 1. A table with the real header but no dashed rule: the parser reads its
#    column boundaries from that rule, so its absence must be a failure. The
#    fixture carries the REAL header line - a simplified one passes on the
#    header regex instead, which is a control that cannot fail.
BAD="$T/bad"; mkdir -p "$BAD"; cp "$GOOD"/* "$BAD"/
{ head -1 "$GOOD/pdffonts.out"; sed -n '3p' "$GOOD/pdffonts.out"; } >"$BAD/pdffonts.out"
out=$(CLI_FORMATS_CAPTURE_DIR="$BAD" bash "$SLOT_TEST" 2>&1)
check "no dashed rule fails" "$out" pdffonts-table-shape FAIL

# 2. A non-PDF that lists a font row: the 'no fonts listed' branch rests on an
#    empty table, and one row means that assumption does not hold. Off by one
#    the first time: >1 let a single row through, which is the control's job.
BAD2="$T/bad2"; mkdir -p "$BAD2"; cp "$GOOD"/* "$BAD2"/
printf 'name type encoding emb\n----\nArial Type 1 Standard yes yes no 7 0\n' >"$BAD2/pdffonts-notpdf.out"
out=$(CLI_FORMATS_CAPTURE_DIR="$BAD2" bash "$SLOT_TEST" 2>&1)
check "a font row from a non-PDF fails" "$out" pdffonts-notpdf-contract FAIL

# 3. arping denied a socket: duplicate detection cannot run unprivileged, and
#    check_internet's note must say so rather than calling it a clean result.
BAD3="$T/bad3"; mkdir -p "$BAD3"; cp "$GOOD"/* "$BAD3"/
printf 'arping: socket: Operation not permitted\n' >"$BAD3/arping-unused.out"
echo 2 >"$BAD3/arping-unused.rc"
out=$(CLI_FORMATS_CAPTURE_DIR="$BAD3" bash "$SLOT_TEST" 2>&1)
check "arping without privilege fails" "$out" arping-unprivileged FAIL

# 4. Prose without a service-type token: the honest-empty case, SKIP with the
#    reason named — never a shape FAIL, and never a PASS either.
BAD4="$T/bad4"; mkdir -p "$BAD4"; cp "$GOOD"/* "$BAD4"/
printf '\n  # avahi-browse will now attempt to detect your services.\n' >"$BAD4/avahi.out"
out=$(CLI_FORMATS_CAPTURE_DIR="$BAD4" bash "$SLOT_TEST" 2>&1)
check "prose only SKIPs with its reason" "$out" avahi-browse-shape SKIP
check "the skip names its cause" "$out" avahi-browse-shape "SKIP \(nothing announced"
absent "prose only is not a PASS" "$out" avahi-browse-shape PASS
absent "prose only is not a FAIL" "$out" avahi-browse-shape FAIL

# 5. avahi-browse exiting non-zero: an image question, not a parser one.
BAD5="$T/bad5"; mkdir -p "$BAD5"; cp "$GOOD"/* "$BAD5"/
echo 3 >"$BAD5/avahi.rc"
printf 'Failed to create client object: Daemon not running\n' >"$BAD5/avahi.out"
out=$(CLI_FORMATS_CAPTURE_DIR="$BAD5" bash "$SLOT_TEST" 2>&1)
check "a failing avahi SKIPs" "$out" avahi-browse-shape SKIP

# --- the live-only parts are honest about being live --------------------------
# `present-*` and `ip neigh` run the real binaries; a host without them must
# say so rather than passing. That is the same rule the slot-test applies to an
# image missing a dependency.
out=$(CLI_FORMATS_CAPTURE_DIR="$GOOD" bash "$SLOT_TEST" 2>&1)
if command -v ip >/dev/null 2>&1; then
  check "ip present: the field order is asserted live" "$out" ip-neigh-field-order PASS
else
  check "no ip here: the field-order check is asserted, not skipped" "$out" ip-neigh-field-order "PASS|FAIL"
  absent "no ip here: no invented pass" "$out" ip-neigh-field-order PASS
fi

# --- a hang is its own outcome, not an empty result ---------------------------
# Measured 2026-10-10: this file hung for 57 minutes at `bandwhich --raw`, a
# continuous monitor that never exits. 30 checks had already passed and were
# lost with it. Every probe is now bounded by `timeout`, which records 124.
#
# These two checks exist so the bound cannot rot back into a comment: a run
# that timed out must SKIP naming the bound, and must not be reported as the
# empty-output SKIP whose cause would be wrong.
HANG="$T/hang"; mkdir -p "$HANG"
cp "$GOOD"/* "$HANG"/ 2>/dev/null || true
echo 124 >"$HANG/bandwhich.rc"
printf 'bandwhich,0,0,0,0\n' >"$HANG/bandwhich.out"
: >"$HANG/bandwhich.err"
out=$(CLI_FORMATS_CAPTURE_DIR="$HANG" bash "$SLOT_TEST" 2>&1)
check "a probe that timed out still produces a verdict" "$out" bandwhich-shape SKIP
check "the timeout SKIP names the bound" "$out" bandwhich-shape "SKIP \(did not return within"
absent "a timeout is not reported as an empty-output SKIP" "$out" bandwhich-shape "SKIP .rc=124, no output"

# --- every probe is bounded ----------------------------------------------------
# The structural form of the same rule: an unbounded `if have X; then X ...`
# is what hung, so the check is on the shape of the source rather than on one
# tool's behaviour.
if grep -nE '^\s*if have [a-z0-9_-]+; then (iotop|iostat|nethogs|bandwhich|strace|unrar|cabextract|lrzip|lzop|arj|unar|lsar|7z)\b' "$SLOT_TEST" >/dev/null 2>&1; then
  no "no probe runs its tool without going through the bounded probe()"
  printf '#   an unbounded probe line: %s\n' \
    "$(grep -nE '^\s*if have [a-z0-9_-]+; then (iotop|iostat|nethogs|bandwhich|strace|unrar|cabextract|lrzip|lzop|arj|unar|lsar|7z)\b' "$SLOT_TEST" | head -1)"
else
  ok "no probe runs its tool without going through the bounded probe()"
fi

# --- every RESULT name appears once in the OUTPUT ------------------------------
# **A check nested inside a loop prints once per iteration, and nothing before
# this noticed.** The rclone block landed between a `for t in zcat...` loop's
# `rc=` line and its `res` line, so its six results printed once per
# decompressor - six identical copies - while the summary happily counted them
# as part of "187 pass, 0 fail". A count with duplicate names in it is a count,
# not a measurement.
#
# **Checked on the output, not the source, and the distinction is the whole
# finding.** A source scan for `res "name"` printed twice would NOT have caught
# it: the bug was one source line sitting inside a loop, so the file held a
# single copy and only its *output* duplicated. The same scan also flags
# legitimate if/else verdict pairs (`res "x" PASS` / `res "x" FAIL`), which print
# once. So this drives the real slot test through the capture seam and counts
# what it actually emitted.
REPLAY_OUT="$(CLI_FORMATS_CAPTURE_DIR="$GOOD" bash "$SLOT_TEST" 2>&1)"
mapfile -t emitted < <(printf '%s\n' "$REPLAY_OUT" | grep -oE '^RESULT [^ ]+' | awk '{print $2}')
dup_out=$(printf '%s\n' "${emitted[@]}" | sort | uniq -d)
if [[ -z "$dup_out" ]]; then
  ok "every one of the ${#emitted[@]} RESULT names is emitted once"
else
  no "a RESULT name is emitted more than once - a check is nested inside a loop"
  printf '#   duplicated: %s\n' "$dup_out"
fi

# The control: this must be able to fail. **A copy of the slot test that emits an
# existing RESULT name a second time must be refused.**
#
# The first version of this control duplicated a check *inside the zcat loop* -
# which in the replay fixture never iterates, because the GOOD capture holds no
# gz-*.rc files, so the duplicate was never printed and the control passed for a
# reason unrelated to the check. A control that cannot fail is not a control.
NESTED="$T/dup.sh"
cp "$SLOT_TEST" "$NESTED"
# An existing name, emitted a second time in a plain sequence - so the check is
# exercised by cause-free duplication rather than by a loop that may not run.
python3 - "$NESTED" <<'PYEOF'
import sys
dst = sys.argv[1]
text = open(dst).read()
marker = 'echo "== probe done"'
assert marker in text, "the probe-done marker moved - update this fixture"
open(dst, "w").write(text.replace(
    marker,
    'res "pdffonts-table-shape" "PASS (a second copy, to prove the check fails)"\n' + marker))
PYEOF
dup_out="$(CLI_FORMATS_CAPTURE_DIR="$GOOD" bash "$NESTED" 2>&1)"
mapfile -t dup_names < <(printf '%s\n' "$dup_out" | grep -oE '^RESULT [^ ]+' | awk '{print $2}')
if printf '%s\n' "${dup_names[@]}" | sort | uniq -d | grep -q 'pdffonts-table-shape'; then
  ok "the duplicate check refuses a slot-test that emits one name twice"
else
  no "the duplicate check accepted a slot-test that emits one name twice - it cannot fail"
fi

# --- no rclone probe may pass on a refusal ------------------------------------
# The second bug: `RCLONE_CONFIG_DIR` was not honoured, every probe answered
# rc=1 with "Config file ... not found - using defaults", and a check that
# recorded rc=1 as PASS printed all of them green. An environment that
# measured nothing must be a FAIL, so the assertion names the cause.
if grep -qE 'rclone-lsd-shape.*FAIL' "$SLOT_TEST"; then
  ok "rclone-lsd-shape can FAIL, so a remote that never configured is not a pass"
else
  no "rclone-lsd-shape has no FAIL branch - a refusal would be reported as a measurement"
fi

printf '\n1..%d\n' "$((pass + fail))"
if (( fail )); then
  echo "# FAILED ${fail} of $((pass + fail)) — chronoa-cli-formats.sh cannot be trusted to say no"
  exit 1
fi
echo "# all ${pass} checks pass — chronoa-cli-formats.sh can fail, and its skips name their causes"
