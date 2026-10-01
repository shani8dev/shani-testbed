#!/bin/bash
# A check of the harness itself: slot-tests/chronoa-speech.sh — run against a
# STUBBED slot, to prove its assertions can actually fail.
#
# WHY THIS FILE EXISTS, and why "it passes" is not the point. A slot-test that
# cannot fail is not a test, it is decoration: it prints PASS on every image,
# on a broken image, and on an image with no Python in it. This repo's own
# AGENTS.md says it plainly — "a negative control that cannot fail is not a
# control" — and chronoa's says the same about a regression suite it built,
# measured and then deleted because every assertion in it passed whether or not
# the renderer worked. So every assertion in chronoa-speech.sh that this file
# can reach is run against a deliberately broken environment here, and required
# to go RED:
#
#   1. an espeak-ng stub that writes only a 44-byte RIFF header and no samples
#      makes tts-produces-real-audio FAIL — the headline assertion is the one
#      that must not be able to accept a stub that "succeeded";
#   2. a piper-tts stub plus a Piper voice makes tts-engine-is-not-extra-piper
#      FAIL — the deliberate control against provisioning TTS from extra/piper,
#      the GTK gaming-mouse configurator that shares the name;
#   3. a whisper-cli stub plus a real ggml-*.bin makes the DERIVED skip flip to
#      PASS by itself, with no edit to the slot-test — this is the whole reason
#      that check is derived rather than hardcoded, so it is the assertion that
#      most needs proving;
#   4. a whisper-cli stub plus a model also makes stt-no-ggml-model-on-this-
#      install FAIL, i.e. the "PASS about the state" line reports the state
#      changing instead of going quietly stale;
#   5. a gsettings stub with one voice key missing makes
#      schema-declares-voice-keys FAIL;
#   6. a launcher carrying the historical dirname(dirname(__file__)) path bug
#      makes launcher-imports-shipped-package FAIL, and the same launcher with
#      'lib/shani-chronoa' joined on makes it PASS — the one assertion guarding
#      the bug that shipped for the whole life of the project because every
#      earlier test bypassed the launcher;
#   7. a pacman database with no desc makes Group A fall through to `pacq -Qi`
#      and still assert, so that fallback is not untested code;
#   8. with NO speech binary at all there is still at least one PASS, and the
#      STT line is a SKIP — never PASS, never FAIL. This is the harness's own
#      failure rule: a file that emits only SKIPs is reported FAILED
#      (lib/boot.sh cmd_slot_test: `rc != 0 || fail > 0 || pass == 0`), so a
#      slot with no TTS must not be able to report the file as failed;
#   9. every emitted line matches `RESULT <name> (PASS|FAIL|SKIP)` exactly, or
#      the three literal greps in cmd_slot_test silently count nothing;
#  10. each stub really mutated the state it targets — a stub nobody can prove
#      was called is a control that proves nothing, so the invocation log is
#      asserted, not assumed;
#  11. `bash -n` is clean on the slot-test.
#
# WHAT IS STUBBED AND WHY IT IS FAITHFUL ENOUGH. `pacq` is a function
# _pacdb.sh defines over `pacman --dbpath "$PACDB"`, so the PATH stub is
# `pacman` and `pacq` becomes the fake; that is the real seam, not a
# convenient one. Everything else — espeak-ng, piper-tts, whisper-cli, soxi,
# gsettings — is the binary the shipped code actually shells out to, so the
# real PiperTTS and the real WhisperSTT run against them with their real argv
# (`espeak-ng --stdin -v en-us -w <out>`, and
# `whisper-cli -m <model> -f <wav> -l en -otxt -np`). The Python package under
# test is NOT a stub: PYTHONPATH points at the real checkout, so these runs
# execute the actual shani_chronoa.tts / shani_chronoa.stt / files.py.
#
# Runs on the host or in the builder container; needs bash, python3 and the real
# ../shani-chronoa checkout beside this repo. Skips, loudly, otherwise — because
# a silently-skipped self-test reads as a passing one.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
SLOT_TEST="$ROOT/slot-tests/chronoa-speech.sh"
# The real package the slot-test will import. Not a fixture: a stubbed
# shani_chronoa.tts would prove that a stub passes, which is the one thing this
# file exists to rule out.
CHRONOA_LIB="$ROOT/../shani-chronoa/usr/lib/shani-chronoa"

pass_n=0 fail_n=0
ok() { printf 'ok   %s\n' "$1"; pass_n=$((pass_n+1)); }
no() { printf 'FAIL %s -- %s\n' "$1" "$2"; fail_n=$((fail_n+1)); }

TMP=$(mktemp -d /tmp/chronoa-speech-selftest.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 is not available here"; exit 0; }
[[ -f "$SLOT_TEST" ]] || {
  echo "SKIP: no slot-test at $SLOT_TEST"; exit 0; }
if [[ ! -f "$CHRONOA_LIB/shani_chronoa/tts.py" ]]; then
  echo "SKIP: no Chronoa checkout beside this repo (looked for $CHRONOA_LIB/shani_chronoa/tts.py)."
  echo "      This self-test executes the real shani_chronoa.tts / .stt against stubbed binaries;"
  echo "      with the package stubbed out it would prove that a stub passes."
  exit 0
fi
CHRONOA_LIB="$(cd "$CHRONOA_LIB" && pwd)"

# --- the executables the slot-test and the stubs reach for -------------------
# A PATH of only the stub dir would remove head/tr/stat/awk along with
# espeak-ng, and scenario 8 below needs espeak-ng GONE while everything else
# still works — so each scenario gets a bin dir of symlinks to the real tools
# plus whatever stubs that scenario wants. Removing a binary from a scenario is
# then the absence of a symlink, which is exact.
TOOLS="bash python3 grep sed tr head stat ls awk mktemp rm timeout cat"
declare -A TOOLPATH=()
for t in $TOOLS; do
  p=$(command -v "$t" 2>/dev/null || true)
  [[ -n "$p" ]] && TOOLPATH[$t]="$p"
done
missing_tool=""
for t in $TOOLS; do
  [[ -n "${TOOLPATH[$t]:-}" ]] || missing_tool+=" $t"
done
if [[ -n "$missing_tool" ]]; then
  echo "SKIP: this host is missing the tools the slot-test needs:${missing_tool}"
  exit 0
fi

# --- a real .PKGINFO for the real pacman local-db layout ---------------------
# Read through slot-tests/_pacdb.sh's own seam ($PACDB/local/<pkg>-<ver>/desc),
# so Group A's primary path — the one the task's mechanism specifies — is what
# runs here, not only the `pacq -Qi` fallback.
#
# Two shapes on purpose, because pacman really writes two and the slot-test has
# to read both: the LOCAL database entry uses %DEPENDS% sections of bare lines,
# while the .PKGINFO inside a package archive (and anything built from one) uses
# `depend = <spec>`. A slot-test that read only the second would look correct
# here and find nothing in a real slot.
mk_pacdb() {  # <dir> <desc|pkginfo|nodesc>
  local d="$1" with="${2:-desc}"
  mkdir -p "$d/local/shani-chronoa-0.1.0-14"
  case "$with" in
    nodesc|nopkg) rmdir "$d/local/shani-chronoa-0.1.0-14"; return 0 ;;
    desc) cat > "$d/local/shani-chronoa-0.1.0-14/desc" <<'EOF'
%FILENAME%
shani-chronoa-0.1.0-14-any.pkg.tar.zst

%NAME%
shani-chronoa

%VERSION%
0.1.0-14

%DESC%
Chronoa - the Shanios voice and text assistant (local-first)

%CSIZE%
1234567

%ISIZE%
1258291

%DEPENDS%
python
python-gobject
gtk4
libadwaita
espeak-ng
tesseract>=5.5.0

%OPTDEPENDS%
ollama: run the language model on this computer
whisper-cpp: voice input (speech recognition)
rhvoice-voice-slt: an English RHVoice voice
EOF
    ;;
    pkginfo) cat > "$d/local/shani-chronoa-0.1.0-14/desc" <<'EOF'
pkgname = shani-chronoa
pkgbase = shani-chronoa
pkgver = 0.1.0-14
pkgdesc = Chronoa - the Shanios voice and text assistant (local-first)
url = https://github.com/shani8dev/shani-chronoa
builddate = 1700000000
packager = Unknown Builder <nobody@nowhere>
size = 1234567
arch = any
license = GPL-3.0-only
depend = python
depend = python-gobject
depend = gtk4
depend = libadwaita
depend = espeak-ng
depend = tesseract>=5.5.0
optdepend = ollama: run the language model on this computer
optdepend = whisper-cpp: voice input (speech recognition)
optdepend = rhvoice-voice-slt: an English RHVoice voice
EOF
    ;;
  esac
}

# Every hard dep above is also reported installed, so Group A is predicted green
# and its assertion is genuinely exercised rather than skipped for free.
INSTALLED_ALL=""
for p in python python-gobject gtk4 libadwaita espeak-ng tesseract libnotify \
         pipewire wireplumber libsecret upower bubblewrap; do
  INSTALLED_ALL+="$p"$'\n'
done

# --- stubs -------------------------------------------------------------------
# Every stub appends to $STUB_LOG when it runs. Scenario 10 asserts the log, so
# a stub that is never reached shows up as a failing self-test rather than as a
# passing check whose premise silently vanished.
STUB_LOG="$TMP/stub-invocations.log"
: > "$STUB_LOG"

# espeak-ng's real argv is `--stdin -v en-us -w <out>`; the text arrives on
# stdin. `header-only` is the deliberate breakage: it exits 0 and writes a WAV
# file, so synthesize()'s own return value is decided purely by its >44 byte
# check — exactly the shape of a silently-useless speech stack.
write_espeak_stub() {  # <path> <good|header-only>
  cat > "$1" <<'STUB'
#!/bin/bash
printf 'espeak-ng %s\n' "$*" >> "$STUB_LOG"
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-w" ]] && out="$a"; prev="$a"; done
cat >/dev/null                       # the text arrives on stdin
[[ -n "$out" ]] || exit 1
if [[ "${STUB_WAV_MODE:-good}" == header-only ]]; then
  printf 'RIFF\xC4\x0F\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x22\x56\x00\x00\x44\xac\x00\x00\x02\x00\x10\x00data\x00\x00\x00\x00' > "$out"
  exit 0
fi
{ printf 'RIFF\xC4\x0F\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x22\x56\x00\x00\x44\xac\x00\x00\x02\x00\x10\x00data\xa0\x0f\x00\x00'
  head -c 4000 /dev/zero | tr '\000' '\200'; } > "$out"
STUB
  chmod 755 "$1"
}

# Piper's real argv is `<piper-tts> --model <voice> --output_file <out>`.
write_piper_stub() {
  cat > "$1" <<'STUB'
#!/bin/bash
printf 'piper-tts %s\n' "$*" >> "$STUB_LOG"
out=""; prev=""
for a in "$@"; do [[ "$prev" == "--output_file" ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] || exit 1
{ printf 'RIFF\xC4\x0F\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x22\x56\x00\x00\x44\xac\x00\x00\x02\x00\x10\x00data\xa0\x0f\x00\x00'
  head -c 4000 /dev/zero | tr '\000' '\200'; } > "$out"
STUB
  chmod 755 "$1"
}

# whisper-cpp's real argv is `whisper-cli -m <model> -f <wav> -l <lang> -otxt -np`
# and stt.py then reads the sibling `<wav>.txt`. This stub writes that file, so
# the transcription is non-empty for a reason and not by accident.
write_whisper_stub() {
  cat > "$1" <<'STUB'
#!/bin/bash
printf 'whisper-cli %s\n' "$*" >> "$STUB_LOG"
inp=""; model=""; prev=""
for a in "$@"; do
  case "$prev" in -m) model="$a";; -f) inp="$a";; esac
  prev="$a"
done
[[ -f "${model:-/nonexistent}" ]] || { echo "whisper-cli: model not found: $model" >&2; exit 2; }
[[ -f "${inp:-/nonexistent}" ]]   || { echo "whisper-cli: no input file" >&2; exit 1; }
printf '%s\n' "${STUB_WHISPER_TEXT:-Shanios speech stack check}" > "${inp%.*}.txt"
STUB
  chmod 755 "$1"
}

# soxi -D <file>: duration = (size - 44 header) / (22050 Hz * 2 bytes). A
# header-only WAV therefore reports 0, which is the second, independent reason
# the broken-espeak control fails.
write_soxi_stub() {
  cat > "$1" <<'STUB'
#!/bin/bash
printf 'soxi %s\n' "$*" >> "$STUB_LOG"
[[ "$1" == "-D" ]] || exit 1
sz=$(stat -c %s "$2" 2>/dev/null || echo 0)
awk -v s="$sz" 'BEGIN{printf "%.5f\n", (s-44)/44100}'
STUB
  chmod 755 "$1"
}

# `pacq` is a function over `pacman --dbpath`, so this IS the fake pacq. The
# args it has to understand are exactly the ones the slot-test passes:
# -Qq (installed names), -Q (version), -Qi (depends + optional depends),
# -Qql/-Ql (the package's files, which is how the slot-test finds the install
# path instead of guessing one).
write_pacman_stub() {
  cat > "$1" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >> "$STUB_LOG"
args=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dbpath) shift 2;;
    *) args="$args $1"; shift;;
  esac
done
args="${args# }"
case "$args" in
  "-Qq") cat "${STUB_INSTALLED:-/dev/null}"; exit 0 ;;
  "-Q shani-chronoa")
    # STUB_NO_PKG models a slot where the package is genuinely not installed --
    # a --local-src-chronoa overlay, or a --local-pkg tarball extracted without
    # its .install scriptlet. pacman really does exit non-zero here.
    [[ -n "${STUB_NO_PKG:-}" ]] && exit 1
    echo "shani-chronoa 0.1.0-14"; exit 0 ;;
  "-Qi shani-chronoa")
    [[ -n "${STUB_NO_PKG:-}" ]] && exit 1
    cat <<'INFO'
Name            : shani-chronoa
Version         : 0.1.0-14
Description     : Chronoa - the Shanios voice and text assistant (local-first)
Architecture    : any
Depends On      : python  python-gobject  gtk4  libadwaita  espeak-ng  tesseract>=5.5.0
Optional Deps   : ollama: run the language model on this computer
                  whisper-cpp: voice input (speech recognition)
                  rhvoice-voice-slt: an English RHVoice voice
Required By     : None
Installed Size  : 1.20 MiB
Validated By    : None
INFO
  exit 0 ;;
  "-Qql shani-chronoa"|"-Ql shani-chronoa")
    echo "${STUB_CHRONOA_LIB:-/nonexistent}/shani_chronoa/__init__.py"
    echo "${STUB_CHRONOA_LIB:-/nonexistent}/shani_chronoa/app.py"
    echo "${STUB_CHRONOA_LIB:-/nonexistent}/shani_chronoa/tts.py"
    echo "${STUB_CHRONOA_LIB:-/nonexistent}/shani_chronoa/stt.py"
    echo "/usr/bin/shani-chronoa"
    exit 0 ;;
esac
exit 1
STUB
  chmod 755 "$1"
}

# gsettings list-keys org.shani.chronoa. $STUB_KEYS carries the key list, so a
# scenario can drop exactly one voice key and watch the assertion notice. One key
# per line, because that is what the real gsettings prints and the slot-test
# matches with `grep -qx`.
write_gsettings_stub() {
  cat > "$1" <<'STUB'
#!/bin/bash
printf 'gsettings %s\n' "$*" >> "$STUB_LOG"
[[ "$1" == list-keys ]] || exit 0
for k in $STUB_KEYS; do printf '%s\n' "$k"; done
STUB
  chmod 755 "$1"
}

REAL_KEYS="whisper-model piper-voice language wake-word-enabled wake-word-model privacy-mode barge-in-vad-enabled audio-sense-enabled hearing-sense-enabled ocr-sense-enabled"

# --- _pacdb.sh stand-in ------------------------------------------------------
# The real one sets PACDB from whatever it can mount, which is a slot-only
# concern; here it is a directory this file owns. Everything else — the pacq()
# function definition and _pacdb_cleanup, which the slot-test's trap calls — is
# the real shape, because the slot-test is expected to survive on those.
STUB_PACDB_SH="$TMP/_pacdb.stub.sh"
# Written per scenario, not once here: PACDB is the scenario's own directory and
# the heredoc is quoted, so the substitution happens when the scenario runs.
mk_pacdb_sh() {  # <pacdb-dir>
  cat > "$STUB_PACDB_SH" <<EOF
#!/bin/bash
# Self-test stand-in for slot-tests/_pacdb.sh. Same two definitions; the mount
# probe is the only thing dropped, because a host has no slot subvolume to
# mount and no business trying.
PACDB="$1"
pacq() { pacman --dbpath "\$PACDB" "\$@"; }
_pacdb_cleanup() { printf 'pacdb-cleanup\n' >> "\$STUB_LOG"; }
EOF
}

# --- run one scenario --------------------------------------------------------
# scenario <name> <espeak: good|header|none> <extras: none|whisper|piper>
#          <gsettings-keys> <launcher: ok|bad|none> <desc-shape: desc|pkginfo>
# The espeak stub and the extras are separate arguments because a Piper control
# still needs a WORKING espeak-ng underneath it — that is what makes it a control
# about which engine is chosen rather than about whether audio happens.
# Prints nothing; the scenario's output lands in $TMP/<name>/out so the
# assertions below can read it. Returns non-zero only if the slot-test itself
# could not be run at all.
scenario() {
  local name="$1" espeak="$2" extras="$3" keys="$4" launcher="$5" shape="${6:-desc}"
  local sd="$TMP/$name"
  mk_pacdb_sh "$sd/pacdb"
  rm -rf "$sd"; mkdir -p "$sd/bin" "$sd/home" "$sd/xdg" "$sd/pacdb"
  for t in "${!TOOLPATH[@]}"; do ln -sf "${TOOLPATH[$t]}" "$sd/bin/$t"; done
  write_pacman_stub "$sd/bin/pacman"
  write_gsettings_stub "$sd/bin/gsettings"
  write_soxi_stub "$sd/bin/soxi"
  case "$espeak" in
    good|header) write_espeak_stub "$sd/bin/espeak-ng" ;;
    none)        : ;;
  esac
  case "$extras" in
    whisper) write_whisper_stub "$sd/bin/whisper-cli"
             mkdir -p "$sd/xdg/whisper/models"
             : > "$sd/xdg/whisper/models/ggml-base.bin" ;;
    piper)   write_piper_stub "$sd/bin/piper-tts"
             mkdir -p "$sd/xdg/piper/voices"
             : > "$sd/xdg/piper/voices/en_US-lessac-medium.onnx" ;;
    none)    : ;;
  esac

  # The launcher scenarios need a launcher at the path the slot-test uses, which
  # is /usr/bin/shani-chronoa in a slot. On the host that path does not exist and
  # creating it would be reaching outside this repo, so the scenario substitutes
  # the path in a COPY of the slot-test and the substitution is asserted below.
  local launcher_arg="LAUNCHER=/usr/bin/shani-chronoa"
  if [[ "$launcher" != none ]]; then
    mkdir -p "$sd/fakeslot/usr/bin" "$sd/fakeslot/usr/lib/shani-chronoa"
    ln -sfn "$CHRONOA_LIB/shani_chronoa" "$sd/fakeslot/usr/lib/shani-chronoa/shani_chronoa"
    if [[ "$launcher" == bad ]]; then
      # The historical bug, exactly as it shipped: dirname(dirname(__file__)) for
      # a script at usr/bin/ is usr/, and the package lives at
      # usr/lib/shani-chronoa/shani_chronoa/ — so inserting usr/ onto sys.path
      # can never import shani_chronoa. It survived the whole life of the
      # project because every earlier verification pass ran the code from inside
      # usr/lib/shani-chronoa with sys.path.insert(0, '.') and never executed
      # this script. Note the broken and fixed launchers differ by ONE string,
      # which is the point: the check has to discriminate that string.
      cat > "$sd/fakeslot/usr/bin/shani-chronoa" <<'STUB'
#!/usr/bin/env python3
"""Shani Chronoa - self-test launcher carrying the historical path bug."""
import sys
import os

_USR_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _USR_DIR)

from shani_chronoa.app import main

if __name__ == "__main__":
    main()
STUB
    else
      cat > "$sd/fakeslot/usr/bin/shani-chronoa" <<'STUB'
#!/usr/bin/env python3
"""Shani Chronoa - self-test launcher with the fixed path computation."""
import sys
import os

_USR_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_USR_DIR, "lib", "shani-chronoa"))

from shani_chronoa.app import main

if __name__ == "__main__":
    main()
STUB
    fi
    chmod 755 "$sd/fakeslot/usr/bin/shani-chronoa"
    launcher_arg="LAUNCHER=$sd/fakeslot/usr/bin/shani-chronoa"
  fi

  # The slot-test's only slot-specific dependency is the absolute _pacdb.sh
  # path. Rewrite it to this scenario's stand-in, and require the rewrite to
  # have applied: a substitution that silently matched nothing would leave the
  # test sourcing a path that does not exist, which under `set -u` still runs
  # and simply has no pacq().
  # XDG_DATA_HOME is substituted for the same reason as the launcher path: the
  # slot-test deliberately redirects it into its own work dir (that redirection
  # is what stt-model-path-follows-xdg-data-home asserts), so a fixture model or
  # Piper voice dropped anywhere else is invisible to it.
  sed -e "s|^source /mnt/testbed/slot-tests/_pacdb.sh\$|source $STUB_PACDB_SH|" \
      -e "s|^LAUNCHER=/usr/bin/shani-chronoa\$|$launcher_arg|" \
      -e "s|^export XDG_DATA_HOME=.*\$|export XDG_DATA_HOME=\"$sd/xdg\"|" \
      "$SLOT_TEST" > "$sd/chronoa-speech.sh"
  # Negative control for the scheduler poll check: strip the in-process consent
  # grant and require that the check then FAILS. The scenario runs under `env -i`,
  # so the grant cannot arrive from outside — the only way it was ever open is the
  # line being removed right here. A control that cannot fail is not a control, and
  # this is the one that proves senses-a-poll-really-runs is not a rubber stamp: it
  # demands a DEPOSITED PERCEPT, so with consent withheld the real consent gate
  # refuses and the check must report bad.
  if [[ "${7:-}" == "no-grant" ]]; then
    grep -c 'SHANI_CHRONOA_CONSENT_GRANT=filesystems-sense-enabled' "$sd/chronoa-speech.sh" > "$sd/grant-lines-before"
    sed -i 's|^\(SHANI_CHRONOA_CONSENT_GRANT=filesystems-sense-enabled \\$\)|#\1|; s|^\( *\)os\.environ\["SHANI_CHRONOA_CONSENT_GRANT"\] = "filesystems-sense-enabled"|\1pass|' "$sd/chronoa-speech.sh"
    grep -c 'os.environ\["SHANI_CHRONOA_CONSENT_GRANT"\] = "filesystems-sense-enabled"' "$sd/chronoa-speech.sh" > "$sd/grant-lines-after"
    local before after
    before=$(cat "$sd/grant-lines-before"); after=$(cat "$sd/grant-lines-after")
    if [[ "$after" == "$before" && "$before" != "0" ]]; then
      printf 'scenario %s: the consent-grant control mutated nothing (still %s grant lines)\n' "$name" "$after"
      return 1
    fi
  fi
  local subs
  subs=$(grep -c -e "^source $STUB_PACDB_SH\$" "$sd/chronoa-speech.sh")
  [[ "$subs" == 1 ]] || { printf 'scenario %s: the _pacdb.sh substitution applied %s times\n' "$name" "$subs"; return 1; }
  grep -q '^source /mnt/testbed/slot-tests/_pacdb.sh$' "$sd/chronoa-speech.sh" && \
    { printf 'scenario %s: the original source line survived the substitution\n' "$name"; return 1; }
  if [[ "$launcher" != none ]]; then
    subs=$(grep -c -e "^LAUNCHER=$sd/fakeslot" "$sd/chronoa-speech.sh")
    [[ "$subs" == 1 ]] || { printf 'scenario %s: the LAUNCHER substitution applied %s times\n' "$name" "$subs"; return 1; }
  fi
  subs=$(grep -c -e "^export XDG_DATA_HOME=\"$sd/xdg\"$" "$sd/chronoa-speech.sh")
  [[ "$subs" == 1 ]] || { printf 'scenario %s: the XDG_DATA_HOME substitution applied %s times\n' "$name" "$subs"; return 1; }

  mk_pacdb "$sd/pacdb" "$shape"
  printf '%s' "$INSTALLED_ALL" > "$sd/installed"
  : > "$STUB_LOG"
  env -i \
    PATH="$sd/bin" \
    HOME="$sd/home" \
    STUB_LOG="$STUB_LOG" \
    STUB_PACDB="$sd/pacdb" \
    STUB_CHRONOA_LIB="$CHRONOA_LIB" \
    STUB_INSTALLED="$sd/installed" \
    STUB_KEYS="$keys" \
    STUB_WAV_MODE="$( [[ "$espeak" == header ]] && echo header-only || echo good )" \
    STUB_WHISPER_TEXT="Shanios speech stack check" \
    bash "$sd/chronoa-speech.sh" > "$sd/out" 2>&1
  printf '%s' "$?" > "$sd/rc"
  cp "$STUB_LOG" "$sd/stub-invocations.log"
  return 0
}

# Re-run an existing scenario with its pacman database rebuilt to a different
# shape, for the checks that need the same stubs but a different metadata layout.
respawn_db() {  # <scenario> <desc-shape>
  local sd="$TMP/$1"
  rm -rf "$sd/pacdb"; mkdir -p "$sd/pacdb"; mk_pacdb "$sd/pacdb" "$2"
  env -i PATH="$sd/bin" HOME="$sd/home" \
    STUB_LOG="$STUB_LOG" STUB_PACDB="$sd/pacdb" \
    STUB_CHRONOA_LIB="$CHRONOA_LIB" STUB_INSTALLED="$sd/installed" \
    STUB_KEYS="$REAL_KEYS" STUB_WAV_MODE=good STUB_NO_PKG="${STUB_NO_PKG:-}" \
    bash "$sd/chronoa-speech.sh" > "$sd/out" 2>&1
  printf '%s' "$?" > "$sd/rc"
  cp "$STUB_LOG" "$sd/stub-invocations.log"
}

verdict() {  # <scenario> <result-name>
  awk -v n="$2" '$1=="RESULT" && $2==n {print $3; exit}' "$TMP/$1/out"
}
reason() {   # <scenario> <result-name>
  awk -v n="$2" '$1=="RESULT" && $2==n {for(i=4;i<=NF;i++) printf "%s ", $i; exit}' "$TMP/$1/out"
}
count_verdict() { grep -cE "^RESULT [^[:space:]]+[[:space:]]+$2" "$TMP/$1/out"; }

want() {  # <scenario> <result-name> <expected> <what>
  local got; got=$(verdict "$1" "$2")
  if [[ "$got" == "$3" ]]; then
    ok "$4"
  else
    no "$4" "$2 is '${got:-absent}', expected $3. Reason given: $(reason "$1" "$2")"
  fi
}

# --- 1. the every-line check, applied to every scenario below ----------------
# One shape for cmd_slot_test's three literal greps: `RESULT ` at column 0, a
# whitespace-free name, then the verdict. A line that drifts off that shape is
# silently uncounted, so a broken test can look like a passing one.
check_shape() {
  local s="$1" total strict
  total=$(grep -c '^RESULT' "$TMP/$s/out")
  strict=$(grep -cE '^RESULT [^[:space:]]+[[:space:]]+(PASS|FAIL|SKIP)([[:space:]]|$)' "$TMP/$s/out")
  if [[ "$total" == 0 ]]; then
    no "[$s] every RESULT line is well shaped" "the scenario emitted no RESULT line at all: $(head -3 "$TMP/$s/out" | tr '\n' ' ')"
  elif [[ "$total" != "$strict" ]]; then
    no "[$s] every RESULT line is well shaped" "$((total-strict)) of $total lines are not \`RESULT <name> (PASS|FAIL|SKIP)\`: $(grep '^RESULT' "$TMP/$s/out" | grep -vE '^RESULT [^[:space:]]+[[:space:]]+(PASS|FAIL|SKIP)([[:space:]]|$)' | head -3 | tr '\n' ' ')"
  else
    ok "[$s] all ${total} RESULT lines are \`RESULT <name> (PASS|FAIL|SKIP)\`"
  fi
}

# --- 2. the base scenario: espeak-ng works, whisper-cpp does not exist -------
# This is what a real Shanios image looks like (20260925 gnome: espeak-ng and
# shani-chronoa present, whisper-cpp/piper-tts/rhvoice/ollama absent, no
# ggml-*.bin anywhere), so it is the scenario where the real assertions have to
# be genuinely satisfied.
scenario base good none "$REAL_KEYS" none desc || no "scenario base runs" "the slot-test could not be prepared"
check_shape base
want base chronoa-package-installed                PASS "the installed package's own .PKGINFO gave the version (not a literal)"
want base chronoa-hard-deps-installed              PASS "every hard dep derived from .PKGINFO resolves (tesseract>=5.5.0 stripped to tesseract)"
want base tts-engine-resolves                      PASS "engine() resolved to a real engine"
[[ "$(verdict base tts-engine-resolves)" == PASS ]] && \
  grep -q 'engine() = espeak-ng' "$TMP/base/out" \
  && ok "the resolved engine is reported, and it is espeak-ng" \
  || no "the resolved engine is reported" "got: $(reason base tts-engine-resolves)"
want base tts-engine-is-not-extra-piper            PASS "no piper-tts and engine() is not piper"
want base tts-produces-real-audio                  PASS "real audio: RIFF + samples + non-zero duration"
want base tts-synthesize-failure-is-not-fatal      PASS "an unwritable path returns False instead of raising"
want base stt-reports-unavailable-not-broken       PASS "STT reports itself unavailable, and the warning branch is reachable"
want base stt-model-path-follows-xdg-data-home     PASS "model_path follows XDG_DATA_HOME (the overlay-liveness proof)"
want base stt-no-ggml-model-on-this-install        PASS "no ggml-*.bin in either model dir — recorded as a fact about the state"
want base stt-transcribes-speech                   SKIP "no whisper binary: the derived SKIP, naming the missing thing"
want base schema-declares-voice-keys               PASS "the RUNNING compiled schema carries the speech/perception keys"
want base whisper-cpp-is-optional-not-required     PASS "whisper-cpp is an optdepend and not a hard depend"
want base snap-is-not-a-shanios-path               PASS "no whisper-cli in the slot and no /snap reference in the installed package"

# The three clauses that decide whether the whole FILE passed (lib/boot.sh
# cmd_slot_test: `rc != 0 || fail > 0 || pass == 0`).
#
# Two lines cannot pass on a HOST and are asserted as the exact failure set
# rather than waved through, because a real slot has both: `app-imports-clean`
# needs the slot's PyGObject (this box has no `gi`), and
# `launcher-imports-shipped-package` needs the INSTALLED /usr/bin/shani-chronoa,
# which on this host would mean writing outside the repo. Pinning the failure
# set is a stronger assertion than demanding zero failures: it says these two,
# and no others, are the lines that require a real install.
# The scheduler pair joins them for the same reason: `senses-scheduler-constructed`
# needs the host to be able to construct a real ChronoaApplication, and
# `senses-a-poll-really-runs` needs that application's store and a real
# /proc/mounts read. Neither is satisfiable here, and both ARE asserted in a real
# slot run - which is the only place they mean anything.
HOST_ONLY="app-imports-clean launcher-imports-shipped-package senses-a-poll-really-runs senses-scheduler-constructed"
base_fails=$(awk '$1=="RESULT" && $3=="FAIL" {print $2}' "$TMP/base/out" | sort | tr '\n' ' ')
base_fails="${base_fails% }"
if [[ "$(cat "$TMP/base/rc")" == 0 ]] && [[ "$(count_verdict base PASS)" -gt 0 ]] \
   && [[ "$(count_verdict base SKIP)" -ge 1 ]] && [[ "$base_fails" == "$HOST_ONLY" ]]; then
  ok "cmd_slot_test's rule: rc=0, $(count_verdict base PASS) pass, $(count_verdict base SKIP) skip, and the only FAILs are the two a host cannot satisfy (${base_fails})"
else
  no "cmd_slot_test's rule sees a healthy file" \
     "rc=$(cat "$TMP/base/rc") pass=$(count_verdict base PASS) skip=$(count_verdict base SKIP) fail=[${base_fails}], expected exactly [${HOST_ONLY}]"
fi

# --- 2b. THE CONTROL FOR senses-a-poll-really-runs ----------------------------
# This check is the only thing in the file that can prove the 44 senses actually
# POLL rather than merely being constructible, so it is exactly the kind of check
# that can rot into a rubber stamp. Its whole value is that it demands a
# DEPOSITED PERCEPT: `sense_allowed` gates every sense behind
# `<name>-sense-enabled`, which defaults false for every sense except memory, so
# an ungranted poll is refused and deposits nothing.
#
# Therefore: strip the in-process consent grant and REQUIRE THE CHECK TO FAIL.
# If it still passed here, it would be passing without a percept and the whole
# scheduler group above would be decoration. The scenario runs under `env -i`, so
# the grant cannot leak in from the caller's environment — the only way it was
# ever open is the line the control removes.
scenario no-grant good none "$REAL_KEYS" none desc no-grant \
  || no "scenario no-grant runs" "the slot-test could not be prepared"
check_shape no-grant
want no-grant senses-a-poll-really-runs FAIL "with consent withheld, the poll check FAILs rather than accepting a refusal as a pass (the control)"

# --- 3. THE HEADLINE CONTROL: an espeak-ng that writes only a header ---------
# A stub that exits 0 and writes a 44-byte RIFF file with no samples behind it.
# synthesize() returns False on it (its own `getsize > 44` check), so both the
# return value and the byte-level checks have to catch it. If this passes, the
# headline assertion is decoration.
scenario espeak-header header none "$REAL_KEYS" none desc || no "scenario espeak-header runs" "the slot-test could not be prepared"
check_shape espeak-header
want espeak-header tts-produces-real-audio FAIL "a header-only espeak-ng makes the audio assertion FAIL (the control)"
grep -q 'bare WAV header' "$TMP/espeak-header/out" \
  && ok "the failure says WHY: a bare WAV header with no samples behind it" \
  || no "the failure says why" "reason: $(reason espeak-header tts-produces-real-audio)"
want espeak-header tts-engine-resolves PASS "engine() still resolves even though the engine writes no audio — availability is not soundness"
want espeak-header tts-engine-is-not-extra-piper PASS "the control against extra/piper does not fire for a broken engine"

# --- 4. NO speech binary at all ---------------------------------------------
# The harness rule is that a file with pass==0 is FAILED, so a slot with neither
# espeak-ng nor piper must still report passes — and the STT line must be a SKIP,
# never a PASS (a transcription that did not happen) and never a FAIL (nothing
# is broken; whisper-cpp is an optdepend).
scenario no-audio none none "$REAL_KEYS" none desc || no "scenario no-audio runs" "the slot-test could not be prepared"
check_shape no-audio
n_pass=$(count_verdict no-audio PASS)
(( n_pass > 0 )) \
  && ok "with no speech binary at all there are still ${n_pass} PASS(es), so cmd_slot_test cannot report this file FAILED on pass==0" \
  || no "a slot with no speech binary still reports a PASS" "0 passes: $(grep -c '^RESULT' "$TMP/no-audio/out") lines, all skips"
want no-audio stt-transcribes-speech SKIP "the STT line is a SKIP with no binaries at all"
v=$(verdict no-audio stt-transcribes-speech)
[[ "$v" != PASS && "$v" != FAIL ]] \
  && ok "the STT line is never a PASS or a FAIL here (got ${v:-absent})" \
  || no "the STT line is never a confident verdict" "got ${v}"
grep -q 'whisper-cpp not installed' "$TMP/no-audio/out" \
  && ok "the SKIP names the concrete missing thing (whisper-cpp not installed; it is an optdepend)" \
  || no "the SKIP names the concrete missing thing" "reason: $(reason no-audio stt-transcribes-speech)"
want no-audio tts-engine-resolves PASS "engine() is None and that is a legal answer, not a failure"

# --- 5. whisper-cli AND a model: the derived SKIP flips itself to PASS -------
# The reason stt-transcribes-speech is derived rather than hardcoded. No edit to
# the slot-test happens here: the dependency simply becomes available.
scenario whisper good whisper "$REAL_KEYS" none desc || no "scenario whisper runs" "the slot-test could not be prepared"
check_shape whisper
want whisper stt-transcribes-speech PASS "with whisper-cli and a ggml model present the derived skip flips to PASS by itself"
grep -q 'transcribed the real WAV' "$TMP/whisper/out" \
  && ok "the PASS quotes the transcribed text rather than just asserting non-emptiness" \
  || no "the transcription PASS quotes the text" "reason: $(reason whisper stt-transcribes-speech)"
# And the "PASS about the state" line must notice the model appearing, or the
# two drift apart quietly.
want whisper stt-no-ggml-model-on-this-install FAIL "the recorded-state line reports the model now existing instead of going stale"
grep -q 'the recorded state has changed' "$TMP/whisper/out" \
  && ok "that failure points at the check to watch (stt-transcribes-speech), not at itself" \
  || no "the recorded-state failure is actionable" "reason: $(reason whisper stt-no-ggml-model-on-this-install)"
want whisper stt-reports-unavailable-not-broken PASS "with both halves present is_available() must be True, and the derived expectation tracks that"

# --- 6. piper-tts plus a Piper voice: the extra/piper control fires ---------
scenario piper good piper "$REAL_KEYS" none desc || no "scenario piper runs" "the slot-test could not be prepared"
check_shape piper
want piper tts-engine-is-not-extra-piper FAIL "a real piper-tts + voice makes the negative control FAIL (it may not be silently accepted)"
grep -q 'extra/piper' "$TMP/piper/out" \
  && ok "the failure names extra/piper, the GTK gaming-mouse configurator that shares the name" \
  || no "the failure names the real cause" "reason: $(reason piper tts-engine-is-not-extra-piper)"
want piper tts-engine-resolves PASS "engine() reports piper, which is the state this control exists to catch"
want piper tts-produces-real-audio PASS "and audio still synthesises — the control is about WHICH engine, not about sound"

# --- 7. a compiled schema missing one voice key -----------------------------
scenario schema-gap good none "$(printf '%s\n' $REAL_KEYS | grep -v '^piper-voice$' | tr '\n' ' ')" none desc \
  || no "scenario schema-gap runs" "the slot-test could not be prepared"
check_shape schema-gap
want schema-gap schema-declares-voice-keys FAIL "a key in the XML but not in gschemas.compiled is caught"
grep -q 'piper-voice' "$TMP/schema-gap/out" \
  && ok "the failure names the absent key" \
  || no "the failure names the absent key" "reason: $(reason schema-gap schema-declares-voice-keys)"

# --- 8. no desc in the local database: Group A falls back to pacq -Qi --------
# Otherwise the `pacq -Qi` reader is untested code that only runs when something
# is already broken.
scenario no-desc good none "$REAL_KEYS" none desc || no "scenario no-desc runs" "the slot-test could not be prepared"
respawn_db no-desc nodesc
check_shape no-desc
want no-desc chronoa-package-installed       PASS "the version still comes back with no local-db desc (pacq -Q)"
want no-desc chronoa-hard-deps-installed     PASS "the hard deps are still derived and asserted, from pacq -Qi"
want no-desc whisper-cpp-is-optional-not-required PASS "the optdepends are still read from pacq -Qi, so the snap/whisper guard holds"
grep -q 'pacq -Qi' "$TMP/no-desc/out" \
  && ok "the result says which reader answered, so the fallback is visible in the output" \
  || no "the fallback reader is named in the output" "$(grep -m2 'RESULT chronoa-package-installed' "$TMP/no-desc/out")"

# --- 8c. NO installed package at all: the three packaging assertions ---------
# A --local-src-chronoa overlay copies the payload but never writes the pacman
# database, so on such a slot nothing can answer "is whisper-cpp declared
# optional?". The honest verdict is then SKIP. This scenario exists to pin that,
# because the alternative -- reporting FAIL -- claims a packaging defect that a
# source overlay cannot establish, and it is exactly what a real run on @blue
# produced before this rule existed.
export STUB_NO_PKG=1   # must span the respawn below too: it rewrites the same out file
scenario no-package good none "$REAL_KEYS" none nopkg || no "scenario no-package runs" "the slot-test could not be prepared"
respawn_db no-package nopkg
unset STUB_NO_PKG
check_shape no-package
want no-package chronoa-package-installed             SKIP "no installed package to read"
want no-package chronoa-hard-deps-installed           SKIP "no hard-dependency list could be read"
want no-package whisper-cpp-is-optional-not-required SKIP "optionality cannot be determined"
grep -q -- '-Q shani-chronoa' "$TMP/no-package/stub-invocations.log" \
  && ok "the control is real: pacman WAS asked for shani-chronoa and answered nothing" \
  || no "the control could not have fired" "pacman was never asked, so the SKIPs prove nothing"
want no-package tts-produces-real-audio              PASS "speech still verified: a SKIP-only file would be reported FAILED by the runner"
want no-package stt-transcribes-speech               SKIP "no whisper-cpp in this scenario"

# --- 8b. the SAME metadata written the OTHER way pacman writes it ------------
# pacman really has two shapes for the same facts: the local database entry uses
# %DEPENDS% sections of bare lines, and the .PKGINFO inside a package archive
# uses `depend = <spec>`. A reader written for one of them would pass against a
# fixture of that shape and find NOTHING in a real slot — so both must assert
# the identical result, here, where the two differ by whitespace alone.
scenario pkginfo-shape good none "$REAL_KEYS" none desc || no "scenario pkginfo-shape runs" "the slot-test could not be prepared"
respawn_db pkginfo-shape pkginfo
check_shape pkginfo-shape
want pkginfo-shape chronoa-hard-deps-installed   PASS "the depend = <spec> shape yields the same hard-dep assertion (constraint still stripped)"
want pkginfo-shape whisper-cpp-is-optional-not-required PASS "the optdepend = shape still proves whisper-cpp optional"
grep -q 'all 6 hard depend' "$TMP/pkginfo-shape/out" \
  && ok "the same six dependencies are counted from either shape, so neither reader is vacuous" \
  || no "the dependency count matches across both metadata shapes" "$(grep -m1 'RESULT chronoa-hard-deps' "$TMP/pkginfo-shape/out")"
grep -q 'all 6 hard depend' "$TMP/base/out" \
  && ok "…and the %DEPENDS% section shape counts the same six" \
  || no "the %DEPENDS% shape counts the same six" "$(grep -m1 'RESULT chronoa-hard-deps' "$TMP/base/out")"

# --- 9. the launcher, with and without the historical path bug --------------
# The assertion guarding the bug that shipped for the whole life of the project,
# because every earlier test bypassed the launcher. It must reject the broken
# path computation and accept the fixed one — which is only meaningful if it can
# tell them apart.
scenario launcher-bad good none "$REAL_KEYS" bad desc || no "scenario launcher-bad runs" "the slot-test could not be prepared"
check_shape launcher-bad
want launcher-bad launcher-imports-shipped-package FAIL "a launcher with the historical dirname(dirname()) path bug is caught"
grep -q 'No module named' "$TMP/launcher-bad/out" \
  && ok "the failure quotes the actual ModuleNotFoundError, not a guess" \
  || no "the launcher failure quotes the real error" "reason: $(reason launcher-bad launcher-imports-shipped-package)"

scenario launcher-ok good none "$REAL_KEYS" ok desc || no "scenario launcher-ok runs" "the slot-test could not be prepared"
check_shape launcher-ok
v=$(verdict launcher-ok launcher-imports-shipped-package)
if [[ "$v" == PASS ]]; then
  ok "the same launcher with the fixed path computation passes — so the check discriminates, not just rejects"
else
  # A host has neither a display nor PyGObject, so the fixed launcher dies
  # importing its own dependencies. That is NOT the bug this line guards, and
  # the honest report is that the assertion did not fire for the right reason.
  r=$(reason launcher-ok launcher-imports-shipped-package)
  if grep -q 'No module named .shani_chronoa' <<<"$r"; then
    no "the same launcher with the fixed path computation passes" "it reported the shani_chronoa import failure anyway: $r"
  else
    ok "the same launcher with the fixed path is NOT reported as a ModuleNotFoundError (it stops later, on this host's missing display/PyGObject: ${r:0:120})"
  fi
fi

# --- 10. every stub really ran ----------------------------------------------
# A stub that was never reached makes its scenario prove nothing, and the
# assertion would still be green. So the invocation log is asserted per stub,
# and STUB_LOG is truncated at the start of every scenario so a leak between
# scenarios shows up as a scenario that cannot prove its own premise.
stub_ran() {  # <scenario> <substring> <what>
  if grep -qF -- "$2" "$TMP/$1/stub-invocations.log"; then
    ok "[$1] $3"
  else
    no "[$1] $3" "the stub was never invoked; log: $(tr '\n' '|' < "$TMP/$1/stub-invocations.log")"
  fi
}
# The log records a whole argv, so an assertion naming only the command would
# also match its own argument list ("-Qql" contains "-Qq"). Hence a regex variant.
stub_ran_re() {  # <scenario> <ere> <what>
  if grep -qE -- "$2" "$TMP/$1/stub-invocations.log"; then
    ok "[$1] $3"
  else
    no "[$1] $3" "no log line matches /$2/; log: $(tr '\n' '|' < "$TMP/$1/stub-invocations.log")"
  fi
}
stub_ran base        "espeak-ng --stdin -v en-us -w" "the espeak-ng stub was really invoked, with the argv PiperTTS.synthesize() actually uses"
stub_ran espeak-header "espeak-ng --stdin -v en-us -w" "the BROKEN espeak-ng stub was really invoked (else the control proves nothing)"
stub_ran espeak-header "soxi -D"                       "the soxi stub was really consulted for the duration"
stub_ran whisper     "whisper-cli -m"                 "the whisper-cli stub was really invoked, with the argv stt.transcribe() actually uses"
stub_ran piper       "piper-tts --model"              "the piper-tts stub was really invoked, with the argv the piper branch actually uses"
stub_ran_re base     '[ ]-Qq$'                        "pacq (the pacman stub) was really asked for the installed package names"
stub_ran base        "pacdb-cleanup"                   "the slot-test's trap called _pacdb_cleanup, as slot-tests/_pacdb.sh's contract requires"
stub_ran base        "gsettings list-keys org.shani.chronoa" "the gsettings stub was really asked for the compiled schema's keys"
# The espeak-ng stub must have been handed a path under the scenario's work dir,
# which proves the WAV the assertions inspected is the one the stub wrote rather
# than something left over from an earlier scenario.
wav=$(grep -oE '\-w [^ ]+' "$TMP/base/stub-invocations.log" | head -1 | cut -d' ' -f2)
if [[ "$wav" == "$TMP"/base/var/tmp/*/out.wav || "$wav" == *chronoa-speech-*/out.wav ]]; then
  ok "the espeak-ng stub was pointed at this run's own WAV path"
else
  no "the espeak-ng stub was pointed at this run's own WAV path" "argv gave: '${wav:-none}'"
fi
# And the byte count the audio assertion reported must be the stub's own byte
# count. It cannot be stat'ed here: the slot-test's EXIT trap deletes its work
# directory, which is correct behaviour and worth not working around.
grep -q 'real 4044-byte RIFF/WAVE' "$TMP/base/out" \
  && ok "the audio assertion measured the stub's own 4044 bytes (44-byte header + 4000 of samples)" \
  || no "the audio assertion measured the stub's own bytes" "got: $(reason base tts-produces-real-audio)"
grep -q 'duration 0.09070s per soxi' "$TMP/base/out" \
  && ok "and the non-zero duration came from soxi, not from the size check standing in for it" \
  || no "the duration branch ran through soxi" "got: $(reason base tts-produces-real-audio)"
[[ ! -e "$TMP/espeak-header/stub-invocations.log" || "$(stat -c %s "$TMP/espeak-header/stub-invocations.log")" -gt 0 ]] \
  && ok "no scenario inherited an earlier scenario's stub log (STUB_LOG is truncated per run)" \
  || no "stub logs are per-scenario" "espeak-header's log is empty"

# --- 11. bash -n on the slot-test itself -------------------------------------
if bash -n "$SLOT_TEST" 2>"$TMP/n.err"; then
  ok "bash -n is clean on slot-tests/chronoa-speech.sh"
else
  no "bash -n is clean on slot-tests/chronoa-speech.sh" "$(head -3 "$TMP/n.err")"
fi
head2=$(sed -n '2p' "$SLOT_TEST")
[[ "$head2" == "# slot-test-mode: boot" ]] \
  && ok "the mode header is the first content line after the shebang (only 'boot' is a valid mode)" \
  || no "the mode header is the first content line after the shebang" "line 2 is '${head2}'"
[[ -x "$SLOT_TEST" ]] \
  && ok "the slot-test is executable" \
  || no "the slot-test is executable" "mode $(stat -c %a "$SLOT_TEST")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass_n" "$fail_n"
(( fail_n == 0 )) || exit 1