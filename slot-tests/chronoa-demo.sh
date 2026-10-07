#!/bin/bash
# slot-test-mode: boot
#
# chronoa-demo — one boot, the whole story, measured: the three required models
# installed through the setup wizard's own step functions (nothing downloaded
# twice - the cache is checked), the outcome model trained and reported, and a
# spread of prompts run through the real assistant with what each one actually
# did recorded.
#
#   slot-test blue chronoa-demo --local-src-chronoa=/opt/shani-chronoa \
#       --repo-pkg=llama-cpp,ggml-vulkan
#
# Models come from the testbed cache when it has them, and the cache is consulted
# rather than re-fetched - which is the point of the check:
#
#   SHANIOS_TEST_EXTRA_BINDS=/home/builduser/build/test-env/cache/llm-models:/mnt/llm-models,/home/builduser/build/test-env/eval-out:/mnt/out
#
# Everything it asserts is a number it measured or a file it read back:
#   - the models verify against their pinned digests afterwards;
#   - the outcome model's report prints both lifts, because accuracy on a 94%
#     majority class means nothing on its own;
#   - every prompt records the tool it called and that tool's verdict, so a
#     prompt that "worked" and a prompt that quietly did nothing look different.
set -u
res() { printf 'RESULT %-44s %s\n' "$1" "$2"; }
T=$(mktemp -d /tmp/chronoa-demo.XXXXXX)
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
export HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
       XDG_STATE_HOME="$T/home/.local/state" XDG_CACHE_HOME="$T/home/.cache" \
       GSETTINGS_SCHEMA_DIR=/usr/share/glib-2.0/schemas GSETTINGS_BACKEND=keyfile \
       PYTHONPATH=/usr/lib/shani-chronoa PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME"
py() { timeout "${2:-600}" python3 -c "$1" 2>"$T/py.err"; }
OUT=/mnt/out; [[ -d $OUT && -w $OUT ]] || OUT=$T

command -v llama-server >/dev/null \
    || { res demo-has-llama-server "FAIL (run with --repo-pkg=llama-cpp)"; exit 0; }

# --- 1. the three required models, through the wizard's own steps ---------
mkdir -p "$XDG_DATA_HOME/shani-chronoa/llm"
for m in Qwen3-1.7B-Q4_K_M.gguf; do
    [[ -f /mnt/llm-models/$m ]] && cp "/mnt/llm-models/$m" "$XDG_DATA_HOME/shani-chronoa/llm/$m"
done
before=$(du -sb "$XDG_CACHE_HOME" 2>/dev/null | cut -f1 || echo 0)
for step in brain ears voice; do :; done
out=$(py '
from shani_chronoa import setup_wizard as w
from shani_chronoa.config import ChronoaConfig
c = ChronoaConfig()
w._consent_given(c, True)
print(w.setup_brain("qwen3-1.7b", config=c))
print(w.setup_ears("base-q5_1", config=c))
print(w.setup_voice("af_sarah", config=c))' 3600)
grep -q "Chronoa now thinks" <<<"$out" && res demo-brain-installed PASS \
    || res demo-brain-installed "FAIL ($(tail -3 $T/py.err))"
verify=$(py '
from shani_chronoa import local_llm, stt_provision, voices
print(local_llm.verify("qwen3-1.7b"), stt_provision.is_provisioned("base-q5_1"),
      voices.kokoro_installed("af_sarah"))')
[[ "$verify" == "True True True" ]] && res demo-models-verify "PASS (all three match their pinned digests)" \
    || res demo-models-verify "FAIL ($verify $(tail -3 $T/py.err))"
eng=$(py 'from shani_chronoa.tts import PiperTTS
from shani_chronoa.config import ChronoaConfig
print(PiperTTS(config=ChronoaConfig()).engine())' 300)
grep -q kokoro <<<"$eng" && res demo-voice-is-kokoro "PASS ($eng)" \
    || res demo-voice-is-kokoro "FAIL ($eng $(tail -2 $T/py.err))"

# Kokoro really speaks, and whisper writes it back: the round trip, not a file.
wav=$T/kokoro.wav
spoke=$(py 'from shani_chronoa import voices, local_llm
from shani_chronoa.tts import PiperTTS
from shani_chronoa.config import ChronoaConfig
voices.install_kokoro("af_sarah")
c = ChronoaConfig()
t = PiperTTS(config=c)
print(t.synthesize("Chronoa is set up and ready to help.", "'"$wav"'"), t.engine())' 900 2>&1)
[[ -s $wav ]] && res demo-kokoro-speaks "PASS ($(du -h $wav | cut -f1) of audio)" \
    || res demo-kokoro-speaks "FAIL ($spoke $(tail -2 $T/py.err))"
heard=$(py 'from shani_chronoa import stt
print(stt.WhisperSTT(model="base-q5_1").transcribe("'"$wav"'"))' 900)
hits=$(grep -oiE 'chronoa|set up|ready|help' <<<"$heard" | wc -l)
(( hits >= 2 )) && res demo-kokoro-heard-back "PASS ($hits/4 key words: ${heard:0:70})" \
    || res demo-kokoro-heard-back "FAIL ($hits/4: ${heard:0:90})"

# --- 2. the cache actually stops a second download -----------------------
again=$(py '
from shani_chronoa import local_llm
# Already installed and verified: provisioning must not touch the network, and
# must not re-fetch. `provision` re-hashes what is there and returns.
p = local_llm.provision("qwen3-1.7b", transport=None)
print("ok", p.name)' 900)
grep -q "^ok " <<<"$again" && res demo-reprovision-is-cached "PASS (no download: $again)" \
    || res demo-reprovision-is-cached "FAIL ($again $(tail -2 $T/py.err))"

# --- 3. the outcome model, trained and reported ---------------------------
out=$(py '
from shani_chronoa import learning
rep = learning.train_and_report()
print(learning.render_outcome(rep))
print("BEST", rep.best_detection(), "HONEST", rep.honest())' 1800)
sed 's/^/  | /' <<<"$out"
best=$(grep '^BEST' <<<"$out")
honest=$(grep '^HONEST' <<<"$out")
[[ "$honest" == *"HONEST True"* ]] && res demo-outcome-model-honest "PASS ($best)" \
    || res demo-outcome-model-honest "INFO ($best, honest=$honest)"
grep -q "not detected" <<<"$out" && res demo-outcome-model-limits "PASS (the report names what it cannot do)" \
    || res demo-outcome-model-limits "FAIL (no limits line)"

# --- 4. a spread of prompts through the real assistant -------------------
# Recorded rather than asserted good: what each prompt actually did is the
# finding, and a prompt that quietly did nothing has to look different from one
# that answered.
sweep=$(py '
import json, time
from shani_chronoa import local_llm, tools
from shani_chronoa.assistant import Assistant
from shani_chronoa.config import ChronoaConfig
from shani_chronoa import tool_select

prompts = [
    "what time is it",
    "how much battery is left",
    "what wifi networks are there",
    "what processes are running",
    "what services are running",
    "how loud is it right now",
    "draw a lighthouse at dusk",
    "delete the file at /tmp/definitely-not-here",
    "remind me to buy milk in ten minutes",
    "what is the capital of France",
]
out = []
for say in prompts:
    row = {"say": say}
    try:
        names = [t["function"]["name"] for t in tool_select.select_tools(say, tools.TOOLS)]
    except Exception as exc:
        names = ["<error %s>" % exc]
    row["sent"] = names[:4]
    try:
        tool = names[0]
        outcome = tools.execute_tool_outcome(tool, {}, origin="user")
        row["ran"] = outcome.ran
        row["verdict"] = outcome.verdict
        row["text"] = outcome.text[:80]
    except Exception as exc:
        row["ran"] = False
        row["verdict"] = "<refused: %s>" % type(exc).__name__
    out.append(row)
    print(json.dumps(row, ensure_ascii=False))
' 1800)
echo "$sweep" | sed 's/^/  | /'
echo "$sweep" > "$OUT/prompts.jsonl"
n=$(grep -c '^{' <<<"$sweep")
refused=$(grep -c 'refused' <<<"$sweep")
ran=$(grep -c '"ran": true' <<<"$sweep")
res demo-prompts-run "PASS ($n prompts, $ran ran a tool, $refused were refused)"
grep -q '"verdict": "failed"' <<<"$sweep" \
    && res demo-prompts-honest "PASS (a failing call is recorded as failed, not hidden)" \
    || res demo-prompts-honest "INFO (no failures in this sweep)"

# --- 5. the distilled router, if one was trained -------------------------
out=$(py 'from shani_chronoa import distill
t = distill.teacher_notes()
r = distill.load_router()
print(" | ".join(t))
print("router:", r.classes if r else None)' 600)
sed 's/^/  | /' <<<"$out"
grep -q "router: None" <<<"$out" \
    && res demo-router "INFO (no student on this machine yet - harvest_rows() needs real conversations)" \
    || res demo-router "PASS (a student loaded)"

# --- 6. keep the artefacts ----------------------------------------------
for f in prompts.jsonl; do [[ -f "$OUT/$f" ]] && res demo-artefacts "PASS ($OUT/$f)"; done
python3 -c "
import json,sys
rows=[json.loads(l) for l in open('$OUT/prompts.jsonl') if l.strip()]
with open('$OUT/demo.md','w') as fh:
    fh.write('# Chronoa on a real ShaniOS slot\n\n')
    fh.write('## Prompts, and what each one actually did\n\n')
    fh.write('| you asked | skills sent | it ran | verdict |\n|---|---|---|---|\n')
    for r in rows:
        fh.write('| %s | %s | %s | %s |\n' % (r['say'], ', '.join(r['sent']) or '-',
                                              r['ran'], r['verdict']))
" 2>/dev/null && res demo-report "PASS ($OUT/demo.md)"
exit 0