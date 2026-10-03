#!/bin/bash
# slot-test-mode: boot
#
# chronoa-eval — Chronoa's task eval (tools/task_eval.py) against the real local
# model on a booted ShaniOS slot: what each harness lever is worth to a small
# model, in right calls out of the cases, measured rather than argued.
#
#   SHANIOS_TEST_EXTRA_BINDS=/home/builduser/build/test-env/cache/llm-models:/mnt/llm-models,\
#   /opt/shani-chronoa:/mnt/chronoa,/home/builduser/build/test-env/eval-out:/mnt/out \
#   slot-test blue chronoa-eval --local-src-chronoa=/opt/shani-chronoa --repo-pkg=llama-cpp,ggml-vulkan
#
# Models: CHRONOA_EVAL_MODELS (default qwen3-0.6b,qwen3-1.7b); each is copied
# from /mnt/llm-models when the cache has it and RE-HASHED, else downloaded.
# Results: /mnt/out/eval-<model>.json and .md when /mnt/out is bound.
# Configs: CHRONOA_EVAL_CONFIGS (default: all four local ones).
#
# Every config is a PASS when it ran - this is a measurement, not a gate; it
# FAILs only when the eval itself could not run.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
T=$(mktemp -d /tmp/chronoa-eval.XXXXXX)
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill $SERVER_PID 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
       XDG_STATE_HOME="$T/home/.local/state" XDG_CACHE_HOME="$T/home/.cache" \
       GSETTINGS_BACKEND=keyfile PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME"
EVAL=/mnt/chronoa/tools/task_eval.py
[[ -f "$EVAL" ]] || { res eval-checkout "FAIL (bind the checkout at /mnt/chronoa)"; exit 0; }
command -v llama-server >/dev/null || { res eval-llama-server "FAIL (run with --repo-pkg=llama-cpp,ggml-vulkan)"; exit 0; }
export PYTHONPATH=/mnt/chronoa/usr/lib/shani-chronoa
py() { timeout "${2:-1800}" python3 -c "$1" 2>"$T/py.err"; }

for key in $(tr ',' ' ' <<<"${CHRONOA_EVAL_MODELS:-qwen3-0.6b,qwen3-1.7b}"); do
    file=$(py "from shani_chronoa import local_llm; print(local_llm.SPECS['$key'].filename)")
    [[ -n "$file" ]] || { res "eval-$key" "FAIL (no such model: $(tail -1 $T/py.err))"; continue; }
    mkdir -p "$XDG_DATA_HOME/shani-chronoa/llm"
    [[ -f "/mnt/llm-models/$file" ]] && cp "/mnt/llm-models/$file" "$XDG_DATA_HOME/shani-chronoa/llm/$file"
    got=$(py "from shani_chronoa import local_llm
class C:
    def get_bool(self, k, d): return True
local_llm.provision('$key', config=C()); local_llm.write_env(); print('ok')" 3600)
    [[ "$got" == ok ]] || { res "eval-$key-model" "FAIL ($(tail -2 $T/py.err))"; continue; }
    [[ -d /mnt/llm-models && -w /mnt/llm-models && ! -f "/mnt/llm-models/$file" ]] \
        && cp "$XDG_DATA_HOME/shani-chronoa/llm/$file" "/mnt/llm-models/$file"
    args=$(sed -n 's/^LLAMA_ARGS=//p' "$XDG_CONFIG_HOME/shani-chronoa/llm.env")
    llama-server $args >"$T/server-$key.log" 2>&1 &   # exactly the unit's ExecStart
    SERVER_PID=$!
    for i in $(seq 1 180); do curl -sf http://127.0.0.1:8765/health >/dev/null && break; sleep 1; done
    out=/mnt/out; [[ -d $out && -w $out ]] || out=$T
    timeout 7200 python3 "$EVAL" --configs="${CHRONOA_EVAL_CONFIGS:-bare,select,select+recover,+compact}" \
        --json="$out/eval-$key.json" --markdown="$out/eval-$key.md" >"$T/eval-$key.log" 2>&1
    rc=$?
    kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; SERVER_PID=""
    if [[ $rc -ne 0 || ! -s "$out/eval-$key.md" ]]; then
        res "eval-$key" "FAIL (rc $rc: $(tail -3 $T/eval-$key.log | tr '\n' ' '))"; continue
    fi
    sed 's/^/  | /' "$out/eval-$key.md"
    python3 - "$out/eval-$key.json" "$key" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
for config, v in r.items():
    print(f"RESULT {('eval-' + sys.argv[2] + '-' + config):40s} PASS ({v['right_call']}/{v['cases']} right calls, "
          f"{v['right_tool']}/{v['cases']} right tool, {v['mean_seconds']}s each)")
PY
done
