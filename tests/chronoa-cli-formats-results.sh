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

printf '\n1..%d\n' "$((pass + fail))"
if (( fail )); then
  echo "# FAILED ${fail} of $((pass + fail)) — chronoa-cli-formats.sh cannot be trusted to say no"
  exit 1
fi
echo "# all ${pass} checks pass — chronoa-cli-formats.sh can fail, and its skips name their causes"
