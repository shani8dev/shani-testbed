#!/bin/bash
# slot-test-mode: boot
#
# chronoa-setup — shani-chronoa's first-run setup (setup_wizard.py) done for
# real in a booted ShaniOS slot: the brain (llama.cpp + a pinned GGUF), the
# ears (a pinned whisper.cpp model) and the voice (Piper + a pinned voice),
# each through the wizard's own step functions - the same ones its window runs.
#
# The images do not ship llama-cpp, ggml-vulkan or whisper-cpp yet (the CLI
# matrix, both images), so run with them from the repositories:
#
#   slot-test blue chronoa-setup --local-src-chronoa=/opt/shani-chronoa \
#       --repo-pkg=llama-cpp,ggml-vulkan,whisper-cpp
#
# The 639 MB test model is not downloaded again if the testbed cache holds it:
# bind test-env/cache/llm-models at /mnt/llm-models (SHANIOS_TEST_EXTRA_BINDS);
# it is copied in and then RE-HASHED by local_llm.provision, so the digest check
# still runs. The speech model, Piper and the voice ARE downloaded (32 + 26 +
# 63 MB) through the real verified download path.
#
# Headline assertions are end-to-end, not "a file exists":
#   - the local model answers a real tool-calling request through Chronoa's own
#     Assistant (get_datetime runs);
#   - Piper says a sentence and whisper.cpp writes the same words back.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
T=$(mktemp -d /tmp/chronoa-setup.XXXXXX)
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill $SERVER_PID 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
       XDG_STATE_HOME="$T/home/.local/state" XDG_CACHE_HOME="$T/home/.cache" \
       GSETTINGS_BACKEND=keyfile PYTHONPATH=/usr/lib/shani-chronoa PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME"
py() { python3 -c "$1" 2>"$T/py.err"; }

for b in llama-server whisper-cli; do
    command -v "$b" >/dev/null && res "setup-has-$b" PASS || res "setup-has-$b" "FAIL (run with --repo-pkg=llama-cpp,ggml-vulkan,whisper-cpp)"
done

before=$(py 'from shani_chronoa import setup_wizard as w; s=w.state(); print(s["brain"]["ready"], s["ears"]["ready"], s["voice"]["ready"], w.needs_setup())')
[[ "$before" == "False False False True" ]] && res setup-state-before "PASS (nothing ready, setup offered)" || res setup-state-before "FAIL ($before $(tail -1 $T/py.err))"

gpu=$(py 'from shani_chronoa import local_llm as l; d=l.gpu_devices(); a=l.server_args(d); print(len(d), "-ngl", a[a.index("-ngl")+1], l.recommended_for_machine(), round(l.ram_gb()))')
res setup-hardware "PASS (gpus/-ngl/default/RAM: $gpu)"

# --- brain -------------------------------------------------------------
MODEL=Qwen3-0.6B-Q8_0.gguf
mkdir -p "$XDG_DATA_HOME/shani-chronoa/llm"
if [[ -f /mnt/llm-models/$MODEL ]]; then
    # a corrupted copy first: provision must refuse it (negative control), so
    # flip one byte in a copy and check verify() says no
    cp /mnt/llm-models/$MODEL "$XDG_DATA_HOME/shani-chronoa/llm/$MODEL"
    printf 'X' | dd of="$XDG_DATA_HOME/shani-chronoa/llm/$MODEL" bs=1 seek=1000 conv=notrunc 2>/dev/null
    bad=$(py 'from shani_chronoa import local_llm as l; print(l.verify("qwen3-0.6b"))')
    [[ "$bad" == False ]] && res setup-brain-digest-refuses-altered PASS || res setup-brain-digest-refuses-altered "FAIL ($bad)"
    cp /mnt/llm-models/$MODEL "$XDG_DATA_HOME/shani-chronoa/llm/$MODEL"
    seeded=" (seeded from the testbed cache, re-hashed)"
else
    seeded=" (downloaded)"
fi
# the wizard's step, with the service start replaced by what the unit runs:
# a booted test slot has no user session for `systemctl --user`
out=$(py '
from shani_chronoa import local_llm, setup_wizard
local_llm.start_service = lambda: (local_llm.write_env(), "")[1]
print(setup_wizard.setup_brain("qwen3-0.6b", wait_seconds=0))')
grep -q "taking a while\|now thinks" <<<"$out" && res setup-brain-step "PASS$seeded" || res setup-brain-step "FAIL ($out $(tail -2 $T/py.err))"
env_args=$(sed -n 's/^LLAMA_ARGS=//p' "$XDG_CONFIG_HOME/shani-chronoa/llm.env")
llama-server $env_args >"$T/server.log" 2>&1 &   # exactly the unit's ExecStart
SERVER_PID=$!
for i in $(seq 1 120); do curl -sf http://127.0.0.1:8765/health >/dev/null && break; sleep 1; done
curl -sf http://127.0.0.1:8765/health >/dev/null && res setup-brain-server-up "PASS (${i}s; $(grep -m1 -oE 'CPU|Vulkan[0-9]' $T/server.log | head -1 || echo cpu))" \
    || { res setup-brain-server-up FAIL; tail -8 "$T/server.log" | sed 's/^/  | /'; }
answer=$(timeout 300 python3 - <<'PY' 2>"$T/a.err"
import asyncio
from shani_chronoa import local_llm, tool_tracking
from shani_chronoa.assistant import Assistant
llm = local_llm.LocalLLM()
assert llm.is_available()
seen = []
a = Assistant(llm)
reply = asyncio.run(a.handle("What is today's date? Use your tool.", on_tool_call=lambda n, args: seen.append(n)))
print("TOOLS", ",".join(seen)); print("REPLY", reply.replace("\n", " ")[:200])
PY
)
echo "$answer" | sed 's/^/  | /'
grep -q "^TOOLS .*get_datetime" <<<"$answer" && res setup-brain-tool-call "PASS (the local model called get_datetime)" \
    || res setup-brain-tool-call "FAIL ($(tail -2 $T/a.err))"
# --- the reply path's latency work, measured on this image's CPU ------------
lat=$(timeout 300 python3 - <<'PY' 2>"$T/l.err"
import asyncio, json, time, httpx
from shani_chronoa import local_llm
from shani_chronoa.assistant import Assistant
llm = local_llm.LocalLLM()
# 1. streaming: first words long before the whole reply
a = Assistant(llm)
marks, t0 = [], time.monotonic()
reply = asyncio.run(a.handle("In three short sentences, describe a calm morning.",
                             on_text=lambda d: marks.append(time.monotonic() - t0)))
total = time.monotonic() - t0
print(f"STREAM deltas={len(marks)} first={marks[0] if marks else -1:.2f}s total={total:.2f}s think={'<think>' in reply}")
# 2. prompt cache: a second turn whose percepts changed reprocesses only the new turn
def ask(percept, history):
    msgs = local_llm.normalize_messages([{"role": "system", "content": "You are Chronoa. " * 40},
                                         {"role": "system", "content": percept}] + history)
    r = httpx.post(f"{local_llm.BASE_URL}/chat/completions", timeout=300, json={
        "model": "x", "messages": msgs, "max_tokens": 8, "chat_template_kwargs": {"enable_thinking": False}})
    return r.json().get("timings", {})
h = [{"role": "user", "content": "Say hi."}]
first = ask("Live percepts: battery 41%", h)
h += [{"role": "assistant", "content": "Hi."}, {"role": "user", "content": "Say bye."}]
second = ask("Live percepts: battery 40%", h)
print(f"CACHE first_prompt_n={first.get('prompt_n')} second_prompt_n={second.get('prompt_n')} "
      f"second_cached={second.get('cache_n')}")
PY
)
echo "$lat" | sed 's/^/  | /'
read -r deltas first total think <<<"$(grep '^STREAM' <<<"$lat" | sed -E 's/STREAM deltas=([0-9]+) first=([0-9.-]+)s total=([0-9.]+)s think=(\w+)/\1 \2 \3 \4/')"
# The first word waits for the model to read the whole prompt (system prompt +
# tool schemas) - streaming cannot hide that; what it buys is the generation
# time after it. So: words arrive while the reply is still being written.
if [[ -n "$deltas" && "$deltas" -gt 3 ]] && python3 -c "import sys; sys.exit(0 if 0 <= $first < $total - 0.5 else 1)" && [[ "$think" == False ]]; then
    res setup-stream-first-words "PASS (first words ${first}s, whole reply ${total}s: $(python3 -c "print(round($total-$first,1))")s of it heard early; no <think>)"
else
    res setup-stream-first-words "FAIL ($(grep '^STREAM' <<<"$lat") $(tail -2 $T/l.err))"
fi
cached=$(grep '^CACHE' <<<"$lat" | sed -E 's/.*second_cached=([0-9]+).*/\1/')
p2=$(grep '^CACHE' <<<"$lat" | sed -E 's/.*second_prompt_n=([0-9]+).*/\1/')
[[ "$cached" =~ ^[0-9]+$ && "$cached" -gt 100 && "$p2" -lt "$cached" ]] \
    && res setup-prompt-cache-reused "PASS (turn 2 reused $cached cached tokens, processed $p2 new)" \
    || res setup-prompt-cache-reused "FAIL ($(grep '^CACHE' <<<"$lat"))"

nctx=$(PYTHONPATH=/usr/lib/shani-chronoa python3 -c 'from shani_chronoa import local_llm; print(local_llm.context_tokens())' 2>/dev/null)
[[ "$nctx" == 8192 ]] && res setup-context-window-read "PASS (n_ctx $nctx from /props)" || res setup-context-window-read "FAIL ($nctx)"

# compacted tool schemas vs full: same tool chosen, less time (decides local_llm.COMPACT_TOOLS)
cmp=$(timeout 900 python3 - <<'PY' 2>"$T/c.err"
import asyncio, time
from shani_chronoa import local_llm
from shani_chronoa.assistant import SYSTEM_PROMPT
from shani_chronoa.tools import TOOLS
from shani_chronoa.tool_select import select_tools
cases = [("What is the battery level?", "get_battery_status"), ("Turn the volume down a little.", "set_volume"),
         ("Set a timer for five minutes.", "set_timer"), ("What's the date today?", "get_datetime")]
result = {}
for compact in (False, True, False, True):
    local_llm.COMPACT_TOOLS = compact
    llm = local_llm.LocalLLM()
    right, spent = 0, 0.0
    for q, want in cases:
        msgs = [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": q}]
        t0 = time.monotonic()
        reply = asyncio.run(llm.chat_message(msgs, tools=select_tools(q, TOOLS)))
        spent += time.monotonic() - t0
        names = [c["function"]["name"] for c in reply.get("tool_calls") or []]
        right += want in names
    a, b = result.get(compact, (0, 0.0))
    result[compact] = (a + right, b + spent)
(fr, ft), (cr, ct) = result[False], result[True]
print(f"COMPACT full={fr}/8 {ft:.1f}s compact={cr}/8 {ct:.1f}s")
PY
)
echo "  | $cmp"
if python3 - "$cmp" <<'PY'
import re, sys
m = re.search(r"full=(\d+)/8 ([\d.]+)s compact=(\d+)/8 ([\d.]+)s", sys.argv[1])
sys.exit(0 if m and int(m.group(3)) >= int(m.group(1)) and float(m.group(4)) < float(m.group(2)) else 1)
PY
then res setup-compact-tools "PASS ($(cut -c9- <<<"$cmp"): as many right calls, less time - compact could be the default)"
else res setup-compact-tools "PASS (measured, compact stays off: $(cut -c9- <<<"$cmp"))"; fi
# ^ a measurement that decides local_llm.COMPACT_TOOLS, not a pass/fail of Chronoa:
#   it fails only if the run itself broke
grep -q "^COMPACT full=" <<<"$cmp" || res setup-compact-tools-ran "FAIL ($(tail -2 $T/c.err))"

st=$(py 'from shani_chronoa import setup_wizard as w; print(w.state()["brain"]["ready"])')
[[ "$st" == True ]] && res setup-brain-ready PASS || res setup-brain-ready "FAIL ($st)"

# --- ears --------------------------------------------------------------
out=$(py 'from shani_chronoa import setup_wizard as w; print(w.setup_ears("tiny-q5_1"))')
[[ "$out" == "Chronoa can now hear you." ]] && res setup-ears-step "PASS (real download, digest checked)" || res setup-ears-step "FAIL ($out $(tail -2 $T/py.err))"

# --- voice -------------------------------------------------------------
out=$(py 'from shani_chronoa import setup_wizard as w; print(w.setup_voice("en_GB-jenny_dioco-medium"))')
grep -q "Jenny" <<<"$out" && res setup-voice-step "PASS (Piper + voice downloaded, digests checked)" || res setup-voice-step "FAIL ($out $(tail -2 $T/py.err))"
heard=$(timeout 300 python3 - <<'PY' 2>"$T/v.err"
from shani_chronoa.tts import PiperTTS
from shani_chronoa.config import ChronoaConfig
from shani_chronoa import stt
tts = PiperTTS(voice=ChronoaConfig().piper_voice)
print("ENGINE", tts.engine())
wav = "/tmp/chronoa-setup-said.wav"
assert tts.synthesize("Hello, I am Chronoa. I will be right here whenever you need me.", wav)
s = stt.WhisperSTT(model="tiny")
print("STT", s.is_available())
print("HEARD", s.transcribe(wav))
PY
)
echo "$heard" | sed 's/^/  | /'
grep -q "^ENGINE piper" <<<"$heard" && res setup-voice-is-piper PASS || res setup-voice-is-piper "FAIL ($(tail -2 $T/v.err))"
words=$(grep '^HEARD' <<<"$heard" | tr 'A-Z' 'a-z')
# the speech model kept loaded in whisper-server vs whisper-cli loading it per utterance
srv=$(timeout 300 python3 - <<'PY' 2>"$T/w.err"
import time
from shani_chronoa import stt, stt_server
s = stt.WhisperSTT(model="tiny")
wav = "/tmp/chronoa-setup-said.wav"
def timed(use):
    s.use_server = use; t0 = time.monotonic(); text = s.transcribe(wav); return time.monotonic() - t0, text
timed(False); cli2, cli_text = timed(False)
warm, _ = timed(True)
srv2, srv_text = timed(True)
stt_server.stop()
same = cli_text.lower().split()[:3] == srv_text.lower().split()[:3]
print(f"WSRV cli={cli2:.2f} server={srv2:.2f} start={warm:.2f} same={same} text={srv_text!r}")
PY
)
echo "  | $srv"
if python3 - "$srv" <<'PY'
import re, sys
m = re.search(r"cli=([\d.]+) server=([\d.]+).*same=(\w+)", sys.argv[1])
sys.exit(0 if m and float(m.group(2)) < float(m.group(1)) and m.group(3) == "True" else 1)
PY
then res setup-whisper-server-faster "PASS ($(sed -E 's/WSRV (cli=[^ ]+ server=[^ ]+ start=[^ ]+).*/\1/' <<<"$srv"), same transcript)"
else res setup-whisper-server-faster "FAIL ($srv $(tail -2 $T/w.err))"; fi
# sentence-by-sentence speech: the first sentence is ready long before a whole-reply WAV would be
first_audio=$(timeout 300 python3 - <<'PY' 2>"$T/q.err"
import time, threading
from shani_chronoa.tts import PiperTTS
from shani_chronoa.config import ChronoaConfig
from shani_chronoa import speech, markdown_lite
tts = PiperTTS(voice=ChronoaConfig().piper_voice)
reply = ("Good morning. The sky is clear and it is twenty two degrees. You have two meetings, the first at ten. "
         "Traffic on your usual route is light, so leaving at half past nine is fine. Have a lovely day.")
t0 = time.monotonic(); tts.synthesize_to_bytes(markdown_lite.to_speech(reply)); whole = time.monotonic() - t0
started, done = threading.Event(), threading.Event(); mark = {}
t0 = time.monotonic()
q = speech.SpeechQueue(tts.synthesize_to_bytes, lambda wav: time.sleep(0.01) or True,
                       on_start=lambda: (mark.setdefault("first", time.monotonic() - t0), started.set()), on_done=done.set)
q.speak(speech.split_sentences(reply)); q.close(); done.wait(120)
print(f"FIRSTAUDIO first={mark.get('first', -1):.2f} whole={whole:.2f} sentences={len(q.spoken)}")
PY
)
echo "  | $first_audio"
read -r fa wh <<<"$(sed -E 's/FIRSTAUDIO first=([0-9.-]+) whole=([0-9.]+).*/\1 \2/' <<<"$first_audio")"
python3 -c "import sys; sys.exit(0 if 0 <= float('$fa') < float('$wh') / 2 else 1)" 2>/dev/null \
    && res setup-speech-first-sentence-sooner "PASS (first audio ${fa}s vs ${wh}s for the whole reply)" \
    || res setup-speech-first-sentence-sooner "FAIL ($first_audio $(tail -2 $T/q.err))"
hits=0; for w in hello right here whenever need; do grep -q "$w" <<<"$words" && hits=$((hits+1)); done
[[ $hits -ge 4 ]] && res setup-piper-to-whisper-round-trip "PASS ($hits/5 words heard back)" || res setup-piper-to-whisper-round-trip "FAIL ($hits/5: $words)"

after=$(py 'from shani_chronoa import setup_wizard as w; s=w.state(); print(s["brain"]["ready"], s["ears"]["ready"], s["voice"]["ready"], w.needs_setup())')
[[ "$after" == "True True True False" ]] && res setup-state-after "PASS (all ready, setup no longer offered)" || res setup-state-after "FAIL ($after)"

# --- the window builds and walks its pages (GTK's Broadway backend, no X) --
if command -v gtk4-broadwayd >/dev/null; then
    gtk4-broadwayd :17 >/dev/null 2>&1 & BPID=$!; sleep 1
    win=$(GDK_BACKEND=broadway BROADWAY_DISPLAY=:17 timeout 60 python3 - <<'PY' 2>"$T/w.err"
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw, GLib
from shani_chronoa import setup_wizard
app = Adw.Application(application_id="dev.shani.test.Setup")
def go(a):
    w = setup_wizard.build_window(a)
    w.present()
    nav = w.get_content().get_content()
    tags = []
    for tag in ("welcome", "brain", "ears", "voice", "done"):
        nav.push_by_tag(tag) if tag != "welcome" else None
        tags.append(nav.get_visible_page().get_tag())
    print("PAGES", " ".join(tags))
    GLib.timeout_add(300, a.quit)
app.connect("activate", go); app.run([])
PY
)
    kill $BPID 2>/dev/null
    [[ "$win" == "PAGES welcome brain ears voice done" ]] && res setup-window-pages PASS || res setup-window-pages "FAIL ($win $(tail -3 $T/w.err))"
else
    res setup-window-pages "SKIP (no gtk4-broadwayd)"
fi
