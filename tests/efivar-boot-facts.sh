#!/bin/bash
# efivar-boot-facts — what a boot of the image's own kernel can see and do to the
# EFI variables the power-cut failover depends on.
#
# WHY THIS FILE EXISTS. `shani-deploy`'s boot-failure hook clears
# `LoaderEntrySysFail` / `LoaderEntryOneShot` / `LoaderEntryPreferred` from the
# initramfs, because systemd-boot reads loader.conf's `default` LAST of seven
# sources (POWER-CUT-STATE.md, `config_select_default_entry()` in boot.c): any
# of those three EFI vars outranks every deploy's loader.conf **forever**, so a
# machine with one set boots whatever it names — failing open, into a broken
# boot. The clearing is implemented as `rm -f` on the efivarfs node plus a
# verification read, and `tests/finalize-boot-efivars.sh` covers the ordering.
#
# **None of that has ever run on a variable that existed.** Every boot in this
# harness has had an empty NVRAM — `lib/vmspawn.sh` passes no `--nvram` — so the
# clearing branch executed with nothing to clear and the code path has never been
# observed doing its job. This measures it, on the real thing.
#
# It settles the question POWER-CUT-STATE.md leaves open ("what would settle it,
# now unblocked: read /sys/firmware/efi/efivars/Loader* from inside a real
# firmware boot") **in one boot rather than two**, because the property the hook
# needs is not "does the variable survive a reboot" — it is "can efivarfs be
# written, read back and unlinked". So this sets a real `LoaderEntryDefault`,
# reads it back, removes it exactly as the hook does, and confirms it is gone.
#
#   iso-install -p gnome --boot-only --iso=iso-latest \
#     --console-put=/opt/shani-testbed/tests/efivar-boot-facts.sh:/tmp/efivar-facts.sh \
#     --console-exec="sh -c 'bash /tmp/efivar-facts.sh > /tmp/f; grep ^EFIVARFACT /tmp/f'" \
#     --boot-timeout=900 | ./tests/efivar-boot-verify.sh
#
# `--console-put` resolves its SOURCE inside the builder container, whose /tmp is
# a tmpfs, so a host path under /tmp does not exist there; /opt/shani-testbed is
# mounted read-only and is the path to use.
#
# Prints `EFIVARFACT key=value` so the parser matches on a KEY rather than a
# sentence's exact wording — pinning prose is the trap AGENTS.md records for the
# espeak argv and the hardcoded module path.
#
# Every fact here is attributed by `kernel_source`: efivarfs only exists under a
# real firmware boot, and a fact that does not say which machine it describes is
# a fact about the wrong one.
set -u
f() { printf 'EFIVARFACT %s=%s\n' "$1" "${2-}"; }

f kernel "$(uname -r)"
f kernel_source "image"

EFIVARS=/sys/firmware/efi/efivars

# --- 1. is efivarfs there at all ------------------------------------------------
# Not measured and absent are different states. A missing mount and an
# unpopulated mount both read as "no Loader* vars", and only one of them means
# the clearing path is untested.
if [ -d "$EFIVARS" ]; then
  f efivarfs_present yes
  f efivarfs_count "$(find "$EFIVARS" -maxdepth 1 -name 'Loader*' 2>/dev/null | wc -l | tr -d ' ')"
  f loader_vars "$(cd "$EFIVARS" 2>/dev/null && ls -1 Loader* 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  # NB: `node_mode` is emitted ONCE, at the end, from the probe node — not here.
  # An earlier version emitted it before the probe as well, and the verifier takes
  # `head -1`, so on a machine with no pre-existing Loader* variable (every boot
  # in this harness) the check would read `none` and SKIP forever while the probe
  # went on to create the very node whose mode it wanted. Two emissions of one
  # key is the defect POWER-CUT-STATE.md records as the leftover-`case` bug.
else
  f efivarfs_present no
  f efivarfs_count 0
  f loader_vars ""
  f node_mode none
  f set_ok no
  f readback ""
  f delete_ok no
  f gone_after_delete no
  f done yes
  exit 0
fi

# Can we create one? A plain write needs a 4-byte little-endian attribute field
# followed by UTF-16LE data, which is what bootctl writes; a bare string write is
# rejected by the kernel with EINVAL and would read as "efivarfs is broken".
f writable yes
if printf '\x07' > "$EFIVARS/.__wtest" 2>/dev/null; then f writable yes; else f writable no; fi
rm -f "$EFIVARS/.__wtest" 2>/dev/null || true

# UTF-16LE of the probe value. iconv if it exists, else built byte by byte in
# bash — a missing tool must not silently produce a zero-length variable, which
# would then "read back" as a pass on a variable that was never written.
to_u16() {
  local s="$1" out="" i ch
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$s" | iconv -f UTF-8 -t UTF-16LE
    return
  fi
  for (( i = 0; i < ${#s}; i++ )); do
    ch="${s:i:1}"
    printf -v out '%s%b\\x00' "$out" "'$ch"
  done
  printf "%b" "$out"
}

PROBE=shani-test-probe
# 0x07 = NON_VOLATILE | BOOTSERVICE_ACCESS | RUNTIME_ACCESS, which is what
# systemd-boot's own LoaderEntry* variables carry.
if { printf '\x07\x00\x00\x00'; to_u16 "$PROBE"; } > "$EFIVARS/LoaderEntryDefault" 2>/dev/null \
   && [ -e "$EFIVARS/LoaderEntryDefault" ]; then
  f set_ok yes
  # Read the data back out and decode, so a variable that was written but is
  # unreadable is distinguishable from one that was never written.
  rb=$(tail -c +5 "$EFIVARS/LoaderEntryDefault" 2>/dev/null | tr -d '\000')
  f readback "${rb:-<empty>}"
  # The mode, captured from the node this probe created — the one place a
  # Loader* node is guaranteed to exist.
  probe_mode="$(stat -c '%a %U:%G' "$EFIVARS/LoaderEntryDefault" 2>/dev/null || echo none)"

  # --- the hook's actual call ---------------------------------------------------
  # `rm -f` on the node, then a verification read. If this unlink does not work
  # the hook's clearing is a silent no-op and the machine keeps booting whatever
  # the variable names — which is the whole failure this file exists to close.
  if rm -f "$EFIVARS/LoaderEntryDefault" 2>/dev/null && [ ! -e "$EFIVARS/LoaderEntryDefault" ]; then
    f delete_ok yes
    f gone_after_delete yes
  else
    f delete_ok no
    f gone_after_delete no
  fi
else
  f set_ok no
  f readback ""
  f delete_ok no
  f gone_after_delete no
fi

# Emitted last, exactly once, so `head -1` in the parser cannot read a stale
# pre-probe value.
f node_mode "${probe_mode:-none}"
f done yes