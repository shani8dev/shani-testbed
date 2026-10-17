#!/usr/bin/env bash
#
# check-uki-initrd.sh - assert a real ShaniOS UKI actually carries the boot
# hooks and the binaries those hooks shell out to.
#
# WHY THIS EXISTS. `lsinitramfs /boot/initramfs-linux.img | grep 99shanios`
# returned ZERO entries on a slot where the module was demonstrably present and
# running. That was recorded as "an lsinitramfs quirk", which may be wrong, and
# the ambiguity is the whole problem: `grep` over a tool's output is not
# evidence about an archive. This asks the archive directly instead.
#
# And it asks about the UKI, not /boot/initramfs-linux.img. The initramfs that
# actually boots is the one embedded in the unified kernel image, produced by
# gen-efi's own call:
#
#   dracut --force --uefi --kver "$kernel_ver" \
#          --kernel-cmdline "$kernel_cmdline" "${uki_path}.tmp"
#
# A UKI is a PE image whose sections are: stub .text, .reloc, then a PE/COFF
# section holding `early_cpio` (microcode, uncompressed), then a zstd-compressed
# cpio holding the real initramfs. So the reliable extraction is:
#
#   objcopy -O binary --only-section=.initrd <uki> out.bin
#   find the zstd magic 28 b5 2f fd, decompress from there, unpack with cpio
#
# `objcopy -O binary` CANNOT write to /dev/stdout - it exits 0 and produces
# nothing, so the pipeline reads as an empty archive rather than an error.
# Extract to a real file and check it is non-empty.
#
# Usage:
#   check-uki-initrd.sh <uki> [<uki> ...]
#   SHANI_EXPECT_FAILOVER=1   additionally require the failover logic text
#
# Exit: 0 all checks passed, 1 a check failed, 2 usage/environment problem.
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <uki> [<uki> ...]" >&2; exit 2; }
for t in objcopy cpio zstd python3 mktemp; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 2; }
done

FAILS=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

# Pull the real initramfs out of a UKI into $2. Echoes nothing; returns non-zero
# with a reason on failure. Every step here is one that has silently produced an
# empty result before.
extract_initrd() {
    local uki="$1" out="$2"
    if ! objcopy -O binary --only-section=.initrd "$uki" "$out" 2>/dev/null; then
        echo "objcopy failed on $uki" >&2; return 1
    fi
    if [ ! -s "$out" ]; then
        echo "no .initrd section, or objcopy wrote nothing (it cannot write to /dev/stdout)" >&2
        return 1
    fi
    # The section begins with a cpio stub (early_cpio/microcode); the real,
    # zstd-compressed initramfs starts at the first zstd magic.
    local off
    off=$(python3 -c "
import sys
d=open(sys.argv[1],'rb').read()
i=d.find(b'\x28\xb5\x2f\xfd')
print(i if i>=0 else -1)" "$out") || return 1
    if [ "$off" -lt 0 ]; then
        echo "no zstd magic in the .initrd section of $uki" >&2; return 1
    fi
    python3 -c "
import sys
d=open(sys.argv[1],'rb').read()
open(sys.argv[2],'wb').write(d[int(sys.argv[3]):])" "$out" "$out.zst" "$off" || return 1
    zstd -d -f -q "$out.zst" -o "$out.cpio" 2>/dev/null || { echo "zstd -d failed" >&2; return 1; }
    [ -s "$out.cpio" ] || { echo "decompressed initramfs is empty" >&2; return 1; }
    return 0
}

for UKI in "$@"; do
    printf '%s\n' "$UKI"
    if [ ! -f "$UKI" ]; then bad "not a file: $UKI"; continue; fi

    WORK=$(mktemp -d) || { echo "mktemp failed" >&2; exit 2; }
    if ! extract_initrd "$UKI" "$WORK/initrd" 2>"$WORK/err"; then
        bad "cannot extract an initramfs: $(cat "$WORK/err")"
        rm -rf "$WORK"; continue
    fi

    # Unpack and ask the archive, not a grep over some tool's rendering of it.
    ( cd "$WORK" && mkdir -p tree && cd tree && cpio -id --quiet < ../initrd.cpio ) 2>/dev/null
    TREE="$WORK/tree"

    H="$TREE/var/lib/dracut/hooks/pre-mount/90-shanios-boot-failure-hook.sh"
    if [ -f "$H" ]; then ok "pre-mount boot-failure hook present"; else bad "pre-mount hook MISSING"; fi

    P="$TREE/var/lib/dracut/hooks/pre-pivot/90-shanios-boot-success-clear.sh"
    if [ -f "$P" ]; then ok "pre-pivot success-clear hook present"; else bad "pre-pivot success-clear hook MISSING"; fi

    # NOT asserted: modules.d/99shanios/module-setup.sh. dracut CONSUMES the
    # module descriptor at build time and installs only the hooks and the
    # binaries they name - the descriptor is a build-time input, not a runtime
    # artifact, so its absence from the initramfs is correct. Asserting it was
    # a FAIL on a perfectly good UKI, which is the exact shape this script
    # exists to stop: an absence read as a finding. The hooks being present IS
    # the evidence that the module was processed.

    # THE CHECK THAT MATTERS MOST. A hook that shells out to a binary dracut was
    # never told to install does not fail - it silently does nothing, and
    # `printf` being present while `cp` is not is exactly what made the failover
    # look inert: the marker line appeared on every boot and nothing else did.
    missing=""
    for b in printf sed blkid mount mountpoint mkdir rmdir rm cat cp ls readlink tr head basename; do
        [ -e "$TREE/usr/bin/$b" ] || [ -e "$TREE/bin/$b" ] || missing="$missing $b"
    done
    if [ -z "$missing" ]; then
        ok "every binary the hooks call is present"
    else
        bad "initramfs is MISSING binaries the hooks call:$missing"
    fi

    if [ "${SHANI_EXPECT_FAILOVER:-0}" = 1 ]; then
        if [ -f "$H" ] && grep -q 'previous boot also failed' "$H"; then
            ok "failover logic present in the shipped hook"
        else
            bad "failover logic NOT in the shipped hook"
        fi
    fi

    rm -rf "$WORK"
done

if [ "$FAILS" -eq 0 ]; then echo "All UKI initramfs checks passed"; exit 0; fi
echo "$FAILS UKI initramfs check(s) failed"; exit 1