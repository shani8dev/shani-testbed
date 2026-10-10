#!/bin/bash
# A check of the harness itself: the audit section of slot-tests/config-validators.sh,
# run against a FAKE rules dir and a FAKE auditctl so every one of its branches is
# forced to a verdict on a host where the kernel refuses the real auditctl.
#
# WHY THIS FILE EXISTS. That section's three outcome branches - PASS, "ruleset is
# short" FAIL, and SKIP - only distinguish themselves inside `if $AUDITCTL -l`.
# On this host the kernel refuses auditctl entirely (measured: "Error sending add
# rule data request (Operation not permitted)" is what a *valid* rule gets, and a
# bare `auditctl -l` fails outright), so the real slot run reports SKIP and the
# other two branches are never reached. A branch no run has executed is the
# absence-shaped green this repo keeps being bitten by: the `comm -13` diff that
# names the missing keys could have been broken all week and nothing would know.
#
# WHAT IS REAL AND WHAT IS FAKED, precisely - the caveat on the whole file:
#
#   * The SLOT TEST is not stubbed or copied. slot-tests/config-validators.sh
#     itself runs, unmodified, with AUDIT_TEST_RULES_DIR, AUDIT_TEST_AUDITCTL and
#     AUDIT_TEST_FORCE_AUDIT set. All three default off/empty, so slot behaviour is
#     byte-identical - this is why a slot run needs no changes for this file.
#   * The rules dir IS faked, by copying the real shipped file from
#     shani-settings - so `want` is the real number, not a made-up one.
#   * `auditctl -l` output IS faked. It is a LISTING, so faking it is faithful by
#     construction: what the kernel prints is exactly the lines selected here.
#   * `auditctl -R` (the negative control) IS faked, and THIS IS THE LIMIT OF
#     THIS FILE. The stub implements the discrimination the section relies on -
#     unparseable exits 1 with no output, parseable prints the EPERM wording -
#     which is the behaviour measured against the real auditctl on Arch. But a
#     stub is not the real parser, so this file does NOT prove the real auditctl
#     rejects the real malformed rule. That is proven only by the real slot run,
#     where audit-negative-control PASSes. What this file proves is that the
#     section's BRANCHING is correct and that the control is load-bearing within
#     the harness.
#
# Each scenario asserts a RESULT line by exact name, so a scenario cannot pass by
# the script failing to run at all.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOT_TEST="$ROOT/slot-tests/config-validators.sh"
REAL_RULES="/w/shani-settings/etc/audit/rules.d/10-shani-base.rules"
[[ -f "$SLOT_TEST" ]] || { echo "FAIL: no $SLOT_TEST" >&2; exit 1; }

pass_n=0 fail_n=0
ok() { printf 'ok   %s\n' "$1"; pass_n=$((pass_n + 1)); }
no() { printf 'FAIL %s -- %s\n' "$1" "$2"; fail_n=$((fail_n + 1)); }

TMP=$(mktemp -d /tmp/cfgval-audit-selftest.XXXXXX)
trap '[[ ${KEEP_TMP:-0} == 1 ]] || rm -rf "$TMP"' EXIT

verdict() { # <output> <name>
    awk -v n="$2" '$1=="RESULT" && $2==n { $1=""; $2=""; sub(/^ +/,""); print; exit }' <<<"$1"
}

# ── the fake auditctl ────────────────────────────────────────────────────────
# Implements the two shapes the section uses, faithfully to what was measured
# against the real binary on Arch (audit 4.x):
#
#   -l                 print $STUB_LIST, exit 0   (or exit 1 with $STUB_LIST_FAIL)
#   -R FILE            per non-comment line: structurally valid -> print the EPERM
#                      wording and exit 1;  invalid -> exit 1 with NO output.
#
# "valid" here is the grammar this repo's rules file actually uses, not a
# lookup table: -w PATH -p PERM -k KEY (PERM drawn from r/w/x/a), and
# -a always,exit -F arch=bNN -S SYSCALL [-S SYSCALL...] [-F f=v...] -k KEY, plus
# the -b/-f/-D/-e directives. Anything else is unparseable.
cat > "$TMP/fake-auditctl" <<'STUB'
#!/bin/bash
set -u
STUB_LIST="${STUB_LIST:-}"; STUB_LIST_FAIL="${STUB_LIST_FAIL:-}"
case "${1:-}" in
  -l)
    if [[ -n "$STUB_LIST_FAIL" ]]; then printf '%s\n' "$STUB_LIST_FAIL" >&2; exit 1; fi
    printf '%s\n' "$STUB_LIST"; exit 0 ;;
  -R)
    f="$2"
    while IFS= read -r line || [[ -n "$line" ]]; do
      b="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$b" || "$b" == \#* ]] && continue
      ok=0
      if [[ "$b" =~ ^-w[[:space:]]+[^[:space:]]+[[:space:]]+-p[[:space:]]+[rwxa]+[[:space:]]+-k[[:space:]]+[A-Za-z0-9_-]+$ ]]; then ok=1; fi
      if [[ "$b" =~ ^-a[[:space:]]+always,exit[[:space:]]+-F[[:space:]]+arch=b(64|32)([[:space:]]+-[SDAF][[:space:]]+[A-Za-z0-9_<>!=,.\"\'-]+)+[[:space:]]+-k[[:space:]]+[A-Za-z0-9_-]+$ ]]; then ok=1; fi
      if [[ "$b" =~ ^-(b[[:space:]]+[0-9]+|f[[:space:]]+[0-9]|D|e[[:space:]]+[0-9])$ ]]; then ok=1; fi
      [[ $ok -eq 1 ]] || exit 1        # unparseable: exit non-zero, print NOTHING
    done < "$f"
    echo "Error sending add rule data request (Operation not permitted)"; exit 1 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TMP/fake-auditctl"

run() { # <rules-dir> <stub-listing> [<stub-l-failure-text>] -> RESULT lines
    AUDIT_TEST_FORCE_AUDIT=1 \
    AUDIT_TEST_RULES_DIR="$1" AUDIT_TEST_AUDITCTL="$TMP/fake-auditctl" \
    STUB_LIST="$2" STUB_LIST_FAIL="${3:-}" bash "$SLOT_TEST" 2>&1
}

# The real shipped rules file, so `want` is the real count and not a fixture.
# Tried in the order a host would see them; the container path first because the
# repo's own harness bind-mounts the siblings read-only there.
for cand in /w/shani-settings/etc/audit/rules.d/10-shani-base.rules \
            "$ROOT/../shani-settings/etc/audit/rules.d/10-shani-base.rules" \
            "$ROOT/../../shani-settings/etc/audit/rules.d/10-shani-base.rules"; do
    if [ -f "$cand" ]; then RULES_SRC="$cand"; break; fi
done
if [ -z "${RULES_SRC:-}" ]; then
  echo "FAIL: cannot find the real shani-settings audit rules file to copy" >&2; exit 1
fi
WANT=$(grep -cE '^[[:space:]]*-[aw]' "$RULES_SRC")
mkdir -p "$TMP/rules-ok"; cp "$RULES_SRC" "$TMP/rules-ok/10-shani-base.rules"
# The listing that matches the file exactly: what `auditctl -l` would print.
LIST_OK=$(grep -E '^[[:space:]]*-[aw]' "$RULES_SRC")

echo "### the real rules file has $WANT loadable rules"

# ── scenario 1: every rule loaded -> PASS with the real count ────────────────
echo "### scenario: the ruleset loaded in full"
OUT=$(run "$TMP/rules-ok" "$LIST_OK")
v=$(verdict "$OUT" audit-rules-loaded)
if [[ "$v" == PASS*"$WANT of $WANT"* ]]; then
    ok "a fully loaded ruleset reports PASS with the real count ($WANT)"
else
    no "a fully loaded ruleset reports PASS" "got: ${v:-<no RESULT row>}"
fi
v=$(verdict "$OUT" audit-negative-control)
if [[ "$v" == PASS* ]]; then ok "an unparseable rule is rejected by the auditctl parser"
else no "an unparseable rule is rejected" "got: ${v:-<no RESULT row>}"; fi

# ── scenario 2: the ruleset is SHORT -> FAIL, and the missing keys are named ──
# This is the branch whose `comm -13` diff no real run has executed. A typo in
# that expression, or a filter that matches nothing, both look like a pass.
echo "### scenario: the ruleset loaded short"
# Take the file's last 10 loadable rules out, and the listing with them.
tail -n 10 <(grep -E '^[[:space:]]*-[aw]' "$RULES_SRC") > "$TMP/dropped.txt"
head -n -10 "$RULES_SRC" 2>/dev/null || grep -E '^[[:space:]]*-[aw]' "$RULES_SRC" | head -n -10 > "$TMP/kept.txt"
mkdir -p "$TMP/rules-full"; cp "$RULES_SRC" "$TMP/rules-full/10-shani-base.rules"
LIST_SHORT=$(grep -E '^[[:space:]]*-[aw]' "$TMP/dropped.txt" >/dev/null; grep -E '^[[:space:]]*-[aw]' "$RULES_SRC" | head -n "$((WANT - 10))")
OUT=$(run "$TMP/rules-full" "$LIST_SHORT")
v=$(verdict "$OUT" audit-rules-loaded)
if [[ "$v" == FAIL*"$((WANT - 10)) of $WANT"* ]]; then
    ok "a short ruleset FAILs naming the exact counts"
else
    no "a short ruleset FAILs naming the exact counts" "got: ${v:-<no RESULT row>}"
fi
# The detail must distinguish "here are the missing keys" from "the shortfall is
# rules whose keys survive elsewhere". An empty line here is what the first draft
# printed, and it reads as "nothing is missing" under a FAIL - the absence-shaped
# green this file exists to catch, one layer down.
if grep -q 'keys the file asks for' <<<"$OUT"; then
    ok "a short ruleset names distinct missing keys below the RESULT row"
elif grep -q 'no distinct key is missing' <<<"$OUT"; then
    ok "a short ruleset says the keys survive elsewhere rather than printing nothing"
else
    no "a short ruleset explains itself below the RESULT row" "no detail line at all"
fi

# ── scenario 3: auditd up, nothing loaded -> FAIL, not PASS ──────────────────
echo "### scenario: auditd up but the ruleset did not load at all"
# A listing of directives only: no -a and no -w line, so `got` is 0 and the
# zero branch is the one under test. Leaving one -a line in it reaches the short
# branch instead, which is a different (and correct) verdict.
LIST_BAD="-b 8192
-f 1"
OUT=$(run "$TMP/rules-ok" "$LIST_BAD")
v=$(verdict "$OUT" audit-rules-loaded)
if [[ "$v" == FAIL*"0 of $WANT"* ]]; then
    ok "nothing loaded FAILs rather than passing on \"some rules present\""
else
    no "nothing loaded FAILs" "got: ${v:-<no RESULT row>}"
fi

# ── scenario 4: the kernel refuses auditctl -> SKIP naming the cause ─────────
echo "### scenario: auditctl exists but the kernel will not answer"
OUT=$(run "$TMP/rules-ok" "" "There was an error while processing parameters")
v=$(verdict "$OUT" audit-rules-loaded)
if [[ "$v" == SKIP* && "$v" == *"kernel audit unavailable"* ]]; then
    ok "a kernel that refuses auditctl SKIPs and names the cause"
else
    no "a kernel that refuses auditctl SKIPs naming the cause" "got: ${v:-<no RESULT row>}"
fi
# The negative control is the one branch that must survive that SKIP: it needs
# no kernel, which is the whole reason it is the load-bearing check here.
v=$(verdict "$OUT" audit-negative-control)
if [[ "$v" == PASS* ]]; then ok "the negative control still discriminates when the load check SKIPs"
else no "the negative control still discriminates when the load check SKIPs" "got: ${v:-<no RESULT row>}"; fi

# ── scenario 5: a control that cannot fail must be able to ────────────────────
# A stub that accepts everything would make audit-negative-control FAIL. Assert
# it does, so a silently-broken parser below cannot read as coverage.
echo "### scenario: an auditctl that accepts anything makes the control FAIL"
cat > "$TMP/accept-all" <<'STUB'
#!/bin/bash
case "${1:-}" in -l) exit 0 ;; -R) echo "Error sending add rule data request (Operation not permitted)"; exit 1 ;; esac
exit 2
STUB
chmod +x "$TMP/accept-all"
OUT=$(AUDIT_TEST_FORCE_AUDIT=1 AUDIT_TEST_RULES_DIR="$TMP/rules-ok" \
      AUDIT_TEST_AUDITCTL="$TMP/accept-all" bash "$SLOT_TEST" 2>&1)
v=$(verdict "$OUT" audit-negative-control)
if [[ "$v" == FAIL* ]]; then ok "a permissive auditctl makes the control FAIL (so the control is load-bearing)"
else no "a permissive auditctl makes the control FAIL" "got: ${v:-<no RESULT row>}"; fi

# ── scenario 6: a genuine unparseable rule in the shipped file is caught ─────
echo "### scenario: a malformed rule written into the real rules file"
mkdir -p "$TMP/rules-broken"; cp "$RULES_SRC" "$TMP/rules-broken/10-shani-base.rules"
printf -- '-w /etc/passwd -p zzz -k identity\n' >> "$TMP/rules-broken/10-shani-base.rules"
OUT=$(run "$TMP/rules-broken" "$LIST_OK")
v=$(verdict "$OUT" audit-rules-loaded)
if [[ "$v" == FAIL* ]]; then ok "a malformed rule in the file fails the load check (count no longer matches)"
else no "a malformed rule in the file fails the load check" "got: ${v:-<no RESULT row>}"; fi

echo
if [[ $fail_n -eq 0 ]]; then echo "all $pass_n audit self-test checks passed"
else echo "$fail_n of $((pass_n + fail_n)) audit self-test checks FAILED"; exit 1; fi
