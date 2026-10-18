#!/bin/bash
# efivar-boot-verify-results — prove `efivar-boot-verify.sh` can say FAIL, before
# any firmware boot is trusted to say PASS.
#
# WHY THIS FILE IS NOT OPTIONAL. The verifier exists to settle whether the
# power-cut hook's EFI clearing works on a variable that exists. Its first runs
# were ~6-minute firmware boots, and a checker that has only ever said PASS is
# worse than none: it would read as "the clearing is fine" when nothing was
# distinguished. This is `tests/audit-boot-proof.sh`'s practice — dry-run against
# a stub in both directions first — applied to the same subsystem, and it is
# cheap: no boot, no container, no slot.
#
# Host-only, no docker, no btrfs, no firmware.
cd "$(dirname "$0")/.." || exit 1
VERIFY=tests/efivar-boot-verify.sh

pass=0; fail=0
ck() {
  if [ "$2" = "ok" ]; then printf 'PASS %-46s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf 'FAIL %-46s %s\n' "$1" "$3"; fail=$((fail+1)); fi
}

# A stream in the shape a real boot produces when everything works: a real
# Loader* variable present, the unlink working.
healthy() {
  cat <<'EOF'
EFIVARFACT kernel=7.2.6-arch2-1
EFIVARFACT kernel_source=image
EFIVARFACT efivarfs_present=yes
EFIVARFACT efivarfs_count=10
EFIVARFACT loader_vars=LoaderEntries-4a67,LoaderEntrySelected-4a67,LoaderFeatures-4a67
EFIVARFACT hook_target_present=yes
EFIVARFACT target_name=LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
EFIVARFACT unlink_errno=
EFIVARFACT rm_present=yes
EFIVARFACT target_mode=644 root:root
EFIVARFACT unlink_ok=yes
EFIVARFACT gone_after_delete=yes
EFIVARFACT creatable=yes
EFIVARFACT create_errno=none
EFIVARFACT done=yes
EOF
}

run() { bash "$VERIFY" "$1" 2>&1; }
verdict() { run "$1" | grep -q "^RESULT $2 .*PASS" && echo ok || echo no; }
failed()  { run "$1" | grep -q "^RESULT $2 .*FAIL" && echo ok || echo no; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# --- 1. the control ------------------------------------------------------------
healthy > "$T/good"
out=$(run "$T/good")
n_pass=$(grep -c 'PASS' <<<"$out")
ck scenario-1-healthy-is-green \
  "$([ "$(verdict "$T/good" efivar-target-unlinks)" = ok ] && [ "$n_pass" -ge 6 ] && echo ok || echo no)" \
  "$n_pass PASS, decisive check green"

# --- 2. THE CONTROL THAT MATTERS: the node survives rm -f ------------------------
# The whole reason the pair exists. rm -f reported success and the node is still
# there -> the hook's clearing is a no-op -> LoaderEntryDefault keeps outranking
# loader.conf and the machine fails open into a broken boot.
sed 's/^EFIVARFACT gone_after_delete=yes$/EFIVARFACT gone_after_delete=no/' "$T/good" > "$T/stuck"
ck scenario-2-node-survives-unlink \
  "$([ "$(failed "$T/stuck" efivar-target-unlinks)" = ok ] && echo ok || echo no)" \
  "$(run "$T/stuck" | grep '^RESULT efivar-target-unlinks')"

# --- 3. rm -f itself reported failure -------------------------------------------
sed 's/^EFIVARFACT unlink_ok=yes$/EFIVARFACT unlink_ok=no/' "$T/good" > "$T/noul"
ck scenario-3-rm-reported-failure \
  "$([ "$(failed "$T/noul" efivar-target-unlinks)" = ok ] && echo ok || echo no)" \
  "$(run "$T/noul" | grep '^RESULT efivar-target-unlinks')"

# --- 4. no variable present: a SKIP that says nothing, not a FAIL ---------------
# A machine nobody has ever pressed a boot-menu key on has none of the hook's four
# targets set. That is the ordinary state, and reporting FAIL for it would be
# claiming the hook is broken on every fresh machine. Equally, reporting PASS
# would be the examined-nothing green. SKIP, naming the reason.
sed -e 's/^EFIVARFACT hook_target_present=yes$/EFIVARFACT hook_target_present=no/' \
    -e 's/^EFIVARFACT target_name=.*$/EFIVARFACT target_name=/' \
    -e 's/^EFIVARFACT target_mode=.*$/EFIVARFACT target_mode=/' \
    -e 's/^EFIVARFACT rm_present=.*$/EFIVARFACT rm_present=yes/' \
    "$T/good" > "$T/none"
none_out=$(run "$T/none")
ck scenario-4-no-target-is-an-honest-skip \
  "$(grep -q '^RESULT efivar-target-unlinks .*SKIP' <<<"$none_out" \
     && ! grep -q '^RESULT efivar-target-unlinks .*FAIL' <<<"$none_out" \
     && echo ok || echo no)" \
  "$(grep '^RESULT efivar-target-unlinks' <<<"$none_out")"

# --- 5. a failed CREATE must not become a broken-UNLINK verdict -----------------
# This is the misattribution the first two real boots produced: the create failed
# with EINVAL, nothing was ever created, `delete_ok=no` came back, and the
# verifier reported "rm -f did not remove the variable, so the hook cannot clear
# LoaderEntry* and the failover fails open" — pointing the fix at the hook's rm -f,
# which is not what failed.
sed -e 's/^EFIVARFACT creatable=yes$/EFIVARFACT creatable=no/' \
    -e 's/^EFIVARFACT create_errno=none$/EFIVARFACT create_errno=Invalid argument/' \
    "$T/good" > "$T/nocreate"
create_out=$(run "$T/nocreate")
ck scenario-5-failed-create-is-not-a-broken-unlink \
  "$([ "$(verdict "$T/nocreate" efivar-target-unlinks)" = ok ] \
     && grep -q '^RESULT efivarfs-is-creatable .*SKIP' <<<"$create_out" && echo ok || echo no)" \
  "unlinks stays PASS; creatable SKIPs with its errno"

# --- 6. not a firmware boot ----------------------------------------------------
# Deliberately FAIL and not SKIP: without efivarfs everything else would SKIP on
# nothing, the examined-nothing green AGENTS.md keeps recording.
sed 's/^EFIVARFACT efivarfs_present=yes$/EFIVARFACT efivarfs_present=no/' "$T/good" > "$T/nofw"
nofw_out=$(run "$T/nofw"); nofw_rc=$?
ck scenario-6-no-efivarfs-fails-and-stops \
  "$([ "$(failed "$T/nofw" firmware-boot-has-efivarfs)" = ok ] && [ "$nofw_rc" = 1 ] && echo ok || echo no)" \
  "rc=$nofw_rc, later checks suppressed"

# --- 7. facts attributed to the wrong machine ---------------------------------
sed 's/^EFIVARFACT kernel_source=image$/EFIVARFACT kernel_source=host/' "$T/good" > "$T/hostfact"
ck scenario-7-host-attribution-is-fail \
  "$([ "$(failed "$T/hostfact" efivar-facts-describe-image)" = ok ] && echo ok || echo no)" \
  "$(run "$T/hostfact" | grep '^RESULT efivar-facts-describe-image')"

# --- 8. a missing key is a failure, not an empty value ------------------------
grep -v '^EFIVARFACT unlink_ok=' "$T/good" > "$T/incomplete"
inc_out=$(run "$T/incomplete"); inc_rc=$?
inc_lines=$(grep -c '^RESULT' <<<"$inc_out")
ck scenario-8-missing-key-is-incomplete \
  "$([ "$(failed "$T/incomplete" efivar-stream-complete)" = ok ] && [ "$inc_rc" = 1 ] \
     && [ "$inc_lines" = 1 ] && echo ok || echo no)" \
  "rc=$inc_rc, $inc_lines verdict(s) — one FAIL, no verdicts about nothing"

# --- 9. the structural guard, driven by a genuinely duplicated verdict --------
sed 's|res efivar-target-unlinks "PASS (rm -f removed|res efivar-target-unlinks "PASS (duplicate emitted here)"; res efivar-target-unlinks "PASS (rm -f removed|' \
  "$VERIFY" > "$T/dupver"
dup_out=$(bash "$T/dupver" "$T/good" 2>&1)
ck scenario-9-duplicate-verdict-is-fail \
  "$(grep -q '^RESULT efivar-one-verdict-per-check .*FAIL' <<<"$dup_out" && echo ok || echo no)" \
  "$(grep '^RESULT efivar-one-verdict-per-check' <<<"$dup_out")"

# --- 10. a node readable by others --------------------------------------------
sed 's/^EFIVARFACT target_mode=644 root:root$/EFIVARFACT target_mode=602 root:root/' "$T/good" > "$T/readable"
ck scenario-10-world-writable-node-is-fail \
  "$([ "$(failed "$T/readable" efivar-node-not-world-writable)" = ok ] && echo ok || echo no)" \
  "$(run "$T/readable" | grep '^RESULT efivar-node-not-world-writable')"

# --- MUTATIONS: revert the guards, confirm the bad input gets through -----------
# A mutation BREAKS a guard. The proof that the guard was load-bearing is that
# after breaking it, the input that should have been caught is let through — so
# the mutated verifier must now report PASS where the real one did not.
#
# FAIL and SKIP both count as "the guard refused": the no-target case holds a SKIP
# and the creatable case holds a SKIP, and both are refusals to call bad input
# green. What must follow the mutation is a PASS.
mut() { # mut <name> <sed-expr> <stream> <check>
  sed "$2" "$VERIFY" > "$T/m"
  if ! bash -n "$T/m" 2>/dev/null; then
    printf 'FAIL mutation-%-40s %s\n' "$1" "mutation produced unparseable bash"
    return
  fi
  local before after
  before=$(run "$3" | grep "^RESULT $4 " || true)
  after=$(bash "$T/m" "$3" 2>&1 | grep "^RESULT $4 " || true)
  case "$before" in
    *PASS*) printf 'FAIL mutation-%-40s %s\n' "$1" "green to begin with ($before) — nothing to prove"; return;;
  esac
  case "$after" in
    *PASS*) printf 'PASS mutation-%-40s %s\n' "$1" "guard removed -> now let through (load-bearing)"; pass=$((pass+1));;
    *)      printf 'FAIL mutation-%-40s %s\n' "$1" "STILL refusing after the guard was broken: $after"; fail=$((fail+1));;
  esac
}

# Matched on the verdict PREFIX, not its full text: pinning the literal meant this
# mutation silently stopped applying when a message gained a qualifier, and a
# mutation matching nothing is a no-op that "passes" as a control.
mut unlink-check-neutered \
  's|^  res efivar-target-unlinks "FAIL (.*$|  res efivar-target-unlinks "PASS (mutated: always ok)"|' \
  "$T/stuck" efivar-target-unlinks
mut completeness-guard-removed \
  's|^  res efivar-stream-complete "FAIL (missing:.*$|  res efivar-stream-complete "PASS (mutated)"|' \
  "$T/incomplete" efivar-stream-complete
mut no-firmware-downgraded \
  's|^  res firmware-boot-has-efivarfs "FAIL (efivarfs not present.*$|  res firmware-boot-has-efivarfs "PASS (mutated)"|' \
  "$T/nofw" firmware-boot-has-efivarfs
# Anchored on a bracket-free substring: the condition is inside `[ ... ]`, which a
# BRE reads as a bracket expression, so a pattern written the obvious way does not
# match and the mutation silently does nothing. Substituting a constant that makes
# the test always true is the same neutering and is expressible without brackets.
mut world-writable-assertion-dropped \
  's|8#\$o & 2|8#0 \& 2|' \
  "$T/readable" efivar-node-not-world-writable

# rm missing: the hook's call was never executed, so a failure there says nothing.
sed 's/^EFIVARFACT rm_present=yes$/EFIVARFACT rm_present=no/' "$T/good" > "$T/norm"
ck scenario-11-no-rm-is-an-honest-skip \
  "$(grep -q '^RESULT efivar-target-unlinks .*SKIP' <<<"$(run "$T/norm")" && echo ok || echo no)" \
  "a missing rm does not condemn the hook"
mut no-rm-gate-removed \
  's|^if \[ "$(fact rm_present)" != "yes" \]; then$|if false; then|' \
  "$T/norm" efivar-target-unlinks

# The no-target gate: turning "no variable present" from a SKIP into a FAIL claims
# the hook is broken on every fresh machine. Remove the gate and it must pass.
mut no-target-gate-removed \
  's|^elif \[ "$(fact hook_target_present)" != "yes" \]; then$|elif false; then|' \
  "$T/none" efivar-target-unlinks

# (d) the structural duplicate guard can never fire (back to reading $STREAM).
#     Needs its own subject: the guard only has something to catch when a verdict
#     really is duplicated, so "before" is the duplicated verifier and "after" is
#     that same verifier with the guard disarmed. Feeding it the healthy stream is
#     "nothing to prove" — which is what it said until scenario 9 gave it prey.
sed 's|^dupes=.*$|dupes=""|' "$T/dupver" > "$T/dupver_disarmed"
if bash "$T/dupver" "$T/good" 2>&1 | grep -q '^RESULT efivar-one-verdict-per-check .*FAIL' \
   && bash "$T/dupver_disarmed" "$T/good" 2>&1 | grep -q '^RESULT efivar-one-verdict-per-check .*PASS'; then
  printf 'PASS mutation-%-40s %s\n' duplicate-guard-disarmed "guard removed -> duplicate now passes (load-bearing)"; pass=$((pass+1))
else
  printf 'FAIL mutation-%-40s %s\n' duplicate-guard-disarmed "disarming the guard did not let the duplicate through"; fail=$((fail+1))
fi

echo
printf 'efivar-boot-verify-results: %d pass, %d fail\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0