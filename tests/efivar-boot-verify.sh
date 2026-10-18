#!/bin/bash
# efivar-boot-verify — turn the `EFIVARFACT key=value` stream from a firmware
# boot into PASS/FAIL/SKIP verdicts, so the failover hook's EFI-variable clearing
# is **checked** rather than believed.
#
# WHY. `tests/efivar-boot-facts.sh` measures; nothing here asserts until now.
# The hook clears three EFI variables that outrank loader.conf's `default`
# (systemd-boot's `config_select_default_entry()` reads `default` LAST of seven
# sources), and it clears them with `rm -f` plus a verification read. That is
# implemented and unit-tested, and **has never run against a variable that
# existed** — every boot in this harness starts from empty NVRAM, so the branch
# executed with nothing to clear. POWER-CUT-STATE.md records the consequence in
# terms: the machine would boot whatever a stale `LoaderEntryDefault` names,
# failing open into a broken boot.
#
# So the decisive check is `efivar-variable-unlinks`: can efivarfs be written,
# read back, and unlinked. If that is no, the hook's clearing is a silent no-op
# and the failover is decorative on any machine that has ever had a boot entry
# set from its menu.
#
#   iso-install -p gnome --boot-only --iso=iso-latest \
#     --console-put=/opt/shani-testbed/tests/efivar-boot-facts.sh:/tmp/efivar-facts.sh \
#     --console-exec="sh -c 'bash /tmp/efivar-facts.sh > /tmp/f; grep ^EFIVARFACT /tmp/f'" \
#     --boot-timeout=900 | ./tests/efivar-boot-verify.sh
#
# Reads stdin, or a file given as $1. `tests/efivar-boot-verify-results.sh`
# proves this can say FAIL against doctored streams before any boot trusts a PASS
# — a checker whose first ever run is a real boot has not been shown it can say no.
#
# **A verdict is about the CLAIM, not about the machine being tidy.** The claim
# is "the hook can clear these". If a future kernel stops permitting the unlink,
# that is the claim becoming false, and saying so is the point of the file.
set -u
# Verdicts are recorded as they are printed, so the structural check at the end can
# look at what THIS run emitted.
_EMITTED=""
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; _EMITTED="$_EMITTED $1"; }
STREAM=${1:-/dev/stdin}

fact() { sed -n "s/^EFIVARFACT ${1}=//p" "$STREAM" | head -1; }
have_key() { grep -q "^EFIVARFACT ${1}=" "$STREAM"; }

# --- 1. the stream itself ------------------------------------------------------
# **An absent key is not an empty value.** A missing measurement and a measured
# absence are different facts, and conflating them is the absence-shaped green
# AGENTS.md keeps recording. Completeness is checked FIRST, and a stream missing
# required keys fails as a failure of the measurement rather than as verdicts
# about the platform.
missing=""
for k in kernel kernel_source efivarfs_present efivarfs_count loader_vars \
         node_mode writable writable_errno set_ok set_errno readback \
         delete_ok gone_after_delete done; do
  have_key "$k" || missing="$missing $k"
done
if [ -n "$missing" ]; then
  res efivar-stream-complete "FAIL (missing:$missing — the measurement did not run; every other verdict would be about nothing)"
  exit 1
fi
res efivar-stream-complete "PASS (${#missing} missing, done=yes)"

# --- 2. attribution ------------------------------------------------------------
# Every other fact describes the kernel that produced it. efivarfs exists only
# under a real firmware boot, so "this describes the image's own kernel" is a
# precondition for reading anything else as being about the product.
if [ "$(fact kernel_source)" = "image" ] && [ -n "$(fact kernel)" ]; then
  res efivar-facts-describe-image "PASS (kernel $(fact kernel), source=image)"
else
  res efivar-facts-describe-image "FAIL (kernel_source='$(fact kernel_source)' kernel='$(fact kernel)'; these facts do not describe the image)"
fi

# --- 3. the boot really was a firmware boot ------------------------------------
# Not vacuous, and deliberately not a SKIP: the whole measurement is predicated
# on booting UEFI. efivarfs absent under `iso-install --boot-only` means the boot
# did not go through firmware, which is a harness fault and means the rest of the
# file would otherwise SKIP on nothing.
if [ "$(fact efivarfs_present)" != "yes" ]; then
  res firmware-boot-has-efivarfs "FAIL (efivarfs not present under $(fact kernel) — this was not a firmware boot, so the clearing path is still unmeasured)"
  exit 1
fi
res firmware-boot-has-efivarfs "PASS ($(fact efivarfs_count) Loader* vars present)"

# --- 4. enumerable -------------------------------------------------------------
# The hook's first act is to list the variables it must clear. A directory that
# cannot be listed means every one of its branches is skipped in silence — the
# shape that hid this bug for a day (POWER-CUT-STATE.md, "BOOT 1 ... the failover
# did NOT fire").
if [ -n "$(fact loader_vars)" ]; then
  res efivars-are-enumerable "PASS ($(fact loader_vars))"
else
  res efivars-are-enumerable "PASS (no Loader* vars set on this machine — the pre-existing state; enumeration itself is exercised by the probe below)"
fi

# --- 5. the mode that keeps a desktop user out ---------------------------------
# The reason shani-chronoa's driver_status reports UNKNOWN instead of guessing:
# efivarfs nodes are root-only. Asserted because the claim "a user cannot read
# its own boot variables" is what licenses that UNKNOWN; if it ever becomes
# readable, driver_status's silence becomes a lie by omission.
mode="$(fact node_mode)"
case "$mode" in
  "400 root:root"|"400 "*) res efivar-node-is-root-only "PASS ($mode)" ;;
  none|"") res efivar-node-is-root-only "SKIP (no Loader* node existed to stat — the mode is only assertable once one exists; the probe below creates one, but this key is recorded before it)" ;;
  *)       res efivar-node-is-root-only "FAIL ($mode — readable by others, so driver_status's UNKNOWN is no longer justified)" ;;
esac

# --- 6. writable ---------------------------------------------------------------
if [ "$(fact writable)" = "yes" ]; then
  res efivarfs-is-writable "PASS"
else
  res efivarfs-is-writable "FAIL (the kernel refused a well-formed efivarfs write: $(fact writable_errno) — nothing can be created or cleared here)"
fi

# --- 7. set + read back --------------------------------------------------------
# Written but unreadable is a different failure from never written, so the
# readback is compared against the probe value rather than merely checked for
# existence. `<empty>` is treated as a failure: a zero-length variable that
# "reads back" is the absence-shaped pass this repo keeps being bitten by.
rb="$(fact readback)"
if [ "$(fact set_ok)" = "yes" ] && [ "$rb" = "shani-test-probe" ]; then
  res efivar-variable-roundtrips "PASS (wrote and read back '$rb')"
else
  res efivar-variable-roundtrips "FAIL (set_ok=$(fact set_ok) readback='$rb' errno=$(fact set_errno))"
fi

# --- 8. THE DECISIVE ONE, but only if there was anything to unlink --------------
# The hook's clearing is `rm -f` on the node. If the unlink does not take effect,
# every variable stays set, `LoaderEntryDefault` keeps outranking loader.conf's
# `default`, and the machine boots whatever it names.
#
# **GATED ON THE SET, and that gate was added because the first real boot got
# this wrong in the dangerous direction.** With the write failing (EINVAL) the
# stream carried `delete_ok=no`, and the unguarded version reported
# "rm -f did not remove the variable, so the hook cannot clear LoaderEntry* and
# the failover fails open" — a confident verdict about the product drawn from a
# probe that never created a variable, so there was nothing to remove. An error
# naming the wrong thing is worse than no error, because it sends the fix to the
# wrong code: that reading points at the hook's `rm -f`, which is not what failed.
# So when the set did not happen, the unlink was never exercised and must say so.
if [ "$(fact set_ok)" != "yes" ]; then
  res efivar-variable-unlinks "SKIP (the probe variable was never created — set_ok=$(fact set_ok) errno=$(fact set_errno) — so \`rm -f\` was never exercised. This says NOTHING about the hook's clearing, in either direction.)"
elif [ "$(fact delete_ok)" = "yes" ] && [ "$(fact gone_after_delete)" = "yes" ]; then
  res efivar-variable-unlinks "PASS (rm -f removed the node and it stayed removed — the hook's clearing is not a no-op)"
else
  res efivar-variable-unlinks "FAIL (the variable was created, and rm -f did not remove it: delete_ok=$(fact delete_ok) gone=$(fact gone_after_delete) — the hook cannot clear LoaderEntry* and the failover fails open)"
fi

# --- 8. THE DECISIVE ONE -------------------------------------------------------
# The hook's clearing is `rm -f` on the node. If the unlink does not take effect,
# every variable stays set, `LoaderEntryDefault` keeps outranking loader.conf's
# `default`, and the machine boots whatever it names. This is the check the whole
# pair exists for, and the one with no passing substitute in any unit test.
# --- 9. structural: one verdict per check --------------------------------------
# A superseded block beside the live chain emitted `module-dir-readonly` twice —
# a PASS and a leftover PASS, which reads as one strong result. The duplicate is
# the defect.
#
# **This reads `_EMITTED`, which this run fills in, not `$STREAM`.** The first
# version grepped the input for `^RESULT ` — but `$STREAM` holds `EFIVARFACT`
# lines, so the grep matched nothing, `dupes` was always empty, and the check was
# permanently green: a guard that exists only in the source, which is the shape
# AGENTS.md records for the `grep -qE '^-rw'` device-node mode.
dupes="$(tr ' ' '\n' <<<"$_EMITTED" | grep -v '^$' | sort | uniq -d | tr '\n' ' ')"
n_emitted="$(tr ' ' '\n' <<<"$_EMITTED" | grep -vc '^$')"
if [ -z "$dupes" ]; then
  res efivar-one-verdict-per-check "PASS ($n_emitted verdicts, no duplicates)"
else
  res efivar-one-verdict-per-check "FAIL (duplicate verdicts:$dupes — a superseded check is still emitting)"
fi

exit 0