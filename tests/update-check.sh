#!/usr/bin/env bash
# tests/update-check.sh — the retired interactive update front-end remains a
# routed, read-only compatibility surface for Shani Cassini's deploy status.
set -Eeuo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }

out="$(bash -c '
  set -Eeuo pipefail
  source "'"$here"'/lib/deploy.sh"
  log() { printf "LOG %s\n" "$*"; }
  die() { printf "DIE %s\n" "$*" >&2; exit 1; }
  _take_local_src() { LOCAL_SRC=""; REST_ARGS=("$@"); }
  _prepare_in_current_slot() {
    printf "PREPARE"
    printf " <%s>" "$@"
    NSPAWN_ENTER_ARGS=(--quiet -- shani-deploy --status --check --json)
  }
  systemd-nspawn() { printf "NSPAWN"; printf " <%s>" "$@"; }
  cmd_updatecheck
' 2>&1)"

check "update-check is routed by the entrypoint" \
  "grep -qE '^[[:space:]]*update-check\)[[:space:]]+cmd_updatecheck' \"$here/testbed\""
check "update-check runs the read-only status contract" \
  "grep -q 'PREPARE <shani-deploy> <--status> <--check> <--json>' <<<\"\$out\""
check "update-check invokes nspawn" \
  "grep -q 'NSPAWN <--quiet> <--> <shani-deploy> <--status> <--check> <--json>' <<<\"\$out\""
check "MCP allow-list includes update-check" \
  "python3 - \"$here/mcp/shani_harness_mcp.py\" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location('shani_harness_mcp', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert 'update-check' in mod.CONTAINER_COMMANDS
PY"
check "usage documents the compatibility semantics" \
  "grep -q 'update-check \[--local-src=<dir>\]' \"$here/lib/usage.sh\" && grep -q 'read-only status' \"$here/lib/usage.sh\""
check "retired front-end wording is absent from active surfaces" \
  "! grep -q 'shani-update' \"$here/lib/deploy.sh\" \"$here/lib/usage.sh\" \"$here/testbed\" \"$here/mcp/shani_harness_mcp.py\""

(( fails == 0 )) && echo "update-check: all checks passed" || { echo "update-check: $fails check(s) failed"; exit 1; }
