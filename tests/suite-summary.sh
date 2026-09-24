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
      for s in clean ca bootstrap upgrade rollback; do
        eval "cmd_$s() { [[ \"\$FAILING\" != $s ]] || return 3; }"
      done
      source "'"$here"'/lib/suite.sh"
      cmd_suite -p gnome
    ' 2>&1
  )" || rc=$?
  echo "--- $name (rc=$rc)"; echo "$out" | sed 's/^/    /'
  local json; json="$(cat "$tmp"/suite-*.json 2>/dev/null || true)"
  if [[ "$failing" == none ]]; then
    check "$name: exits 0"                    "[[ $rc -eq 0 ]]"
    check "$name: prints suite PASSED"        "grep -q 'suite PASSED' <<<\"\$out\""
    check "$name: summary lists all 6 steps"  "[[ \$(grep -cE '^\[INFO\]   (clean|ca|bootstrap|upgrade|rollback) +PASS' <<<\"\$out\") -eq 6 ]]"
    check "$name: JSON has 6 entries"         "[[ \$(grep -o '\"step\"' <<<\"\$json\" | wc -l) -eq 6 ]]"
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
echo
(( fails == 0 )) && echo "suite-summary: all checks passed" || { echo "suite-summary: $fails check(s) failed"; exit 1; }
