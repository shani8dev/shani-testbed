#!/bin/bash
# The driver-environment facts that ONLY a boot of the image's own kernel can
# measure, because `systemd-nspawn` shares the host's kernel.
#
# Run as root in systemd's debug shell by `iso-install --boot-only
# --console-exec`, copied in with `--console-put`. It lives HERE rather than in
# a scratchpad for two reasons: a scratchpad copy is lost at the end of the
# session, and the first attempt at this could not be run at all - `--console-put`
# resolves its source **inside the builder container**, whose `/tmp` is a tmpfs,
# so a host path under /tmp does not exist in there. `--console-put` takes
# `/opt/shani-testbed/...`, which the runner mounts read-only.
#
#   iso-install -p gnome --boot-only --iso=iso-latest \
#     --console-put=/opt/shani-testbed/tests/driver-boot-facts.sh:/tmp/driver-facts.sh \
#     --console-exec="bash /tmp/driver-facts.sh" --boot-timeout=900
#
# Prints `DRIVERFACT key=value`
# lines so the harness's parser matches on a KEY rather than on a sentence's
# exact wording - pinning the prose is the trap this file's own AGENTS.md records
# for the espeak argv.
#
# Written after the nspawn run found two of these unanswerable there:
#   - `uname -r` in a slot is the HOST's kernel, so every fact derived from it
#     described the development machine;
#   - /sys/kernel/security/lockdown and the SecureBoot efivar are absent
#     under nspawn, and the efivar is the one a desktop user cannot read at all
#     (efivarfs is root-only 0400) - which is exactly why Chronoa's
#     driver_status reports UNKNOWN there rather than guessing.
set -u
f() { printf 'DRIVERFACT %s=%s\n' "$1" "${2-}"; }

f kernel "$(uname -r)"
f kernel_source "image"

# --- the lockdown format: the bracketed active mode ---------------------------
if [ -r /sys/kernel/security/lockdown ]; then
  f lockdown_present yes
  # The whole line, with the line's own trailing newline removed. The parser
  # takes the BRACKETED token as the enforced mode and the rest as the modes
  # available, so the whole line is the measurement and trimming it would hide
  # exactly the shape under test.
  f lockdown "$(tr -d '\n' < /sys/kernel/security/lockdown)"
  f lockdown_bracketed "$(grep -oE '\[[^]]*\]' /sys/kernel/security/lockdown | head -1)"
else
  f lockdown_present no
fi

# --- Secure Boot, read as root -------------------------------------------------
sb=absent
for v in /sys/firmware/efi/efivars/SecureBoot-*; do
  [ -e "$v" ] || continue
  b=$(od -An -tx1 -N5 "$v" 2>/dev/null | awk '{print $5}')
  sb="readable byte=${b:-none}"
  f secureboot_path "$v"
done
f secureboot "$sb"

# --- the layout ---------------------------------------------------------------
f var_fstype "$(awk '$2=="/var"{print $3; exit}' /proc/mounts)"
if [ -w /usr/lib/modules ]; then f modulesdir writable; else f modulesdir readonly; fi
if [ -e "/lib/modules/$(uname -r)/build" ] || [ -e "/usr/lib/modules/$(uname -r)/build" ]; then
  f builddir present
else
  f builddir absent
fi

# --- the packages, from the image's own database ------------------------------
f pacman "$(command -v pacman || echo absent)"
if command -v pacman >/dev/null 2>&1; then
  f linux_pkg "$(pacman -Q linux 2>/dev/null | awk '{print $2}')"
  f headers_pkg "$(pacman -Qq linux-headers linux-lts-headers 2>/dev/null | tr '\n' ',')"
fi
for b in gcc make dkms modprobe insmod modinfo i2cdetect i2cget i2cset v4l2-ctl fusermount3 socat udevadm dracut; do
  if command -v "$b" >/dev/null 2>&1; then f "has_$b" "$(command -v "$b")"; fi
done

# --- the devices, which is where the slot and a real boot differ --------------
f i2c_node_count "$(ls /dev/i2c-* 2>/dev/null | wc -l)"
f i2c_node_sample "$(ls -l /dev/i2c-* 2>/dev/null | head -2 | tr '\n' ' ')"
if command -v i2cdetect >/dev/null 2>&1; then
  f i2cdetect_rc "$(i2cdetect -l >/dev/null 2>&1; echo $?)"
  f i2cdetect_bus_count "$(i2cdetect -l 2>/dev/null | grep -c 'i2c-')"
fi
if [ -e /dev/fuse ]; then f dev_fuse present; else f dev_fuse absent; fi
f fuse_mounts "$(awk -F' - ' '$2 ~ /fuse/{print $2}' /proc/self/mountinfo 2>/dev/null | wc -l)"
if command -v v4l2-ctl >/dev/null 2>&1; then
  f v4l2_rc "$(v4l2-ctl --list-devices >/dev/null 2>&1; echo $?)"
  f v4l2_devices "$(v4l2-ctl --list-devices 2>/dev/null | grep -cE '/dev/video[0-9]+')"
fi
echo "DRIVERFACT done=yes"