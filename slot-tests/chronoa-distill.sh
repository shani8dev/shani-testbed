#!/bin/bash
# slot-test-mode: boot
#
# chronoa-distill — distil the real local model into a routing student, on a
# booted ShaniOS slot, and report what it actually learned.
#
# This is the only place the question can be answered. `tools/eval_cases.json`
# asks one request per skill (57 requests, 53 skills) because its job is to prove
# the skills exist; a router needs the same skill asked several ways, or every
# held-out request names a skill the training half never saw. That is why
# `tools/route_cases.json` exists, and why this test runs both shapes: the second
# one is expected to refuse, and a refusal with the right reason is the evidence
# that the gate is real rather than decorative.
#
#   SHANIOS_TEST_EXTRA_BINDS=/home/builduser/build/test-env/cache/llm-models:/mnt/llm-models,\
#   /opt/shani-chronoa:/mnt/chronoa,/home/builduser/build/test-env/eval-out:/mnt/out \
#   slot-test blue chronoa-distill --local-src-chronoa=/opt/shani-chronoa --repo-pkg=llama-cpp
#
# Models: CHRONOA_DISTILL_MODELS (default qwen3-0.6b). Copied from
# /mnt/llm-models when the cache has it and RE-HASHED, else downloaded.
# Results: /mnt/out/distill-<model>.json and .md when /mnt/out is bound.
#
# Every stage PASSes when it ran and reported; the measurement itself is in the
# detail string, because a distillation that agrees with nobody is a finding, not
# a failure of the harness.
set -u
res() { printf 'RESULT %-42s %s\n' "$1" "$2"; }
T=$(mktemp -d /tmp/chronoa-distill.XXXXXX)
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT
export HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
       XDG_STATE_HOME="$T/home/.local/state" XDG_CACHE_HOME="$T/home/.cache" \
       GSETTINGS_BACKEND=keyfile PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME"

# The checkout reaches a slot two ways: an explicit bind at /mnt/chronoa
# (chronoa-eval.sh's convention), or the Chronoa source overlay, which installs
# `tools/` as /usr/lib/shani-chronoa-tools. Asking for one and failing when only
# the other is present is the same harness rot as pinning a filename inside a
# package its neighbours refactor, so both are accepted and the one that is
# there is named in the output.
SRC=""
for candidate in /mnt/chronoa /usr/lib/shani-chronoa-tools; do
    [[ -f "$candidate/tools/distill_run.py" ]] && { SRC="$candidate"; break; }
done
[[ -n "$SRC" ]] || {
    res distill-checkout "FAIL (neither /mnt/chronoa nor the source overlay's /usr/lib/shani-chronoa-tools has tools/distill_run.py)"
    exit 0
}
res distill-checkout "PASS (checkout at $SRC)"
RUNNER="$SRC/tools/distill_run.py"
command -v llama-server >/dev/null || {
    res distill-llama-server "FAIL (llama-server is absent; run with --repo-pkg=llama-cpp)"; exit 0; }
res distill-llama-server "PASS ($(command -v llama-server))"
export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}/usr/lib/shani-chronoa"

# The teacher's own consent gate, and the two privacy gates the teacher layer
# enforces. Both must be open or `distill.resolve()` correctly refuses, and this
# test would then measure the refusal instead of the model.
py() { timeout "${2:-600}" python3 -c "$1" 2>"$T/py.err"; }

for key in $(tr ',' ' ' <<<"${CHRONOA_DISTILL_MODELS:-qwen3-0.6b}"); do
    file=$(py "from shani_chronoa import local_llm; print(local_llm.SPECS['$key'].filename)")
    [[ -n "$file" ]] || { res "distill-$key" "FAIL (no such model: $(tail -1 $T/py.err))"; continue; }
    mkdir -p "$XDG_DATA_HOME/shani-chronoa/llm"
    [[ -f "/mnt/llm-models/$file" ]] && cp "/mnt/llm-models/$file" "$XDG_DATA_HOME/shani-chronoa/llm/$file"
    got=$(py "from shani_chronoa import local_llm
class C:
    def get_bool(self, k, d): return True
local_llm.provision('$key', config=C()); local_llm.write_env(); print('ok')" 3600)
    [[ "$got" == ok ]] || { res "distill-$key-model" "FAIL ($(tail -2 $T/py.err))"; continue; }
    [[ -d /mnt/llm-models && -w /mnt/llm-models && ! -f "/mnt/llm-models/$file" ]] \
        && cp "$XDG_DATA_HOME/shani-chronoa/llm/$file" "/mnt/llm-models/$file"

    # exactly the unit's ExecStart
    args=$(sed -n 's/^LLAMA_ARGS=//p' "$XDG_CONFIG_HOME/shani-chronoa/llm.env")
    # shellcheck disable=SC2086
    llama-server $args >"$T/server-$key.log" 2>&1 &
    SERVER_PID=$!
    up=no
    for i in $(seq 1 240); do
        if curl -sf http://127.0.0.1:8765/health >/dev/null; then up=yes; break; fi
        sleep 1
    done
    if [[ $up != yes ]]; then
        res "distill-$key-server" "FAIL (llama-server never answered: $(tail -3 $T/server-$key.log | tr '\n' ' '))"
        kill $SERVER_PID 2>/dev/null; SERVER_PID=""
        continue
    fi
    res "distill-$key-server" "PASS (llama-server answered on 127.0.0.1:8765)"

    # The teacher must be reachable, and it must be the LOCAL one: this whole
    # check is about distilling from a model on this machine, and a cloud
    # provider answering instead would be a different measurement entirely.
    teacher=$(py "from shani_chronoa import distill
print(','.join(f'{t.id}:{int(t.on_this_machine)}' for t in distill.available_teachers()))")
    case "$teacher" in
        *llama.cpp:1*) res "distill-$key-teacher" "PASS ($teacher)" ;;
        *) res "distill-$key-teacher" "FAIL (expected a local llama.cpp teacher, saw: $teacher)";;
    esac

    out=/mnt/out; [[ -d $out && -w $out ]] || out=$T

    # 1. the real shape: several phrasings per skill, so a student is possible
    timeout 3600 python3 "$RUNNER" --cases="$SRC/tools/route_cases.json" \
        --teacher=llama.cpp --fresh \
        --json="$out/distill-$key.json" --markdown="$out/distill-$key.md" \
        >"$T/run-$key.log" 2>&1
    rc=$?
    if [[ $rc -ne 0 || ! -s "$out/distill-$key.json" ]]; then
        res "distill-$key-run" "FAIL (rc $rc: $(tail -3 $T/run-$key.log | tr '\n' ' '))"
    else
        python3 - "$out/distill-$key.json" "$key" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); key = sys.argv[2]
print(f"RESULT {'distill-' + key + '-agreement':42s} "
      f"{'PASS' if r.get('agreement') is not None else 'FAIL'} "
      f"({r.get('agreed')}/{r.get('cases')} agreed with the human label, "
      f"{float(r.get('agreement', 0)):.0%})")
student = r.get("student") or {}
if r.get("student_written"):
    p = student.get("provenance", {})
    print(f"RESULT {'distill-' + key + '-student':42s} PASS "
          f"({p.get('skills')} skills, {p.get('accuracy'):.0%} vs a "
          f"{p.get('baseline'):.0%} baseline on {p.get('held_out')} held out)")
    print(f"RESULT {'distill-' + key + '-weights':42s} "
          f"{'PASS' if r.get('student_loads_back') else 'FAIL'} "
          f"(loads back, {r.get('student_right_on_all_cases')}/"
          f"{r.get('student_all_cases')} right on the cases)")
    print(f"RESULT {'distill-' + key + '-selector-sees-it':42s} "
          f"{'PASS' if r.get('selector_sees_it') else 'FAIL'} "
          f"(tool_select picks {r.get('selector_picks')})")
else:
    # Not a FAIL: a model that agrees with nobody cannot produce a student, and
    # that is the finding. The reason is printed so it cannot read as a bug.
    print(f"RESULT {'distill-' + key + '-no-student':42s} PASS "
          f"(no student, and the reason is: {student.get('reason')})")
PY
        [[ -s "$out/distill-$key.md" ]] && sed 's/^/  | /' "$out/distill-$key.md"
    fi

    # 2. the smoke-test shape, which must REFUSE and say why. A gate that cannot
    #    refuse is not a gate, so this is the negative control for the whole file.
    timeout 3600 python3 "$RUNNER" --cases="$SRC/tools/eval_cases.json" \
        --teacher=llama.cpp --fresh --json="$out/distill-thin-$key.json" \
        >"$T/run-thin-$key.log" 2>&1
    python3 - "$out/distill-thin-$key.json" "$key" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"RESULT {'distill-thin-' + sys.argv[2]:42s} FAIL (no summary: {exc})")
    raise SystemExit(0)
reason = ((r.get("student") or {}).get("reason")) or ""
ok = not r.get("student_written") and ("under two each" in reason or "one request per skill" in reason)
print(f"RESULT {'distill-thin-' + sys.argv[2]:42s} {'PASS' if ok else 'FAIL'} "
      f"(one request per skill must not train a student; said: {reason[:90] or 'nothing'})")
PY

    kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; SERVER_PID=""
done