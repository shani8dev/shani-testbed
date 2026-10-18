#!/bin/bash
# efivar-boot-verify-results — prove `efivar-boot-verify.sh` can say FAIL, before
# any firmware boot is trusted to say PASS.
#
# WHY THIS FILE IS NOT OPTIONAL. The verifier exists to settle whether the
# power-cut hook's EFI clearing works on a variable that exists. Its first ever
# run will be a ~6-minute firmware boot, and a checker that has only ever said
# PASS is worse than none: it would read as "the clearing is fine" when nothing
# was distinguished. This is `tests/audit-boot-proof.sh`'s practice — dry-run
# against a stub in both directions first — applied to the same subsystem, and it
# is cheap: no boot, no container, no slot.
#
# Host-only, no docker, no btrfs, no firmware. Nine scenarios.
cd "$(dirname "$0")/.." || exit 1
VERIFY=tests/efivar-boot-verify.sh

pass=0; fail=0
ck() { # ck <name> <condition-result>
  if [ "$2" = "ok" ]; then printf 'PASS %-46s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf 'FAIL %-46s %s\n' "$1" "$3"; fail=$((fail+1)); fi
}

# A stream in the shape a real boot produces when everything works.
healthy() {
  cat <<'EOF'
EFIVARFACT kernel=7.2.6-arch2-1
EFIVARFACT kernel_source=image
EFIVARFACT efivarfs_present=yes
EFIVARFACT efivarfs_count=0
EFIVARFACT loader_vars=
EFIVARFACT node_mode=400 root:root
EFIVARFACT writable=yes
EFIVARFACT writable_errno=none
EFIVARFACT set_ok=yes
EFIVARFACT set_errno=none
EFIVARFACT readback=shani-test-probe
EFIVARFACT delete_ok=yes
EFIVARFACT gone_after_delete=yes
EFIVARFACT done=yes
EOF
}

run() { bash "$VERIFY" "$1" 2>&1; }
# verdict <stream-file> <check-name> -> ok if that check reported PASS
verdict() { run "$1" | grep -q "^RESULT $2 .*PASS" && echo ok || echo no; }
# failed <stream-file> <check-name> -> ok if that check reported FAIL
failed() { run "$1" | grep -q "^RESULT $2 .*FAIL" && echo ok || echo no; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# --- 1. the control: a healthy stream is all PASS -------------------------------
healthy > "$T/good"
out=$(run "$T/good")
n_pass=$(grep -c 'PASS' <<<"$out")
ck scenario-1-healthy-is-green ok \
  "$([ "$(verdict "$T/good" efivar-variable-unlinks)" = ok ] && [ "$n_pass" -ge 8 ] \
     && echo "$n_pass PASS, decisive check green" || echo "$out")"

# --- 2. THE CONTROL THAT MATTERS: the unlink does not take effect ----------------
# This is the whole reason the pair exists. `rm -f` reported success but the node
# is still there -> the hook's clearing is a no-op -> LoaderEntryDefault keeps
# outranking loader.conf and the machine fails open into a broken boot.
sed 's/^EFIVARFACT gone_after_delete=yes$/EFIVARFACT gone_after_delete=no/' "$T/good" > "$T/stuck"
ck scenario-2-node-survives-unlink \
  "$([ "$(failed "$T/stuck" efivar-variable-unlinks)" = ok ] && echo ok || echo no)" \
  "$(run "$T/stuck" | grep '^RESULT efivar-variable-unlinks')"

# --- 3. rm -f itself reported failure --------------------------------------------
sed 's/^EFIVARFACT delete_ok=yes$/EFIVARFACT delete_ok=no/' "$T/good" > "$T/nodel"
ck scenario-3-rm-reported-failure \
  "$([ "$(failed "$T/nodel" efivar-variable-unlinks)" = ok ] && echo ok || echo no)" \
  "$(run "$T/nodel" | grep '^RESULT efivar-variable-unlinks')"

# --- 4. a variable written but unreadable ----------------------------------------
# `set_ok=yes` with an empty readback is the absence-shaped pass: a zero-length
# variable "reads back" fine. It must not be green.
sed 's/^EFIVARFACT readback=shani-test-probe$/EFIVARFACT readback=<empty>/' "$T/good" > "$T/empty"
ck scenario-4-empty-readback-is-fail \
  "$([ "$(failed "$T/empty" efivar-variable-roundtrips)" = ok ] && echo ok || echo no)" \
  "$(run "$T/empty" | grep '^RESULT efivar-variable-roundtrips')"

# --- 5. the wrong readback value ------------------------------------------------
sed 's/^EFIVARFACT readback=shani-test-probe$/EFIVARFACT readback=some-other-entry/' "$T/good" > "$T/wrong"
ck scenario-5-wrong-readback-is-fail \
  "$([ "$(failed "$T/wrong" efivar-variable-roundtrips)" = ok ] && echo ok || echo no)" \
  "$(run "$T/wrong" | grep '^RESULT efivar-variable-roundtrips')"

# --- 6. not a firmware boot ------------------------------------------------------
# Deliberately a FAIL and not a SKIP: without efivarfs every later check would SKIP
# on nothing, which is the examined-nothing green AGENTS.md keeps recording.
sed -e 's/^EFIVARFACT efivarfs_present=yes$/EFIVARFACT efivarfs_present=no/' "$T/good" > "$T/nofw"
nofw_out=$(run "$T/nofw"); nofw_rc=$?
ck scenario-6-no-efivarfs-fails-and-stops \
  "$([ "$(failed "$T/nofw" firmware-boot-has-efivarfs)" = ok ] && [ "$nofw_rc" = 1 ] && echo ok || echo no)" \
  "rc=$nofw_rc, later checks suppressed (no premature green)"

# --- 7. facts attributed to the wrong machine -----------------------------------
sed 's/^EFIVARFACT kernel_source=image$/EFIVARFACT kernel_source=host/' "$T/good" > "$T/hostfact"
ck scenario-7-host-attribution-is-fail \
  "$([ "$(failed "$T/hostfact" efivar-facts-describe-image)" = ok ] && echo ok || echo no)" \
  "$(run "$T/hostfact" | grep '^RESULT efivar-facts-describe-image')"

# --- 8. a missing key is a failure, not an empty value ---------------------------
grep -v '^EFIVARFACT delete_ok=' "$T/good" > "$T/incomplete"
inc_out=$(run "$T/incomplete"); inc_rc=$?
inc_lines=$(grep -c '^RESULT' <<<"$inc_out")
ck scenario-8-missing-key-is-incomplete \
  "$([ "$(failed "$T/incomplete" efivar-stream-complete)" = ok ] && [ "$inc_rc" = 1 ] \
     && [ "$inc_lines" = 1 ] && echo ok || echo no)" \
  "rc=$inc_rc, $inc_lines verdict(s) — one FAIL, no verdicts about nothing"

# --- 9. the structural guard, driven by a genuinely duplicated verdict ----------
# The guard reads `_EMITTED` (this run's own output). A verifier whose ninth check
# is duplicated has a superseded block still live — the leftover-`case` defect.
sed 's|res efivar-variable-unlinks "PASS (rm -f removed the node and it stayed removed|res efivar-variable-unlinks "PASS (duplicate emitted here)"; res efivar-variable-unlinks "PASS (rm -f removed the node and it stayed removed|' \
  "$VERIFY" > "$T/dupver"
dup_out=$(bash "$T/dupver" "$T/good" 2>&1)
ck scenario-9-duplicate-verdict-is-fail \
  "$(grep -q '^RESULT efivar-one-verdict-per-check .*FAIL' <<<"$dup_out" && echo ok || echo no)" \
  "$(grep '^RESULT efivar-one-verdict-per-check' <<<"$dup_out")"

# --- 10. a node readable by others ----------------------------------------------
# The claim that licenses shani-chronoa's driver_status reporting UNKNOWN instead
# of guessing is "a user cannot read their own boot variables". If efivarfs ever
# becomes group/other-readable, that silence becomes a lie by omission — so the
# assertion has a direction, and this is that direction.
sed 's/^EFIVARFACT node_mode=400 root:root$/EFIVARFACT node_mode=644 root:root/' "$T/good" > "$T/readable"
ck scenario-10-readable-node-is-fail \
  "$([ "$(failed "$T/readable" efivar-node-is-root-only)" = ok ] && echo ok || echo no)" \
  "$(run "$T/readable" | grep '^RESULT efivar-node-is-root-only')"

# --- 11. a failed SET must not be reported as a broken UNLINK --------------------
# Found by the first real boot. With the write failing (EINVAL) the stream carried
# `delete_ok=no`, and the verifier then printed "rm -f did not remove the variable,
# so the hook cannot clear LoaderEntry* and the failover fails open" — a confident
# verdict about the product drawn from a probe that never created a variable. It
# points the fix at the hook's `rm -f`, which is not what failed.
sed -e 's/^EFIVARFACT set_ok=yes$/EFIVARFACT set_ok=no/' \
    -e 's/^EFIVARFACT set_errno=none$/EFIVARFACT set_errno=Invalid argument/' \
    -e 's/^EFIVARFACT readback=shani-test-probe$/EFIVARFACT readback=/' \
    "$T/good" > "$T/noset"
set_out=$(run "$T/noset")
ck scenario-11-failed-set-is-not-a-broken-unlink \
  "$(grep -q '^RESULT efivar-variable-unlinks .*SKIP' <<<"$set_out" \
     && ! grep -q '^RESULT efivar-variable-unlinks .*FAIL' <<<"$set_out" && echo ok || echo no)" \
  "$(grep '^RESULT efivar-variable-unlinks' <<<"$set_out")"


# --- MUTATIONS: revert the guards and confirm they go red ------------------------
# A mutation BREAKS a guard. The proof that the guard was load-bearing is that
# after breaking it, the input that should have been caught is let through — so
# the mutated verifier must now report PASS where the real one reported FAIL.
#
# (Getting this backwards is easy and it fails silently in the reassuring
# direction: asserting the mutated run is still red would "pass" every mutation
# that did nothing at all, because a guard that never fires is always red-free.)
mut() { # mut <name> <sed-expr> <bad-stream> <check>
  sed "$2" "$VERIFY" > "$T/m"
  if ! bash -n "$T/m" 2>/dev/null; then
    printf 'FAIL mutation-%-40s %s\n' "$1" "mutation produced unparseable bash — it changed nothing"
    return
  fi
  local before after
  before=$(run "$3" | grep "^RESULT $4 " || true)
  after=$(bash "$T/m" "$3" 2>&1 | grep "^RESULT $4 " || true)
  # "The guard held" means the verdict was NOT a pass. FAIL and SKIP both count:
  # the set-gate turns a bad verdict into a SKIP rather than a FAIL, and both are
  # the guard refusing to let bad input through as green. What must follow the
  # mutation is a PASS — that is the bad input getting through.
  case "$before" in
    *PASS*) printf 'FAIL mutation-%-40s %s\n' "$1" "scenario $3 was green to begin with ($before) — nothing to prove"; return;;
  esac
  case "$after" in
    *PASS*) printf 'PASS mutation-%-40s %s\n' "$1" "guard removed -> now let through (load-bearing)"; pass=$((pass+1));;
    *)      printf 'FAIL mutation-%-40s %s\n' "$1" "STILL refusing after the guard was broken, so this guard is not what held it: $after"; fail=$((fail+1));;
  esac
}

# (a) the decisive check neutered: a failed unlink reported as a pass.
#     Matched on the verdict's PREFIX, not its full text. Pinning the whole
#     literal meant this mutation silently stopped applying the moment the
#     message gained the "the variable was created" qualifier — and a mutation
#     that no longer matches anything "passes" as a no-op, which is the harness
#     rot AGENTS.md records for the espeak argv and the hardcoded module path.
mut unlink-check-neutered \
  's|^  res efivar-variable-unlinks "FAIL (.*$|  res efivar-variable-unlinks "PASS (mutated: always ok)"|' \
  "$T/stuck" efivar-variable-unlinks
# (b) the completeness guard removed
mut completeness-guard-removed \
  's|^  res efivar-stream-complete "FAIL (missing:.*$|  res efivar-stream-complete "PASS (mutated: ignores missing keys)"|' \
  "$T/incomplete" efivar-stream-complete
# (c) no-efivarfs downgraded to a SKIP-like PASS
mut no-firmware-downgraded \
  's|^  res firmware-boot-has-efivarfs "FAIL (efivarfs not present.*$|  res firmware-boot-has-efivarfs "PASS (mutated: absent is fine)"|' \
  "$T/nofw" firmware-boot-has-efivarfs
# (d) the structural duplicate guard can never fire (back to reading $STREAM).
#     This one needs its own subject: the guard only has anything to catch when a
#     verdict really is duplicated, so "before" is the duplicated verifier from
#     scenario 9 and "after" is that same verifier with the guard disarmed. Feeding
#     it the healthy stream would be "nothing to prove", which is what it said
#     until scenario 9 gave it something to chew on.
sed 's|^dupes=.*$|dupes=""|' "$T/dupver" > "$T/dupver_disarmed"
if bash "$T/dupver" "$T/good" 2>&1 | grep -q '^RESULT efivar-one-verdict-per-check .*FAIL' \
   && bash "$T/dupver_disarmed" "$T/good" 2>&1 | grep -q '^RESULT efivar-one-verdict-per-check .*PASS'; then
  printf 'PASS mutation-%-40s %s\n' duplicate-guard-disarmed "guard removed -> duplicate now passes (load-bearing)"; pass=$((pass+1))
else
  printf 'FAIL mutation-%-40s %s\n' duplicate-guard-disarmed "disarming the guard did not let the duplicate through"
  fail=$((fail+1))
fi
# (e) an empty readback accepted as a pass -- the absence-shaped green
mut empty-readback-accepted \
  's|\[ "$rb" = "shani-test-probe" \]|[ "$rb" != "__never__" ]|' \
  "$T/empty" efivar-variable-roundtrips
# (f) the root-only assertion dropped
mut set-gate-removed \
  's|^if \[ "$(fact set_ok)" != "yes" \]; then$|if false; then|' \
  "$T/noset" efivar-variable-unlinks
mut root-only-assertion-dropped \
  's|^  \*)       res efivar-node-is-root-only "FAIL (.*$|  *)       res efivar-node-is-root-only "PASS (mutated)"|' \
  "$T/readable" efivar-node-is-root-only

echo
printf 'efivar-boot-verify-results: %d pass, %d fail\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0