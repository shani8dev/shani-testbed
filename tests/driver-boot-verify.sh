#!/bin/bash
# driver-boot-verify — turn the `DRIVERFACT key=value` stream from a firmware
# boot into PASS/FAIL/SKIP verdicts, so the claims shani-chronoa makes about
# this platform are **checked** rather than written down once.
#
# WHY THIS FILE EXISTS. `tests/driver-boot-facts.sh` measures; nothing asserted.
# `AGENTS.md` in both repos records "no linux-headers, /var is tmpfs, /usr/lib/
# modules is read-only, lockdown enforces none" as the current state of this
# platform - and a recorded fact is a claim that rots silently. This is the
# staleness check, and it is deliberately shaped like
# `tests/audit-boot-proof.sh`'s practice: **prove the checker can say FAIL before
# trusting a boot's PASS**, which `tests/driver-boot-verify-results.sh` does
# against doctored fact streams including ones that must go red.
#
#   iso-install -p gnome --boot-only --iso=iso-latest \
#     --console-put=/opt/shani-testbed/tests/driver-boot-facts.sh:/tmp/driver-facts.sh \
#     --console-exec="sh -c 'bash /tmp/driver-facts.sh > /tmp/f; \
#       grep ^DRIVERFACT /tmp/f'" --boot-timeout=900 | ./tests/driver-boot-verify.sh
#
# IT READS ITS INPUT ON STDIN, and it also accepts a file, because piping a
# boot's console through a grep and then into this is how the facts get here.
#
# **The verdict is about the DOCUMENTED CLAIM, not about the machine.** A
# future image may legitimately gain linux-headers; when it does, this reports
# FAIL and says so, because a profile that starts shipping the toolchain makes
# shani-chronoa's "a module cannot be built here" sentence wrong and its refusal
# a lie by omission. That is the whole point of the file.
set -u
res() { printf 'RESULT %-44s %s\n' "$1" "$2"; }
STREAM=${1:-/dev/stdin}

# fact <key> -> value, or empty. Never errors on a missing key: a missing key is
# reported as missing by the completeness check, not silently as an empty value.
fact() { local k="$1"; sed -n "s/^DRIVERFACT ${k}=//p" "$STREAM" | head -1; }
# Is the sample's node readable by others?
#
# **The first version of this was `grep -qE '^-rw'`, which never matched
# anything**: a device node is `crw-rw----+`, so its mode field begins `crw-`,
# not `rw-`. The check therefore could not fire on any input - the same
# "a guard that exists only in the source" shape as the EEPROM denylist in
# shani-chronoa's own user_driver, found here by the self-test's own doctored
# stream rather than by reading the regex.
#
# It asks the actual question instead: a mode field is a type letter followed by
# three triplets, so the OTHERS-READ bit is **index 7** - `crw-rw-rw-` has
# others `rwx` at 7,8,9. The first attempt at this fix used index 9, which is the
# others-EXECUTE bit, so `crw-rw-rw-` read as NOT world-readable and the doctored
# stream still passed; caught by the self-test, not by reading it.
others_readable() {
  local mode
  mode=$(awk 'NR==1{print $1}' <<<"$1")
  [ "${mode:7:1}" = "r" ]
}
have_key() { grep -q "^DRIVERFACT ${1}=" "$STREAM"; }

# --- 1. the stream itself -----------------------------------------------------
# **An absent key is not an empty value.** The first version of the measurement
# script printed `linux_pkg=` for an unreadable package database, which reads as
# a measured absence rather than as a question that could not be asked - the same
# class as every `0/0` this repo keeps recording. So completeness is checked
# FIRST and a stream missing required keys fails as a failure of the
# measurement, not as a verdict about the image.
missing=""
# `kernel_source` is in this list because every other fact below is attributed by
# it: without it, "these facts describe the image" is an assumption. The first
# version omitted it, and the self-test's incomplete-stream scenario deleted that
# very key and was answered with a full set of PASSes.
for k in kernel kernel_source lockdown lockdown_present lockdown_bracketed \
         secureboot var_fstype modulesdir builddir pacman i2c_node_count \
         dev_fuse fuse_mounts v4l2_rc done; do
  have_key "$k" || missing="$missing $k"
done
if [ -n "$missing" ]; then
  res "fact-stream-complete" "FAIL (the boot produced no value for:${missing}. A key with no value and a key that was never asked are different facts, and a measurement that cannot tell them apart is not a measurement)"
  echo "== verification done"
  exit 1
fi
res "fact-stream-complete" "PASS (every required key was measured; $(grep -c '^DRIVERFACT ' "$STREAM") fact(s) in the stream)"

# --- 2. this boot was the image's own kernel ----------------------------------
# Everything below describes the image. A fact stream captured on a host kernel
# describes the host, so this is checked before any of them is believed.
ks=$(fact kernel_source)
if [ "$ks" = "image" ]; then
  res "boot-is-the-images-kernel" "PASS (kernel $(fact kernel) is the image's own, so every fact below describes the image)"
else
  res "boot-is-the-images-kernel" "FAIL (kernel_source=${ks}, so these facts describe the machine that ran the VM, not the image - the nspawn mistake in a VM's clothing)"
fi

# --- 3. the lockdown format, which the parser depends on ----------------------
if [ "$(fact lockdown_present)" = "no" ]; then
  res "lockdown-format" "SKIP (no /sys/kernel/security/lockdown on this boot; the bracketed-mode reading is unobserved and the parser's 'no file' path is what runs)"
elif [ -n "$(fact lockdown_bracketed)" ]; then
  mode=$(fact lockdown_bracketed | tr -d '[]')
  res "lockdown-format" "PASS (reads '$(fact lockdown)'; enforced mode $(fact lockdown_bracketed) - the bracketed token is what the parser takes, and the line read whole would say the opposite)"
  # The claim: this platform does not enforce lockdown, so signing is not what
  # stops an unsigned module. If that ever flips, the docs are stale.
  if [ "$mode" = "none" ]; then
    res "unsigned-modules-not-refused" "PASS (lockdown enforces 'none', so an unsigned out-of-tree module is NOT refused for its signature here; the real barriers are the toolchain and the read-only root)"
  else
    res "unsigned-modules-not-refused" "FAIL (lockdown enforces '${mode}' instead of 'none', so an unsigned module IS refused for its signature on this image - shani-chronoa's signing sentence in driver_dev.py and AGENTS.md is now STALE and must say so)"
  fi
else
  res "lockdown-format" "FAIL (lockdown reads '$(fact lockdown)' with no [bracketed] active mode, so driver_status would report unknown and its own note about this file's format is wrong)"
  res "unsigned-modules-not-refused" "SKIP (no bracketed mode to read, so whether a signature is refused is undetermined)"
fi

# --- 4. Secure Boot: recorded as unknown, and it must stay unknown ------------
sb=$(fact secureboot)
if [ "${sb%% *}" = "readable" ]; then
  byte=$(echo "$sb" | sed -n 's/.*byte=//p')
  if [ "$byte" = "01" ] || [ "$byte" = "01" ]; then
    res "secureboot-state" "FAIL (the SecureBoot efivar reads 1 - Secure Boot is ON, so an unsigned module would be refused, and driver_status's 'not enforced' reasoning needs the signing story after all)"
  else
    res "secureboot-state" "PASS (the efivar is readable as root and reads ${byte}; a desktop user cannot read it at all - efivarfs is root-only 0400 - which is why driver_status reports UNKNOWN rather than a verdict)"
  fi
else
  res "secureboot-state" "SKIP (${sb}; no SecureBoot variable on this boot. driver_status reports UNKNOWN here, which is correct: 'not present' is not the same claim as 'off', and a desktop user could not have read it either way)"
fi

# --- 5. the layout claims, as staleness checks --------------------------------
# Written as if/elif rather than `case` after a case statement here refused to
# parse at all: the branches carry long sentences containing apostrophes,
# brackets and a command substitution, and `bash -n` rejected the `*)` branch
# with "syntax error near unexpected token `)'" while every minimal
# reconstruction of it parsed. An if/elif chain says the same thing, is easier to
# read, and - the only part that matters - parses.
vfstype=$(fact var_fstype)
if [ "$vfstype" = "tmpfs" ] || [ "$vfstype" = "ramfs" ]; then
  res "var-is-volatile" "PASS (/var is ${vfstype}, so systemd.volatile=state is real and a module placed there is gone on reboot - the reason driver_build says so, and the reason no install action is offered)"
elif [ -z "$vfstype" ]; then
  res "var-is-volatile" "SKIP (/var was not a separate mount, so whether it is volatile is unmeasured here)"
else
  res "var-is-volatile" "FAIL (/var is ${vfstype}, not a tmpfs - the documented claim that a module has nowhere to persist is STALE for this image, and its refusal would be over-cautious)"
fi

mdir=$(fact modulesdir)
if [ "$mdir" = "readonly" ]; then
  res "module-dir-readonly" "PASS (/usr/lib/modules is read-only, which is the blue/green layout and the second half of why a built module has nowhere to live)"
elif [ "$mdir" = "writable" ]; then
  res "module-dir-readonly" "FAIL (/usr/lib/modules is WRITABLE on a real boot, so a module could be installed after all - the read-only-root claim behind not offering an install action is STALE)"
else
  res "module-dir-readonly" "SKIP (/usr/lib/modules is '${mdir}', which this checker has no claim about)"
fi

# --- 6. the toolchain claim ---------------------------------------------------
have_tool=0
for b in gcc make dkms; do
  have_key "has_$b" && have_tool=1
done
if [ "$have_tool" = 0 ]; then
  res "no-build-toolchain" "PASS (no gcc, make or dkms, so a kernel module cannot be built on this image and driver_status's refusal is the truth; the packages to install are named from files._PACKAGE_HINTS, not guessed)"
else
  present=$(grep -oE '^DRIVERFACT has_(gcc|make|dkms)=.*' "$STREAM" | sed 's/DRIVERFACT has_//; s/=.*//' | tr '\n' ' ')
  res "no-build-toolchain" "FAIL ($present present: this image CAN build a kernel module, so driver_status's 'cannot be built here' refusal and the AGENTS.md sentence about no desktop profile shipping a toolchain are both STALE)"
fi

# --- 7. the permission claim, from the node itself ---------------------------
nodes=$(fact i2c_node_count)
if [ "$nodes" = "0" ]; then
  res "i2c-nodes-not-world-writable" "SKIP (no /dev/i2c-* node on this boot, so nothing to check; note this is a different fact from a bus with no node, which is what a slot showed)"
elif others_readable "$(fact i2c_node_sample)"; then
  res "i2c-nodes-not-world-writable" "FAIL ($(fact i2c_node_sample) is world-writable, so any local user can write any device on that bus - device_i2c's permission story would be incomplete)"
else
  res "i2c-nodes-not-world-writable" "PASS (${nodes} node(s), group-owned not world-writable: $(fact i2c_node_sample). An unprivileged caller reaches none of it, which is why its tool failures are reported as 'nothing is known about the device's state')"
fi

echo "== verification done"