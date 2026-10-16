set -uo pipefail
cd /work
rm -rf x new.cpio new.cpio.zst; mkdir -p x
echo "--- extracting the FULL initramfs (1338 entries)"
( cd x && cpio -id --quiet < ../real.cpio ) 2>/dev/null
echo "    extracted: $(find x | wc -l) paths"
T=x/var/lib/dracut/hooks/pre-mount/90-shanios-boot-failure-hook.sh
[ -f "$T" ] || { echo "TARGET MISSING"; exit 2; }
echo "--- before: $(grep -c 'previous boot also failed' "$T") occurrence(s) of the fix"
cp /src/image_profiles/shared/overlay/rootfs/usr/lib/dracut/modules.d/99shanios/shanios-boot-failure-hook.sh "$T"
echo "--- after:  $(grep -c 'previous boot also failed' "$T") occurrence(s)"
echo "--- repacking all of it"
( cd x && find . -print0 | cpio --null -o --format=newc --quiet ) > new.cpio 2>/dev/null
ls -la new.cpio | awk '{print "    new.cpio "$5" bytes"}'
zstd -19 -q -f new.cpio -o new.cpio.zst
ls -la new.cpio.zst | awk '{print "    new.cpio.zst "$5" bytes"}'
echo "--- verify the repack round-trips and still has the module hook"
echo "    entries=$(cpio -t < new.cpio 2>/dev/null | wc -l)  99shanios-hooks=$(cpio -t < new.cpio 2>/dev/null | grep -c 'shanios-boot-failure-hook')"
