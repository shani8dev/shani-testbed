#!/bin/bash
# slot-test-mode: boot
#
# chronoa-extras — the setup window's optional extras done for real in a booted
# ShaniOS slot, each through setup_wizard's own step function and then USED:
#
#   eyes     a llama.cpp vision model describes a picture whose content is known;
#            the server's --sleep-idle-seconds gives its memory back and wakes again
#   imagine  stable-diffusion.cpp (the release build setup installs) draws a
#            picture, and the eyes are asked what it shows
#   memory   an embedding model makes conversation search find by meaning what
#            no word matches - and the same search without it finds nothing
#   kokoro   the Kokoro voice (sherpa-onnx) speaks, and whisper writes the words back
#   hindi    the Hindi Piper voice (newer than the 2023 Piper binary) speaks a
#            Devanagari reply, and tesseract has the Hindi reading data
#   photos   OpenCV (user-local wheel) names the apple imagine drew; a photo with
#            text in it is found by that text (real OCR, real EXIF reader)
#   sounds   CED-tiny hears its own cat recording as a cat
#   speakers a real two-person recording comes back as two speakers, and as
#            subtitles; the cleaned copy keeps its sample rate
#   edits    imagine changes a photo by description; edit_image upscales 2x
#
#   slot-test blue chronoa-extras --local-src-chronoa=/opt/shani-chronoa \
#       --repo-pkg=llama-cpp,ggml-vulkan,whisper-cpp
#
# Large models are copied from the testbed cache when it holds them (bind
# test-env/cache/llm-models at /mnt/llm-models through SHANIOS_TEST_EXTRA_BINDS)
# and RE-HASHED by the provisioning code, so the digest checks still run; what
# is downloaded is copied back into the cache when it is writable. A booted
# slot has no user session, so each server is run exactly as its unit would
# run it: the binary and arguments from ~/.config/shani-chronoa/model-<name>.env.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
T=$(mktemp -d /tmp/chronoa-extras.XXXXXX)
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
export HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
       XDG_STATE_HOME="$T/home/.local/state" XDG_CACHE_HOME="$T/home/.cache" \
       GSETTINGS_BACKEND=keyfile PYTHONPATH=/usr/lib/shani-chronoa PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME"
py() { timeout "${2:-900}" python3 -c "$1" 2>"$T/py.err"; }
CACHE=/mnt/llm-models
D="$XDG_DATA_HOME/shani-chronoa"

seed() {  # seed <subdir> <file>: copy from the cache if it has it
    mkdir -p "$D/$1"
    [[ -f "$CACHE/$2" ]] && cp "$CACHE/$2" "$D/$1/$2" && echo " (seeded from the testbed cache, re-hashed)"
}
keep() {  # keep <subdir> <file>: save a download for the next run
    [[ -d "$CACHE" && -w "$CACHE" && ! -f "$CACHE/$2" && -f "$D/$1/$2" ]] && cp "$D/$1/$2" "$CACHE/$2"
    return 0
}
serve() {  # serve <instance> <health path> <seconds>: run what the unit would, wait for it
    local bin args
    bin=$(sed -n 's/^MODEL_BIN=//p' "$XDG_CONFIG_HOME/shani-chronoa/model-$1.env")
    args=$(sed -n 's/^MODEL_ARGS=//p' "$XDG_CONFIG_HOME/shani-chronoa/model-$1.env")
    $bin $args >"$T/$1.log" 2>&1 &
    PIDS+=($!)
    SERVED_PID=$!
    local port; port=$(py "from shani_chronoa import model_service as m; print(m.PORTS['$1'])")
    for i in $(seq 1 "$3"); do curl -sf "http://127.0.0.1:$port$2" >/dev/null && return 0; sleep 1; done
    tail -6 "$T/$1.log" | sed 's/^/  | /'
    return 1
}
STUB='from shani_chronoa import model_service; model_service.start = lambda instance: ""'

for b in llama-server whisper-cli tesseract; do
    command -v "$b" >/dev/null && res "extras-has-$b" PASS || res "extras-has-$b" "FAIL (run with --repo-pkg=llama-cpp,ggml-vulkan,whisper-cpp)"
done
before=$(py 'from shani_chronoa import setup_wizard as w; s=w.state(); print(s["eyes"]["ready"], s["imagine"]["ready"], s["memory"]["ready"], s["languages"]["chosen"], s["kokoro"]["installed"])')
[[ "$before" == "False False False [] False" ]] && res extras-state-before "PASS (nothing set up)" || res extras-state-before "FAIL ($before $(tail -1 $T/py.err))"

# a 256x256 PNG with a big red square on white, written with zlib only
py '
import struct, zlib
w = h = 256
rows = b"".join(b"\x00" + b"".join(b"\xd0\x10\x10" if 64 <= x < 192 and 64 <= y < 192 else b"\xff\xff\xff"
                                   for x in range(w)) for y in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open("'"$T"'/red.png", "wb").write(png)'

# --- eyes ----------------------------------------------------------------
V=$(py 'from shani_chronoa import local_vision as v; m=v.MODELS["smolvlm2-500m"]; print(m.model.filename, m.mmproj.filename)')
read -r VM VP <<<"$V"
s1=$(seed vision "$VM"); seed vision "$VP" >/dev/null
out=$(py "$STUB
from shani_chronoa import setup_wizard
print(setup_wizard.setup_eyes('smolvlm2-500m', wait_seconds=0))" 1800)
grep -q "can now see" <<<"$out" && res extras-eyes-step "PASS${s1}" || res extras-eyes-step "FAIL ($out $(tail -2 $T/py.err))"
keep vision "$VM"; keep vision "$VP"
# a short idle time, so going to sleep and waking can be watched inside a test
sed -i 's/--sleep-idle-seconds [0-9]*/--sleep-idle-seconds 15/' "$XDG_CONFIG_HOME/shani-chronoa/model-vision.env"
if serve vision /health 180; then
    VPID=$SERVED_PID
    t0=$(date +%s.%N)
    desc=$(py "from shani_chronoa import local_vision as v; print(v.describe(open('$T/red.png','rb').read(), 'What colour is the square in the middle of this picture? Answer in one word.', 300).replace(chr(10),' '))" 400)
    t1=$(date +%s.%N)
    grep -qi "red" <<<"$desc" && res extras-eyes-describes "PASS (\"${desc:0:60}\" in $(printf '%.1f' $(echo "$t1-$t0" | bc))s)" \
        || res extras-eyes-describes "FAIL (${desc:0:120} $(tail -2 $T/py.err))"
    awake=$(awk '/VmRSS/{print $2}' /proc/$VPID/status)
    sleep 25
    asleep=$(awk '/VmRSS/{print $2}' /proc/$VPID/status)
    desc2=$(py "from shani_chronoa import local_vision as v; print(v.describe(open('$T/red.png','rb').read(), 'What colour is the square? One word.', 300))" 400)
    if (( asleep * 2 < awake )) && grep -qi red <<<"$desc2"; then
        res extras-eyes-sleeps-and-wakes "PASS (RSS $((awake/1024)) MB awake, $((asleep/1024)) MB asleep, answered again after waking)"
    else
        res extras-eyes-sleeps-and-wakes "FAIL (RSS ${awake} -> ${asleep} kB; second answer: ${desc2:0:60} $(grep -i sleep $T/vision.log | tail -2))"
    fi
else
    res extras-eyes-server-up FAIL
fi

# --- memory ----------------------------------------------------------------
EM=$(py 'from shani_chronoa import local_embed as e; print(e.MODEL.filename)')
s2=$(seed embed "$EM")
out=$(py "$STUB
from shani_chronoa import setup_wizard
print(setup_wizard.setup_memory(wait_seconds=0))" 900)
grep -q "by what they meant" <<<"$out" && res extras-memory-step "PASS${s2}" || res extras-memory-step "FAIL ($out $(tail -2 $T/py.err))"
keep embed "$EM"
if serve embed /health 120; then
    found=$(py '
from shani_chronoa import conversation_store as c
root = c.session_dir()
a = c.active_path(root)
for role, text in (("user", "the wifi box keeps dropping every evening"), ("assistant", "Try moving it off the floor")):
    c.append({"role": role, "content": text}, a)
c.new_session(root)
for role, text in (("user", "a dal recipe for tonight"), ("assistant", "Soak the lentils first")):
    c.append({"role": role, "content": text}, c.active_path(root))
now = c.new_session(root)
words = c.search(root, "router problems", exclude=now, embed=lambda *a, **k: None)
meaning = c.search(root, "router problems", exclude=now)
print(len(words), meaning[0]["match"] if meaning else "-", meaning[0]["snippet"][:40] if meaning else "-",
      any("dal" in h["snippet"] for h in meaning[:1]))' 300)
    read -r nw how snip <<<"$found"
    [[ "$nw" == 0 && "$how" == meaning && "$found" == *"wifi box"* && "$found" == *False ]] \
        && res extras-memory-finds-by-meaning "PASS (words: 0 hits; meaning: \"${found#* meaning }\")" \
        || res extras-memory-finds-by-meaning "FAIL ($found $(tail -2 $T/py.err))"
else
    res extras-memory-server-up FAIL
fi

# --- imagine ---------------------------------------------------------------
SD=$(py 'from shani_chronoa import imagegen as i; print(i.MODEL.filename)')
s3=$(seed imagine "$SD")
out=$(py "$STUB
from shani_chronoa import setup_wizard
print(setup_wizard.setup_imagine(wait_seconds=0, gpu=False))" 2400)
grep -q "can now make pictures" <<<"$out" && res extras-imagine-step "PASS${s3}" || res extras-imagine-step "FAIL ($out $(tail -2 $T/py.err))"
keep imagine "$SD"
if serve imagine /sdapi/v1/sd-models 120; then
    pic=$(py '
import time
from shani_chronoa.skills import generate_image
t = time.monotonic()
print(generate_image._run({"prompt": "a single red apple on a plain white table, photo", "size": 512, "steps": 2, "seed": 7}))
print("SECONDS", round(time.monotonic() - t, 1))' 700)
    file=$(grep -oE "/[^ ]+\.png" <<<"$pic" | head -1)
    if [[ -n "$file" && -f "$file" ]] && head -c 8 "$file" | od -An -c | grep -q "P   N   G"; then
        res extras-imagine-draws "PASS (512x512 in $(sed -n 's/^SECONDS //p' <<<"$pic")s, $(stat -c %s "$file") bytes)"
        what=$(py "from shani_chronoa import local_vision as v; print(v.describe(open('$file','rb').read(), 'What fruit is in this picture? One word.', 300))" 400)
        grep -qi "apple" <<<"$what" && res extras-imagine-eyes-agree "PASS (the eyes say: ${what:0:40})" \
            || res extras-imagine-eyes-agree "FAIL (the eyes say: ${what:0:80})"
        edited=$(py "
from shani_chronoa.skills import generate_image
print(generate_image._run({'prompt': 'a green apple on a white table, photo', 'from_photo': '$file', 'strength': 0.6, 'seed': 3}))" 700)
        efile=$(grep -oE "/[^ ]+\.png" <<<"$edited" | head -1)
        [[ -n "$efile" && -s "$efile" && "$efile" != "$file" ]] && res extras-imagine-edits-a-photo "PASS (${edited:0:90})" \
            || res extras-imagine-edits-a-photo "FAIL ($edited $(tail -2 $T/py.err))"
        APPLE="$file"
    else
        res extras-imagine-draws "FAIL ($pic $(tail -3 $T/py.err) $(tail -3 $T/imagine.log))"
    fi
else
    res extras-imagine-server-up FAIL
fi

# --- kokoro ----------------------------------------------------------------
out=$(py 'from shani_chronoa import setup_wizard; print(setup_wizard.setup_voice("af_sarah"))' 900)
grep -q "speaks with Kokoro" <<<"$out" && res extras-kokoro-step PASS || res extras-kokoro-step "FAIL ($out $(tail -2 $T/py.err))"
spoke=$(py '
import time
from shani_chronoa.tts import PiperTTS
t = PiperTTS()
s = time.monotonic()
ok = t.synthesize("The meeting moved to four in the afternoon.", "'"$T"'/kokoro.wav")
print(t.engine("hello"), ok, round(time.monotonic() - s, 1))' 300)
read -r eng ok secs <<<"$spoke"
[[ "$eng" == kokoro && "$ok" == True && -s "$T/kokoro.wav" ]] && res extras-kokoro-speaks "PASS (${secs}s)" \
    || res extras-kokoro-speaks "FAIL ($spoke $(tail -2 $T/py.err))"
heard=$(py '
from shani_chronoa import setup_wizard, stt_provision
setup_wizard.setup_ears("tiny-q5_1")
from shani_chronoa.stt import WhisperSTT
s = WhisperSTT(model="tiny", language="en"); s.use_server = False
print(s.transcribe("'"$T"'/kokoro.wav"))' 600)
hits=0; for w in meeting moved four afternoon; do grep -qi "$w" <<<"$heard" && hits=$((hits+1)); done
(( hits >= 3 )) && res extras-kokoro-heard-back "PASS ($hits/4 words: ${heard:0:60})" || res extras-kokoro-heard-back "FAIL ($hits/4: ${heard:0:80} $(tail -2 $T/py.err))"

# --- hindi -------------------------------------------------------------------
out=$(py 'from shani_chronoa import setup_wizard; print(setup_wizard.setup_languages(["hi"], listen=True))' 900)
grep -q "Added Hindi (reading and speaking)" <<<"$out" && res extras-hindi-step PASS || res extras-hindi-step "FAIL ($out $(tail -2 $T/py.err))"
langs=$(tesseract --list-langs --tessdata-dir "$D/tessdata" 2>&1 | tr '\n' ' ')
dflt=$(py 'from shani_chronoa.senses import ocr; print("+".join(ocr.default_languages()))')
[[ "$langs" == *hin* && "$langs" == *eng* && "$dflt" == eng+hin ]] && res extras-hindi-reads "PASS (tesseract: ${langs#*: } default $dflt)" \
    || res extras-hindi-reads "FAIL ($langs / $dflt)"
said=$(py '
import array, math, wave
from shani_chronoa.tts import PiperTTS
t = PiperTTS()
path, speaker = t._piper_voice_for("नमस्ते, आपका टाइमर पाँच मिनट के लिए लग गया है।")
ok = t.synthesize("नमस्ते, आपका टाइमर पाँच मिनट के लिए लग गया है।", "'"$T"'/hi.wav")
w = wave.open("'"$T"'/hi.wav"); frames = w.readframes(w.getnframes())
pcm = array.array("h", frames)
rms = int(math.sqrt(sum(s * s for s in pcm) / max(1, len(pcm))))
print(t.engine("नमस्ते"), ok, path.rsplit("/", 1)[-1], round(w.getnframes() / w.getframerate(), 1), rms)' 300)
read -r eng ok voice dur rms <<<"$said"
[[ "$eng" == piper && "$ok" == True && "$voice" == hi_IN-priyamvada-medium.onnx ]] && awk "BEGIN{exit !($dur > 1.5 && $rms > 300)}" \
    && res extras-hindi-speaks "PASS (Priyamvada, ${dur}s, rms $rms - the 2023 Piper binary runs the 2025 voice)" \
    || res extras-hindi-speaks "FAIL ($said $(tail -3 $T/py.err))"
lang=$(py 'from shani_chronoa.config import ChronoaConfig; print(ChronoaConfig().get("language"))')
[[ "$lang" == auto ]] && res extras-hindi-listens "PASS (whisper language: auto)" || res extras-hindi-listens "FAIL ($lang)"

# --- photos and videos (OpenCV) ----------------------------------------------
out=$(py 'from shani_chronoa import setup_wizard; print(setup_wizard.setup_photos())' 1200)
grep -q "can now find faces" <<<"$out" && res extras-photos-step PASS || res extras-photos-step "FAIL ($out $(tail -2 $T/py.err))"
if [[ -n "${APPLE:-}" ]]; then
    seen=$(py "from shani_chronoa.skills import photo_video; print(photo_video._run({'action': 'identify', 'path': '$APPLE'}))" 300)
    grep -qi "apple" <<<"$seen" && res extras-photos-identifies "PASS (${seen:0:80})" || res extras-photos-identifies "FAIL (${seen:0:120} $(tail -2 $T/py.err))"
fi
mkdir -p "$HOME/Pictures/Shops"
magick -size 900x300 xc:white -fill black -pointsize 64 -annotate +30+120 'HAMMER 450' -annotate +30+220 'NAILS 120' "$HOME/Pictures/Shops/scan-0042.png" 2>"$T/magick.err"
found=$(py '
from shani_chronoa import photo_library
from pathlib import Path
import os
photo_library.pictures_dir = lambda: Path(os.environ["HOME"]) / "Pictures"
r = photo_library.index()
hits = photo_library.search("hammer nails")
print(r["indexed"], hits[0]["path"].rsplit("/", 1)[-1] if hits else "-", (hits[0]["text"] if hits else "")[:40])' 300)
[[ "$found" == *scan-0042.png*HAMMER* ]] && res extras-photos-found-by-text "PASS ($found)" || res extras-photos-found-by-text "FAIL ($found $(tail -2 $T/py.err) $(cat $T/magick.err))"
up=$(py "
from shani_chronoa.skills import edit_image
print(edit_image._run({'path': '$HOME/Pictures/Shops/scan-0042.png', 'upscale': 2}))" 120)
upf=$(grep -oE "/[^ ]+\.png" <<<"$up" | tail -1)
dims=$(magick identify -format '%wx%h' "$upf" 2>/dev/null)
[[ "$dims" == 1800x600 ]] && res extras-edits-upscale "PASS (900x300 -> $dims)" || res extras-edits-upscale "FAIL ($up / $dims)"

# --- sounds -------------------------------------------------------------------
out=$(py 'from shani_chronoa import setup_wizard; print(setup_wizard.setup_sounds())' 900)
grep -q "tell what a sound is" <<<"$out" && res extras-sounds-step PASS || res extras-sounds-step "FAIL ($out $(tail -2 $T/py.err))"
cat_wav=$(ls "$D"/sounds/*/test_wavs/1.wav 2>/dev/null | head -1)
heard=$(py "from shani_chronoa import sounds; from pathlib import Path; print(sounds.describe(sounds.tag(Path('$cat_wav'))))" 120)
grep -qi "cat" <<<"$heard" && res extras-sounds-hears "PASS ($heard)" || res extras-sounds-hears "FAIL ($heard $(tail -2 $T/py.err))"

# --- speakers, subtitles, clean -----------------------------------------------
out=$(py 'from shani_chronoa import setup_wizard; print(setup_wizard.setup_speakers())' 900)
grep -q "who said what" <<<"$out" && res extras-speakers-step PASS || res extras-speakers-step "FAIL ($out $(tail -2 $T/py.err))"
mkdir -p "$HOME/Music"
curl -sfL --retry 3 -o "$HOME/Music/talk.wav" https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/2-two-speakers-en.wav
who=$(py "from shani_chronoa.skills import recording; print(recording._run({'action': 'speakers', 'path': '$HOME/Music/talk.wav', 'language': 'en'}))" 900)
n=$(grep -oE "Speaker [0-9]+" <<<"$who" | sort -u | wc -l)
(( n >= 2 )) && res extras-speakers-turns "PASS ($n speakers: $(sed -n 2p <<<"$who" | cut -c1-70))" || res extras-speakers-turns "FAIL (${who:0:160} $(tail -2 $T/py.err))"
sub=$(py "from shani_chronoa.skills import recording; print(recording._run({'action': 'subtitles', 'path': '$HOME/Music/talk.wav', 'language': 'en'}))" 900)
blocks=$(grep -c -- "-->" "$HOME/Music/talk.srt" 2>/dev/null || echo 0)
(( blocks >= 3 )) && res extras-subtitles "PASS ($blocks cues: $(sed -n 3p $HOME/Music/talk.srt | cut -c1-60))" || res extras-subtitles "FAIL ($sub)"
cl=$(py "from shani_chronoa.skills import recording; print(recording._run({'action': 'clean', 'path': '$HOME/Music/talk.wav'}))" 600)
rate=$(ffprobe -v error -show_entries stream=sample_rate -of csv=p=0 "$HOME/Music/talk-clean.wav" 2>/dev/null)
orig=$(ffprobe -v error -show_entries stream=sample_rate -of csv=p=0 "$HOME/Music/talk.wav" 2>/dev/null)
[[ -n "$rate" && "$rate" == "$orig" ]] && res extras-clean "PASS (sample rate kept: $rate)" || res extras-clean "FAIL ($cl / $rate vs $orig)"

# --- YouTube captions (yt-dlp from the image; the video itself is never downloaded) ----
if command -v yt-dlp >/dev/null; then
    yt=$(py "from shani_chronoa.skills import recording; print(recording._run({'action': 'text', 'path': 'https://www.youtube.com/watch?v=jNQXAC9IVRw'}))" 240)
    grep -qi "elephant" <<<"$yt" && res extras-youtube-captions "PASS (${yt:0:90})" || res extras-youtube-captions "FAIL (${yt:0:160})"
else
    res extras-youtube-captions "SKIP (yt-dlp is not on this image)"
fi

after=$(py 'from shani_chronoa import setup_wizard as w; s=w.state(); print(s["eyes"]["ready"], s["imagine"]["ready"], s["memory"]["ready"], s["languages"]["chosen"], s["voice"]["ready"])')
[[ "$after" == "True True True ['hi'] True" ]] && res extras-state-after "PASS (all set up)" || res extras-state-after "FAIL ($after)"
