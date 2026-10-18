#!/bin/bash
# efivar-boot-verify — turn the `EFIVARFACT key=value` stream from a firmware
# boot into PASS/FAIL/SKIP verdicts, so the failover hook's EFI-variable clearing
# is **checked** rather than believed.
#
# WHY. `tests/efivar-boot-facts.sh` measures; nothing here asserts until now.
# The hook clears three EFI variables that outrank loader.conf's `default`
# (systemd-boot's `config_select_default_entry()` reads `default` LAST of seven
# sources), using `rm -f` plus a verification read. It is implemented and
# unit-tested, and POWER-CUT-STATE.md records the consequence in terms: a machine
# with a stale `LoaderEntryDefault` boots whatever it names, failing open into a
# broken boot.
#
# The decisive check is `efivar-target-unlinks`: can an existing efivarfs
# variable actually be unlinked? If not, the hook's clearing is a silent no-op.
# Note it is an **unlink of something that exists**, not a create-then-delete —
# the first two boots measured the create, which fails with EINVAL on this
# kernel, so the check could never reach the operation the hook performs.
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
         hook_target_present target_name target_mode unlink_ok \
         gone_after_delete creatable create_errno done; do
  have_key "$k" || missing="$missing $k"
done
if [ -n "$missing" ]; then
  res efivar-stream-complete "FAIL (missing:$missing — the measurement did not run; every other verdict would be about nothing)"
  exit 1
fi
res efivar-stream-complete "PASS (0 missing, done=yes)"

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
# Not vacuous, and deliberately not a SKIP: the measurement is predicated on
# booting UEFI. efivarfs absent means the boot did not go through firmware, which
# is a harness fault and would otherwise leave every later check SKIPping on
# nothing.
if [ "$(fact efivarfs_present)" != "yes" ]; then
  res firmware-boot-has-efivarfs "FAIL (efivarfs not present under $(fact kernel) — this was not a firmware boot, so the clearing path is still unmeasured)"
  exit 1
fi
res firmware-boot-has-efivarfs "PASS ($(fact efivarfs_count) Loader* vars present)"

# --- 4. what is actually on the machine ----------------------------------------
# The hook's four targets are only present once something has set them, so their
# absence is the ordinary state of a machine nobody has ever pressed a boot-menu
# key on. The count is reported so "nothing to clear" is a measurement rather
# than an assumption, and so a future image that starts shipping them is visible.
res efivar-loader-vars-present "PASS ($(fact efivarfs_count) present: $(fact loader_vars | cut -c1-90))"

# --- 5. the mode that keeps a desktop user out ---------------------------------
# The reason shani-chronoa's driver_status reports UNKNOWN instead of guessing:
# efivarfs nodes are root-only. Asserted because the claim "a user cannot read
# its own boot variables" is what licenses that UNKNOWN; if it ever becomes
# readable, driver_status's silence becomes a lie by omission.
case "$(fact target_mode)" in
  "400 root:root"|"400 "*) res efivar-node-is-root-only "PASS ($(fact target_mode))" ;;
  none|"") res efivar-node-is-root-only "SKIP (no node existed to stat — the mode is only assertable when a variable is present, and none of the hook's four targets was set on this machine)" ;;
  *)       res efivar-node-is-root-only "FAIL ($(fact target_mode) — readable by others, so driver_status's UNKNOWN is no longer justified)" ;;
esac

# --- 6. THE DECISIVE ONE -------------------------------------------------------
# `rm -f` on a real efivarfs node, then a verification read. If the unlink does
# not take effect, every LoaderEntry* stays set, LoaderEntryDefault keeps
# outranking loader.conf, and the machine boots whatever it names.
if [ "$(fact hook_target_present)" != "yes" ]; then
  res efivar-target-unlinks "SKIP (no Loader* variable existed to unlink — this machine has none of the hook's four targets set, so the hook's clearing has nothing to act on here. This says NOTHING about the hook in either direction.)"
elif [ "$(fact unlink_ok)" = "yes" ] && [ "$(fact gone_after_delete)" = "yes" ]; then
  res efivar-target-unlinks "PASS (rm -f removed $(fact target_name) and it stayed removed — the hook's clearing is not a no-op)"
else
  res efivar-target-unlinks "FAIL (unlink_ok=$(fact unlink_ok) gone=$(fact gone_after_delete) on $(fact target_name) — the hook cannot clear LoaderEntry* and the failover fails open)"
fi

# --- 7. can efivarfs be told what to boot? -------------------------------------
# A DIFFERENT question from the unlink, and deliberately not gating it. The hook
# also SETS LoaderEntryDefault. This reports what happened without letting a
# failed create decide the unlink verdict — which is exactly the misattribution
# the first two boots produced, where a failed create was reported as "rm -f did
# not remove the variable, so the hook cannot clear LoaderEntry*".
case "$(fact creatable)" in
  yes) res efivarfs-is-creatable "PASS (a well-formed create was accepted)" ;;
  *)   res efivarfs-is-creatable "SKIP (efivarfs refused to create a variable: $(fact create_errno) — so whether the hook can SET LoaderEntryDefault is unanswered here. This does not bear on the unlink above, which is a different syscall path.)" ;;
esac

# --- 8. structural: one verdict per check --------------------------------------
# A superseded block beside the live chain emitted `module-dir-readonly` twice —
# a PASS and a leftover PASS, which reads as one strong result. It caught the same
# defect in this file's own new code, when a gate was added beside the block it
# was meant to replace.
#
# **This reads `_EMITTED`, which this run fills in, not `$STREAM`.** The first
# version grepped the input for `^RESULT ` — but `$STREAM` holds `EFIVARFACT`
# lines, so the grep matched nothing and the check was permanently green: a guard
# that exists only in the source, which is the shape AGENTS.md records for the
# `grep -qE '^-rw'` device-node mode.
dupes="$(tr ' ' '\n' <<<"$_EMITTED" | grep -v '^$' | sort | uniq -d | tr '\n' ' ')"
n_emitted="$(tr ' ' '\n' <<<"$_EMITTED" | grep -vc '^$')"
if [ -z "$dupes" ]; then
  res efivar-one-verdict-per-check "PASS ($n_emitted verdicts, no duplicates)"
else
  res efivar-one-verdict-per-check "FAIL (duplicate verdicts:$dupes — a superseded check is still emitting)"
fi

exit 0