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
# **Measured 2026-10-10: the first version of this called pacman naively and got
# TWO EMPTY ANSWERS on a real boot** - `linux_pkg=` and `headers_pkg=` both came
# back blank, which reads exactly like "this image has no kernel package". It
# has one. On a real ShaniOS boot `/var` is an empty tmpfs
# (`systemd.volatile=state`), so `/var/lib/pacman/local` **does not exist at
# runtime**, and pacman answers nothing. `_pacdb.sh` exists for exactly this:
# it mounts the slot's own read-only subvolume underneath the tmpfs and points
# pacman at it. That file's own header says "On a real ShaniOS boot /var is an
# empty tmpfs ... the database is still in the slot's own read-only subvolume".
#
# **An empty string is not an answer.** So the two are distinguished: a package
# question is answered from the subvolume or reported as unanswerable here,
# never as an empty list.
f pacman "$(command -v pacman || echo absent)"
pacdb="/var/lib/pacman/local"
if [ -z "$(ls -A /var/lib/pacman/local 2>/dev/null)" ]; then
  f pacdb "absent (/var is $(awk '$2=="/var"{print $3; exit}' /proc/mounts)) - pacman cannot answer package questions at runtime on a real boot"
  # The subvolume pacman actually reads, which is what makes the package
  # questions answerable at all.
  #
  # **`set -u` bites here, and it is this repo's own documented trap in a new
  # place.** The first version wrote `[ -e "$_dev" ] || _src=$(...)` and then
  # used `$_src` unconditionally, so on a machine where the label EXISTS the
  # right-hand side never runs, `_src` is never assigned, and the script dies
  # with `_src: unbound variable` before printing anything - which reads like
  # the measurement having produced no answer rather than like a crash. Both
  # are initialised empty first, and `_dev` is only overwritten when the
  # fallback actually produced something.
  _dev=/dev/disk/by-label/shani_root
  _src=""
  if [ ! -e "$_dev" ]; then
    _src=$(findmnt -no SOURCE / 2>/dev/null || echo "")
    [ -n "$_src" ] && _dev=${_src%%[*}
  fi
  _sub=$(sed -n 's/.*subvol=@\{0,1\}\([a-z]*\).*/\1/p' /proc/cmdline 2>/dev/null || echo "")
  # The `2>/dev/null` belongs on the READ, not only the command: with the file
  # absent the shell prints "No such file or directory" from the redirection
  # itself, and a line of stderr in a boot log reads as a fault rather than as
  # the optional lookup it is.
  if [ -z "$_sub" ] && [ -r /data/current-slot ]; then
    _sub=$(tr -d '[:space:]' < /data/current-slot)
  fi
  mnt=$(mktemp -d /run/drv-pacdb.XXXXXX 2>/dev/null || echo "")
  if [ -n "$mnt" ] && [ -n "$_dev" ] && mount -o ro,subvol="@${_sub}" "$_dev" "$mnt" 2>/dev/null; then
    pacdb="$mnt/var/lib/pacman"
    f pacdb_mnt "mounted @${_sub} read-only"
  else
    [ -n "$mnt" ] && rmdir "$mnt" 2>/dev/null
    mnt=""
    f pacdb_mnt "unavailable"
  fi
else
  f pacdb "present"
  mnt=""
fi
if [ -n "$mnt" ] && [ -d "$pacdb/local" ]; then
  f linux_pkg "$(pacman --dbpath "$pacdb" -Q linux 2>/dev/null | awk '{print $2}')"
  hdr=$(pacman --dbpath "$pacdb" -Qq linux-headers linux-lts-headers 2>/dev/null | tr '\n' ' ')
  f headers_pkg "${hdr:-none}"
  f toolchain_pkgs "$(pacman --dbpath "$pacdb" -Qq base-devel gcc make dkms 2>/dev/null | tr '\n' ' ' || true)"
else
  f linux_pkg "unknown (no readable package database at runtime; this is the /var tmpfs, not an absent kernel)"
  f headers_pkg "unknown (no readable package database at runtime)"
  f toolchain_pkgs "unknown (no readable package database at runtime)"
fi
[ -n "$mnt" ] && { umount "$mnt" 2>/dev/null; rmdir "$mnt" 2>/dev/null; }
exit 0
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