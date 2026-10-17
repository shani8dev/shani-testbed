set -uo pipefail
SLOT="${1:-green}"
M=/usr/lib/dracut/modules.d/99shanios
ESP=/boot/efi
UKI="$ESP/EFI/shanios/shanios-$SLOT.efi"
KV=$(ls /usr/lib/modules/ | head -1)

echo "=== drop the corrected module into the slot ==="
cp /home/builduser/build/image_profiles/shared/overlay/rootfs/usr/lib/dracut/modules.d/99shanios/module-setup.sh "$M/module-setup.sh"
echo "  instmods vfat now present: $(grep -c 'instmods vfat' "$M/module-setup.sh")"
echo "  inst_multiple extras now: $(grep -c 'cat cp ls readlink' "$M/module-setup.sh")"

echo "=== take the cmdline from the UKI that is already there ==="
# objcopy -O binary cannot write to /dev/stdout; it exits 0 and produces nothing.
tmpc=$(mktemp)
objcopy -O binary --only-section=.cmdline "$UKI" "$tmpc" 2>/dev/null || { echo "  objcopy failed"; exit 1; }
[ -s "$tmpc" ] || { echo "  no .cmdline section"; exit 1; }
CMDLINE=$(tr -d '\0' < "$tmpc")
rm -f "$tmpc"
echo "  cmdline: ${CMDLINE:0:110}..."

echo "=== regenerate the UKI through the same path gen-efi uses ==="
dracut --force --uefi --kver "$KV" --kernel-cmdline "$CMDLINE" "${UKI}.tmp" || { echo "  dracut FAILED"; exit 1; }
echo "  dracut ok: $(stat -c %s "${UKI}.tmp") bytes"

echo "=== sign it exactly as sign_efi_binary does ==="
sbsign --key /etc/secureboot/keys/MOK.key --cert /etc/secureboot/keys/MOK.crt \
       "${UKI}.tmp" --output "${UKI}.tmp.signed" || { echo "  sbsign FAILED"; exit 1; }
mv -f "${UKI}.tmp.signed" "$UKI"
rm -f "${UKI}.tmp"
echo "  installed: $(stat -c %s "$UKI") bytes"
