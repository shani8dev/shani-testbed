#!/bin/bash
# slot-test-mode: boot
#
# chronoa-driver-tools — the environment a Linux driver needs, measured on the
# REAL ShaniOS image.
#
# WHY THIS FILE EXISTS. shani-chronoa grew three driver-development skills on
# 2026-10-10 (`driver_status`, `driver_scaffold`, `driver_build` in
# `skills/driver_dev.py`, and `device_probe`/`device_i2c` in
# `skills/user_driver.py`). Their whole design rests on a set of facts about
# this platform, and every one of them was read out of the image *matrices*
# (`chronoa-matrix.json` for GNOME 20260925 and Plasma 20260922) rather than
# measured on a booted machine:
#
#   no compiler, no make, no dkms, no linux-headers on any desktop profile
#     -> so a kernel module cannot be built here, and driver_status says so
#     with the missing package named rather than showing a compiler's stderr;
#   kmod ships (insmod/rmmod/modprobe/modinfo) -> the load side exists;
#   i2c-tools, v4l-utils, fuse3 all ship -> the user-space half needs no
#     compiler, which is why that half is the useful one;
#   / is a read-only blue/green slot and /var is tmpfs -> a built module has
#     nowhere to persist, which is why `install` is deliberately not an action.
#
# A matrix is a package list. **A matrix cannot tell you whether
# /sys/kernel/security/lockdown is there, what it reads, whether the SecureBoot
# efivar is readable in a slot, what /var is actually mounted as, or whether
# /dev/i2c-* nodes exist and who owns them** - and those are precisely the
# facts `driver_status`'s output turns on. The lockdown one matters most:
# the file reads `[none] integrity confidentiality`, the active mode is the
# bracketed token, and the first version of the parser read the whole line and
# called an unlocked machine "locked down". That was caught on an Ubuntu dev
# box; this file is what checks the real image's format.
#
# THE SEAM. Every measurement is written into $DRIVER_TOOLS_CAPTURE_DIR and the
# assertions read it from there; the probes only run when that is unset. That
# is what lets tests/chronoa-driver-tools-results.sh drive these same
# assertions on the host against doctored captures - including ones that must
# FAIL - so a pass here means the check ran, not that it can say no.
#
# NOT ASSERTED HERE: that the skills do the right thing. That is
# shani-chronoa's own suite. This file measures the machine they measure.
set -u
res() { printf 'RESULT %-46s %s\n' "$1" "$2"; }
WORK=${DRIVER_TOOLS_CAPTURE_DIR:-$(mktemp -d /var/tmp/chronoa-driver-tools-XXXXXX)}
[[ -n "${DRIVER_TOOLS_CAPTURE_DIR:-}" ]] || trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

have() { command -v "$1" >/dev/null 2>&1; }

# --- capture ------------------------------------------------------------------
if [[ -z "${DRIVER_TOOLS_CAPTURE_DIR:-}" ]]; then
  # Presence, one line each, recorded either way. **A binary absent from the
  # image is a finding, not a failure**: it is exactly the
  # dependency-missing case the skills have to degrade through honestly, so
  # which way this image goes is the measurement.
  for b in gcc cc clang make dkms modprobe insmod rmmod modinfo lsmod depmod \
           i2cdetect i2cget i2cset v4l2-ctl fusermount3 fusermount socat udevadm dracut mkinitcpio; do
    if have "$b"; then printf '%s\n' "$(command -v "$b")" >"$WORK/have-$b"
    else : >"$WORK/have-$b.absent"; fi
  done

  # The kernel build tree, for the *running* kernel. `uname -r` is written out
  # too, because a report that says "the build tree is missing" is only
  # meaningful against the kernel it looked for.
  uname -r >"$WORK/uname" 2>/dev/null || printf '(unknown)\n' >"$WORK/uname"
  release=$(cat "$WORK/uname")
  for d in "/lib/modules/$release/build" "/usr/lib/modules/$release/build"; do
    if [[ -e "$d" ]]; then printf '%s\n' "$d" >"$WORK/builddir"; break; fi
  done
  : >"$WORK/builddir.absent"

  # /sys/kernel/security/lockdown, verbatim. The parser takes the bracketed
  # token as the enforced mode, so the WHOLE line is kept - a file this
  # harness trimmed would hide exactly the shape under test.
  if [[ -r /sys/kernel/security/lockdown ]]; then
    cat /sys/kernel/security/lockdown >"$WORK/lockdown" 2>/dev/null
  fi
  : >"$WORK/lockdown.absent"

  # The SecureBoot efivar. **Unreadable for an ordinary desktop user** (efivarfs
  # is root-owned 0400), which is why `driver_status` reports UNKNOWN rather
  # than "off" there. A slot boots as root, so this measures what the variable
  # actually says - the fact the desktop path cannot know.
  sb=unknown
  for f in /sys/firmware/efi/efivars/SecureBoot-*; do
    [[ -e "$f" ]] || continue
    if out=$(od -An -tx1 -N5 "$f" 2>/dev/null); then
      byte=$(awk '{print $5}' <<<"$out")
      case "$byte" in 1) sb=enabled ;; 0) sb=disabled ;; *) sb="byte=${byte:-none}" ;; esac
      printf '%s\n' "$f" >"$WORK/sbpath"
      break
    fi
  done
  printf '%s\n' "$sb" >"$WORK/secureboot"

  # What /var is actually mounted as here. **This differs between a plain
  # nspawn slot and a real boot**: plain nspawn shows the image's whole /var,
  # and `slot-test --volatile` boots with it as a tmpfs, which is what a real
  # ShaniOS machine has. So the value is recorded with which mode produced it,
  # rather than asserted - asserting tmpfs here would make the default
  # (non-volatile) invocation fail for a reason that is the harness's, not the
  # platform's.
  awk '$2=="/var"{print $3; exit}' /proc/mounts >"$WORK/varfstype" 2>/dev/null
  : >"$WORK/varfstype.none"

  # Where a module would have to live, and whether that is writable. The
  # layout is the reason `install` is not an action.
  if [[ -d /usr/lib/modules ]]; then
    if [[ -w /usr/lib/modules ]]; then printf 'writable\n' >"$WORK/modulesdir"
    else printf 'readonly\n' >"$WORK/modulesdir"; fi
  else
    printf 'absent\n' >"$WORK/modulesdir"
  fi

  # I2C: the node list, and who owns the nodes. The honest-permission half of
  # `device_i2c` rests on these being group-owned rather than world-writable.
  ls -l /dev/i2c-* >"$WORK/i2c-nodes" 2>/dev/null
  : >"$WORK/i2c-nodes.absent"
  if have i2cdetect; then
    timeout 20 i2cdetect -l >"$WORK/i2cdetect-l.out" 2>"$WORK/i2cdetect-l.err"
    printf '%s\n' "$?" >"$WORK/i2cdetect-l.rc"
  fi

  if have v4l2-ctl; then
    timeout 20 v4l2-ctl --list-devices >"$WORK/v4l2-devices.out" 2>"$WORK/v4l2-devices.err"
    printf '%s\n' "$?" >"$WORK/v4l2-devices.rc"
  fi

  # FUSE: the helper, plus the mountinfo lines the parser reads. `fusermount3`
  # is a helper for an already-present FUSE filesystem - mounting one needs a
  # userspace daemon Chronoa's whitelist has no way to start - so what is
  # measured here is the helper and the parser's input, not a mount.
  if have fusermount3; then printf 'fusermount3\n' >"$WORK/fusehelper"
  elif have fusermount; then printf 'fusermount\n' >"$WORK/fusehelper"
  fi
  awk -F' - ' '$2 ~ /fuse/{print $2}' /proc/self/mountinfo >"$WORK/mountinfo-fuse" 2>/dev/null
  : >"$WORK/mountinfo-fuse.none"
  if [[ -e /dev/fuse ]]; then printf 'present\n' >"$WORK/devfuse"; else printf 'absent\n' >"$WORK/devfuse"; fi
fi

cap() { cat "$WORK/$1" 2>/dev/null; }

# Three states, not two. `present` was `[[ ! -f "$WORK/have-$1.absent" ]]`,
# which is **true when nothing was measured at all** - so a capture directory
# that had been emptied reported every one of kmod's tools as present, in a
# file whose whole purpose is to report what is on an image. The self-test's
# empty-capture scenario is what found it, and it is this repo's own rule: a
# `0/0` or an all-green line that examined nothing is the absence-shaped
# green, and it reads exactly like a pass.
present()   { [[ -f "$WORK/have-$1" ]]; }
absent_bin() { [[ -f "$WORK/have-$1.absent" ]]; }

# --- assertions ---------------------------------------------------------------

# 1. THE LOAD-BEARING CLAIM: no kernel build toolchain on a desktop image.
# Recorded as a measurement rather than asserted as a requirement, because a
# future profile could legitimately add base-devel - and then the sentence in
# `driver_status`'s refusal would be the thing that is stale. What is asserted
# is only that each piece was actually looked for, so "cannot be built here"
# is a claim about four probes rather than an assertion about the universe.
release=$(cap uname)
if [[ -n "$release" && "$release" != "(unknown)" ]]; then
  if [[ -f "$WORK/builddir" ]]; then
    res "kernel-build-tree" "PASS (present for ${release}: $(cap builddir))"
  else
    res "kernel-build-tree" "PASS (ABSENT for ${release}, which is what makes a kernel module unbuildable here: no /lib/modules/<release>/build, so linux-headers is not installed)"
  fi
fi
for b in gcc make dkms; do
  if present "$b"; then
    res "toolchain-$b" "PASS (present: $(cap have-$b) - a module could be built here, so driver_status must NOT claim otherwise)"
  elif absent_bin "$b"; then
    res "toolchain-$b" "PASS (not on this image: driver_status's refusal names it rather than showing a compiler's stderr)"
  else
    res "toolchain-$b" "SKIP (${b} was not measured - no capture and no binary to look for, so nothing is claimed about it)"
  fi
done
# The load side, which does exist and is the reason the report is worth having.
for b in modprobe insmod modinfo; do
  if present "$b"; then res "kmod-$b" "PASS ($(cap have-$b))"
  elif absent_bin "$b"; then
    res "kmod-$b" "FAIL (kmod's ${b} is absent, so a module could not even be loaded here - driver_status says the module cannot be kept and not that it cannot load)"
  else
    res "kmod-$b" "SKIP (${b} was not measured, so its absence is not a finding)"
  fi
done

# 2. THE LOCKDOWN FORMAT. This is the one the parser actually depends on, and
# the shape that caused a real bug: the file reads `[none] integrity
# confidentiality`, so the enforced mode is the BRACKETED token. A file whose
# active mode is not bracketed is the case the parser reports as UNKNOWN, and
# an assertion that accepted any content would prove nothing.
if [[ ! -f "$WORK/lockdown" && ! -f "$WORK/lockdown.absent" ]]; then
  # Not measured at all. **This branch is here because the empty-capture
  # scenario in the self-test caught the file FAILing on a capture that had
  # never read anything** - a FAIL for "we did not look" is the same confident
  # wrong verdict as a PASS, and the self-test is the only thing that saw it.
  res "lockdown-format" "SKIP (nothing measured: no lockdown capture and no capture directory, so no claim is made about the format)"
elif [[ -f "$WORK/lockdown.absent" ]]; then
  res "lockdown-format" "SKIP (no /sys/kernel/security/lockdown on this machine, so the parser's [active] reading is unobserved here; it reports 'no file', and Secure Boot state is then read from the efivar)"
else
  raw=$(cap lockdown)
  if grep -qE '^\s*\[[^]]+\]' <<<"$raw"; then
    mode=$(grep -oE '\[[^]]*\]' <<<"$raw" | head -1)
    res "lockdown-format" "PASS (read '${raw}'; enforced mode ${mode} - the bracketed token is what the parser takes, and '${raw}' read whole would wrongly say 'locked down')"
  else
    res "lockdown-format" "FAIL (lockdown reads '${raw}', with no [bracketed] active mode, so driver_status would report unknown and its own note about this format would be wrong)"
  fi
fi

# 3. Secure Boot, which a desktop user cannot read. Measured here because this
# is a root slot, and it is the fact `driver_status` reports as UNKNOWN on a
# normal desktop - so the pair is: here we learn what it says, and the skill
# keeps saying UNKNOWN rather than guessing it.
sb=$(cap secureboot)
case "$sb" in
  enabled)  res "secureboot-efivar" "PASS (readable as root and reads 1: Secure Boot is ON, so an unsigned out-of-tree module would be refused by the kernel. A desktop user cannot read this (efivarfs is root-only 0400), which is why driver_status reports UNKNOWN there rather than 'on')" ;;
  disabled) res "secureboot-efivar" "PASS (readable as root and reads 0: Secure Boot is OFF here, so an unsigned module could load - and driver_status still reports UNKNOWN on a desktop, which remains the right answer because it could not read it)" ;;
  *)        res "secureboot-efivar" "SKIP (no SecureBoot efivar or it was unreadable: ${sb}. A machine booted without UEFI has no such variable, and that is a fact about the firmware rather than about Chronoa)" ;;
esac

# 4. Where a module would have to live. The layout is why `install` is not an
# action, and `readonly` here is the normal answer on a desktop profile - so it
# is recorded rather than asserted, because asserting `writable` would report a
# harness problem as a platform finding.
case "$(cap modulesdir)" in
  writable) res "module-install-location" "PASS (/usr/lib/modules is writable, so a module could be installed here - the read-only-slot claim in driver_status does not apply to this machine)" ;;
  readonly) res "module-install-location" "PASS (/usr/lib/modules is read-only, which is the blue/green layout: / is a read-only slot and /var is $(cap varfstype), so a module has nowhere to persist across a reboot - the reason driver_build says so and `install` is not offered)" ;;
  *)        res "module-install-location" "SKIP (no /usr/lib/modules at all, so there is nothing to say about installing one)" ;;
esac

# 5. I2C: the nodes, and who owns them. `device_i2c`'s honest-permission
# refusal depends on these being group-owned; a world-writable node would mean
# any user can write any device, which the skill's refusal does not mention.
if [[ ! -f "$WORK/i2c-nodes" && ! -f "$WORK/i2c-nodes.absent" ]]; then
  # **Zero nodes counted as a PASS would be the `0/0` rule.** With nothing
  # measured, "0 node(s)" is not a machine without I2C, it is a check that
  # looked at nothing.
  res "i2c-nodes" "SKIP (nothing measured: no node capture, so this says nothing about the machine's buses)"
elif [[ -f "$WORK/i2c-nodes.absent" ]]; then
  res "i2c-nodes" "SKIP (no /dev/i2c-* nodes in this slot, so the bus a caller would name cannot be checked here - device_probe reports this as 'none found' with the reason, not as an empty machine)"
else
  nodes=$(cap i2c-nodes | grep -c 'i2c-')
  world=$(cap i2c-nodes | grep -c 'root root' || true)
  res "i2c-nodes" "PASS (${nodes} node(s); ${world} of them root:root - device_i2c reaches none of these unprivileged, which is why its tool failures are reported as 'nothing is known about the device's state')"
  head -4 <<<"$(cap i2c-nodes)" | sed 's/^/  | /'
fi
if [[ -f "$WORK/i2cdetect-l.rc" && -f "$WORK/i2cdetect-l.out" ]]; then
  rc=$(cap i2cdetect-l.rc)
  if [[ "$rc" == 0 ]] && grep -q 'i2c-' <<<"$(cap i2cdetect-l.out)"; then
    res "i2cdetect-shape" "PASS (rc=0 and bus lines present: $(head -2 <<<"$(cap i2cdetect-l.out)" | tr '\n' '|' | head -c 90))"
  else
    res "i2cdetect-shape" "SKIP (rc=${rc}, no bus lines: $(tr -d '\n' <"$WORK/i2cdetect-l.err" 2>/dev/null | head -c 90) - i2cdetect needs its device nodes, so its empty answer here is the environment and not a shape failure)"
  fi
fi

# 6. V4L2 and FUSE: the two user-space routes `device_probe` reports on.
if [[ -f "$WORK/v4l2-devices.rc" && -f "$WORK/v4l2-devices.out" ]]; then
  rc=$(cap v4l2-devices.rc)
  out=$(cap v4l2-devices.out)
  if [[ "$rc" == 0 ]]; then
    n=$(grep -cE '/dev/video[0-9]+' <<<"$out" || true)
    res "v4l2-shape" "PASS (rc=0, ${n} video device reference(s): $(head -3 <<<"$out" | tr '\n' '|' | head -c 90))"
  else
    res "v4l2-shape" "SKIP (rc=${rc}: $(tr -d '\n' <"$WORK/v4l2-devices.err" 2>/dev/null | head -c 90) - no camera on this slot is an ordinary answer, and device_probe reports it as 'none listed')"
  fi
fi
helper=$(cap fusehelper)
if [[ -z "$helper" && ! -f "$WORK/devfuse" ]]; then
  res "fuse-helper" "SKIP (nothing measured: no helper and no /dev/fuse capture, so the absence of fusermount is not claimed)"
elif [[ -n "$helper" ]]; then
  fused=$(wc -l <"$WORK/mountinfo-fuse" 2>/dev/null || printf 0)
  res "fuse-helper" "PASS (${helper} present, /dev/fuse $(cap devfuse), ${fused} fuse mount(s) in mountinfo - the line shape device_probe parses on ' - ' splitting)"
  [[ -s "$WORK/mountinfo-fuse" ]] && head -2 "$WORK/mountinfo-fuse" | sed 's/^/  | /'
else
  res "fuse-helper" "FAIL (neither fusermount3 nor fusermount is installed, so device_probe's FUSE line always reports the absent helper and the userspace-filesystem route does not exist on this image)"
fi

echo "== probe done"