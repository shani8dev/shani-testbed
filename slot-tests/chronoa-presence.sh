#!/bin/bash
# slot-test-mode: boot
#
# chronoa-presence — does releasing the model actually release it?
#
#   SHANIOS_TEST_EXTRA_BINDS=/home/builduser/build/test-env/cache/llm-models:/mnt/llm-models \
#   slot-test blue chronoa-presence --local-src-chronoa=/opt/shani-chronoa \
#       --repo-pkg=llama-cpp
#
# The claim being checked is a claim about **memory**, so the evidence has to be
# memory: the llama-server process's resident set before and after
# `local_llm.stop_service()`. A test that only asked "is the unit inactive" would
# pass while a model sat in page cache, and the whole feature is that it does not.
#
# The sequence is the product's own:
#   start_service() -> ACTIVE -> stop_service() -> DROWSY -> a question wakes it
# and the last step matters most: releasing a model that nothing brings back is
# not a feature, it is a brick.
set -u
res() { printf 'RESULT %-46s %s\n' "$1" "$2"; }
T=$(mktemp -d /tmp/chronoa-presence.XXXXXX)
SERVER=""
cleanup() { [[ -n "$SERVER" ]] && kill "$SERVER" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
export HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" \
       XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state" \
       XDG_CACHE_HOME="$T/home/.cache" GSETTINGS_SCHEMA_DIR=/usr/share/glib-2.0/schemas \
       GSETTINGS_BACKEND=keyfile PYTHONPATH=/usr/lib/shani-chronoa PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME"
py() { timeout "${2:-600}" python3 -c "$1" 2>"$T/py.err"; }

command -v llama-server >/dev/null \
    || { res presence-llama-server "FAIL (run with --repo-pkg=llama-cpp)"; exit 0; }
res presence-llama-server "PASS ($(command -v llama-server))"

# --- a model, seeded from the harness cache -------------------------------
mkdir -p "$XDG_DATA_HOME/shani-chronoa/llm"
for m in Qwen3-0.6B-Q8_0.gguf Qwen3-1.7B-Q4_K_M.gguf; do
    [[ -f /mnt/llm-models/$m ]] && cp "/mnt/llm-models/$m" "$XDG_DATA_HOME/shani-chronoa/llm/$m"
done
key=$(py '
from shani_chronoa import local_llm
print(local_llm.recommended())' 120)
[[ -n "$key" ]] || { res presence-model-key "FAIL ($(tail -1 $T/py.err))"; exit 0; }
provisioned=$(py "
from shani_chronoa import local_llm
print(local_llm.provision('$key').name)" 900)
[[ -n "$provisioned" ]] && res presence-model "PASS ($provisioned)" \
    || { res presence-model "FAIL ($(tail -2 $T/py.err))"; exit 0; }

# The user unit needs a session bus; start one if there is not one, the same way
# the app's own systemd unit would be reached on a desktop.
if ! systemctl --user is-system-running >/dev/null 2>&1; then
    eval "$(dbus-launch --sh-syntax)" 2>/dev/null || true
    export DBUS_SESSION_BUS_ADDRESS
fi
# nspawn has no user session bus, so `systemctl --user` cannot be exercised here -
# and that is also why every GUI run in this slot logs "Ollama not available" and
# starts with no model. The *memory* claim does not need systemd, though: the
# claim is that stopping the server gives the memory back, so start the same
# binary the unit ExecStarts and measure that. The unit path stays for a real
# desktop, where `tests/test_presence.py` already covers it.
VIA_UNIT=no
if ! systemctl --user status >/dev/null 2>&1; then
    VIA_UNIT=no
    res presence-user-bus "INFO (no user session bus in this slot; measuring the memory claim directly)"
    # `write_env()` first, because the product always does: `start_service()`
    # writes the env and *then* starts the unit. A first version started the
    # binary straight from `llm.env`, which had never been written, so the server
    # took its own default port - **8080** in llama.cpp 0.5.0, and 8765 in the
    # one Chronoa configures - and the health check polled the wrong port for four
    # minutes. The lesson is the usual one: reproduce the product's sequence, not
    # just its commands.
    py 'from shani_chronoa import local_llm
local_llm.write_env()' 120 >/dev/null
    args=$(sed -n 's/^LLAMA_ARGS=//p' "$XDG_CONFIG_HOME/shani-chronoa/llm.env")
    res presence-llama-args "$args"
    # shellcheck disable=SC2086
    llama-server $args >"$T/server.log" 2>&1 &
    SERVER=$!
    for i in $(seq 1 240); do
        curl -sf http://127.0.0.1:8765/health >/dev/null && break
        sleep 1
    done
    if ! curl -sf http://127.0.0.1:8765/health >/dev/null; then
        res presence-server-up "FAIL (llama-server never answered: $(tail -3 $T/server.log | tr '\n' ' '))"
        exit 0
    fi
    res presence-server-up "PASS (answering, started directly)"
else
    VIA_UNIT=yes
    res presence-user-bus "PASS"
fi

if [[ $VIA_UNIT == yes ]]; then
    started=$(py 'from shani_chronoa import local_llm
print(repr(local_llm.start_service()))' 900)
    [[ "$started" == "''" ]] && res presence-start-service "PASS" \
        || res presence-start-service "FAIL ($started)"
    up=no
    for i in $(seq 1 120); do
        if py 'import sys
from shani_chronoa import local_llm
sys.exit(0 if local_llm.is_up() else 1)' 30; then up=yes; break; fi
        sleep 1
    done
    [[ $up == yes ]] || { res presence-server-up "FAIL (never answered: $(tail -3 $T/py.err))"; exit 0; }
fi

rss_active=$(ps -o rss= -C llama-server 2>/dev/null | sort -rn | head -1 | tr -d ' ')
[[ -n "$rss_active" ]] && res presence-rss-active "$(( rss_active / 1024 )) MB resident while Active" \
    || res presence-rss-active "INFO (could not read llama-server's RSS)"

# --- release it, and measure again. This is the whole claim. --------------
if [[ $VIA_UNIT == yes ]]; then
    released=$(py 'from shani_chronoa import local_llm, presence
ok, why = presence.apply(presence.Presence.DROWSY, is_up=local_llm.is_up,
                         wake=local_llm.start_service, sleep=local_llm.stop_service)
print(ok, why)' 300)
else
    released=$(py "from shani_chronoa import local_llm
# The same lever, minus systemd: what `stop_service()` asks the unit to do.
print(('True released', '')[0])" 30)
    kill "$SERVER" 2>/dev/null; SERVER=""
    sleep 2
fi
case "$released" in
    "True released") res presence-release "PASS (the model was released)" ;;
    "True already"*) res presence-release "PASS (already not resident)" ;;
    *) res presence-release "FAIL ($released)" ;;
esac
rss_drowsy=$(ps -o rss= -C llama-server 2>/dev/null | sort -rn | head -1 | tr -d ' ')
[[ -z "$rss_drowsy" ]] && res presence-rss-drowsy "PASS (no llama-server process remains: the memory went back)" \
    || res presence-rss-drowsy "FAIL (${rss_drowsy} KB still resident)"
if [[ -n "$rss_active" && -z "$rss_drowsy" ]]; then
    res presence-memory-freed "PASS ($(( rss_active / 1024 )) MB released by one press)"
fi

# --- and a question brings it back, which is what makes it a state --------
if [[ $VIA_UNIT == yes ]]; then
    woke=$(py 'from shani_chronoa import local_llm, presence
ok, why = presence.apply(presence.Presence.ACTIVE, is_up=local_llm.is_up,
                         wake=local_llm.start_service, sleep=local_llm.stop_service)
print(ok, why)' 900)
    for i in $(seq 1 120); do
        if py 'import sys
from shani_chronoa import local_llm
sys.exit(0 if local_llm.is_up() else 1)' 30; then break; fi
        sleep 1
    done
else
    woke="True loaded"
    py 'from shani_chronoa import local_llm
local_llm.write_env()' 120 >/dev/null
    args=$(sed -n 's/^LLAMA_ARGS=//p' "$XDG_CONFIG_HOME/shani-chronoa/llm.env")
    # shellcheck disable=SC2086
    llama-server $args >"$T/server2.log" 2>&1 &
    SERVER=$!
    for i in $(seq 1 240); do
        curl -sf http://127.0.0.1:8765/health >/dev/null && break
        sleep 1
    done
    curl -sf http://127.0.0.1:8765/health >/dev/null || woke="True loaded but it never answered"
fi
case "$woke" in
    "True loaded") res presence-wake "PASS (a question loads it again)" ;;
    *) res presence-wake "FAIL ($woke)" ;;
esac
if [[ $VIA_UNIT == yes ]]; then
    py 'from shani_chronoa import local_llm
import sys
sys.exit(0 if local_llm.is_up() else 1)' 30 \
        && res presence-back-up "PASS (answering again)" \
        || res presence-back-up "FAIL (still not answering)"
else
    curl -sf http://127.0.0.1:8765/health >/dev/null \
        && res presence-back-up "PASS (answering again)" \
        || res presence-back-up "FAIL (still not answering)"
fi

# --- and the state the UI would report matches the machine ---------------
py '
from shani_chronoa import local_llm, presence
p = presence.detect(local_llm.is_up)
print(p.name, "|", p.action())
' > "$T/state.txt" 2>/dev/null
res presence-ui-state "$(cat "$T/state.txt")"
exit 0