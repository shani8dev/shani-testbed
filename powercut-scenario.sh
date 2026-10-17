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

set_default() {
    # Refuse to write a default that names no entry. `default` matching nothing
    # is NOT a harmless no-op: systemd-boot silently falls back to its own
    # ordering, so the machine boots something other than the slot under test
    # and every result afterwards is about the wrong image. This exact trap
    # shipped `shanios-green-broken+3-0.conf.conf`.
    # systemd-boot reports the entry ID of shanios-blue+3-0.conf as
    # shanios-blue.conf, so a default naming the BASE id resolves even when no
    # such file exists - bootctl list showed exactly that, isDefault: true.
    # Requiring the literal file would abort a legitimate default, which is
    # its own kind of wrong. So accept the name if ANY entry resolves to it:
    # either the file is literally there, or its tries suffix strips away to
    # the requested id.
    local resolved=no f2 id2
    for f2 in "$MNT/esp/loader/entries"/*.conf; do
        [[ -f $f2 ]] || continue
        # Two forms of this entry's ID. loader.conf's default INCLUDES
        # ".conf" ("default shanios-blue.conf"), and the tries suffix sits in
        # the middle, so it cannot just be stripped off the end - doing that
        # eats the .conf too and nothing ever matches. Strip the suffix off the
        # stem, then put .conf back.
        id2=$(basename "$f2")
        alt="${id2%.conf}"; alt="${alt%%+[0-9]*-[0-9]*}.conf"
        if [[ "$id2" == "$1" || "$alt" == "$1" ]]; then resolved=yes; break; fi
    done
    if [[ $resolved != yes ]]; then
        echo "SCENARIO ABORT: default '$1' resolves to no entry; entries are:" >&2
        ls "$MNT/esp/loader/entries" >&2
        exit 2
    fi
    sed -i "s|^default[[:space:]].*|default $1|" "$MNT/esp/loader/loader.conf"
    echo "    default -> $(sed -n 's/^default[[:space:]]*//p' "$MNT/esp/loader/loader.conf")"
}
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
C) # The reported failure. The candidate must genuinely fail to mount.
   #
   # NOT by editing the entry. finalize_boot_entries() writes entries with only
   # `title` and `efi` - no `options` line - because slot selection is done by
   # each entry loading a DIFFERENT UKI, each carrying its own embedded
   # `.cmdline` with its own rootflags/subvol. So there is no `subvol=` in the
   # entry to point anywhere: an earlier version of this scenario ran
   # `sed -i 's|subvol=@[^, ]*|subvol=@no-such-slot|'` here, that matched
   # nothing, and the scenario reported success after booting a perfectly
   # healthy system - the whole test was a no-op that read as a pass.
   #
   # The bad subvolume has to go into the UKI's own .cmdline, which means
   # building a UKI with that cmdline (gen-efi/dracut), not patching one after
   # the fact. Hand-patching a UKI is where the earlier six boots went, so
   # refuse rather than pretend.
   BAD="${GOOD}-broken+3-0"          # base name only; ".conf" is added below
   cp "$MNT/esp/loader/entries/${GOOD}.conf" "$MNT/esp/loader/entries/${BAD}.conf"
   set_default "${BAD}.conf"
   printf 'blue\n' > "$MNT/data/boot_hard_failure"
   # Verify the thing this scenario actually depends on, rather than assuming
   # it: the UKI this entry loads must really carry the bad subvolume in its
   # own .cmdline. objcopy --only-section is the reliable extractor here -
   # lsinitrd / unmkinitramfs / ukify are not in the builder image.
   EFI_REL=$(sed -n 's/^efi[[:space:]]*//p' "$MNT/esp/loader/entries/${BAD}.conf" | head -1)
   EFI_ABS="$MNT/esp${EFI_REL}"
   if [[ ! -f $EFI_ABS ]]; then
       echo "SCENARIO C ABORT: ${BAD}.conf loads ${EFI_REL}, which is not on the ESP" >&2
       exit 2
   fi
   # objcopy -O binary cannot write to /dev/stdout, and it exits 0 while
   # producing nothing when you ask it to - so the pipeline read as an empty
   # cmdline rather than an error. Extract to a real file and check it exists.
   CMD_BIN=$(mktemp) || exit 2
   if ! objcopy -O binary --only-section=.cmdline "$EFI_ABS" "$CMD_BIN" 2>/dev/null \
        || [[ ! -s $CMD_BIN ]]; then
       echo "SCENARIO C ABORT: could not read .cmdline from ${EFI_REL}" >&2
       rm -f "$CMD_BIN"; exit 2
   fi
   UKI_CMDLINE=$(tr -d '\0' < "$CMD_BIN" | tr ' ' '\n' \
       | sed -n 's/.*subvol=@\([^,]*\).*/\1/p' | head -1)
   rm -f "$CMD_BIN"
   echo "    candidate UKI      : ${EFI_REL}"
   echo "    candidate subvolume: @${UKI_CMDLINE:-<none in .cmdline>}"
   if [[ "$UKI_CMDLINE" != "no-such-slot" ]]; then
       {
         echo "SCENARIO C ABORT: the candidate UKI mounts @${UKI_CMDLINE:-<nothing>}, not @no-such-slot."
         echo
         echo "Scenario C only means something if the candidate genuinely fails to mount."
         echo "Right now it would boot normally, succeed, and take the success path -"
         echo "which clears the marker, so it is never read. That is scenario B, and"
         echo "proceeding anyway is how this scenario already reported a pass while"
         echo "testing nothing."
         echo
         echo "Build the bad UKI by construction (gen-efi/dracut with a different"
         echo "kernel cmdline) rather than patching one, point this entry at it, and"
         echo "re-run. See POWER-CUT-STATE.md, 'Scenario C must be built, not patched'."
       } >&2
       exit 2
   fi
   echo "SCENARIO C applied (post-flip, unbootable candidate, prior failure recorded)" ;;
*) echo "unknown scenario"; exit 2 ;;
esac
sync; echo "SCENARIO $SC READY"
