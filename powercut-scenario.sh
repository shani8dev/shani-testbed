#!/bin/bash
# Apply a "power was cut here" end state to install.img.
#   $1 = A | B | C     (see powercut-scenarios.md)
# The cut itself is not what is under test; what a cut DETERMINISTICALLY LEAVES
# BEHIND is, so each scenario reproduces one end state to be booted for real.
set -uo pipefail
SC="${1:?scenario A|B|C}"
IMG="${SHANIOS_DISK:-/disk}/install.img"
LOOP=$(losetup --show -fP "$IMG") || { echo "losetup failed - no free loop device?"; exit 1; }
cleanup() { sync; umount "${MNT[@]:-}" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; }
trap cleanup EXIT

partprobe "$LOOP" 2>/dev/null; udevadm settle --timeout=10 2>/dev/null
ESP=""; ROOT=""
for p in ${LOOP}p*; do
  L=$(blkid -o value -s LABEL "$p" 2>/dev/null||true); T=$(blkid -o value -s TYPE "$p" 2>/dev/null||true)
  [ "$L" = shani_boot ] && ESP="$p"; [ "$T" = btrfs ] && ROOT="$p"
done
[ -n "$ESP" ] && [ -n "$ROOT" ] || { echo "SCENARIO ABORT: partitions not identified"; exit 2; }
MNT=/mnt/scen
mkdir -p "$MNT/esp" "$MNT/data"
mount "$ESP" "$MNT/esp" || exit 2
mount -t btrfs -o subvol=@data,rw "$ROOT" "$MNT/data" || exit 2
MNT=("$MNT/esp" "$MNT/data")

echo "--- entries:";  ls "$MNT/esp/loader/entries" | sed 's/^/      /'
echo "--- default:  $(sed -n 's/^default[[:space:]]*//p' "$MNT/esp/loader/loader.conf")"
echo "--- marker:   $(cat "$MNT/data/boot_hard_failure" 2>/dev/null || echo '(none)')"

set_default() { sed -i "s|^default[[:space:]].*|default $1|" "$MNT/esp/loader/loader.conf"
                echo "    default -> $(sed -n 's/^default[[:space:]]*//p' "$MNT/esp/loader/loader.conf")"; }
GOOD=$(ls "$MNT/esp/loader/entries" | grep -v '+' | sed 's/\.conf$//' | head -1)
[ -n "$GOOD" ] || { echo "SCENARIO ABORT: no plain (known-good) entry to fall back to"; exit 2; }

case "$SC" in
A) # cut during extract, BEFORE the flip: the default was never changed.
   rm -f "$MNT/data/boot_hard_failure"; set_default "$GOOD"
   echo "SCENARIO A applied (pre-flip; nothing should move)" ;;
B) # post-flip, HEALTHY candidate. The control the fix must not break.
   rm -f "$MNT/data/boot_hard_failure"
   cp "$MNT/esp/loader/entries/${GOOD}.conf" "$MNT/esp/loader/entries/${GOOD}+3-0.conf"
   set_default "${GOOD}+3-0"
   echo "SCENARIO B applied (post-flip, healthy; the hook must NOT act)" ;;
C) # The reported failure. The candidate must genuinely fail to mount, so its
   # options line is pointed at a subvolume that does not exist - otherwise the
   # entry boots fine and the scenario tests nothing.
   BAD="${GOOD}-broken"
   cp "$MNT/esp/loader/entries/${GOOD}.conf" "$MNT/esp/loader/entries/${BAD}+3-0.conf"
   sed -i 's|subvol=@[^, ]*|subvol=@no-such-slot|' "$MNT/esp/loader/entries/${BAD}+3-0.conf"
   set_default "${BAD}+3-0"
   printf 'blue\n' > "$MNT/data/boot_hard_failure"
   echo "SCENARIO C applied (post-flip, unbootable candidate, prior failure recorded)"
   grep -o 'subvol=@[^, ]*' "$MNT/esp/loader/entries/${BAD}+3-0.conf" | sed 's/^/    candidate will mount: /' ;;
*) echo "unknown scenario"; exit 2 ;;
esac
sync; echo "SCENARIO $SC READY"
