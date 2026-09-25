#!/usr/bin/env bash
# tests/suite-summary.sh — the real cmd_suite (lib/suite.sh) under the same
# `set -Eeuo pipefail` as ./testbed, with the six step commands stubbed.
# Guards the bug where the summary loop's
#   json+="$([[ $i -gt 0 ]] && echo ,)..."
# returned 1 on the first row and errexit killed the harness mid-summary:
# one summary line, no JSON, no PASSED/FAILED, exit 1 even on success.
#
#   tests/suite-summary.sh      (no root, no disks, no container needed)
set -Eeuo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }

run_case() {  # <name> <failing-step|none>
  local name="$1" failing="$2" tmp out rc=0
  tmp="$(mktemp -d)"
  out="$(
    FAILING="$failing" DATA_DIR="$tmp" bash -c '
      set -Eeuo pipefail
      log()  { echo "[INFO] $*"; }
      warn() { echo "[WARN] $*"; }
      die()  { echo "[ERROR] $*"; exit 1; }
      _take_local_src() { LOCAL_SRC=""; REST_ARGS=("$@"); }
      MNT="$DATA_DIR/mnt"; mkdir -p "$MNT/@blue/etc" "$MNT/@green/etc" "$MNT/@data"
      _current_slot() { cat "$MNT/@data/current-slot"; }
      for s in clean ca; do
        eval "cmd_$s() { [[ \"\$FAILING\" != $s ]] || return 3; }"
      done
      # slots behave like the real thing (or like the old destructive rollback)
      cmd_bootstrap() { [[ "$FAILING" != bootstrap ]] || return 3; echo blue > "$MNT/@data/current-slot"
        echo 20260821 > "$MNT/@blue/etc/shani-version"; echo 20260821 > "$MNT/@green/etc/shani-version"; }
      cmd_upgrade() { [[ "$FAILING" != upgrade ]] || return 3; echo green > "$MNT/@data/current-slot"; echo 20260924 > "$MNT/@green/etc/shani-version"; }
      cmd_rollback() { [[ "$FAILING" != rollback ]] || return 3
        if [[ "${DESTRUCTIVE:-}" ]]; then echo 20260924 > "$MNT/@blue/etc/shani-version"   # old behaviour: copy of the new slot
        else echo blue > "$MNT/@data/current-slot"; fi; }
      source "'"$here"'/lib/suite.sh"
      cmd_suite -p gnome
    ' 2>&1
  )" || rc=$?
  echo "--- $name (rc=$rc)"; echo "$out" | sed 's/^/    /'
  local json; json="$(cat "$tmp"/suite-*.json 2>/dev/null || true)"
  if [[ "$failing" == none ]]; then
    check "$name: exits 0"                    "[[ $rc -eq 0 ]]"
    check "$name: prints suite PASSED"        "grep -q 'suite PASSED' <<<\"\$out\""
    check "$name: summary lists all 8 steps"  "[[ \$(grep -cE '^\[INFO\]   (clean|ca|bootstrap|upgrade|rollback|upgrade:switched|rollback:restored) +PASS' <<<\"\$out\") -eq 8 ]]"
    check "$name: JSON has 8 entries"         "[[ \$(grep -o '\"step\"' <<<\"\$json\" | wc -l) -eq 8 ]]"
  else
    check "$name: exits non-zero"             "[[ $rc -ne 0 ]]"
    check "$name: prints suite FAILED"        "grep -q 'suite FAILED' <<<\"\$out\""
    check "$name: summary shows $failing FAIL(3)" "grep -qE '^\[INFO\]   $failing +FAIL\(3\)' <<<\"\$out\""
    check "$name: final clean still ran"      "[[ \$(grep -c 'suite: clean' <<<\"\$out\") -eq 2 ]]"
    check "$name: JSON records the failure"   "grep -q '\"step\":\"$failing\",\"rc\":3' <<<\"\$json\""
  fi
  rm -rf "$tmp"
}

run_case all-pass none
run_case upgrade-fails upgrade
# the rollback bug this suite missed: exit 0, previous system overwritten
tmp2="$(mktemp -d)"
out="$(FAILING=none DESTRUCTIVE=1 DATA_DIR="$tmp2" bash -c '
  set -Eeuo pipefail; log(){ echo "[INFO] $*"; }; warn(){ echo "[WARN] $*"; }; die(){ echo "[ERROR] $*"; exit 1; }
  _take_local_src() { LOCAL_SRC=""; REST_ARGS=("$@"); }
  MNT="$DATA_DIR/mnt"; mkdir -p "$MNT/@blue/etc" "$MNT/@green/etc" "$MNT/@data"
  _current_slot() { cat "$MNT/@data/current-slot"; }
  cmd_clean() { :; }; cmd_ca() { :; }
  cmd_bootstrap() { echo blue > "$MNT/@data/current-slot"; echo 20260821 > "$MNT/@blue/etc/shani-version"; echo 20260821 > "$MNT/@green/etc/shani-version"; }
  cmd_upgrade() { echo green > "$MNT/@data/current-slot"; echo 20260924 > "$MNT/@green/etc/shani-version"; }
  cmd_rollback() { echo 20260924 > "$MNT/@blue/etc/shani-version"; }
  source "'"$here"'/lib/suite.sh"; cmd_suite -p gnome' 2>&1)" || true
check "destructive rollback: suite FAILED"          "grep -q 'suite FAILED' <<<\"\$out\""
check "destructive rollback: rollback:restored FAIL" "grep -qE '^\[INFO\]   rollback:restored +FAIL' <<<\"\$out\""
rm -rf "$tmp2"
echo
(( fails == 0 )) && echo "suite-summary: all checks passed" || { echo "suite-summary: $fails check(s) failed"; exit 1; }
