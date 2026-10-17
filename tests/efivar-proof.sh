#!/bin/bash
# Which of the candidate operations actually DELETES an efivarfs node?
#
# WHY THIS EXISTS - the finding, measured on a real firmware boot.
#
# The dracut boot-failover hook clears the four EFI variables that outrank
# loader.conf so systemd-boot stops choosing the failed candidate:
#
#     printf '' > "$_efivar/$v"
#
# Run against real efivarfs (edk2-ovmf, `iso-install --boot-only`), that is a
# **silent no-op**:
#
#     trunc-zero-write-rc=0     exit status: success
#     trunc-zero-write-err=     no error message
#     exists-after=true         the variable is still there
#     size-after=180            unchanged, not even truncated
#
# So the hook reports clearing four variables and clears none, on every
# machine, while its unit test stays green - because that test drives the hook
# against a scratch directory, where the same write truncates a regular file to
# zero bytes. tmpfs cannot reproduce efivarfs, which is why nothing noticed.
#
# This enumerates the candidate operations against a variable that really
# exists and reports each one's real errno, so the fix can be written against
# something measured rather than against the idiom everyone quotes.
#
# SAFE ONLY BECAUSE `iso-install --boot-only` boots with fresh NVRAM and a fresh
# TPM every run, so a variable deleted here is regenerated next run. NEVER run
# this against a real machine's efivarfs.
#
# Prints EFIVARFACT key=value lines, the format tests/driver-boot-verify.sh
# already parses: a measurement whose output is a sentence cannot be asserted
# on safely.
set -u
emit() { printf 'EFIVARFACT %s\n' "$1"; }

EF=/sys/firmware/efi/efivars
GUID=8BE4DF61-93CA-11D2-AA0D-00E098032B8C

emit "efivarfs-present=$([[ -d $EF ]] && echo true || echo false)"
[[ -d $EF ]] || { emit "note=no-uefi"; exit 0; }

# Inert firmware bookkeeping the bootloader does not need to find the next
# boot. Not Loader*/Boot*/SecureBoot*/Setup*/KEK*/db*/dbx*: this DELETES one,
# and "the VM regenerated it" is the entire safety argument.
CANDIDATES=(
  "ConOut-$GUID"
  "ConIn-$GUID"
  "ErrOut-$GUID"
  "Lang-$GUID"
  "PlatformLang-$GUID"
)
victim=""
for c in "${CANDIDATES[@]}"; do
  [[ -e "$EF/$c" ]] && { victim="$EF/$c"; break; }
done
if [[ -z $victim ]]; then
  emit "note=none-of-the-allowlisted-inert-variables-exist-nothing-deleted"
  emit "available=$(find "$EF" -maxdepth 1 -mindepth 1 -printf '%f ' 2>/dev/null)"
  exit 0
fi
emit "victim=${victim##*/}"
emit "size-before=$(stat -c %s "$victim" 2>/dev/null || echo absent)"
emit "exists-before=$([[ -e $victim ]] && echo true || echo false)"

# Each op: a label, the command, and whether it should have deleted.
try() { # <label> <command...>
  local label="$1"; shift
  local before after
  before=$([[ -e $victim ]] && echo true || echo false)
  if [[ $before != true ]]; then
    emit "op=$label skipped=the-variable-was-already-gone"
    return 0
  fi
  out=$("$@" 2>&1); rc=$?
  after=$([[ -e $victim ]] && echo true || echo false)
  emit "op=$label rc=$rc exists-after=$after"
  emit "op=$label out=${out:-<none>}"
  [[ $after == false ]] && emit "op=$label DELETED=true"
}

# 1. What the hook does today.
try "redirect-trunc" bash -c 'printf "" > "$1"' _ "$victim"

# 2. truncate(2) rather than a truncating open - a different path, because
#    efivarfs has no .setattr, and O_TRUNC may be the part that is refused.
try "truncate-sz0" truncate -s 0 "$victim"

# 3. Plain unlink. efivarfs historically had no .unlink, so this may be
#    EPERM; it is worth the errno either way.
try "unlink" rm -f "$victim"

# 4. Open without O_TRUNC and write zero bytes - the kernel's documented
#    "empty write means delete", reached without a truncating open.
try "write-empty-notrunc" python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
try:
    n = os.write(fd, b"")
finally:
    os.close(fd)
sys.exit(0 if n == 0 else 9)' "$victim"

# 5. O_WRONLY|O_TRUNC then write zero bytes explicitly.
try "write-empty-trunc" python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_TRUNC)
try:
    n = os.write(fd, b"")
finally:
    os.close(fd)
sys.exit(0 if n == 0 else 9)' "$victim"

# 6. dd, which is the shape most scripts reach for.
try "dd-null" bash -c 'dd if=/dev/null of="$1" 2>/dev/null' _ "$victim"

emit "exists-final=$([[ -e $victim ]] && echo true || echo false)"
emit "size-final=$(stat -c %s "$victim" 2>/dev/null || echo absent)"
emit "done=true"