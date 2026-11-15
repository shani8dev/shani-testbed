#!/bin/bash
# probe-counter — settle two questions in ONE firmware boot.
#
# Q1 (counter): does pinning `default` to a `+3-0` entry defeat systemd-boot's
#   tries fallback? The fallback is a SORT rule in boot_entry_compare(), and
#   config_select_default_entry() returns on the FIRST match — so an explicit
#   default is expected to bypass it. Needs bootctl's real id/triesLeft/
#   triesDone/isDefault, plus LoaderBootCountPath (the source says boot
#   counting "only works [if] userspace can actually find the selected option").
#
# Q2 (efivars): the hook clears LoaderEntry{SysFail,OneShot,Preferred,Default}
#   with `rm -f`. A measured EPERM says that cannot work (efivarfs nodes are
#   S_IMMUTABLE unless allowlisted — ed8b0de). The `chattr -i` fix is grounded
#   but untested. Those four variables do not exist on a fresh machine, so they
#   must be CREATED here before they can be tried.
#
# The previous probe assumed /boot/efi was mounted. It is not, in a running
# system — hence no loader.conf and bootctl refusing the path. Mount first.
EFIVARS=/sys/firmware/efi/efivars
echo "=== KERNEL / MOUNT STATE ==="
uname -r
mount | grep -E 'efivarfs|/boot/efi' || echo "  (neither mounted)"

# --- mount the ESP the way the initramfs hook does --------------------------
ESPDEV="$(blkid -L shani_boot 2>/dev/null)"
echo "=== ESP ==="
echo "  blkid -L shani_boot = [${ESPDEV}]"
if [ -n "$ESPDEV" ] && ! mountpoint -q /boot/efi; then
  mkdir -p /boot/efi
  mount "$ESPDEV" /boot/efi 2>&1 && echo "  mounted OK" || echo "  mount FAILED"
fi
mountpoint -q /boot/efi && echo "  /boot/efi IS mounted" || echo "  /boot/efi NOT mounted"

echo "=== Q1a: loader.conf ==="
cat /boot/efi/loader/loader.conf 2>&1 || echo "  (absent)"
echo "=== Q1b: entries on the ESP ==="
ls -1 /boot/efi/loader/entries/ 2>&1 || echo "  (absent)"
echo "=== Q1c: bootctl's view (id / triesLeft / triesDone / isDefault) ==="
bootctl --esp-path=/boot/efi list --json=short 2>&1 | head -8
echo "=== Q1d: LoaderBootCountPath (what bless-boot needs) ==="
ls -1 "$EFIVARS" 2>/dev/null | grep -i bootcount || echo "  ABSENT — boot counting cannot work without it"

echo "=== Q2: are the hook's four targets deletable once they EXIST? ==="
# Create them the way the product does, via bootctl, so the attributes are the
# real ones rather than a hand-rolled efivarfs write.
for v in LoaderEntryDefault LoaderEntryPreferred; do
  if bootctl --esp-path=/boot/efi set-default "shanios-blue.conf" >/dev/null 2>&1; then
    echo "  bootctl set-default: OK"
    break
  fi
done
echo "  LoaderEntry* now present:"
ls -1 "$EFIVARS" 2>/dev/null | grep -i '^LoaderEntry' | sed 's/^/    /' || echo "    (none)"

for v in LoaderEntryDefault LoaderEntryOneShot LoaderEntryPreferred LoaderEntrySysFail; do
  for f in "$EFIVARS/${v}-"*; do
    [ -e "$f" ] || continue
    printf '  %s: immutable=%s ' "$(basename "$f")" "$(lsattr "$f" 2>/dev/null | awk '{print $1}' || echo '?')"
    # plain unlink, as the hook did before the fix
    if rm -f "$f" 2>/dev/null; then r1=removed; else r1="FAILED($(rm -f "$f" 2>&1 | sed 's/.*: //'))"; fi
    printf 'rm=%s ' "$r1"
    if [ -e "$f" ]; then
      chattr -i "$f" 2>/dev/null || true
      if rm -f "$f" 2>/dev/null; then printf 'chattr-i+rm=REMOVED\n'; else printf 'chattr-i+rm=FAILED\n'; fi
    else
      printf 'chattr-i+rm=n/a (already gone)\n'
    fi
  done
done
echo "=== END ==="