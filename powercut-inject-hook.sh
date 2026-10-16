#!/bin/bash
# Put the new hook into install.img's rootfs and regenerate the initramfs, so
# the image carries the fix rather than the pre-fix hook baked in at build time.
set -uo pipefail
IMG=/disk/install.img
NEWHOOK=/src/image_profiles/shared/overlay/rootfs/usr/lib/dracut/modules.d/99shanios
LOOP=$(losetup --show -fP "$IMG") || { echo "losetup failed"; exit 1; }
ESP=""; ROOT=""
for p in ${LOOP}p*; do
  L=$(blkid -o value -s LABEL "$p" 2>/dev/null||true); T=$(blkid -o value -s TYPE "$p" 2>/dev/null||true)
  [ "$L" = shani_boot ] && ESP="$p"; [ "$T" = btrfs ] && ROOT="$p"
done
echo "esp=${ESP:-NONE} root=${ROOT:-NONE}"
M=/mnt/inject; mkdir -p $M/esp $M/blue $M/green
mount "$ESP" $M/esp || exit 2
for s in blue green; do mount -t btrfs -o subvol=@$s "$ROOT" $M/$s 2>/dev/null || echo "  (@$s not mounted)"; done
echo "--- entries on the ESP:"; ls $M/esp/loader/entries 2>/dev/null | sed 's/^/      /'
echo "--- current default:"; sed -n 's/^default[[:space:]]*//p' $M/esp/loader/loader.conf | sed 's/^/      /'
for s in blue green; do
  [ -d "$M/$s/usr" ] || continue
  if [ -d "$M/$s/usr/lib/dracut/modules.d/99shanios" ]; then
    cp "$NEWHOOK/shanios-boot-failure-hook.sh" "$M/$s/usr/lib/dracut/modules.d/99shanios/" || echo "  copy failed @$s"
    echo "  injected into @$s"
    if grep -q 'previous boot also failed' "$M/$s/usr/lib/dracut/modules.d/99shanios/shanios-boot-failure-hook.sh"; then
      echo "  VERIFIED: new hook text is in @$s"
    else
      echo "  WARNING: new text NOT found in @$s"
    fi
  else
    echo "  @$s has no 99shanios dracut module"
  fi
done
sync; umount $M/blue $M/green $M/esp 2>/dev/null; losetup -d "$LOOP"
echo "INJECT PHASE DONE"
