# Does `bootctl set-preferred` work on this platform, and is the variable it
# writes deletable the way the hook needs? Both were read from upstream source
# and neither was run here.
ESPDEV="$(blkid -L shani_boot 2>/dev/null)"
[ -n "$ESPDEV" ] && { mkdir -p /boot/efi; mount "$ESPDEV" /boot/efi 2>/dev/null; }
E=/sys/firmware/efi/efivars
echo "=== does the verb exist at all on this bootctl? ==="
bootctl --version | head -1
bootctl set-preferred --help >/dev/null 2>&1 && echo "  set-preferred: recognised" || echo "  set-preferred: NOT recognised by this bootctl"
echo "=== set-preferred ==="
if bootctl --esp-path=/boot/efi set-preferred shanios-blue.conf 2>&1; then echo "  rc=0 OK"; else echo "  rc=$? FAILED"; fi
echo "  present now: $(ls -1 $E 2>/dev/null | grep -c '^LoaderEntryPreferred')"
echo "  value: $(for f in $E/LoaderEntryPreferred-*; do [ -e "$f" ] && tail -c +5 "$f" | tr -d '\000'; done)"
echo "=== precedence proof: does bootctl now report Preferred as the default? ==="
bootctl --esp-path=/boot/efi list --json=short 2>&1 | head -4
echo "=== deletable, the way the hook must do it? ==="
for f in $E/LoaderEntryPreferred-*; do
  [ -e "$f" ] || continue
  echo "  $(basename $f): immutable=$(lsattr "$f" 2>/dev/null | awk '{print $1}')"
  rm -f "$f" 2>/dev/null && echo "    bare rm: REMOVED" || echo "    bare rm: FAILED ($(rm -f "$f" 2>&1 | sed 's/.*: //'))"
  [ -e "$f" ] && { chattr -i "$f" 2>/dev/null; rm -f "$f" 2>/dev/null && echo "    chattr-i + rm: REMOVED" || echo "    chattr-i + rm: FAILED"; } || echo "    chattr-i + rm: n/a"
done
echo "=== END ==="
