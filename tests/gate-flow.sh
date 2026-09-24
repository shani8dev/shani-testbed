#!/usr/bin/env bash
# tests/gate-flow.sh — the real cmd_gate (lib/gate.sh) under `set -Eeuo
# pipefail` with every step command, the R2 pointers and the slot identity
# stubbed. Checks the step order, that a failure stops its phase, that a
# wrong build in the slot (identity) fails the gate, and that the .passed
# marker is written only on success.
#
#   tests/gate-flow.sh      (no root, no disks, no network)
set -Eeuo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }

run_case() {  # <name> <failing-cmd|none> <slot-version-after-upgrade> [extra gate args]
  local name="$1" failing="$2" upver="$3"; shift 3
  local tmp out rc=0
  tmp="$(mktemp -d)"
  out="$(
    FAILING="$failing" UPVER="$upver" DATA_DIR="$tmp" SCRIPT_DIR="$tmp" bash -c '
      set -Eeuo pipefail
      log()  { echo "[INFO] $*"; }
      warn() { echo "[WARN] $*"; }
      die()  { echo "[ERROR] $*"; exit 1; }
      MNT="$DATA_DIR/mnt"; mkdir -p "$MNT/@blue/etc" "$MNT/@green/etc" "$MNT/@data"
      _gate_pointer() { case $2 in latest) echo shanios-20260922-gnome.zst ;; stable) echo shanios-20260807-gnome.zst ;; iso-latest) echo 20260921 ;; esac; }
      _current_slot() { cat "$MNT/@data/current-slot"; }
      setver() { echo "$1" > "$MNT/@$2/etc/shani-version"; }
      for s in ca clean verifyboot slot_test desktop; do
        eval "cmd_$s() { echo CALL $s \"\$*\"; [[ \"\$FAILING\" != $s ]] || return 3; }"
      done
      _gate_wait_net() { :; }
      cmd_bootstrap() { echo CALL bootstrap "$*"; echo blue > "$MNT/@data/current-slot"; setver "$(grep -oE "[0-9]{8}" <<<"$*")" blue; }
      cmd_iso_install() { echo CALL iso_install "$*"; echo blue > "$MNT/@data/current-slot"; setver "$(grep -oE "[0-9]{8}" <<<"$*")" blue; }
      cmd_upgrade()   { echo CALL upgrade "$*"; [[ "$FAILING" != upgrade ]] || return 3; echo green > "$MNT/@data/current-slot"; setver "$UPVER" green; }
      cmd_rollback()  { echo CALL rollback "$*"; echo blue > "$MNT/@data/current-slot"; }
      source "'"$here"'/lib/gate.sh"
      cmd_gate -p gnome '"$*"'
    ' 2>&1
  )" || rc=$?
  echo "--- $name (rc=$rc)"; echo "$out" | sed 's/^/    /'
  if [[ "$failing" == none && "$upver" == 20260922 ]]; then
    check "$name: exits 0"                      "[[ $rc -eq 0 ]]"
    check "$name: .passed = image + ISO"        "[[ \$(tr '\n' ' ' < $tmp/gate-gnome.passed) == 'shanios-20260922-gnome.zst 20260921 ' ]]"
    check "$name: fresh installs from the ISO"  "grep -q 'CALL iso_install -p gnome --iso=20260921' <<<\"\$out\""
    check "$name: fresh upgrades the ISO install" "[[ \$(grep -c 'CALL upgrade --self-update' <<<\"\$out\") -eq 2 ]]"
    check "$name: launchers on the ISO slot"    "grep -q 'CALL slot_test blue boot-health fresh-user launchers' <<<\"\$out\""
    check "$name: upgrade installs stable"      "grep -q 'CALL bootstrap -p gnome -d 20260807 --from-r2' <<<\"\$out\""
    check "$name: upgrade without --local-src"  "! grep 'CALL upgrade' <<<\"\$out\" | grep -q local-src"
    check "$name: no launchers on R2-installed" "[[ \$(grep -c 'CALL slot_test green boot-health fresh-user\$' <<<\"\$out\") -eq 1 ]]"
    check "$name: rolled-back slot verified"    "[[ \$(grep 'CALL verifyboot' <<<\"\$out\" | tail -1) == 'CALL verifyboot blue 120' ]]"
    check "$name: JSON passed=1"                "grep -q '\"passed\":1' $tmp/gate-gnome-*.json"
  else
    check "$name: exits non-zero"               "[[ $rc -ne 0 ]]"
    check "$name: no .passed marker"            "[[ ! -e $tmp/gate-gnome.passed ]]"
    check "$name: prints gate FAILED"           "grep -q 'gate FAILED' <<<\"\$out\""
    check "$name: final clean still ran"        "[[ \$(grep 'CALL clean' <<<\"\$out\" | wc -l) -ge 2 ]]"
    check "$name: JSON passed=0"                "grep -q '\"passed\":0' $tmp/gate-gnome-*.json"
  fi
  rm -rf "$tmp"
}

run_case all-pass none 20260922
run_case wrong-build-deployed none 20260923
run_case upgrade-fails upgrade 20260922
run_case slot-test-fails slot_test 20260922
run_case_skip() {  # --skip=fresh: ISO untested, so .passed has no ISO line
  local tmp; tmp="$(mktemp -d)"
  UPVER=20260922 FAILING=none DATA_DIR="$tmp" SCRIPT_DIR="$tmp" bash -c '
      set -Eeuo pipefail; log(){ :; }; warn(){ :; }; die(){ echo "$*"; exit 1; }
      MNT="$DATA_DIR/mnt"; mkdir -p "$MNT/@blue/etc" "$MNT/@green/etc" "$MNT/@data"
      _gate_pointer() { case $2 in latest) echo shanios-20260922-gnome.zst ;; stable) echo shanios-20260807-gnome.zst ;; iso-latest) echo 20260921 ;; esac; }
      _current_slot() { cat "$MNT/@data/current-slot"; }
      setver() { echo "$1" > "$MNT/@$2/etc/shani-version"; }
      for s in ca clean verifyboot slot_test desktop; do eval "cmd_$s() { :; }"; done
      _gate_wait_net() { :; }
      cmd_bootstrap() { echo blue > "$MNT/@data/current-slot"; setver "$(grep -oE "[0-9]{8}" <<<"$*")" blue; }
      cmd_iso_install() { cmd_bootstrap "$@"; }
      cmd_upgrade()   { echo green > "$MNT/@data/current-slot"; setver "$UPVER" green; }
      cmd_rollback()  { echo blue > "$MNT/@data/current-slot"; }
      source "'"$here"'/lib/gate.sh"; cmd_gate -p gnome --skip=fresh' >/dev/null 2>&1
  check "skip-fresh: .passed has no ISO" "[[ \$(sed -n 2p $tmp/gate-gnome.passed) == '' && \$(sed -n 1p $tmp/gate-gnome.passed) == shanios-20260922-gnome.zst ]]"
  rm -rf "$tmp"
}
run_case_skip
out="$(DATA_DIR=/nonexistent bash -c 'set -Eeuo pipefail; log(){ :; }; warn(){ :; }; die(){ echo "$*"; exit 1; }
  _gate_pointer() { [[ $2 == latest ]] && echo shanios-20260922-gnome.zst; }
  source "'"$here"'/lib/gate.sh"; cmd_gate -p gnome --candidate=shanios-20260915-gnome.zst' 2>&1)" || true
check "stale --candidate refused" "grep -q 'is not what latest.txt names' <<<\"\$out\""
echo
(( fails == 0 )) && echo "gate-flow: all checks passed" || { echo "gate-flow: $fails check(s) failed"; exit 1; }
