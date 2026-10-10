#!/usr/bin/env bash
# The harness's own verdict counter, tested.
#
# `cmd_slot_test` decides whether a slot-test passed by counting RESULT lines.
# It got that wrong, and the way it was wrong is the reason this file exists.
#
#   fail=$(grep -c '^RESULT .* FAIL' <<<"$out")
#
# `.*` is unbounded, so a **PASS** line whose *message* contains the word
# FAILED was counted as a fail as well as a pass. Measured on
# `chronoa-cli-formats` 2026-10-10: the summary read **"89 pass 1 fail"** and
# the harness printed `[ERROR] slot-test FAILED`, while **no `RESULT ... FAIL`
# line existed anywhere in the output at all** - the one phantom came from
#
#   RESULT ip-neigh-field-order  PASS ('IP dev <iface>' holds on Arch:
#     172.17.0.3 dev docker0 FAILED  192.168.31.1 dev wlp0s20f3 ...)
#
# which is a perfectly good PASS whose message names a field that failed to
# match. A slot-test that cannot pass is worse than one that fails, because it
# sends you hunting a fault that is not there.
#
# Run directly:  bash tests/result-verdict-counting.sh

set -uo pipefail

pass_n=0
fail_n=0
ok()   { printf 'ok %d - %s\n'   "$((pass_n + fail_n + 1))" "$1"; pass_n=$((pass_n + 1)); }
no()   { printf 'not ok %d - %s\n' "$((pass_n + fail_n + 1))" "$1"; fail_n=$((fail_n + 1)); }

# --- the fixture -------------------------------------------------------------
# Three real lines: two passes (one of which mentions FAILED in its message)
# and one genuine failure. If a counter cannot tell the last from the middle
# one, it is not counting.
T=$(mktemp -d /tmp/result-verdict-XXXXXX)
trap 'rm -rf "$T"' EXIT
cat >"$T/out" <<'EOF'
RESULT present-ip                                  PASS (present: /usr/sbin/ip)
RESULT ip-neigh-field-order                        PASS ('IP dev <iface>' holds on Arch: 172.17.0.3 dev docker0 FAILED  192.168.31.1 dev wlp0s20f3)
RESULT sevenzip-reads-rar                          FAIL (this image's 7z does NOT list RAR)
RESULT compsize-shape-_                            SKIP (rc=1, Not btrfs)
RESULT archive-tool-unrar                          PASS (rc=7, present)
EOF

# --- the counter, copied from lib/boot.sh ------------------------------------
# Kept as a literal copy rather than sourced, because sourcing boot.sh pulls in
# the whole harness; the test is that *this* expression is right, and a copy
# that drifts is caught by the counts below failing against the fixture.
count() { # count <verdict> <file>
  grep -cE "^RESULT [^ ]+ +$1\\b" "$2" || true
}

p=$(count PASS "$T/out")
f=$(count FAIL "$T/out")

if [[ "$p" == 3 ]]; then ok "passes counted: $p (of the 3 PASS lines)"; else no "passes counted: $p (want 3)"; fi
if [[ "$f" == 1 ]]; then ok "one real failure counted"; else no "failures counted: $f (want exactly 1 - the line whose verdict IS FAIL)"; fi

# --- the negative control: the old expression must be wrong ------------------
# Without this the test above passes for any regex that counts the FAIL line,
# including one that never looks at the verdict's position.
old_f=$(grep -c '^RESULT .* FAIL' "$T/out" || true)
if [[ "$old_f" -gt "$f" ]]; then
  ok "the old unbounded pattern really was wrong ($old_f vs $f)"
else
  no "the old pattern gives the same count ($old_f) - the fixture does not separate them"
fi

# And the mirror: a SKIP must never be counted as either.
sk=$(count SKIP "$T/out")
if [[ "$sk" == 1 ]]; then ok "the SKIP is counted once, as a SKIP"; else no "SKIP count: $sk (want 1)"; fi
if ! grep -qE '^RESULT [^ ]+ +(PASS|FAIL)\b' <(grep SKIP "$T/out"); then
  ok "a SKIP line is not matched as a pass or a fail"
else
  no "a SKIP line matched a pass/fail pattern"
fi

# --- the empty case ----------------------------------------------------------
: >"$T/empty"
if [[ "$(count PASS "$T/empty")" == 0 && "$(count FAIL "$T/empty")" == 0 ]]; then
  ok "no output counts as zero of everything"
else
  no "empty output counted as pass=$(count PASS "$T/empty") fail=$(count FAIL "$T/empty")"
fi

printf '\n1..%d\n' "$((pass_n + fail_n))"
if (( fail_n )); then
  echo "# FAILED ${fail_n} of $((pass_n + fail_n)) - the verdict counter cannot be trusted"
  exit 1
fi
echo "# all $((pass_n)) checks pass - a PASS line mentioning FAILED is not a failure"