#!/bin/bash
# efivar-boot-facts — what a boot of the image's own kernel can see and do to the
# EFI variables the power-cut failover depends on.
#
# WHY THIS FILE EXISTS. `shani-deploy`'s boot-failure hook clears
# `LoaderEntrySysFail` / `LoaderEntryOneShot` / `LoaderEntryPreferred` from the
# initramfs, because systemd-boot reads loader.conf's `default` LAST of seven
# sources (POWER-CUT-STATE.md, `config_select_default_entry()` in boot.c): any
# of those three EFI vars outranks every deploy's loader.conf **forever**, so a
# machine with one set boots whatever it names — failing open, into a broken boot.
# The clearing is `rm -f` on the efivarfs node plus a verification read.
#
# **The first two boots of this file measured the wrong operation, and it took
# both of them to see it.** The check began as "create a probe variable, read it
# back, delete it" — and the CREATE fails with EINVAL on this kernel, so the
# check could never reach the delete, which is the only operation the hook
# performs. It reported `delete_ok=no` and the verifier duly reported "rm -f did
# not remove the variable, so the hook cannot clear LoaderEntry*": a confident
# verdict about the product, drawn from a probe that never created anything.
#
# **So the measurement deletes something that already exists.** A real boot
# carries ten `Loader*` variables (`LoaderEntries-`, `LoaderEntrySelected-`,
# `LoaderFeatures-`, `LoaderFirmwareType-`, ...), and `LoaderEntrySelected-` is
# the right target: same class, a real node, and systemd-boot rewrites it on
# every boot, so removing it is safe and self-healing. That measures the hook's
# exact operation with no dependency on creating anything.
#
# It also records, separately and without gating anything, whether efivarfs will
# accept a create at all — because the hook *sets* `LoaderEntryDefault` too, and
# "can this platform be told what to boot" is a different question from "can it
# be told to forget".
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
# espeak argv and the hardcoded module path. **Every key is emitted exactly
# once**: an earlier version emitted `node_mode` and `writable` twice and the
# verifier's `head -1` read the optimistic first value, turning a failed probe
# into a PASS.
set -u
f() { printf 'EFIVARFACT %s=%s\n' "$1" "${2-}"; }

f kernel "$(uname -r)"
f kernel_source "image"

EFIVARS=/sys/firmware/efi/efivars

if [ ! -d "$EFIVARS" ]; then
  f efivarfs_present no
  f efivarfs_count 0
  f loader_vars ""
  f hook_target_present no
  f target_name ""
  f target_mode ""
  f unlink_ok no
  f gone_after_delete no
  f creatable no
  f create_errno skipped
  f done yes
  exit 0
fi

f efivarfs_present yes
f loader_vars "$(cd "$EFIVARS" 2>/dev/null && ls -1 Loader* 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
f efivarfs_count "$(find "$EFIVARS" -maxdepth 1 -name 'Loader*' 2>/dev/null | wc -l | tr -d ' ')"

# --- 1. THE MEASUREMENT: unlink a variable that already exists ------------------
# Prefer `LoaderEntrySelected-`: a real systemd-boot variable of the same class,
# rewritten every boot so removing it is self-healing. Any `Loader*` is an
# acceptable fallback, and the name is reported so the verdict can name it.
target="$(cd "$EFIVARS" 2>/dev/null && ls -1 LoaderEntrySelected-* Loader* 2>/dev/null | head -1)"
if [ -n "$target" ] && [ -e "$EFIVARS/$target" ]; then
  f hook_target_present yes
  f target_name "$target"
  f target_mode "$(stat -c '%a %U:%G' "$EFIVARS/$target" 2>/dev/null || echo none)"

  # The hook's actual call, verbatim in shape: rm -f, then verify.
  if rm -f "$EFIVARS/$target" 2>/dev/null; then
    f unlink_ok yes
  else
    f unlink_ok no
  fi
  if [ ! -e "$EFIVARS/$target" ]; then
    f gone_after_delete yes
  else
    f gone_after_delete no
  fi
else
  f hook_target_present no
  f target_name ""
  f target_mode ""
  f unlink_ok no
  f gone_after_delete no
fi

# --- 2. is efivarfs creatable at all? ------------------------------------------
# Recorded, never gating. The hook also SETS `LoaderEntryDefault`, so this is a
# real question — but it is a different one from the unlink above, and letting a
# failed create decide the unlink verdict is precisely the misattribution this
# file's first two boots produced.
#
# The stderr of the redirect target is captured with `2>&1 1>&3` rather than a
# temp file: the previous version wrote `2>/tmp/e` and the guest's debug shell
# reported `No such file or directory`, so the errno it then reported was empty
# and the verdict said `unknown` — a fix for "stop guessing the errno" that
# silently guessed nothing at all.
creatable=no; create_errno=none
exec 3>&1
_err=$( { printf '\x07\x00\x00\x00ShaniProbe\000'; } > "$EFIVARS/ShaniProbeVar" 2>&1 1>&3 )
exec 3>&-
if [ -e "$EFIVARS/ShaniProbeVar" ]; then creatable=yes; else create_errno="${_err:-unknown}"; fi
rm -f "$EFIVARS/ShaniProbeVar" 2>/dev/null || true
f creatable "$creatable"
f create_errno "$(printf '%s' "$create_errno" | tr -d '\r\n')"

f done yes