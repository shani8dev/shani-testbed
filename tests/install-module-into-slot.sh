#!/bin/bash
# Install the CURRENT 99shanios dracut module from the working tree into a real
# slot subvolume, so `regen-uki.sh` can rebuild that slot's UKI from it.
#
#   tests/install-module-into-slot.sh <slot> [<slot>...]      (in the builder
#                                                            container, as root)
#
# WHY IT IS NOT A ONE-LINE `cp`. Four separate things went wrong doing this by
# hand, and each failed in a way that reported success:
#
#   1. `enter` boots the nspawn OVERLAY, not the subvolume. A stale copy of the
#      module in `nspawn-overlay-<slot>/upper/usr/lib/dracut/modules.d/99shanios`
#      shadows whatever was just written into the subvolume — so a regeneration
#      can rebuild from the OLD module, report success, and produce a UKI that
#      comes out SMALLER than the one it replaced. Removing the overlay's copy is
#      the caller's job; this script does the subvolume.
#   2. Subvolume flags live in the PARENT, so `btrfs property set ro false` on a
#      mounted subvolume fails with "Could not set subvolume flags: Read-only
#      file system". subvolid=5 must be mounted writable first — the order
#      shani-deploy itself uses.
#   3. `mount -o rw` did not always give a writable ESP/subvolume here; the
#      mount came up read-only and `sed -i`/`cp` failed on their temp files,
#      leaving entries half-written. So this refuses if the result is not
#      writable, rather than reporting a partial copy.
#   4. Existence is not verification. A silent copy failure once regenerated a
#      UKI from the old module. This compares the CONTENT it wrote against the
#      source, per file.
set -uo pipefail
REPO="${SHANIOS_REPO_ROOT:-/work}"
SRC="$REPO/image_profiles/shared/overlay/rootfs/usr/lib/dracut/modules.d/99shanios"
SLOTS=("$@")

[[ -d "$SRC" ]] || { echo "no module source at $SRC (set SHANIOS_REPO_ROOT)" >&2; exit 2; }
[[ ${#SLOTS[@]} -gt 0 ]] || { echo "usage: install-module-into-slot.sh <slot> [<slot>...]" >&2; exit 2; }

W=/tmp/shani-mod-slot; TOP=/tmp/shani-mod-top
mkdir -p "$W" "$TOP"
FREE=$(losetup -f); N=${FREE#/dev/loop}
[[ -e "$FREE" ]] || { d=$(cat /sys/block/loop${N}/dev 2>/dev/null) && mknod "$FREE" b "${d%%:*}" "${d##*:}"; }
L=$(losetup --show -fP "$REPO/test-env/disk/install.img") || { echo "losetup failed" >&2; exit 2; }
cleanup() { umount "$W" "$TOP" 2>/dev/null; losetup -d "$L" 2>/dev/null; }
trap cleanup EXIT

# A loop's partition nodes do not exist merely because the loop does.
for d in /sys/block/$(basename "$L")/*/dev; do
  pn="/dev/$(basename "$(dirname "$d")")"
  [[ -e "$pn" ]] || mknod "$pn" b "$(cut -d: -f1 <"$d")" "$(cut -d: -f2 <"$d")" 2>/dev/null || true
done
udevadm settle --timeout=10 2>/dev/null || true
ROOT=""
for p in "${L}"p*; do
  [[ "$(blkid -o value -s TYPE "$p" 2>/dev/null || true)" == btrfs ]] && ROOT="$p"
done
[[ -n $ROOT ]] || { echo "no btrfs partition on $L" >&2; exit 2; }

fail=0
for SLOT in "${SLOTS[@]}"; do
  # (2) clear the ro flag through the parent
  mount -t btrfs -o subvolid=5,rw "$ROOT" "$TOP" 2>/dev/null || { echo "@$SLOT: cannot mount subvolid=5" >&2; fail=1; continue; }
  btrfs property set -f -ts "$TOP/@$SLOT" ro false 2>/dev/null
  umount "$TOP" 2>/dev/null

  mount -t btrfs -o "subvol=@$SLOT,rw" "$ROOT" "$W" 2>/dev/null || { echo "@$SLOT: mount failed" >&2; fail=1; continue; }
  # (3) refuse rather than half-write
  if ! touch "$W/.shani-mod-wtest" 2>/dev/null; then
      echo "@$SLOT: STILL READ-ONLY after clearing ro - refusing rather than half-copying" >&2
      umount "$W" 2>/dev/null; fail=1; continue
  fi
  rm -f "$W/.shani-mod-wtest"

  DEST="$W/usr/lib/dracut/modules.d/99shanios"
  mkdir -p "$DEST"

  # Copy EVERY file in the module, not just the shell ones. `*.sh` alone dropped
  # shanios-recover-default.service on the floor, so no regenerated initramfs
  # contained the unit, and `systemctl enable` reported
  # "shanios-recover-default.service does not exist" on every real boot - which
  # reads as a systemd problem and is a harness one. The module has carried a
  # .service since the in-boot recovery was written; every test of that unit
  # until now tested a unit that was never installed.
  #
  # Anything not matching a known type is a hard error, so the next file type
  # added to this module cannot be skipped quietly the same way.
  FILES=()
  for f in "$SRC"/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.sh|*.service) FILES+=("$f") ;;
      *) echo "@$SLOT: UNKNOWN MODULE FILE TYPE: $f - refusing to skip it" >&2
         umount "$W" 2>/dev/null; fail=1; continue 2 ;;
    esac
  done
  cp -f "${FILES[@]}" "$DEST/" 2>/dev/null || { echo "@$SLOT: copy failed" >&2; umount "$W"; fail=1; continue; }

  # (4) compare content, per file
  bad=""
  for f in "${FILES[@]}"; do
    b=$(basename "$f")
    if [[ ! -f "$DEST/$b" ]]; then bad="$bad $b(absent)"; continue; fi
    cmp -s "$f" "$DEST/$b" || bad="$bad $b(differs)"
  done
  if [[ -n $bad ]]; then
      echo "@$SLOT: COPY DID NOT LAND:$bad" >&2
      umount "$W" 2>/dev/null; fail=1; continue
  fi
  # A .service present in the working tree and missing from the slot is the
  # failure this whole block exists to prevent, so say so by name rather than
  # reporting a file count that looks fine either way.
  for f in "$SRC"/*.service; do
    [ -f "$f" ] || continue
    if [[ ! -f "$DEST/$(basename "$f")" ]]; then
      echo "@$SLOT: UNIT NOT INSTALLED: $(basename "$f") - the slot's initramfs will not contain it" >&2
      umount "$W" 2>/dev/null; fail=1; continue
    fi
  done
  echo "@$SLOT: module installed and byte-identical to the working tree (${#FILES[@]} files, incl $(ls "$SRC"/*.service 2>/dev/null | wc -l) unit)"
  umount "$W" 2>/dev/null
done
sync
exit $fail