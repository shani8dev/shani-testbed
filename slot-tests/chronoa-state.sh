#!/bin/bash
# slot-test-mode: boot
#
# chronoa-state — does Chronoa's state land somewhere that survives, on the
# immutable layout this image actually boots?
#
#   slot-test blue chronoa-state --local-src-chronoa=/opt/shani-chronoa
#
# ShaniOS is a read-only Btrfs root slot (@blue or @green) with selective
# persistence, so "it works on my machine" and "it works here" are different
# questions. From the image's own /etc/fstab:
#
#   /              read-only root slot          ← nothing may be written here
#   /etc           overlay, upper in /data      ← writable, survives a switch
#   /var           tmpfs (systemd.volatile)    ← gone on reboot
#   /home          @home subvolume             ← persists
#   /data          @data subvolume             ← persists
#   /var/cache     @cache subvolume            ← persists, SHARED between slots
#   /var/log       @log subvolume              ← persists
#
# That last one matters more than it looks: Chronoa's download cache defaults to
# /var/cache/shani-chronoa/models, and on this layout that is precisely the
# directory the fstab says exists "to avoid re-downloading packages after slot
# switches". So the default is right *by agreement with the image*, not by
# accident - and this test is what would notice if it were ever moved onto tmpfs.
#
# What it checks, per path:
#   - does it exist, and is it writable by this user
#   - which filesystem is it on: tmpfs (lost), the read-only root (cannot be
#     written at all), or a persistent subvolume (kept)
# and then asserts the three rules that follow from the layout:
#   1. nothing Chronoa writes may land on tmpfs
#   2. nothing may be written outside $HOME, /data, /etc, /var/cache or /var/log
#   3. the download cache must be on a persistent filesystem, because a model
#      fetched twice is 639 MB fetched twice
set -u
res() { printf 'RESULT %-46s %s\n' "$1" "$2"; }
T=$(mktemp -d /tmp/chronoa-state.XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" \
       XDG_STATE_HOME="$T/home/.local/state" XDG_CACHE_HOME="$T/home/.cache" \
       GSETTINGS_BACKEND=keyfile PYTHONDONTWRITEBYTECODE=1 \
       PYTHONPATH=/usr/lib/shani-chronoa
mkdir -p "$HOME"
command -v python3 >/dev/null || { res state-python "FAIL (no python3)"; exit 0; }

# --- what this root actually looks like, from the kernel not from a comment ---
root_fs=$(findmnt -n -o FSTYPE,TARGET / 2>/dev/null | head -1)
root_opts=$(findmnt -n -o OPTIONS / 2>/dev/null | head -1)
ro=""
case "$root_opts" in *ro,*) ro=" read-only";; esac
res state-root "${root_fs:-unknown}${ro}"
[[ -n "$ro" ]] && res state-root-is-read-only "PASS (a write to / must fail here)" \
                || res state-root-is-read-only "INFO (root is writable - not the immutable layout)"

for m in /etc /var /home /data /var/cache /var/log; do
    fstype=$(findmnt -n -o FSTYPE --target "$m" 2>/dev/null | tail -1)
    src=$(findmnt -n -o SOURCE --target "$m" 2>/dev/null | tail -1)
    res "state-mount-$m" "${fstype:-none} from ${src:-?}"
done

# --- where Chronoa's own state goes, and whether it survives ----------------
# `data_home()` etc. are read through a fresh interpreter with the slot's real
# XDG variables, not with this script's temporary ones, because the question is
# where it lands on a real machine.
out=$(env -u HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
      timeout 300 python3 - <<'PY' 2>&1
import os
from shani_chronoa import (conversation_store, files, learning, local_embed,
                           local_llm, local_vision, sherpa, voices)
from shani_chronoa.senses import store as stores

paths = {
    "models (llm)": local_llm.model_dir(),
    "whisper models": files.data_home() / "whisper" / "models",
    "piper voices": voices.voice_dir(),
    "kokoro": voices.kokoro_dir() if hasattr(voices, "kokoro_dir") else None,
    "sherpa-onnx": sherpa.install_dir(),
    "vision models": local_vision.model_dir(),
    "embed model": local_embed.model_dir(),
    "conversations": conversation_store.session_dir(),
    "tool log": files.data_home() / "shani-chronoa" / "logs",
    "learned models": learning.models_dir(),
    "senses store": stores.DURABLE_FILE,
    "download cache": __import__("shani_chronoa.stt_provision",
                                 fromlist=["x"]).cache_dir(),
}
for name, path in paths.items():
    if path is None:
        print(f"  {name}\t-\t-")
        continue
    try:
        path.mkdir(parents=True, exist_ok=True)
        writable = os.access(path, os.W_OK)
        print(f"  {name}\t{path}\t{'writable' if writable else 'NOT WRITABLE'}")
    except Exception as exc:
        print(f"  {name}\t{path}\tCANNOT CREATE ({type(exc).__name__}: {exc})")
PY
)
printf '%s\n' "$out" | sed 's/^/  | /'

# The verdict, and it runs **without this script's temporary HOME**.
#
# A first version exported HOME=$T/home (under /tmp) and then asked whether the
# paths were volatile - so it audited its own scratch directory and reported, in
# all seriousness, that Chronoa's models were "on tmpfs, so lost on reboot".
# Every one of those paths was where *this test* had put them. The question is
# where Chronoa puts them on a real machine, so the real environment is what has
# to be in effect: no HOME override, no XDG overrides.
# Declared in bash as well as in the python below. They were only declared in
# the python, so `${unknown}` was unbound on the first `[[ -n ]]` - and with
# `set -u` that aborted the script after the checks it was summarising.
unknown=""
bad=""
bad=$(env -u HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
     timeout 120 python3 - <<'PY'
import os
import subprocess
from shani_chronoa import (conversation_store, files, learning, local_embed,
                           local_llm, local_vision, sherpa, voices,
                           stt_provision)

paths = [local_llm.model_dir(), files.data_home() / "whisper" / "models",
         voices.voice_dir(), sherpa.install_dir(), local_vision.model_dir(),
         local_embed.model_dir(), conversation_store.session_dir(),
         learning.models_dir(), stt_provision.cache_dir()]
survives = ("btrfs", "ext4", "xfs", "f2fs")
# Only tmpfs is a *finding*. A filesystem outside this list is a fact this test
# does not recognise, and calling it a failure is how a slot test ends up red for
# its own ignorance - which it did on the first run: under nspawn the root is
# `overlay`, not `btrfs`, so every path under $HOME was reported as not
# surviving. Unknown is reported as unknown.
unknown=""
bad=""
for path in paths:
    if path is None:
        continue
    try:
        path.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        bad="${bad}${bad:+; }${path}: cannot create (${type(exc).__name__})"
        continue
    if not os.access(path, os.W_OK):
        bad="${bad}${bad:+; }${path}: not writable by this user"
        continue
    fs = subprocess.run(["findmnt", "-n", "-o", "FSTYPE", "--target", str(path)],
                        capture_output=True, text=True).stdout.strip().splitlines()
    fs = fs[-1] if fs else "?"
    if fs == "tmpfs":
        bad="${bad}${bad:+; }${path}: on tmpfs, lost on reboot"
    elif fs not in survives:
        unknown="${unknown}${unknown:+; }${path} is on ${fs}"
print("\n".join(bad))
PY
)
# A plain string, not an array: `set -u` plus `${#arr[@]}` on an empty array is
# "unbound variable" in bash before 4.4, and that aborted the script here twice -
# after the checks it was meant to summarise had already run.
[[ -n "$unknown" ]] && res state-filesystem-unrecognised \
    "INFO (not counted as failures): $unknown"
# The evidence goes *inside* the RESULT line, not beside it. A first version
# printed the offending paths on their own lines, and the harness summary showed
# `FAIL` with nothing after it - so the one line a person actually reads said
# nothing about what was wrong, which is the difference between a report and a
# verdict.
if [[ -z "$bad" ]]; then
    res state-paths-persist "PASS (every path is writable, and none is on volatile storage)"
else
    res state-paths-persist "FAIL: $(printf '%s' "$bad" | tr '\n' ';' | cut -c1-300)"
fi

# --- the download cache, specifically: it must not be tmpfs -----------------
cache=$(env -u HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
        timeout 120 python3 -c "
from shani_chronoa import stt_provision
print(stt_provision.cache_dir() or 'NONE')" 2>/dev/null | tail -1)
if [[ "$cache" == NONE || -z "$cache" ]]; then
    res state-download-cache "INFO (no shared cache here; every model is fetched into \$HOME)"
else
    cfs=$(findmnt -n -o FSTYPE --target "$cache" 2>/dev/null | tail -1)
    res state-download-cache "${cache} on ${cfs:-unknown}"
    [[ "$cfs" == tmpfs ]] \
        && res state-download-cache-survives "FAIL (a model fetched again after every reboot)" \
        || res state-download-cache-survives "PASS (a 639 MB model is fetched once per machine, not once per reboot)"
fi

# --- and prove it: write through every path, read it back -------------------
rt=$(env -u HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
     timeout 180 python3 - <<'PY'
import os
from shani_chronoa import conversation_store, files, learning, local_llm, sherpa, voices

failures = []
for name, path in (("llm", local_llm.model_dir()),
                   ("voice", voices.voice_dir()),
                   ("sherpa", sherpa.install_dir()),
                   ("conversations", conversation_store.session_dir()),
                   ("learned", learning.models_dir()),
                   ("logs", files.data_home() / "shani-chronoa" / "logs")):
    try:
        path.mkdir(parents=True, exist_ok=True)
        probe = path / ".chronoa-write-probe"
        probe.write_text("x", encoding="utf-8")
        read_back = probe.read_text(encoding="utf-8")
        probe.unlink()
        if read_back != "x":
            failures.append(f"{name}: wrote but read back {read_back!r}")
    except Exception as exc:
        failures.append(f"{name}: {type(exc).__name__}: {exc}")
print("\n".join(failures))
PY
)
[[ -z "$rt" ]] && res state-write-round-trip "PASS (wrote and read back through every path)" \
                || res state-write-round-trip "FAIL: $(printf '%s' "$rt" | tr '\n' ';' | cut -c1-300)"
exit 0