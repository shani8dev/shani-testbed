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
# Create the partition nodes from sysfs rather than trusting udev to have done
# it. In a container udev is not running, so ${LOOP}p* can be empty even though
# the partitions exist, and "partitions not identified" reads like a missing
# disk rather than a missing device node. Same reason the loop node itself has
# to be created on this host: its loop devices are exhausted and `losetup -f`
# names a /dev/loopNN that does not exist.
for _d in /sys/block/$(basename "$LOOP")/$(basename "$LOOP")p*/dev; do
    _n="/dev/$(basename "$(dirname "$_d")")"
    [ -e "$_n" ] && continue
    mknod "$_n" b "$(cut -d: -f1 <"$_d")" "$(cut -d: -f2 <"$_d")" 2>/dev/null || true
done
ESP=""; ROOT=""
for p in ${LOOP}p*; do
  L=$(blkid -o value -s LABEL "$p" 2>/dev/null||true); T=$(blkid -o value -s TYPE "$p" 2>/dev/null||true)
  [ "$L" = shani_boot ] && ESP="$p"; [ "$T" = btrfs ] && ROOT="$p"
done
[ -n "$ESP" ] && [ -n "$ROOT" ] || { echo "SCENARIO ABORT: partitions not identified"; exit 2; }
BASE=/mnt/scen
ESPMNT="$BASE/esp"
DATAMNT="$BASE/data"
mkdir -p "$ESPMNT" "$DATAMNT"
mount "$ESP" "$ESPMNT" || exit 2
mount -t btrfs -o subvol=@data,rw "$ROOT" "$DATAMNT" || exit 2
# MNT is the list cleanup unmounts; the paths above are what the rest uses.
MNT=("$ESPMNT" "$DATAMNT")

echo "--- entries:";  ls "$ESPMNT/loader/entries" | sed 's/^/      /'
echo "--- default:  $(sed -n 's/^default[[:space:]]*//p' "$ESPMNT/loader/loader.conf")"
echo "--- marker:   $(cat "$DATAMNT/boot_hard_failure" 2>/dev/null || echo '(none)')"

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
    for f2 in "$ESPMNT/loader/entries"/*.conf; do
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
        ls "$ESPMNT/loader/entries" >&2
        exit 2
    fi
    sed -i "s|^default[[:space:]].*|default $1|" "$ESPMNT/loader/loader.conf"
    echo "    default -> $(sed -n 's/^default[[:space:]]*//p' "$ESPMNT/loader/loader.conf")"
}
GOOD=$(ls "$ESPMNT/loader/entries" | grep -v '+' | sed 's/\.conf$//' | head -1)   # base name, no .conf
[ -n "$GOOD" ] || { echo "SCENARIO ABORT: no plain (known-good) entry to fall back to"; exit 2; }

case "$SC" in
A) # cut during extract, BEFORE the flip: the default was never changed.
   rm -f "$DATAMNT/boot_hard_failure"; set_default "${GOOD}.conf"
   echo "SCENARIO A applied (pre-flip; nothing should move)" ;;
B) # post-flip, HEALTHY candidate. The control the fix must not break.
   rm -f "$DATAMNT/boot_hard_failure"
   cp "$ESPMNT/loader/entries/${GOOD}.conf" "$ESPMNT/loader/entries/${GOOD}+3-0.conf"
   set_default "${GOOD}+3-0.conf"
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
   # The good slot needs a PLAIN entry, or the hook's fallback resolves to the
   # broken candidate and the "recovery" boots the same broken binary.
   #
   # After a real post-flip deploy finalize_boot_entries() has written
   # <good>.conf for the good slot and <cand>.conf + <cand>+3-0.conf for the
   # candidate, so the good slot always has a plain entry and sorts first. Left
   # over from earlier scenario runs the ESP had blue as +3-0 ONLY, which is not a
   # state a deploy produces - and it made this scenario look like it recovered:
   # the hook switched shanios-green-broken+3-0 -> shanios-green, which are
   # different NAMES loading the same EFI binary. The hook compares entry names
   # and cannot see that, so the guard below is the only thing that can.
   # WHICH slot is the candidate has to be stated, not guessed. Scenario C builds
   # the broken entry FROM the candidate's own entry, so it must know which one
   # that is - and it used to take the first plain entry on the ESP. That is wrong
   # the moment the healthy slot sorts first, and it produced a run that switched
   # shanios-green-broken+3 -> shanios-green: different NAMES, the same broken
   # EFI binary. The hook compares entry names and cannot see that, so it reported
   # a recovery that booted the candidate that had just failed.
   CAND="${SHANIOS_CANDIDATE:-}"
   if [[ -z $CAND ]]; then
       echo "SCENARIO C ABORT: SHANIOS_CANDIDATE must name the slot whose UKI is unbootable." >&2
       echo "  Set it to the slot regen-uki.sh --break-root was run against, e.g." >&2
       echo "      SHANIOS_CANDIDATE=green bash powercut-scenario.sh C" >&2
       exit 2
   fi
   if [[ ! -f "$ESPMNT/loader/entries/shanios-${CAND}.conf" ]]; then
       echo "SCENARIO C ABORT: no plain entry for the candidate slot '${CAND}'." >&2
       echo "  Entries are:" >&2; ls "$ESPMNT/loader/entries" >&2
       exit 2
   fi
   CAND_EFI=$(sed -n 's/^efi[[:space:]]*//p' "$ESPMNT/loader/entries/shanios-${CAND}.conf" | head -1)

   # The healthy sibling needs a PLAIN entry. After a real post-flip deploy it has
   # one; left over from earlier scenario runs it may only have a tries entry,
   # which the hook skips, so the fallback would resolve to the candidate itself.
   SIB=""
   for f in "$ESPMNT/loader/entries"/*.conf; do
       [ -f "$f" ] || continue
       e=$(sed -n 's/^efi[[:space:]]*//p' "$f" | head -1)
       [ "$e" = "$CAND_EFI" ] && continue
       SIB="$f"; break
   done
   if [[ -z $SIB ]]; then
       echo "SCENARIO C ABORT: no entry loads a UKI other than the candidate's (${CAND_EFI})." >&2
       echo "  There is nothing to fall back TO, so a recovery could not be shown." >&2
       exit 2
   fi
   SIB_STEM=$(basename "$SIB" .conf); SIB_STEM="${SIB_STEM%%+[0-9]*-[0-9]*}"
   if [[ ! -f "$ESPMNT/loader/entries/${SIB_STEM}.conf" ]]; then
       cp "$SIB" "$ESPMNT/loader/entries/${SIB_STEM}.conf"
       echo "    restored the good slot's plain entry: ${SIB_STEM}.conf"
   fi

   BAD="shanios-${CAND}+3-0"      # finalize_boot_entries() names it shanios-<slot>+3-0
   cp "$ESPMNT/loader/entries/shanios-${CAND}.conf" "$ESPMNT/loader/entries/${BAD}.conf"
   set_default "${BAD}.conf"
   printf '%s\n' "${SIB_STEM#shanios-}" > "$DATAMNT/boot_hard_failure"

   # Verify the fallback is a DIFFERENT BINARY, not merely a different name.
   # The hook's selection is reproduced here exactly - shell glob order over
   # *.conf, skipping any name containing +N-N - because a scenario that cannot
   # distinguish "switched to the good slot" from "switched to the same broken
   # UKI by another name" reports a recovery that never happened.
   HOOK_FALLBACK=""
   for E in "$ESPMNT/loader/entries"/*.conf; do
       [ -f "$E" ] || continue
       N=$(basename "$E" .conf)
       case "$N" in *+*-*) continue ;; esac
       HOOK_FALLBACK="$N"; break
   done
   efi_of() { sed -n 's/^efi[[:space:]]*//p' "$ESPMNT/loader/entries/$1.conf" 2>/dev/null | head -1; }
   echo "    hook would fall back to: ${HOOK_FALLBACK:-<none>}"
   if [[ -z "$HOOK_FALLBACK" ]]; then
       echo "SCENARIO C ABORT: no plain entry for the hook to fall back to." >&2
       echo "  Without one the hook refuses to act and there is nothing to test." >&2
       exit 2
   fi
   if [[ "$(efi_of "$HOOK_FALLBACK")" == "$(efi_of "${BAD}")" ]]; then
       echo "SCENARIO C ABORT: the fallback '${HOOK_FALLBACK}' loads the SAME efi as the" >&2
       echo "  default '${BAD}' ($(efi_of "$HOOK_FALLBACK")). The hook would switch the" >&2
       echo "  default to a different NAME for the same broken binary, and every" >&2
       echo "  observation below would be of a boot that failed for the same reason." >&2
       echo "  This is a state no real deploy produces - see the comment above." >&2
       exit 2
   fi
   echo "    fallback loads a different binary: OK"
   # Verify the thing this scenario actually depends on, rather than assuming
   # it: the UKI this entry loads must really carry the bad subvolume in its
   # own .cmdline. objcopy --only-section is the reliable extractor here -
   # lsinitrd / unmkinitramfs / ukify are not in the builder image.
   EFI_REL=$(sed -n 's/^efi[[:space:]]*//p' "$ESPMNT/loader/entries/${BAD}.conf" | head -1)
   EFI_ABS="${ESPMNT}${EFI_REL}"
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
   if [[ "${SHANIOS_HOOK_ONLY:-0}" == 1 ]]; then
       # Hook-only mode. The hook's decision does not depend on the candidate
       # failing: it reads a pre-existing marker and a tries-counted default,
       # and acts on those. So the switch can be observed on a boot that
       # succeeds. What this does NOT prove is the whole field loop - that a
       # genuinely unbootable candidate leaves a marker, and that the next boot
       # then lands on the good slot. Said here so a green run is not read as
       # more than it is.
       echo "    *** HOOK-ONLY: candidate is NOT unbootable; this proves the hook"
       echo "        fires, NOT that an unbootable candidate recovers. ***"
   elif [[ "$UKI_CMDLINE" != "no-such-slot" ]]; then
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
sync
cat <<EOF
SCENARIO $SC READY

  Boot it with (scenario C REQUIRES SHANIOS_CANDIDATE - it refuses without it,
  because it has to know which slot's UKI is the unbootable candidate):
    cd ../shani-install-media && ./test-env/test.sh vmspawn --commit --timeout=900

  Two boots, and the second one is the whole point: it selects nothing, shows no
  menu, and must land on the known-good slot. Reads as a pass only if it does.

  --commit is REQUIRED here, not a convenience. vmspawn boots a qcow2 overlay and
  discards it on exit, so without it nothing the guest wrote reaches install.img
  and you will read the pre-boot state - which is byte-identical to what a boot
  that changed nothing leaves behind. For a scenario whose entire point is a boot
  that writes, that is a green run proving nothing. See README.md,
  "vmspawn: UEFI + TPM boots without KVM", and tests/vmspawn-args.sh.
EOF
