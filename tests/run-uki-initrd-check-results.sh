#!/usr/bin/env bash
#
# run-uki-initrd-check-results.sh - prove tests/check-uki-initrd.sh can say no.
#
# A checker whose first run is a real UKI has never been shown it discriminates.
# These are synthetic UKIs built the way the layout is documented: a PE carrying
# an early_cpio stub followed by a zstd-compressed cpio in its .initrd section.
# The .initrd section gets the alloc flag, because `objcopy -O binary` lays
# sections out by address and silently skips the rest - a missing flag produces
# a zero-byte "archive" that reads exactly like an empty initramfs.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$HERE/check-uki-initrd.sh"
PASS=0; FAIL=0
pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

mkinitrd() { # $1=dir  $2=omit-binary (optional)
    local omit="${2:-}"
    mkdir -p "$1"/var/lib/dracut/hooks/pre-mount "$1"/var/lib/dracut/hooks/pre-pivot \
             "$1"/usr/lib/dracut/modules.d/99shanios "$1"/usr/bin
    printf '#!/bin/sh\nwarn "previous boot also failed"\n' \
        >"$1"/var/lib/dracut/hooks/pre-mount/90-shanios-boot-failure-hook.sh
    printf '#!/bin/sh\ntrue\n' \
        >"$1"/var/lib/dracut/hooks/pre-pivot/90-shanios-boot-success-clear.sh
    printf '#!/bin/bash\ninst_hook pre-mount 90 "$moddir/x.sh"\n' \
        >"$1"/usr/lib/dracut/modules.d/99shanios/module-setup.sh
    for b in printf sed blkid mount mountpoint mkdir rmdir rm cat ls readlink tr head basename; do
        [ "$b" = "$omit" ] && continue
        printf '#!/bin/sh\n' >"$1"/usr/bin/"$b"
    done
    [ -n "$omit" ] || printf '#!/bin/sh\n' >"$1"/usr/bin/cp   # cp only in the complete fixture
}

mkuki() { # $1=out.efi $2=dir
    ( cd "$2" && find . -print0 | cpio --null -o --quiet --format=newc ) >"$W/plain.cpio" 2>/dev/null
    # a cpio stub (the microcode early_cpio) in front, like a real UKI
    printf 'stub-early-cpio-payload' >"$W/stub.bin"
    cat "$W/stub.bin" "$W/plain.cpio" >"$W/withstub.cpio"
    zstd -q -f "$W/withstub.cpio" -o "$W/real.zst"
    cp /usr/bin/true "$W/base.efi" 2>/dev/null || cp /bin/true "$W/base.efi"
    objcopy --add-section .initrd="$W/real.zst" \
            --set-section-flags .initrd=contents,alloc,load,readonly,data \
            --change-section-vma .initrd=0x900000 \
            "$W/base.efi" "$1" 2>/dev/null
}

echo "check-uki-initrd.sh discrimination"

# 1. a complete UKI passes
mkinitrd "$W/good"; mkuki "$W/good.efi" "$W/good"
out=$(SHANI_EXPECT_FAILOVER=1 bash "$CHECK" "$W/good.efi" 2>&1)
[ $? -eq 0 ] && pass "complete UKI passes all checks" || fail "complete UKI: $out"

# 2. THE NEGATIVE CONTROL: the same UKI without `cp`. cp is what performs the
#    loader.conf rewrite, and a hook that calls an uninstalled binary does not
#    fail - it silently does nothing. A checker that cannot see that is worse
#    than no checker.
mkinitrd "$W/nocp" cp; mkuki "$W/nocp.efi" "$W/nocp"
out=$(bash "$CHECK" "$W/nocp.efi" 2>&1); rc=$?
if [ $rc -ne 0 ] && grep -q 'MISSING binaries' <<<"$out"; then
    pass "missing cp is caught (the failover's own binary)"
else
    fail "checker missed a UKI with no cp: $out"
fi

# 3. failover text absent, while everything else is fine
mkinitrd "$W/nofail"
printf '#!/bin/sh\nwarn "writes marker"\n' \
    >"$W/nofail/var/lib/dracut/hooks/pre-mount/90-shanios-boot-failure-hook.sh"
mkuki "$W/nofail.efi" "$W/nofail"
out=$(SHANI_EXPECT_FAILOVER=1 bash "$CHECK" "$W/nofail.efi" 2>&1); rc=$?
[ $rc -ne 0 ] && pass "absent failover logic is caught" || fail "checker missed an absent failover: $out"

# 4. the hooks entirely absent
mkinitrd "$W/nohook"
rm -f "$W/nohook"/var/lib/dracut/hooks/pre-mount/*.sh "$W/nohook"/var/lib/dracut/hooks/pre-pivot/*.sh
mkuki "$W/nohook.efi" "$W/nohook"
out=$(bash "$CHECK" "$W/nohook.efi" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'hook MISSING' <<<"$out" \
    && pass "absent hooks are caught" || fail "checker missed absent hooks: $out"

# 5. not a UKI at all - must fail cleanly, not report an empty archive as fine
out=$(bash "$CHECK" "$W/base.efi" 2>&1); rc=$?
[ $rc -ne 0 ] && pass "a non-UKI is refused rather than read as empty" \
    || fail "a non-UKI passed: $out"

# 6. usage: no arguments
bash "$CHECK" >/dev/null 2>&1; [ $? -eq 2 ] && pass "no args exits 2 (usage)" || fail "no args did not exit 2"

echo
if [ "$FAIL" -eq 0 ]; then echo "All $PASS discrimination checks passed"; exit 0; fi
echo "$FAIL of $((PASS+FAIL)) discrimination checks failed"; exit 1