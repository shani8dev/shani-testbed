#!/bin/bash
# slot-test-mode: boot
#
# initramfs-drivers — every UKI on the ESP carries the drivers its root disk
# can need, so the initqueue can find root=UUID= on more than a virtio disk.
#
# Why (2026-10-08): an unencrypted plasma install (ISO 20261005) to an
# external USB SSD hung forever in the dracut initqueue. uas and usb_storage
# are modules on the Arch kernel and the hostonly initramfs had neither, even
# with root on that very UAS disk. No gate could see it: the VMs use
# virtio_blk, which is built in. This reads the UKI itself, so it needs no
# USB disk and runs on any slot.
#
# The list is deliberately independent of shani-dracut.conf: dropping a driver
# from the config must turn this red. A driver built into the slot's kernel
# passes (it needs no initramfs copy); one that is neither built in nor a
# module of this kernel is reported, not silently skipped.
# NEGATIVE control: the same check on the UKI's listing with uas removed must
# report uas missing.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }

# root path: USB / Thunderbolt enclosures, SD and eMMC, NVMe and Intel VMD,
# SATA in IDE mode, Hyper-V; LUKS; an I2C laptop keyboard at the LUKS prompt
REQUIRED="uas usb_storage thunderbolt sdhci sdhci_pci sdhci_acpi mmc_block nvme vmd ata_piix hv_storvsc dm_crypt i2c_hid_acpi"

kver=$(ls /usr/lib/modules 2>/dev/null | head -1)
M="/usr/lib/modules/${kver}"
[[ -n "$kver" && -f "$M/modules.builtin" ]] || { res initramfs-drivers "FAIL (no kernel modules in this slot)"; exit 0; }
command -v lsinitrd >/dev/null || { res initramfs-drivers "FAIL (no lsinitrd in this slot)"; exit 0; }

# missing <listing>: required drivers neither built in nor in the listing
missing() {
  local listing="$1" d pat out=()
  for d in $REQUIRED; do
    pat="/${d//[-_]/[-_]}\.ko"
    grep -qE "$pat" "$M/modules.builtin" && continue
    grep -qE "$pat" <<<"$listing" && continue
    if find "$M" -regextype egrep -regex ".*${pat}.*" | grep -q .; then out+=("$d")
    else out+=("$d(not-in-kernel)"); fi
  done
  echo "${out[*]}"
}

shopt -s nullglob
ukis=(/boot/efi/EFI/*/shanios-*.efi)
(( ${#ukis[@]} )) || { res initramfs-drivers "FAIL (no shanios-*.efi on the ESP)"; exit 0; }
first=""
for u in "${ukis[@]}"; do
  name=$(basename "$u" .efi)
  listing=$(lsinitrd "$u" 2>/dev/null)
  [[ -n "$listing" ]] || { res "initramfs-drivers-${name#shanios-}" "FAIL (lsinitrd cannot read ${u})"; continue; }
  [[ -z "$first" ]] && first="$listing"
  m=$(missing "$listing")
  echo "== ${u}: $(grep -c '\.ko' <<<"$listing") modules, $(( $(stat -c %s "$u") / 1048576 )) MiB"
  [[ -z "$m" ]] && res "initramfs-drivers-${name#shanios-}" "PASS ($(wc -w <<<"$REQUIRED") root-path drivers)" \
    || res "initramfs-drivers-${name#shanios-}" "FAIL (missing: ${m})"
done

# negative control: hide uas from a real listing
if [[ -n "$first" ]]; then
  if grep -qE '/uas\.ko' "$M/modules.builtin"; then
    res negative-control-detected "SKIP (uas is built into this kernel)"
  else
    m=$(missing "$(grep -vE '/uas\.ko' <<<"$first")")
    [[ " $m " == *" uas "* ]] && res negative-control-detected PASS \
      || res negative-control-detected "FAIL (a listing without uas was not flagged: '${m}')"
  fi
fi
