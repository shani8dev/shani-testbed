#!/bin/bash
# Regression test: cmd_serve must refuse to start when its port is already
# held, instead of dying later inside python's bind with the stale server
# still answering.
#
# Why this matters (found live, 2026-09-26): a `test serve` from an earlier
# session was still holding 127.0.0.1:443 and answering with ITS docroot. The
# new invocation died with "Address already in use" while the old server kept
# serving, so the feed looked reachable but was missing exactly the files being
# looked for — indistinguishable from "the feed is unreachable". That cost a
# long debugging session; the guard turns it into an immediate, named error.
set -u

TESTBED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TESTBED_ROOT" || exit 1

# lib/common.sh reads these at source time (the real `testbed` entrypoint sets
# them before loading the modules), and it derives CA_DIR from SHANIOS_TEST_DATA.
# Point that at a temp dir so the test never touches the real harness state.
MEDIA_ROOT="${SHANIOS_TEST_MEDIA_ROOT:-/home/shrinivaskumbhar/Documents/shani/shani-install-media}"
SCRIPT_DIR="$MEDIA_ROOT/test-env"
export SHANIOS_TEST_DATA="${SHANIOS_TEST_DATA:-$(mktemp -d)}"
mkdir -p "$SHANIOS_TEST_DATA"

# die()/log() are defined in the media repo's config/config.sh (which `testbed`
# sources before loading the modules) — without it the guard's die() is undefined
# and the script falls through to python's bind error instead of refusing.
# config.sh resolves its paths relative to CWD, so source it from the media repo
# exactly as `testbed` does (it cd's to MEDIA_ROOT first for this reason), then
# cd back. It must be sourced in THIS shell, not a subshell: it defines the
# die()/log() functions cmd_serve calls, and a subshell would discard them.
# shellcheck source=/dev/null
source "$MEDIA_ROOT/config/config.sh" || { echo "cannot source $MEDIA_ROOT/config/config.sh (need die/log)"; exit 1; }
cd "$TESTBED_ROOT" || exit 1
# shellcheck source=/dev/null
source lib/common.sh
# shellcheck source=/dev/null
source lib/pki.sh

command -v cmd_serve >/dev/null 2>&1 || { echo "cmd_serve not loaded - cannot test"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"; CA="$WORK/ca"
mkdir -p "$OUT/gnome" "$CA"
printf 'shanios-20260925-gnome.zst\n' > "$OUT/gnome/stable.txt"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$CA/ca.key" \
  -out "$CA/ca.crt" -subj "/CN=shani-testbed-guard" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$CA/server.key" \
  -out "$WORK/leaf.csr" -subj "/CN=downloads.shani.dev" >/dev/null 2>&1
openssl x509 -req -in "$WORK/leaf.csr" -days 1 -CA "$CA/ca.crt" -CAkey "$CA/ca.key" \
  -CAcreateserial -out "$CA/server.crt" \
  -extfile <(printf "subjectAltName=DNS:downloads.shani.dev") >/dev/null 2>&1

export CA_DIR="$CA" OUTPUT_DIR="$OUT"
_leaf_cert_paths downloads.shani.dev

fails=0
expect() { # name pattern
  if grep -q "$2" "$WORK/out.log"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (no '$2' in output)"
    sed 's/^/       /' "$WORK/out.log" | head -3
    fails=$((fails + 1))
  fi
}

# --- a free port must NOT trip the guard -------------------------------------
# config.sh enables `set -e`, and this call is EXPECTED to end non-zero (the
# timeout kills the foreground server), so it must run with errexit suspended.
FREE_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
set +e
timeout 5 cmd_serve "$FREE_PORT" "$OUT" downloads.shani.dev > "$WORK/out.log" 2>&1
set -e
if grep -q 'already in use' "$WORK/out.log"; then
  echo "FAIL - free port ${FREE_PORT} was wrongly reported as in use"; fails=$((fails+1))
else
  echo "ok   - a free port is not reported as in use"
fi

# --- a held port must be refused, by name -------------------------------------
python3 - "$WORK" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1] + "/held.port", "w").write(str(s.getsockname()[1]))
time.sleep(30)
PY
holder=$!
sleep 2
HELD_PORT="$(cat "$WORK/held.port" 2>/dev/null || echo "")"
if [ -z "$HELD_PORT" ]; then
  echo "FAIL - could not occupy a port to test against"; fails=$((fails+1))
else
  set +e
  # In a subshell: the guard path calls die(), which exits — that would
  # otherwise terminate this whole test script instead of just this check.
  ( cmd_serve "$HELD_PORT" "$OUT" downloads.shani.dev ) > "$WORK/out.log" 2>&1
  set -e
  expect "a held port is refused by the guard" 'Port [0-9]* is already in use'
  # The refusal must tell the caller WHY and what to do, not just that it failed.
  if grep -qi 'previous' "$WORK/out.log" && grep -qi 'pkill' "$WORK/out.log"; then
    echo "ok   - the refusal names the cause (a previous serve) and the fix (pkill)"
  else
    echo "FAIL - the refusal does not explain the cause or the fix"
    sed 's/^/       /' "$WORK/out.log" | head -3
    fails=$((fails + 1))
  fi
fi
kill "$holder" 2>/dev/null || true

echo
if [ "$fails" -eq 0 ]; then
  echo "serve port guard: all checks passed"
else
  echo "serve port guard: $fails check(s) failed"
fi
exit "$fails"
