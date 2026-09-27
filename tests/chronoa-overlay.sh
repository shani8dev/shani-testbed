#!/bin/bash
# A check of the harness itself: lib/chronoa.sh's source overlay, against a
# throwaway "merged slot" tree instead of a real slot.
#
# This exists because the overlay's fragile part is not the copying, it is the
# gschemas.compiled rebuild — the step whose failure mode you cannot see.
# Dropping a new .xml next to an existing compiled blob changes nothing, and
# glib-compile-schemas is all-or-nothing and can exit 0 having written nothing.
# Chronoa's own AGENTS.md records a whole gschema file being silently discarded
# that way, taking every setting with it. So the compile is exercised for real
# here, on a real schema directory, and its effect is verified by reading the
# consent keys back out of the COMPILED blob (GSETTINGS_SCHEMA_DIR) rather than
# out of the XML.
#
# Runs on the host or in the builder container; needs glib-compile-schemas, and
# gsettings for the read-back. Skips, loudly, if glib is absent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL %s -- %s\n' "$1" "$2"; fail=$((fail+1)); }

command -v glib-compile-schemas >/dev/null 2>&1 || {
  echo "SKIP: glib-compile-schemas is not available here (this check compiles a real schema)"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The globals lib/chronoa.sh and the overlay helpers read, plus the two commands
# they call. Nothing else from the harness is needed — _overlay_one is
# deliberately not used (see its own comment in lib/chronoa.sh).
export TESTBED_ROOT="$ROOT"
export NSPAWN_WORK="$TMP/work"
mkdir -p "${NSPAWN_WORK}/merged" "${NSPAWN_WORK}/upper"
log() { printf '       %s\n' "$*"; }
die() { printf '       die(): %s\n' "$*"; exit 9; }
_local_src_record() { echo "${NSPAWN_WORK}/.local-src-overlaid"; }
# shellcheck source=/dev/null
source "${ROOT}/lib/chronoa.sh"

# --- a stand-in Chronoa checkout -------------------------------------------
SRC="$TMP/checkout"
mkdir -p "${SRC}/usr/bin" \
         "${SRC}/usr/lib/shani-chronoa/shani_chronoa/senses/__pycache__" \
         "${SRC}/usr/share/glib-2.0/schemas" "${SRC}/usr/share/applications"
printf '#!/usr/bin/env python3\nprint("hi")\n' > "${SRC}/usr/bin/shani-chronoa-sense"
printf '#!/usr/bin/env python3\n' > "${SRC}/usr/bin/shani-chronoa"
chmod 755 "${SRC}/usr/bin/shani-chronoa-sense"
printf '"""pkg"""\n' > "${SRC}/usr/lib/shani-chronoa/shani_chronoa/__init__.py"
printf '"""ocr"""\n' > "${SRC}/usr/lib/shani-chronoa/shani_chronoa/senses/ocr.py"
# Bytecode the developer left behind: it must not be copied...
printf 'developer-era bytecode\n' \
  > "${SRC}/usr/lib/shani-chronoa/shani_chronoa/senses/__pycache__/ocr.cpython-312.pyc"
cat > "${SRC}/usr/share/glib-2.0/schemas/org.shani.chronoa.gschema.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="org.shani.chronoa" path="/org/shani/chronoa/">
    <key name="ocr-sense-enabled" type="b"><default>false</default></key>
    <key name="memory-sense-enabled" type="b"><default>false</default></key>
  </schema>
</schemalist>
XML
printf '[Desktop Entry]\nName=Chronoa\n' > "${SRC}/usr/share/applications/shani-chronoa.desktop"

# What the "image" already has: a compiled schema blob, and a .pyc of its own.
M="${NSPAWN_WORK}/merged"
mkdir -p "${M}/usr/share/glib-2.0/schemas" \
         "${M}/usr/lib/shani-chronoa/shani_chronoa/senses/__pycache__"
printf 'OLD' > "${M}/usr/share/glib-2.0/schemas/gschemas.compiled"
cp "${M}/usr/share/glib-2.0/schemas/gschemas.compiled" "${TMP}/image-blob"
printf 'image-era bytecode\n' \
  > "${M}/usr/lib/shani-chronoa/shani_chronoa/senses/__pycache__/ocr.cpython-312.pyc"

# --- 1. a directory that is not a Chronoa checkout is refused --------------
out=$(_chronoa_src_dir "$TMP/not-a-checkout" 2>&1); rc=$?
if (( rc != 0 )) && grep -q 'no usr/lib/shani-chronoa/shani_chronoa/__init__.py' <<<"$out"; then
  ok "rejects a directory that is not a Chronoa checkout"
else
  no "rejects a directory that is not a Chronoa checkout" "rc=${rc}, got: ${out}"
fi

# --- 2. the happy path -----------------------------------------------------
if _overlay_chronoa_src blue "$SRC" >"$TMP/overlay.log" 2>&1; then
  ok "_overlay_chronoa_src succeeds on a real checkout"
else
  no "_overlay_chronoa_src succeeds on a real checkout" "$(tail -3 "$TMP/overlay.log")"
  printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
  exit 1
fi

# Permission bits, NOT [[ -x ]]: run_in_container.sh mounts /tmp as a Docker
# tmpfs, which is noexec, and on this kernel even root's access(X_OK) fails
# there — so a real 0755 launcher reads as "not executable" and the check would
# report a defect that does not exist. The bits are what _chronoa_overlay_file
# actually sets, so assert those.
mode=$(stat -c %a "${M}/usr/bin/shani-chronoa-sense" 2>/dev/null)
[[ "$mode" == 755 ]] \
  && ok "usr/bin/shani-chronoa-sense is overlaid mode 755" \
  || no "usr/bin/shani-chronoa-sense is overlaid mode 755" "mode=${mode:-missing}"
[[ -f "${M}/usr/lib/shani-chronoa/shani_chronoa/senses/ocr.py" ]] \
  && ok "the Python package is overlaid" \
  || no "the Python package is overlaid" "senses/ocr.py missing"
if find "${M}/usr/lib/shani-chronoa" -name '*.pyc' -print -quit | grep -q .; then
  no "no bytecode reaches the slot" "found: $(find "${M}/usr/lib/shani-chronoa" -name '*.pyc' | tr '\n' ' ')"
else
  ok "no bytecode reaches the slot (source .pyc skipped, image-era .pyc removed)"
fi

# --- 3. the compiled schema, which is the whole point ----------------------
if cmp -s "${M}/usr/share/glib-2.0/schemas/gschemas.compiled" "${TMP}/image-blob" 2>/dev/null; then
  no "gschemas.compiled was rebuilt" "the image's own blob is still there, byte for byte"
elif command -v gsettings >/dev/null 2>&1; then
  keys=$(GSETTINGS_SCHEMA_DIR="${M}/usr/share/glib-2.0/schemas" gsettings list-keys org.shani.chronoa 2>/dev/null)
  if grep -qx 'ocr-sense-enabled' <<<"$keys"; then
    ok "gschemas.compiled rebuilt; ocr-sense-enabled readable from the RUNNING schema"
  else
    no "gschemas.compiled rebuilt; ocr-sense-enabled readable" "read back: $(tr '\n' ' ' <<<"$keys")"
  fi
else
  ok "gschemas.compiled was rebuilt (gsettings absent, so the read-back was skipped)"
fi

# --- 4. every written path is recorded, so the next run reverts ------------
rec=$(_local_src_record)
missing=""
for want in usr/bin/shani-chronoa-sense \
            usr/lib/shani-chronoa/shani_chronoa/senses/ocr.py \
            usr/share/glib-2.0/schemas/org.shani.chronoa.gschema.xml \
            usr/share/glib-2.0/schemas/gschemas.compiled; do
  grep -qx "$want" "$rec" || missing+=" ${want}"
done
[[ -z "$missing" ]] \
  && ok "revert record lists every written path (launcher, package, schema xml, compiled schema)" \
  || no "revert record lists every written path" "not recorded:${missing}"

# --- 5. the real _revert_local_src_overlay really undoes it -----------------
# Sourced straight out of lib/nspawn.sh rather than reimplemented: this is the
# code that has to undo the overlay, and a copy of it would prove nothing.
eval "$(sed -n '/^_revert_local_src_overlay()/,/^}/p' "${ROOT}/lib/nspawn.sh")"
rm -rf "${NSPAWN_WORK}/upper"; mkdir -p "${NSPAWN_WORK}/upper"
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  mkdir -p "${NSPAWN_WORK}/upper/$(dirname "$rel")"
  printf 'OVERLAY\n' > "${NSPAWN_WORK}/upper/${rel}"
done < "$rec"
_revert_local_src_overlay
left=""
for rel in $(cat "$rec"); do
  [[ -e "${NSPAWN_WORK}/upper/${rel}" || -L "${NSPAWN_WORK}/upper/${rel}" ]] && left+=" ${rel}"
done
[[ -z "$left" ]] \
  && ok "revert removes every recorded path from upper/ (the image's own copies become visible again)" \
  || no "revert removes every recorded path from upper/" "still present:${left}"
[[ ! -f "$(_local_src_record 2>/dev/null)" ]] \
  && ok "revert clears the record file, so a second run does not repeat it" \
  || no "revert clears the record file" "still present"

# The half that only a real overlayfs can show: with the upper entry gone, the
# LOWER layer's file is what a reader sees. Proved here for real when the check
# is running privileged (inside the builder container, or as root); skipped
# loudly otherwise, because a plain directory cannot reproduce it and a fake
# assertion would be worse than none.
LOWER="$TMP/lower"; OV="$TMP/ov"
mkdir -p "${LOWER}/usr/share/glib-2.0/schemas"
printf 'OLD' > "${LOWER}/usr/share/glib-2.0/schemas/gschemas.compiled"
mkdir -p "${OV}/upper/usr/share/glib-2.0/schemas" "${OV}/work" "$TMP/ovmerged"
printf 'OVERLAY\n' > "${OV}/upper/usr/share/glib-2.0/schemas/gschemas.compiled"
if mount -t overlay overlay -o "lowerdir=${LOWER},upperdir=${OV}/upper,workdir=${OV}/work" "$TMP/ovmerged" 2>/dev/null; then
  BLB="${TMP}/ovmerged/usr/share/glib-2.0/schemas/gschemas.compiled"
  if cmp -s "$BLB" "${TMP}/image-blob"; then
    no "overlayfs: while upper has the file, upper wins" "the lower blob is what a reader sees"
  else
    ok "overlayfs: while upper has the file, upper wins"
  fi
  umount "$TMP/ovmerged" 2>/dev/null || umount -l "$TMP}/ovmerged" 2>/dev/null
  # Removing from upper/ directly does NOT flip a live mount (overlayfs caches
  # the copy-up), so the "image's own blob is restored" property is only
  # observable on a FRESH mount — which is exactly how the real slot sees it:
  # revert runs at end of slot-test, the slot is torn down, and the next boot
  # mounts a clean overlay. Reproduce that here.
  rm -f "${OV}/upper/usr/share/glib-2.0/schemas/gschemas.compiled"
  mount -t overlay overlay -o "lowerdir=${LOWER},upperdir=${OV}/upper,workdir=${OV}/work" "$TMP/ovmerged" 2>/dev/null
  if cmp -s "$BLB" "${TMP}/image-blob"; then
    ok "overlayfs: on a fresh mount after revert, the lower layer's own blob is what a reader sees"
  else
    no "overlayfs: fresh mount after revert reveals the lower blob" "got: $(head -c 16 "$BLB")"
  fi
  umount "$TMP/ovmerged" 2>/dev/null || umount -l "$TMP}/ovmerged" 2>/dev/null
else
  printf 'SKIP overlayfs lower-layer check (needs root; run this in the builder container)\n'
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
(( fail == 0 )) || exit 1
