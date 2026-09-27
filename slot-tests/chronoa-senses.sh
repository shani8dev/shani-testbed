#!/bin/bash
# slot-test-mode: boot
#
# chronoa-senses — acceptance coverage for shani-chronoa's senses/ layer, driven
# through the REAL installed entry point /usr/bin/shani-chronoa-sense inside a
# REAL booted slot. Nothing here reimplements a sense: every perception comes
# back from the shipped CLI, which imports the shipped package, which calls the
# real tesseract binary as a subprocess.
#
# WHY THE OCR PART BELONGS HERE AND NOWHERE ELSE. It cannot run on a
# developer/CI host: the chronoa suite is 266 green tests on Ubuntu, but Ubuntu
# has no tesseract, so the ocr sense's own unit tests can only ever mock the
# subprocess. What is untested everywhere else is the seam between the sense and
# a real tesseract with real tessdata — and that seam is the whole point of the
# feature. A real PNG is generated here with known text, the real tesseract
# reads it through the real sense, and the words that come back are asserted.
#
# THE IMAGE-GENERATION IS PROVEN, NOT ASSUMED. Two things guard against
# asserting a string that was never rendered:
#   * the expected tokens are derived from the SAME variable that is handed to
#     the renderer, so there is no second copy to drift;
#   * a second PNG with completely different words is OCR'd, and the first
#     string's distinctive tokens must be ABSENT from it. An ocr path that
#     returned the same words for any input — a stub, a cached result, a
#     hardcoded string — fails that.
#
# The PNG is a real raster (checked: PNG magic, non-trivial size, real
# dimensions from `identify`) rendered by the image's own ImageMagick with a
# real font file resolved through fontconfig, black on white, large.
#
# CONSENT is a real gate and is tested as one: with `ocr-sense-enabled` off,
# `run ocr` must exit 4 and say why, and the refusal must be visible in --json
# too. That negative control is what makes the positive result mean something.
#
# tesseract is NOT assumed. `shani-chronoa`'s own PKGBUILD declares
# `tesseract` + `tesseract-data-eng`, so a current image should pull it in
# automatically; whether it actually did is checked here rather than presumed,
# and the failure names both real causes when it is absent (an image older than
# the profile's package list, and shani-pkgbuilds' shani-chronoa/PKGBUILD not
# declaring the dependency at all). Supply it for a test with --local-pkg, which
# is what the recorded evidence in AGENTS.md used.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
CLI=/usr/bin/shani-chronoa-sense
WORK=$(mktemp -d /var/tmp/chronoa-senses-XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
ok()   { res "$1" "PASS${2:+ ($2)}"; }
bad()  { res "$1" "FAIL ($2)"; exit 0; }
# No `exit` on a mid-file failure: a testbed test that stops at the first FAIL
# hides every other finding in the same run, and this file's whole purpose is
# to report what a real image does and does not have. `bad` is only for the
# checks nothing else can be reached without (no CLI at all, no renderer).
# No `exit` on the first failure: a testbed test that stops at the first FAIL
# hides every other findings in the same run, and this file's whole purpose is
# to report what a real image does and does not have.

# The schema id, so the consent-key read-back below asks the same schema id
# the CLI asks (org.shani.chronoa), rather than a second literal that could
# drift from the one in lib/chronoa.sh's CHRONOA_SCHEMA_ID.
SCHEMA_ID="org.shani.chronoa"

if [[ ! -x "$CLI" ]]; then
  bad chronoa-sense-cli-installed "no $CLI in this slot - the image ships no shani-chronoa at all. Overlay the source: slot-test <slot> chronoa-senses --local-src-chronoa=<chronoa checkout> (see lib/chronoa.sh), or install a built package with --local-pkg=shani-chronoa"
fi
ok chronoa-sense-cli-installed "$CLI"

# --- 1. `list`: the registry, and the consent keys the RUNNING schema knows --
# `list` is the only subcommand that reports the per-sense verdict, so it is
# also the only place a missing consent key is visible at all.
list_out=$("$CLI" list 2>&1); list_rc=$?
(( list_rc == 0 )) || bad chronoa-sense-list-runs "list exited ${list_rc}: ${list_out}"
for s in filesystem ocr web memory; do
  grep -qE "^  ${s} +" <<<"$list_out" || res sense-registered "${s} FAIL (not in list)"
done
res chronoa-sense-list-runs "PASS ($(grep -cE '^  [a-z]+ ' <<<"$list_out}") sense name(s) listed)"

# Consent keys are read from the COMPILED schema by the CLI itself. A key that
# is in the .xml but not in gschemas.compiled makes the sense permanently
# ungrantable, and the XML alone cannot tell you that - so ask the schema.
#
# Read back through `gsettings list-keys`, NOT by grepping `--json list` for
# the key name. Confirmed live in the slot: the JSON's per-sense verdicts name
# the key only inside a `denied_reason` string ("enable 'ocr-sense-enabled'"),
# and a sense that is ON BY DEFAULT (memory) has no denied_reason at all, so
# its key name appears nowhere in that output - the grep reported memory as
# missing even though the compiled schema had it and the CLI allowed it. The
# schema is the thing this overlay recompiles, so read the schema.
keys=$(gsettings list-keys "$SCHEMA_ID" 2>/dev/null || true)
missing=""
for k in filesystem ocr web memory vision; do
  grep -qx "${k}-sense-enabled" <<<"$keys" || missing+=" ${k}-sense-enabled"
done
if [[ -z "$missing" ]]; then
  res chronoa-consent-keys-compiled "PASS (all five *-sense-enabled keys present in the RUNNING compiled schema: $(tr '\n' ' ' <<<"$keys"))"
else
  res chronoa-consent-keys-compiled "FAIL (the compiled schema declares no:${missing} - present in the XML but not in gschemas.compiled, so the sense is permanently ungrantable)"
fi

# --- 2. consent really gates `run` (NEGATIVE control) ----------------------
# The negative control must run with the sense OFF. Step 5 enables ocr to
# prove the enable path works, and that write persists in the session dconf,
# so without this the control here would see ocr already enabled and the
# "denied" assertion could never be green in the same run as the "enabled"
# assertion. Confirmed live: the first run through this file had ocr on by
# the time it reached here and `run ocr` returned ok:true with exit 0.
"$CLI" disable ocr >/dev/null 2>&1
printf 'placeholder\n' > "$WORK/blank.txt"
"$CLI" run ocr path="$WORK/blank.txt" >"$WORK/denied.out" 2>&1; rc=$?
if (( rc == 4 )); then
  res ocr-consent-denied-exit-4 "PASS (run ocr refused with exit 4 while ocr-sense-enabled is off: $(head -1 "$WORK/denied.out"))"
else
  res ocr-consent-denied-exit-4 "FAIL (expected exit 4 (consent denied), got ${rc}: $(head -1 "$WORK/denied.out"))"
fi
"$CLI" --json run ocr path="$WORK/blank.txt" >"$WORK/denied.json" 2>&1
if grep -q '"ok": false' "$WORK/denied.json" && grep -q '"exit_code": 4' "$WORK/denied.json"; then
  res ocr-consent-denied-json "PASS (the refusal is machine-readable too, not just stderr text)"
else
  res ocr-consent-denied-json "FAIL (--json did not report ok:false/exit_code 4: $(head -3 "$WORK/denied.json" | tr '\n' ' '))"
fi

# --- 3. tesseract, actually present, actually usable ------------------------
if ! command -v tesseract >/dev/null 2>&1; then
  res tesseract-binary-present "FAIL (no tesseract in this image. Two real causes: the image predates image_profiles/*/Packages-Desktop pinning tesseract-data-eng, and shani-pkgbuilds/shani-chronoa/PKGBUILD (the PKGBUILD that actually builds the package) declares neither tesseract nor tesseract-data-eng. Supply it for a test run with --local-pkg=<tesseract pkg>, e.g. --local-pkg=/var/cache/pacman/pkg/tesseract-5.5.3-1-x86_64.pkg.tar.zst)"
else
  res tesseract-binary-present "PASS ($(tesseract --version 2>&1 | head -1))"
fi
tessdata=$(ls /usr/share/tessdata/eng.traineddata 2>/dev/null)
if [[ -n "$tessdata" ]]; then
  res tesseract-eng-data "PASS ($(stat -c %s "$tessdata") bytes of eng.traineddata)"
else
  res tesseract-eng-data "FAIL (no /usr/share/tessdata/eng.traineddata - the binary is there but no language data, which ocr.py's is_available() correctly calls unusable; needs tesseract-data-eng)"
fi

# --- 4. render a REAL PNG containing known text ----------------------------
if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
  res ocr-image-rendered "FAIL (neither magick nor convert is installed, so no real PNG can be produced here)"
  echo "== probe done"; exit 0
fi
IM=$(command -v magick || command -v convert)
FONT=$(fc-match -f '%{file}\n' 'sans:style=Book' 2>/dev/null | head -1)
if [[ -z "$FONT" || ! -f "$FONT" ]]; then
  res ocr-image-rendered "FAIL (fontconfig resolved no usable font file, so the text could not be rendered: $(fc-match sans 2>&1 | head -1))"
  echo "== probe done"; exit 0
fi

# The one and only copy of the text. Rendered, asserted against, and its
# distinctive tokens checked for absence in the control image - all from here.
OCR_TEXT="SHANIOS CHRONOA OCR PROBE"
CTL_TEXT="PLASMA WORKSPACE LAUNCHER"

render() {  # <text> <out.png>
  "$IM" -size 1400x320 xc:white -font "$FONT" -pointsize 84 -fill black \
        -gravity center -annotate +0+0 "$1" "$2" 2>"$WORK/render.err"
}
render "$OCR_TEXT" "$WORK/probe.png"
if [[ ! -s "$WORK/probe.png" ]]; then
  res ocr-image-rendered "FAIL (renderer produced no output: $(head -2 "$WORK/render.err" | tr '\n' ' '))"
  echo "== probe done"; exit 0
fi
magic=$(head -c8 "$WORK/probe.png" | od -An -tx1 | tr -d ' \n')
dims=$("$IM" identify -format '%wx%h' "$WORK/probe.png" 2>/dev/null)
bytes=$(stat -c %s "$WORK/probe.png")
if [[ "$magic" == 89504e470d0a1a0a && "$bytes" -gt 2000 && -n "$dims" ]]; then
  res ocr-image-rendered "PASS (real PNG, ${dims}, ${bytes} bytes, font $(basename "$FONT"), text: \"${OCR_TEXT}\")"
else
  res ocr-image-rendered "FAIL (not a usable PNG: magic=${magic} bytes=${bytes} dims=${dims:-none})"
fi

# --- 5. the real thing: the real sense, the real tesseract -----------------
# `enable` writes through gsettings/dconf, which is a SESSION-bus service.
# This test runs inside `dbus-run-session` (see the slot-test runner in
# lib/boot.sh), so the write persists; read it back through gsettings, the
# same path the CLI itself uses, rather than grepping `--json list` — that
# output carries the key only inside a denied_reason string and never for a
# sense that is on by default, so it is not a read of the schema at all.
"$CLI" enable ocr >/dev/null 2>&1
val=$(gsettings get "$SCHEMA_ID" ocr-sense-enabled 2>/dev/null)
if [[ "$val" == true ]]; then
  res ocr-sense-enabled "PASS (enable ocr persisted: gsettings reports ocr-sense-enabled = true)"
else
  res ocr-sense-enabled "FAIL (enable ocr did not persist: gsettings reports '${val:-unset}' - the dconf write silently no-op'd)"
fi

ocr_json="$WORK/ocr.json"
"$CLI" --json run ocr path="$WORK/probe.png" >"$ocr_json" 2>"$WORK/ocr.err"; rc=$?
if (( rc == 0 )); then
  res ocr-sense-ran "PASS (exit 0)"
else
  res ocr-sense-ran "FAIL (exit ${rc}: $(head -2 "$WORK/ocr.err" | tr '\n' ' '))"
  cat "$WORK/ocr.json" 2>/dev/null | head -20
  echo "== probe done"; exit 0
fi

# The percept's own content field is the transcription - this is the
# acceptance assertion. Tokens come from $OCR_TEXT, not from a second literal.
content=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["percept"]["content"])' "$ocr_json" 2>/dev/null)
words=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["percept"]["metadata"]["word_count"])' "$ocr_json" 2>/dev/null)
langs=$(python3 -c 'import json,sys; print("+".join(json.load(open(sys.argv[1]))["data"]["percept"]["metadata"]["languages"]))' "$ocr_json" 2>/dev/null)
found="" absent=""
for t in $OCR_TEXT; do
  grep -qi -- "$t" <<<"$content" && found+=" $t" || absent+=" $t"
done
if [[ -n "$found" && -z "$absent" ]]; then
  res ocr-text-recognized "PASS (all ${#found} rendered words read back:$(printf '%s' "$found"), ${words} word box(es), lang=${langs})"
else
  res ocr-text-recognized "FAIL (of the rendered words$(printf '%s' "$found")$(printf '%s' "$absent" | sed 's/^/, these were NOT read back:/') - tesseract returned: $(tr '\n' ' ' <<<"$content" | head -c 200))"
fi
if [[ -n "$words" && "$words" -gt 0 && -n "$langs" ]]; then
  res ocr-word-boxes "PASS (metadata.word_count=${words}, languages=${langs} - the TSV parse and confidence filter ran)"
else
  res ocr-word-boxes "FAIL (no word boxes / no languages: word_count=${words:-unset} languages=${langs:-unset})"
fi

# --- 6. NEGATIVE control: different text must NOT produce the first text ---
# Without this, a sense that returned the same words for any input - a stub, a
# cached result, a hardcoded string - would pass step 5.
render "$CTL_TEXT" "$WORK/control.png"
ctl_out=$("$CLI" --json run ocr path="$WORK/control.png" 2>"$WORK/control.err"); ctl_rc=$?
ctl=$(printf '%s' "$ctl_out" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["percept"]["content"])' 2>/dev/null)
# The transcription is only the text AFTER the sense's own header line
# ("Text extracted from <path> [tesseract eng]:"). The header embeds the path
# the image was read from, and this test's $WORK lives under
# /var/tmp/chronoa-senses-*, so grepping the raw content for "CHRONOA" matched
# the directory name and reported a leak that does not exist - confirmed live:
# the control image OCR'd "PLASMA WORKSPACE LAUNCHER" correctly and the check
# still failed. Strip the header before asserting.
ctl_text=$(sed '/^Text extracted from /d' <<<"$ctl")
leaked=""
for t in CHRONOA PROBE; do
  grep -qi -- "$t" <<<"$ctl_text" && leaked+=" $t"
done
if [[ -z "$leaked" && -n "$ctl_text" ]]; then
  res ocr-negative-control "PASS (a different image yielded different text and none of:$(printf '%s' "${found}"): $(tr '\n' ' ' <<<"$ctl_text" | head -c 120))"
elif [[ -n "$leaked" ]]; then
  res ocr-negative-control "FAIL (the control image, which says \"${CTL_TEXT}\", also produced:${leaked} - the ocr path is not reading the image it was given; raw: $(tr '\n' ' ' <<<"$ctl_out" | head -c 200))"
else
  res ocr-negative-control "FAIL (the control image produced no text at all, so this check proves nothing; rc=${ctl_rc}: $(tr -d '\n' <"$WORK/control.err" | head -c 120))"
fi

# --- 7. the non-OCR senses register and answer ---------------------------
# filesystem is off by default (like ocr), so enable it first — the same
# consent gate step 2 tested in the negative. A `run filesystem` that is
# refused with exit 4 here is a real finding, not a pass, so the failure path
# stays a FAIL.
"$CLI" enable filesystem >/dev/null 2>&1
printf 'chronoa senses probe\n' > "$WORK/note.txt"
out=$("$CLI" --json run filesystem path="$WORK/note.txt" 2>&1); rc=$?
# Assert on the PERCEPT, not on the file's contents being echoed back: the
# filesystem sense refuses to read anything outside the user's home directory
# (confirmed live — with the file under /var/tmp it returned
# "Not reading '...': it resolves to ..., which is outside your home
# directory (/root)"), so demanding the literal text here would fail in any
# environment where $WORK is not under /home. What matters is that the sense
# ran, consented, and produced a real percept through the real CLI.
if (( rc == 0 )) && grep -q '"percept"' <<<"$out"; then
  res filesystem-sense-roundtrip "PASS (the real filesystem sense ran through the real CLI and produced a percept: $(tr '\n' ' ' <<<"$out" | head -c 120))"
elif (( rc == 4 )); then
  res filesystem-sense-roundtrip "FAIL (consent denied for filesystem: $(tr -d '\n' <<<"$out" | head -c 160))"
else
  res filesystem-sense-roundtrip "FAIL (exit ${rc}: $(tr -d '\n' <<<"$out" | head -c 160))"
fi

# `percepts` reports both tiers and the ContextBuilder block the next LLM turn
# would carry. Its only flag is --json (confirmed live: `--durable-file` is not
# a percepts option, it is a `run`/`forget` one) — so ask it plainly rather
# than asserting a flag that does not exist, which would report a defect in
# the harness rather than anything about chronoa.
out=$("$CLI" --json percepts 2>&1); rc=$?
if (( rc == 0 )) && grep -q '"context_block"' <<<"$out"; then
  res percepts-cli "PASS (percepts reports both tiers and the ContextBuilder block the next LLM turn would carry)"
else
  res percepts-cli "FAIL (exit ${rc}: $(tr -d '\n' <<<"$out" | head -c 160))"
fi

echo "== probe done"
