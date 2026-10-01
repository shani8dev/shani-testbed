#!/bin/bash
# slot-test-mode: boot
#
# chronoa-speech — acceptance coverage for shani-chronoa's SPEECH stack
# (whisper.cpp STT + Piper/RHVoice/espeak-ng TTS) inside a REAL booted ShaniOS
# slot. Nothing here reimplements a speech component: the checks construct the
# real classes out of the real INSTALLED package, and the headline assertion
# makes the real PiperTTS synthesize a real WAV through the real espeak-ng.
#
# WHY THIS LIVES IN slot-tests/ AND NOT IN tests/ (read this before adding a
# unit test that "covers" the same thing). The host unit suite is 3071 green
# tests, and not one of them can notice either of the two facts this file
# exists to record:
#
#   * `stt.py` and `tts.py` find their binaries with `shutil.which`. A unit test
#     MOCKS `shutil.which`, so it is asserting against a fixture the test wrote
#     itself. No amount of mocking can answer "is whisper-cli actually on this
#     machine", and the measured answer on a real image is NO: whisper-cpp is
#     an optdepend and no Shanios image profile installs it. The 20260925 gnome
#     image (1295 packages) ships espeak-ng, shani-chronoa and tesseract, and
#     ships no whisper-cpp, no piper-tts, no rhvoice-* and no ollama.
#   * `_get_model_path()` searches `$XDG_DATA_HOME/whisper/models` and
#     `/usr/share/whisper/models`. On this image NEITHER contains a
#     `ggml-*.bin`, and `/usr/share/whisper/models` does not exist at all. A
#     unit test creates its own temp model, so the question "is there a model on
#     a real install" is never asked by anything.
#
# So the unit suite proves the branches execute; this file proves which branch
# a real install lands in. Both are needed and they are not substitutes.
#
# THE RULE THIS FILE IS BUILT ON (it is this project's, not the harness's): a
# component whose failure mode is a plausible-looking wrong answer is worse
# than one that fails. So:
#
#   * TTS must be ASSERTED to produce real audio. `synthesize()` returning True
#     is the claim; a 44-byte RIFF header with no samples behind it is a lie
#     that returns True. The headline check asserts the magic, the size and the
#     duration, in that order of strength.
#   * STT must be asserted to report itself UNAVAILABLE. "Ready" with no binary
#     and no model is the confident wrong answer, and it is a FAIL here, never a
#     SKIP.
#
# ON THE ONE SKIP IN THIS FILE (stt-transcribes-speech). It is DERIVED from
# the machine's real state, on purpose, in the same spirit as fresh-user.sh's
# `since()` gate — generalised from a version gate to an availability gate. A
# hardcoded SKIP has to be flipped by hand, and a hardcoded SKIP that someone
# forgot to flip rots back into looking like coverage: the suite keeps printing
# a line while the code path behind it stays untested. A derived one flips to
# PASS by itself the day the dependency lands, with no edit here. Both the
# binary and the model are checked, because either alone is useless and the
# SKIP names whichever one is actually missing.
#
# NOTHING EXITS ON A MID-FILE FAILURE. `bad` deliberately does not exit: a test
# that stops at the first FAIL hides every other finding in the same run, and
# this file's whole job is to report what a real image does and does not have.
#
# Run it:
#   slot-test blue chronoa-speech --local-src-chronoa=<checkout>
# A control run WITHOUT --local-src-chronoa goes red on exactly one line —
# stt-model-path-follows-xdg-data-home — because the stale shipped package
# hardcoded ~/.local/share where current HEAD resolves via files.data_home().
# That difference is the overlay-liveness proof for this file.
set -u
res()  { printf 'RESULT %-44s %s\n' "$1" "$2"; }
pass() { res "$1" "PASS${2:+ ($2)}"; }
bad()  { res "$1" "FAIL ($2)"; }
skip() { res "$1" "SKIP ($2)"; }

# pacman, against the slot's own subvolume rather than /var (a real boot has an
# empty tmpfs /var, so /var/lib/pacman does not exist at runtime). Same seam
# unit-verify.sh / service-start.sh / repo-pytest.sh already use.
source /mnt/testbed/slot-tests/_pacdb.sh
WORK=$(mktemp -d /var/tmp/chronoa-speech-XXXXXX)
cleanup() { rm -rf "$WORK"; _pacdb_cleanup; }
trap cleanup EXIT

PKG=shani-chronoa
# The schema id, so this file asks the same one the app asks rather than
# keeping a second literal that could drift.
SCHEMA_ID="org.shani.chronoa"
# Deliberately NOT relaying through a wrapper: several checks below read
# XDG_DATA_HOME out of the environment between calls, and the point of one of
# them is that files.data_home() resolves per call.
export XDG_DATA_HOME="$WORK/xdg-data"
export HOME="${HOME:-/root}"

echo "== Group A: the packaging contract, read out of the package itself"

# --- A1/A2: the INSTALLED package's own metadata, no hardcoded dep list -----
# A literal list of expected dependencies is rot: the day a dependency is added
# or dropped, the literal is wrong in whichever direction nobody looked. So the
# expectation is DERIVED — every `depend =` line of the installed package's own
# .PKGINFO, with the version constraint stripped, must resolve in this image.
# That is what makes a future manifest bug detectable here with no list to
# forget: a PKGBUILD that declares something the image profile does not ship
# cannot pass this file.
#
# The metadata is read twice over on purpose. The pacman local database is the
# primary source (that desc IS the .PKGINFO), and `pacq -Qi` is the fallback for
# the same facts when the db lives somewhere the glob cannot reach — it prints
# the desc's own Depends On / Optional Deps sections. Two readers of one truth:
# if they ever disagree, one of them is broken and the disagreement is visible.
PKGINFO=()
# 1 only when the slot really has a pacman-installed package whose metadata can
# be read. A --local-src-chronoa overlay copies the payload but never writes the
# pacman database, and --local-pkg extracts a tarball without running its
# .install scriptlet, so on such a slot NO metadata reader can answer. When that
# is the case every packaging assertion below SKIPs: "cannot determine" is the
# honest verdict, and calling it a FAIL would report a defect that is not there.
PKG_META=0
for f in "$PACDB"/local/shani-chronoa-*/desc; do
  [[ -f "$f" ]] && PKGINFO+=("$f")
done
QVER=$(pacq -Q "$PKG" 2>/dev/null | awk '{print $2}')
DESC_SRC=""
if (( ${#PKGINFO[@]} > 0 )); then
  DESC_SRC="${PKGINFO[0]}"
  PKGVER=$(sed -n 's/^%VERSION%$//p;/^%VERSION%$/ {n;p}' "$DESC_SRC" 2>/dev/null | head -1)
else
  PKGVER="$QVER"
fi
if [[ -z "$PKGVER" && -z "$QVER" ]]; then
  skip chronoa-package-installed "no installed $PKG to read: neither $PACDB/local/$PKG-*/desc nor 'pacq -Q $PKG' answered. A --local-src-chronoa overlay (or an unregistered --local-pkg file overlay) puts the payload on disk without writing the pacman database, so there is no .PKGINFO and no pacq answer -- the packaging assertions in this file are then unanswerable rather than wrong. Two real causes: this slot was never bootstrapped from an image that ships $PKG, or only a source/file overlay was applied"
else
  PKG_META=1
  if (( ${#PKGINFO[@]} > 0 )); then
    pass chronoa-package-installed "$PKG ${PKGVER:-$QVER} (metadata read from the installed package's own .PKGINFO: $DESC_SRC)"
  else
    pass chronoa-package-installed "$PKG ${PKGVER:-$QVER} (metadata read via pacq -Qi; the local database at $PACDB/local holds no $PKG-* desc)"
  fi
fi

# Every declared hard dependency, version constraint stripped (`pkg>=1.2` and
# `pkg` are the same obligation as far as "is it installed" goes).
#
# BOTH metadata shapes are read, because there are two and they are not the same
# file: the .PKGINFO inside a package archive — and anything built from one, such
# as `pacman -Qkk` — writes `depend = <spec>`, while the pacman LOCAL database
# entry this actually reads ($PACDB/local/<pkg>-<ver>/desc) writes the same facts
# as a `%DEPENDS%` section of bare lines. Reading only one shape passes on a
# machine where nobody noticed which one was there. Both are handled by one
# pass, so neither shape can rot into an empty dependency list that silently
# verifies nothing.
#
# `%OPTDEPENDS%` entries are `name: description` and the description may itself
# contain spaces, so it is cut at the first colon — a package name cannot contain
# one.
_pkginfo_names() {  # <depend|optdepend>
  local kind="$1" f section="" line
  (( ${#PKGINFO[@]} > 0 )) || return 0
  for f in "${PKGINFO[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      if [[ "$line" =~ ^%[A-Z]+%$ ]]; then
        section="${line:1:${#line}-2}"
        continue
      fi
      if [[ "$line" == "$kind = "* ]]; then
        line="${line#"$kind = "}"
      else
        case "$section" in
          DEPENDS)    [[ "$kind" == depend ]] || continue ;;
          OPTDEPENDS) [[ "$kind" == optdepend ]] || continue ;;
          *)          continue ;;
        esac
      fi
      [[ -n "$line" ]] || continue
      line="${line%%:*}"
      line="${line%%[<>=~]*}"
      line="${line%% *}"
      [[ -n "$line" ]] && printf '%s\n' "$line"
    done < "$f"
  done
}
dep_names()     { _pkginfo_names depend; }
optdep_names()  { _pkginfo_names optdepend; }
# The same two facts from `pacq -Qi`, which prints the desc's own "Depends On" /
# "Optional Deps" sections. The field name is tracked because a wrapped entry
# lands on its own INDENTED line and has to be attributed to the field above it.
#
# Split with `read`, not with a regex on the colon: pacman pads the field names
# into a column ("Depends On      : ..."), and a regex capture of
# [A-Za-z[:space:]]* keeps that padding, so `case "$section" in "Depends On")`
# never matches and the whole section reads as empty. An earlier version of this
# function did exactly that and reported "no hard-dependency list could be read"
# against a perfectly good pacman. `read` splits on IFS, so the padding is gone.
qi_deps() {  # <req|opt>
  local want="$1" section="" rest="" line e out=""
  while IFS= read -r line; do
    if [[ "$line" == " "* ]]; then
      rest="$line"                    # a wrapped entry: the field above still owns it
    elif [[ "$line" == *:* ]]; then
      rest="${line#*:}"
      section="${line%%:*}"
      while [[ "$section" == *[[:space:]] ]]; do section="${section%?}"; done
    fi
    case "$section" in
      "Depends On")   [[ "$want" == req ]] || continue ;;
      "Optional Deps") [[ "$want" == opt ]] || continue ;;
      *) continue ;;
    esac
    for e in $rest; do
      e="${e%%:*}"; e="${e%%[<>=~]*}"; e="${e%% *}"
      [[ -n "$e" ]] && out+="$e"$'\n'
    done
  done < <(pacq -Qi "$PKG" 2>/dev/null)
  printf '%s' "$out"
}

REQS=$(dep_names); OPTS=$(optdep_names)
REQ_SRC="the installed .PKGINFO"
if [[ -z "$REQS" ]]; then
  REQS=$(qi_deps req); REQ_SRC="pacq -Qi"
fi
if [[ -z "$OPTS" ]]; then
  OPTS=$(qi_deps opt); [[ "$REQ_SRC" == "the installed .PKGINFO" ]] && REQ_SRC="pacq -Qi and the installed .PKGINFO"
fi

if [[ -z "$REQS" ]]; then
  skip chronoa-hard-deps-installed "no hard-dependency list could be read for $PKG from either $PACDB/local/$PKG-*/desc or 'pacq -Qi $PKG', so nothing was verified and nothing is wrong. See chronoa-package-installed for why: on a source-overlay slot the pacman database is not written, so this assertion cannot be answered here. Two real causes: $PKG is not installed in this slot at all, or its .PKGINFO declares no depend = lines (a package with no declared dependencies is its own finding)"
else
  INSTALLED=$(pacq -Qq 2>/dev/null)
  absent=""
  nreq=0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    nreq=$((nreq+1))
    grep -qxF "$d" <<<"$INSTALLED" || absent+=" $d"
  done <<<"$REQS"
  if [[ -z "$absent" ]]; then
    pass chronoa-hard-deps-installed "all ${nreq} hard depend(ies) declared by $PKG are installed (read from $REQ_SRC, none of them a list written here)"
  else
    bad chronoa-hard-deps-installed "${nreq} declared hard dep(s) are not installed:${absent}. Two real causes: image_profiles/*/Packages-Desktop for this profile does not pin the package(s) above, so the image never pulled them; and shani-pkgbuilds/shani-chronoa/PKGBUILD declares a dependency the profile does not ship. Both halves are needed — a dependency added to the PKGBUILD and not to the image manifest installs for nobody, and this line is what catches that the day it is committed"
  fi
fi

echo "== Group B: TTS — the unconditional group, because espeak-ng is a hard dep"

# The installed package's location, asked of pacman rather than guessed. Group E
# has to import the real package and Group F has to grep the real source, and a
# hardcoded /usr/lib/shani-chronoa would be a second thing to rot.
CHRONOA_LIB=$(pacq -Qql "$PKG" 2>/dev/null \
  | sed -n 's|^\(.*\)/shani_chronoa/__init__\.py$|\1|p' | head -1)
if [[ -z "$CHRONOA_LIB" ]]; then
  # Fall back to the single directory every launcher puts the package in, and
  # confirm it before trusting it.
  if [[ -f /usr/lib/shani-chronoa/shani_chronoa/__init__.py ]]; then
    CHRONOA_LIB=/usr/lib/shani-chronoa
  fi
fi
py() {  # run the SLOT's python against the INSTALLED package
  PYTHONPATH="$CHRONOA_LIB${PYTHONPATH:+:$PYTHONPATH}" python3 "$@"
}

TTS_TXT="Shanios speech stack check"
WAV="$WORK/out.wav"

eng=$(py -c 'from shani_chronoa.tts import PiperTTS
print(PiperTTS().engine() or "none")' 2>"$WORK/tts.err")
eng_rc=$?
if (( eng_rc != 0 )); then
  bad tts-engine-resolves "the real PiperTTS could not be constructed by the slot's python: $(head -2 "$WORK/tts.err" | tr '\n' ' ')"
elif [[ "$eng" == piper || "$eng" == rhvoice || "$eng" == espeak-ng || "$eng" == none ]]; then
  if [[ "$eng" == none ]]; then
    eng_note="None: no piper-tts, no RHVoice, no espeak-ng — the app logs 'Piper TTS not available - TTS disabled' and speaks nothing"
  else
    eng_note="PiperTTS() selected '${eng}' from the installed package; nothing here reimplements it"
  fi
  pass tts-engine-resolves "engine() = ${eng} (${eng_note})"
else
  bad tts-engine-resolves "engine() returned '${eng}', which is not one of piper/rhvoice/espeak-ng/None — a caller that branches on this string would fall through every branch and still look healthy"
fi

# NEGATIVE CONTROL, and the reason for it: the pacman caches on this machine
# contain a package literally named `piper`. That is extra/piper, a GTK gaming-
# mouse configurator — it is NOT Piper TTS. The TTS binary is `piper-tts`. So a
# TTS stack can be "provisioned" with the wrong package and every symptom still
# looks fine until the app launches a mouse configurator with TTS arguments and
# nobody reads the log. This line is red the moment engine() starts reporting
# piper, and it refuses to accept `piper-tts` merely being on PATH as evidence.
pip_bin=$(command -v piper-tts 2>/dev/null || true)
if [[ "$eng" == piper ]]; then
  bad tts-engine-is-not-extra-piper "engine() reports piper, so a file this test believed to be Piper TTS satisfied it at '${pip_bin:-/usr/bin/piper-tts}'. Two real causes: shani_chronoa.tts's piper_path default was pointed at /usr/bin/piper, which on Arch is extra/piper's GTK gaming-mouse configurator and not Piper TTS; or a package providing the real piper-tts binary was added to the image. Supply Piper as piper-tts plus a voice under \$XDG_DATA_HOME/piper/voices/ — an empty/absent piper-tts with espeak-ng present is the correct state on a Shanios image"
elif [[ -n "$pip_bin" ]]; then
  pass tts-engine-is-not-extra-piper "piper-tts exists at ${pip_bin} but engine() is still ${eng}, so the Piper branch is not being taken by accident"
else
  pass tts-engine-is-not-extra-piper "no piper-tts on PATH and engine() = ${eng}; speech is espeak-ng, which is the one TTS every Shanios image ships"
fi

# THE HEADLINE. `synthesize()` returning True is a CLAIM; a 44-byte RIFF header
# with no samples behind it returns True and is a lie. So the returned bool is
# checked AND the bytes are inspected: RIFF magic at offset 0, more than 44
# bytes (a bare header is exactly 44), and — when a duration tool exists — a
# non-zero duration. The size and the magic are always required; the duration is
# an extra because espeak-ng is not guaranteed to be accompanied by sox/ffmpeg.
synth=$(py -c 'import sys
from shani_chronoa.tts import PiperTTS
print("yes" if PiperTTS().synthesize(sys.argv[1], sys.argv[2]) else "no")' "$TTS_TXT" "$WAV" 2>"$WORK/synth.err")
synth_rc=$?
bytes=$(stat -c %s "$WAV" 2>/dev/null || echo 0)
magic=$(head -c4 "$WAV" 2>/dev/null || true)
dur="" durtool=""
if command -v soxi >/dev/null 2>&1; then
  durtool=soxi; dur=$(soxi -D "$WAV" 2>/dev/null)
elif command -v ffprobe >/dev/null 2>&1; then
  durtool=ffprobe; dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null)
fi
why=""
head_only_note=""
(( synth_rc == 0 )) || why+="the synthesize() call itself failed (rc=${synth_rc}): $(head -2 "$WORK/synth.err" | tr '\n' ' '); "
[[ "$synth" == yes ]] || why+="synthesize() returned ${synth:-nothing}; "
if [[ ! -f "$WAV" ]]; then
  why+="no file was written at $WAV; "
elif [[ "$magic" != RIFF ]]; then
  why+="the ${bytes} bytes it wrote do not begin with RIFF; "
else
  # A bare 44-byte header with nothing behind it is the specific lie this
  # assertion exists for: the file exists, the magic is right, and it is silent.
  if (( bytes <= 44 )); then
    why+="the file is ${bytes} bytes, i.e. a bare WAV header with no samples behind it; "
    head_only_note="an espeak-ng that wrote only a header would produce exactly this, and nothing in synthesize()'s own return value distinguishes it from real audio except this byte count"
  elif [[ -n "$dur" ]] && ! awk -v d="${dur:-0}" 'BEGIN{exit !(d+0 > 0)}'; then
    why+="${durtool} reports a duration of '${dur}' for ${bytes} bytes, i.e. the samples behind the header are silent; "
  fi
fi
if [[ -z "$why" ]]; then
  if [[ -n "$dur" ]]; then
    pass tts-produces-real-audio "real ${bytes}-byte RIFF/WAVE, duration ${dur}s per ${durtool}, from PiperTTS().synthesize('${TTS_TXT}') via ${eng}"
  else
    pass tts-produces-real-audio "real ${bytes}-byte RIFF/WAVE with samples behind the header (neither soxi nor ffprobe is installed here, so size+magic is the evidence for a non-zero duration)"
  fi
else
  bad tts-produces-real-audio "${why%%[; ] }${head_only_note:+ — $head_only_note}"
fi

# An unwritable target must be REPORTED, not raised. The app calls synthesize()
# from the GTK thread on every reply, so an exception here is a traceback in a
# user's session instead of a spoken reply. The path is a directory that does
# not exist rather than a 0555 directory on purpose: the slot runs as root, and
# root writes into a mode-0555 directory happily, which would make this
# assertion pass without ever reaching the failure path.
unwritable="$WORK/no-such-dir/out.wav"
tryres=$(py -c 'import sys
from shani_chronoa.tts import PiperTTS
try:
    ok = PiperTTS().synthesize(sys.argv[1], sys.argv[2])
except BaseException as exc:
    print("RAISED " + type(exc).__name__)
else:
    print("returned False" if not ok else "returned True")' "$TTS_TXT" "$unwritable" 2>>"$WORK/synth.err")
if [[ "$tryres" == "returned False" ]]; then
  pass tts-synthesize-failure-is-not-fatal "synthesize() to $unwritable returned False instead of raising, so a failed write degrades to silence"
else
  bad tts-synthesize-failure-is-not-fatal "synthesize() to an unwritable path ${tryres:-said nothing at all} rather than returning False — the app calls this from the GTK thread on every reply, so this surfaces as a traceback in the user's session instead of a silent reply"
fi

echo "== Group C: STT — honest degradation, never a confident wrong answer"

# What is actually on this machine, decided ONCE and used by three checks, so
# the three cannot disagree about the state they are reasoning about.
stt_bin=""
for b in whisper-cli whisper.cpp; do
  command -v "$b" >/dev/null 2>&1 && { stt_bin=$(command -v "$b"); break; }
done
MODEL_DIRS=("$XDG_DATA_HOME/whisper/models" "/usr/share/whisper/models")
stt_model=""
for d in "${MODEL_DIRS[@]}"; do
  for m in "$d"/ggml-*.bin; do
    [[ -f "$m" ]] && { stt_model="$m"; break; }
  done
  [[ -n "$stt_model" ]] && break
done
have_bin=0; [[ -n "$stt_bin" ]] && have_bin=1
have_model=0; [[ -n "$stt_model" ]] && have_model=1

avail=$(py -c 'from shani_chronoa.stt import WhisperSTT
print("yes" if WhisperSTT().is_available() else "no")' 2>"$WORK/stt.err")
avail_rc=$?
# The truth on this machine, derived: is_available() requires BOTH the binary
# and the model file to exist, so with either missing it must say no.
want="no"; (( have_bin && have_model )) && want="yes"
if (( avail_rc != 0 )); then
  bad stt-reports-unavailable-not-broken "the real WhisperSTT could not be constructed by the slot's python: $(head -2 "$WORK/stt.err" | tr '\n' ' ')"
elif [[ "$avail" != "$want" ]]; then
  if [[ "$want" == no && "$avail" == yes ]]; then
    bad stt-reports-unavailable-not-broken "is_available() returned True with no whisper binary (${stt_bin:-none}) and no ggml-*.bin model — a component that reports itself ready when it cannot transcribe is the worst outcome available here, worse than being absent, because every caller trusts this answer and the user gets silence at the point they pressed the orb"
  else
    bad stt-reports-unavailable-not-broken "is_available() returned '${avail}' but the machine has whisper binary=${have_bin} model=${have_model}, so the availability check is not tracking reality"
  fi
else
  # The warning path is asserted reachable, not just described. app.py guards
  # STT with `if not self.stt.is_available(): logger.warning("Whisper.cpp not
  # available - STT disabled")`, so with is_available() false the branch IS
  # taken — and the string has to still be in the INSTALLED app.py, or the
  # degradation has been removed and nobody reads the log. An empty stderr is
  # not accepted as evidence of anything.
  if py -c 'import sys
from shani_chronoa.stt import WhisperSTT
raise SystemExit(0 if (not WhisperSTT().is_available()) else 1)' 2>>"$WORK/stt.err"; then
    guard="yes"
  else
    guard="no"
  fi
  # The warning is interpolated, not literal: app.py logs
  # "%s not available - STT disabled" with the backend's own name, so the
  # string to look for is "not available - STT disabled". Pinning
  # "Whisper.cpp not available" instead would fail the moment a second
  # backend exists, which is the wrong way round: what matters is that the
  # degradation is stated, not which engine stated it.
  warn=""
  grep -q 'not available - STT disabled' "${CHRONOA_LIB}/shani_chronoa/app.py" 2>/dev/null && warn="yes"
  if [[ "$warn" == yes ]]; then
    warnstate="present"
  else
    warnstate="ABSENT"
  fi
  if [[ "$want" == no && "$guard" == yes && "$warn" == yes ]]; then
    pass stt-reports-unavailable-not-broken "is_available() is False (no whisper binary${stt_bin:+ at $stt_bin}${have_model:+, no model}), so app.py's 'not available - STT disabled' branch (with the backend's own name interpolated) is the one taken and the string is still in the installed app.py — degraded, not broken, and saying so"
  elif [[ "$want" == yes ]]; then
    # Both halves present, so is_available() is True and app.py must NOT take the
    # degradation branch. The line that has to be readable either way is the one
    # in the source, which is what the other half of this check is for.
    pass stt-reports-unavailable-not-broken "is_available() is True and tracks reality (whisper binary ${stt_bin} and model ${stt_model} both present), so the STT-disabled branch is correctly NOT taken; the warning string is still ${warnstate} in the installed app.py for the day one half goes away"
  else
    bad stt-reports-unavailable-not-broken "is_available() is correctly False, but the degradation is not visible: the not-is_available() guard evaluated ${guard} and the 'not available - STT disabled' warning string is ${warnstate} in ${CHRONOA_LIB}/shani_chronoa/app.py — STT goes quiet for a reason nobody can read"
  fi
fi

# ALSO THE OVERLAY-LIVENESS PROOF for this file. With XDG_DATA_HOME exported,
# files.data_home() resolves per call (it is a function, not an import-time
# constant, precisely so a run can be relocated), so model_path MUST land under
# it. On the stale SHIPPED package — built from a commit that hardcoded
# ~/.local/share — it does not, and this goes red. That is why a control run
# without --local-src-chronoa is expected to fail on exactly this line and pass
# everywhere else: it is the line that distinguishes "the overlay is live" from
# "the test is reading an old build".
mp=$(py -c 'from shani_chronoa.stt import WhisperSTT
print(WhisperSTT().model_path)' 2>>"$WORK/stt.err")
case "$mp" in
  "$XDG_DATA_HOME"/*)
    pass stt-model-path-follows-xdg-data-home "model_path ${mp} is under XDG_DATA_HOME (${XDG_DATA_HOME}), so files.data_home() is resolved per call and the --local-src-chronoa overlay is the code under test" ;;
  *)
    bad stt-model-path-follows-xdg-data-home "with XDG_DATA_HOME=${XDG_DATA_HOME} exported, model_path is ${mp:-unset} — outside it. The installed shani_chronoa resolves models from a hardcoded ~/.local/share instead of files.data_home(). Two real causes: this slot has the stale SHIPPED shani-chronoa and the overlay was not applied (--local-src-chronoa=<checkout>), or files.data_home() regressed to a constant. Re-run with the overlay to tell the two apart" ;;
esac

# A PASS about the STATE, deliberately. Both model directories are empty of
# ggml-*.bin today, which is the fact nothing else records and the reason
# Group D's transcription is a SKIP rather than a failure. The day it stops
# being true, this line goes red and points at the check that must be revisited
# (stt-transcribes-speech) instead of leaving the two to drift apart quietly.
model_found=""
for d in "${MODEL_DIRS[@]}"; do
  found=$(ls "$d"/ggml-*.bin 2>/dev/null | head -3)
  [[ -n "$found" ]] && model_found+=" ${found}"
done
if [[ -z "$model_found" ]]; then
  pass stt-no-ggml-model-on-this-install "no ggml-*.bin in ${MODEL_DIRS[0]} or ${MODEL_DIRS[1]} (whisper.cpp models are multi-hundred-MB downloads that no Shanios image profile ships and neither manifest declares), so STT has no model to find on this install"
else
  bad stt-no-ggml-model-on-this-install "a whisper model is now present:${model_found} — the recorded state has changed and the derived branch in stt-transcribes-speech will now attempt a REAL transcription; that check is the one to watch, not this one"
fi

echo "== Group D: the derived skip — transcription, when there is anything to do it with"

if (( have_bin == 0 )); then
  skip stt-transcribes-speech "whisper-cpp not installed; it is an optdepend and no Shanios image profile installs it"
elif (( have_model == 0 )); then
  skip stt-transcribes-speech "no ggml-*.bin model on this install (binary is ${stt_bin}, but neither ${MODEL_DIRS[0]} nor ${MODEL_DIRS[1]} holds a model)"
else
  # Both present: a REAL transcription, not a mocked one. The audio is the same
  # WAV the TTS check just produced, so this costs no extra dependency and no
  # extra download — the stack speaks to itself.
  tr_out=$(py -c 'import sys
from shani_chronoa.stt import WhisperSTT
print(WhisperSTT().transcribe(sys.argv[1]) or "")' "$WAV" 2>"$WORK/tr.err")
  tr_rc=$?
  tr_text=$(printf '%s' "$tr_out" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 120)
  if (( tr_rc != 0 )); then
    bad stt-transcribes-speech "transcribe() raised on a real ${bytes}-byte WAV (rc=${tr_rc}): $(head -3 "$WORK/tr.err" | tr '\n' ' ')"
  elif [[ -z "$tr_text" ]]; then
    bad stt-transcribes-speech "whisper ran on a real ${bytes}-byte WAV and returned no text — either the model is broken or the transcription is silently empty, and an empty transcription fed to the LLM reads as 'the user said nothing'"
  else
    pass stt-transcribes-speech "whisper-cli transcribed the real WAV: \"${tr_text}\" (model ${stt_model})"
  fi
fi

echo "== Group E: the app contract, with no display"

# The RUNNING COMPILED schema, never the XML. A key present in the .xml and
# absent from gschemas.compiled is permanently ungrantable while the XML still
# reads fine, and the failure mode where glib-compile-schemas exits 0 having
# written nothing is invisible to any XML check — this project's own history has
# a whole gschema file silently discarded that way, taking every setting with
# it. These are the keys speech input and perception consent depend on: without
# them the mic button does nothing, and the senses cannot be granted.
VOICE_KEYS=(whisper-model piper-voice language wake-word-enabled wake-word-model
            privacy-mode barge-in-vad-enabled audio-sense-enabled hearing-sense-enabled)
keys=$(gsettings list-keys "$SCHEMA_ID" 2>/dev/null || true)
missing=""
for k in "${VOICE_KEYS[@]}"; do
  grep -qx "$k" <<<"$keys" || missing+=" ${k}"
done
if [[ -z "$missing" ]]; then
  pass schema-declares-voice-keys "all ${#VOICE_KEYS[@]} speech/perception consent keys are in the RUNNING compiled schema $SCHEMA_ID (whisper-model, piper-voice, language, wake-word-enabled, wake-word-model, privacy-mode, barge-in-vad-enabled, audio-sense-enabled, hearing-sense-enabled)"
else
  bad schema-declares-voice-keys "the compiled schema $SCHEMA_ID declares no:${missing} — declared in the XML but absent from gschemas.compiled, so ${missing// /, } is silently ungrantable while the source XML still looks correct. Re-run with --local-src-chronoa (which recompiles the schema in place) to tell an overlay miss apart from a manifest miss"
fi

# The launcher, RUN AS A SUBPROCESS, not `sys.path.insert(0, '.')`. This is not
# ceremony: both usr/bin launchers shipped the entire life of this project
# computing their package path as dirname(dirname(__file__)), which for a script
# at usr/bin/ is usr/ — so `shani-chronoa` raised ModuleNotFoundError: No module
# named 'shani_chronoa' every single time it was invoked directly. Every prior
# verification pass ran code from inside usr/lib/shani-chronoa and never once
# executed the installed launcher, so it survived. Nothing but running this
# binary can catch that class of bug again.
LAUNCHER=/usr/bin/shani-chronoa
if [[ ! -e "$LAUNCHER" ]]; then
  bad launcher-imports-shipped-package "no $LAUNCHER in this slot. Two real causes: this image's package list does not include $PKG, and the overlay for usr/bin was never applied (--local-src-chronoa=<checkout>)"
else
  tout=$(timeout 90 "$LAUNCHER" 2>&1 </dev/null); trc=$?
  if grep -q "No module named .shani_chronoa" <<<"$tout"; then
    bad launcher-imports-shipped-package "$LAUNCHER (rc=${trc}) died with ModuleNotFoundError: $(grep -m1 'No module named' <<<"$tout"). The launcher resolved its own package directory wrongly — the historical bug was dirname(dirname(__file__)) (usr/bin -> usr/) with no 'lib/shani-chronoa' joined on, and it shipped for the whole life of the project because every other test bypassed the launcher"
  elif [[ -z "$tout" ]]; then
    bad launcher-imports-shipped-package "$LAUNCHER (rc=${trc}) produced NO output at all, so this check cannot distinguish a working import from a launcher that exited before saying anything"
  else
    marker="the launcher's own startup log line"
    grep -q 'Starting Shani Chronoa' <<<"$tout" || marker="an error raised after the import chain completed"
    pass launcher-imports-shipped-package "ran the real $LAUNCHER as a subprocess (rc=${trc}, no display in a slot so it stops where the GUI starts) and reached ${marker}: $(tr -d '\n' <<<"$tout" | grep -m1 -E 'Starting Shani Chronoa|Traceback|cannot open display|Gtk-WARNING|Error' | head -c 160)"
  fi
fi

# The same import, in-process this time, with the path the INSTALLED package is
# on rather than the repo's. The module's __file__ is read back so the assertion
# says WHICH copy imported — a green import of a checkout while the installed
# package is broken would otherwise be invisible.
imp=$(py -c 'import shani_chronoa.app as m
print(m.__file__ or "?")' 2>"$WORK/imp.err")
imp_rc=$?
if (( imp_rc != 0 )); then
  bad app-imports-clean "importing shani_chronoa.app failed in the slot's python: $(grep -vE '^  File |^Traceback' "$WORK/imp.err" | head -2 | tr '\n' ' ') (full traceback in the slot's own run)"
else
  pass app-imports-clean "the slot's python imported ${imp} — the whole application module, GTK and senses included, not just the two speech modules"
fi

echo "== Group E2: the senses scheduler — constructed, and actually polling"

# The senses layer had 44 consent switches in Settings and no way to run any of
# them from the GUI: `sense.run()` had exactly two call sites in the whole
# repository, and both were the headless CLI. A green suite said nothing about
# this because the unit tests construct the scheduler and then never start it.
# So this group asks the only two questions that matter, in the real slot, with
# the real image's python: is one built, and does polling one produce a percept.

sched=$(py -c 'from shani_chronoa.app import ChronoaApplication as A
a = A()
a._init_components()
s = getattr(a, "sense_scheduler", None)
print(type(s).__name__ if s is not None else "NONE")
print("running" if (s is not None and s.running) else "stopped")
print("shares-store" if (s is not None and s._store is a.percept_store) else "own-store")
print("has-engine" if getattr(a, "event_engine", None) is not None else "no-engine")' 2>"$WORK/sched.err")
sched_rc=$?
if (( sched_rc != 0 )); then
  bad senses-scheduler-constructed "building the scheduler failed in the slot's python: $(grep -vE '^  File |^Traceback' "$WORK/sched.err" | head -2 | tr '\n' ' ')"
else
  mapfile -t sched_lines <<<"$sched"
  if [[ "${sched_lines[0]:-}" == "AmbientScheduler" ]]; then
    pass senses-scheduler-constructed "the slot's python built a real AmbientScheduler from the installed package, and it is ${sched_lines[1]:-?} after _init_components (constructed-but-not-started is correct: several unit tests call _init_components directly, and start() would put a live poller in the suite)"
  else
    bad senses-scheduler-constructed "the app built ${sched_lines[0]:-no scheduler at all}, so the 44 consent switches in Settings cannot grant anything: $(grep -vE '^  File |^Traceback' "$WORK/sched.err" | head -2 | tr '\n' ' ')"
  fi
  [[ "${sched_lines[2]:-}" == "shares-store" ]] \
    && pass senses-scheduler-shares-the-apps-store "the scheduler writes to the app's own PerceptStore, so a percept a sense deposits reaches the conversation through the context builder the assistant already reads; a second store would be a second, invisible one" \
    || bad senses-scheduler-shares-the-apps-store "the scheduler holds its OWN store (${sched_lines[2]:-unknown}), so what it perceives reaches nothing and the feature is invisible by construction"
  [[ "${sched_lines[3]:-}" == "has-engine" ]] \
    && pass senses-scheduler-has-an-event-engine "an EventEngine is constructed alongside it, so event-trigger rules can fire in the GUI; before this a rule authored through manage_triggers could only ever run under the headless CLI" \
    || bad senses-scheduler-has-an-event-engine "no EventEngine is constructed, so trigger rules authored in the GUI can never fire from the GUI"
fi

# The real proof: poll an ambient sense with no external binary and see whether a
# percept is actually deposited. `filessystems` reads /proc/mounts, which exists
# on any Linux machine and needs no package, so this exercises the real sense,
# the real store and the real deposit path rather than a fixture.
# The real proof: poll an ambient sense and see whether a percept is ACTUALLY
# deposited. `filessystems` reads /proc/self/mountinfo, which exists on any
# Linux machine and needs no package, so this exercises the real sense, the real
# store and the real deposit path rather than a fixture.
#
# Consent is granted for this one process on purpose. `sense_allowed` gates every
# sense behind `<name>-sense-enabled` (config.py: "defaults to false for every
# sense except memory"), so WITHOUT a grant this poll is refused and proves
# nothing about whether the scheduler runs. `SHANI_CHRONOA_CONSENT_GRANT` is the
# mechanism the product itself uses for exactly this: it names ONE key, is read
# per-call from the environment, and needs neither dconf nor a D-Bus session bus
# (which a slot-test has no bus for) nor a write to the installed schema.
#
# Granting consent is also what makes this check able to FAIL. A refusal used to
# be accepted here as a pass, on the theory that "a refusal that explains itself
# is correct behaviour" - but that only proves the scheduler was CONSTRUCTED, not
# that it ever polled anything. Every branch below now demands a deposited
# percept; anything else is a failure.
SHANI_CHRONOA_CONSENT_GRANT=filesystems-sense-enabled \
polled=$(SHANI_CHRONOA_CONSENT_GRANT=filesystems-sense-enabled py -c '
import os
os.environ["SHANI_CHRONOA_CONSENT_GRANT"] = "filesystems-sense-enabled"
from shani_chronoa.app import ChronoaApplication as A
a = A()
a._init_components()
sch = a.sense_scheduler
names = sorted(getattr(sch, "_senses", {}))
r = sch.poll("filessystems")
# key=value lines: positional parsing of this stdout is how the previous version
# of this check came to read a consent refusal as a missing sense.
print("ok=%s" % getattr(r, "ok", None))
print("percept=%s" % (getattr(r, "percept", None) is not None))
print("denied=%s" % getattr(r, "denied", None))
print("suppressed=%s" % getattr(r, "suppressed", None))
print("reason=%s" % (getattr(r, "reason", "") or ""))
print("sense=%s" % getattr(r, "name", ""))
print("registered=%d" % len(names))
print("has_filesystems=%s" % ("filesystems" in names))' 2>"$WORK/poll.err")
poll_rc=$?
if (( poll_rc != 0 )); then
  bad senses-a-poll-really-runs "polling a real sense raised in the slot: $(grep -vE '^  File |^Traceback' "$WORK/poll.err" | head -2 | tr '\n' ' ')"
else
  declare -A P=()
  while IFS='=' read -r k v; do [[ -n "$k" ]] && P["$k"]="$v"; done <<<"$polled"
  if [[ "${P[ok]:-}" == "True" && "${P[percept]:-}" == "True" ]]; then
    pass senses-a-poll-really-runs "polling 'filessystems' inside the slot deposited a REAL percept through the app's own store (registered=${P[registered]:-?}) - so the scheduler is not merely constructible, it runs; consent was granted for this process only"
  elif [[ "${P[ok]:-}" == "True" ]]; then
    bad senses-a-poll-really-runs "poll() reported ok=True but deposited no percept (suppressed=${P[suppressed]:-?}, reason='${P[reason]:-}'). An ok poll that stored nothing is not a working scheduler - PerceptStore saw no change to record"
  elif [[ "${P[has_filesystems]:-}" != "True" ]]; then
    bad senses-a-poll-really-runs "the scheduler holds no 'filesystems' sense (registered=${P[registered]:-?}), so nothing was polled at all. A refusal because the sense is MISSING is not a consent refusal and must never read as a pass - this is the false-clean-answer shape this file exists to catch"
  else
    bad senses-a-poll-really-runs "polling 'filessystems' with consent GRANTED still did not deposit a percept: ok=${P[ok]:-?} denied=${P[denied]:-?} reason='${P[reason]:-}' (registered=${P[registered]:-?}). Consent is not the excuse here - it was opened for this process - so this is a real failure of the poll/deposit path, not a correct refusal"
  fi
  unset P
fi

echo "== Group F: the snap question, as a standing guard rather than a note"

if (( ! PKG_META )); then
  skip whisper-cpp-is-optional-not-required "no installed $PKG to read, so whether whisper-cpp is declared optional cannot be determined on this slot (see chronoa-package-installed). On a real Shanios image $PKG IS pacman-installed and this assertion answers"
elif grep -qxF 'whisper-cpp' <<<"$OPTS" && ! grep -qxF 'whisper-cpp' <<<"$REQS"; then
  pass whisper-cpp-is-optional-not-required "whisper-cpp is an optdepend of $PKG and is NOT a hard depend, which is what lets the app ship and boot with STT simply absent"
else
  if grep -qxF 'whisper-cpp' <<<"$REQS"; then
    bad whisper-cpp-is-optional-not-required "whisper-cpp is now a HARD depend of $PKG. The moment it is, a user without it gets a half-configured assistant whose mic button cannot work, and the 'STT disabled' degradation this file asserts above becomes unreachable. Nothing in the design needs this: espeak-ng already guarantees TTS and whisper.cpp has never shipped in a Shanios image. Put it back in optdepends"
  else
    bad whisper-cpp-is-optional-not-required "whisper-cpp is not listed as an optdepend either (read from $REQ_SRC), so the reason STT is absent is undeclared — a reader cannot tell an intentional optional component from a forgotten dependency"
  fi
fi

# On the maintainer's dev box a snap DOES supply a real whisper-cli, at
# /snap/whisper-cpp/1043/bin/whisper-cli, and it is outside PATH — so a
# host-side check that "sees" whisper working is looking at a package Shanios
# does not depend on at all, and snapd is not in any Shanios manifest. Two
# assertions, so that cannot be mistaken for the install path: nothing named
# whisper-cli resolves inside the slot, and no chronoa code path reaches into
# /snap. (The literal "/snap" is matched with a delimiter, so the numerous
# "snapshots" senses and gsettings keys in this codebase do not trip it.)
snap_bin=$(command -v whisper-cli 2>/dev/null || true)
snap_refs=$(grep -rInE "/snap(/|[\"']|$)" "$CHRONOA_LIB" /usr/bin/shani-chronoa* 2>/dev/null | head -3)
snap_why=""
case "$snap_bin" in
  /snap/*) snap_why+="whisper-cli resolves to ${snap_bin}, a snap: snapd is not a Shanios dependency, so this binary is not part of the install path being tested; " ;;
esac
[[ -n "$snap_refs" ]] && snap_why+="the installed chronoa source references /snap: $(tr '\n' ' ' <<<"$snap_refs" | head -c 160); "
if [[ -z "$snap_why" ]]; then
  pass snap-is-not-a-shanios-path "no whisper-cli on PATH inside the slot (${snap_bin:-none}) and no /snap reference anywhere in the installed package or its launchers, so a snap-supplied whisper on a developer machine cannot be mistaken for the Shanios install path"
else
  bad snap-is-not-a-shanios-path "${snap_why% }"
fi

echo "== probe done"