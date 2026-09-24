# ------------------------------------------------------------------
# shared helpers
# ------------------------------------------------------------------
# Loop-device attachment (unlike root.img/esp.img themselves, which are
# bind-mounted and persist on the host) does NOT survive across separate
# `run_in_container.sh` invocations — each is a fresh container, so its
# /dev/disk/by-label/* symlinks (created by cmd_disk) start out empty even
# when root.img/esp.img already exist from an earlier session. Re-attach to
# the existing images instead of requiring a fresh `disk` (which would wipe
# and reformat them) every time a new container needs them.
#
# Loop devices themselves, however, DO live in the host kernel (not the
# container's namespace) and are exposed into every container via
# run_in_container.sh's `-v /dev:/dev` — so a loop device attached by an
# EARLIER container invocation that never ran `clean` is still attached when
# a later, unrelated container starts. Two things go wrong from this if
# unhandled: (1) `losetup -j <img>` can find MORE THAN ONE loop device
# already bound to the same backing file (e.g. a previous `disk`/`enter` run
# that was interrupted before writing .root_loop, then something re-attached
# a second one), which silently broke the naive
# `$(losetup -j "$img" | cut -d: -f1)` one-liner this used to be — piping
# multiple lines through command substitution collapses them into one
# newline-containing string, which `ln -sf`/`losetup -d` then choke on; and
# (2) /dev/disk/by-label/* symlinks always get re-pointed at whatever this
# run just resolved, so a stale symlink from a dead loop device is replaced
# rather than left dangling. _loops_for_image/_detach_all_loops/
# _ensure_single_loop below are the shared self-healing primitives — see
# their own comments for exactly how each one behaves.
# ------------------------------------------------------------------

# Prints one loop device path per line currently attached to backing file $1.
# Empty output (no lines) if none are attached. Never fails — a missing
# image or no attachments are both just "no output", not an error.
_loops_for_image() {
  losetup -j "$1" 2>/dev/null | cut -d: -f1
}

# Detaches EVERY loop device currently attached to backing file $1, however
# many there are (0, 1, or a stale duplicate). Used right before an image is
# about to be wiped and recreated (cmd_disk, cmd_install) — at that point no
# attachment should survive, clean or not.
# A prior encrypted `install` run can leave /dev/mapper/shani_root open,
# referencing a partition of a loop device something is about to detach —
# `losetup -d` on a loop device with a live dm-crypt mapping still backed
# by it doesn't fully release the device, and can leave the mapping
# itself dangling against a now-gone backing loop. Every loop-detach path
# in this file (cmd_clean's own loop, and _detach_all_loops below) needs
# this same close-first step — confirmed live: without it, a second
# `install --encrypted` run in the same session fails with "Device
# shani_root already exists." / "LUKS open failed" even though the loop
# was already "detached". One shared helper instead of duplicating the
# same 3 lines in both places.
_close_stale_shani_root_mapper() {
  [[ -e /dev/mapper/shani_root ]] || return 0
  log "Closing stale LUKS mapper shani_root"
  cryptsetup close shani_root 2>/dev/null || true
}

_detach_all_loops() {
  local img="$1" loop
  _close_stale_shani_root_mapper
  while read -r loop; do
    [[ -n "$loop" ]] || continue
    log "Detaching loop device $loop ($img)"
    losetup -d "$loop" 2>/dev/null || warn "Failed to detach $loop"
  done < <(_loops_for_image "$img")
}

# Ensures exactly ONE loop device is attached to backing file $1 and prints
# its path to stdout. This is the "reuse cleanly, or detach+reattach" half of
# the contract (cmd_disk's preflight uses _detach_all_loops instead, since it
# always wipes the image anyway): zero attachments -> attach fresh; exactly
# one -> reuse it as-is (the common case: reattaching after a prior
# container exited without `clean`); MORE than one (the actual "stale/
# duplicate loop-device attachments" scenario from a prior session) -> log a
# warning, detach ALL of them, then attach one fresh device — never guesses
# which of several existing attachments is "the right one".
_ensure_single_loop() {
  local img="$1"
  local -a loops=()
  local l
  while read -r l; do
    [[ -n "$l" ]] && loops+=("$l")
  done < <(_loops_for_image "$img")

  if (( ${#loops[@]} > 1 )); then
    warn "Found ${#loops[@]} loop devices attached to $img at once (${loops[*]}) — this is the stale/duplicate-attachment scenario from a prior run_in_container.sh session; detaching all of them and reattaching cleanly"
    for l in "${loops[@]}"; do
      losetup -d "$l" 2>/dev/null || warn "Failed to detach stale loop device $l"
    done
    loops=()
  fi

  if (( ${#loops[@]} == 1 )); then
    echo "${loops[0]}"
    return 0
  fi

  losetup --find --show "$img" || die "Failed to attach loop device for $img"
}

# Points /dev/disk/by-label/{shani_root,shani_boot} at the root.img/esp.img
# loop devices and records them in .root_loop/.esp_loop. Shared by `disk`
# (fresh images) and _ensure_disk_attached (re-attach in a new container).
_link_disk_pair() {
  local root_loop="$1" esp_loop="$2"
  mkdir -p /dev/disk/by-label
  ln -sf "$root_loop" /dev/disk/by-label/shani_root
  ln -sf "$esp_loop" /dev/disk/by-label/shani_boot
  echo "$root_loop" > "${DATA_DIR}/.root_loop"
  echo "$esp_loop" > "${DATA_DIR}/.esp_loop"
}

_ensure_disk_attached() {
  [[ -e /dev/disk/by-label/shani_root && -e /dev/disk/by-label/shani_boot ]] && return 0

  [[ -f "$ROOT_IMG" && -f "$ESP_IMG" ]] \
    || die "root.img/esp.img not found under $DATA_DIR — run '$(basename "$0") disk' first"

  local root_loop esp_loop
  root_loop=$(_ensure_single_loop "$ROOT_IMG")
  esp_loop=$(_ensure_single_loop "$ESP_IMG")
  _link_disk_pair "$root_loop" "$esp_loop"
  log "Re-attached existing disk images from a prior session: root=$root_loop esp=$esp_loop"
}

_mount_root() {
  _ensure_disk_attached
  mkdir -p "$MNT"
  # compress=zstd matches production's BTRFS_TOP_OPTS (install.sh/build-base-image.sh).
  # Without it, a rootfs that fits comfortably in production's compressed
  # filesystem can exhaust an equally-sized uncompressed test disk mid-receive
  # — btrfs then blocks in uninterruptible I/O wait (D state) trying to find
  # metadata space rather than promptly failing with ENOSPC, hanging the
  # whole test indefinitely instead of erroring out.
  mountpoint -q "$MNT" || mount -o subvolid=5,compress=zstd "/dev/disk/by-label/shani_root" "$MNT"
}

_current_slot() {
  _mount_root
  local slot
  slot=$(tr -d '[:space:]' < "$MNT/@data/current-slot" 2>/dev/null || echo "")
  [[ "$slot" =~ ^(blue|green)$ ]] || die "Couldn't read current-slot marker — run '$(basename "$0") bootstrap' first"
  echo "$slot"
}

# ------------------------------------------------------------------
# disk   (was 00-create-disk.sh)
# ------------------------------------------------------------------
cmd_disk() {
  if ! command -v mkfs.fat &>/dev/null && command -v pacman &>/dev/null; then
    log "mkfs.fat not found — installing dosfstools"
    pacman -Sy --needed --noconfirm dosfstools || warn "Could not auto-install dosfstools — install it manually if the ESP step below fails"
  fi

  check_dependencies_test

  # 32G disk (~28GB usable after btrfs metadata overhead) for deployment testing.
  local root_size="${ROOT_SIZE:-32G}"
  local esp_size="${ESP_SIZE:-512M}"

  mkdir -p "$DATA_DIR" /dev/disk/by-label

  # Preflight: this command is about to wipe and recreate both images, so any
  # loop device already attached to them — whether left over cleanly from a
  # previous session (documented in `clean`'s help text) or a stale/duplicate
  # attachment (more than one loop device bound to the same backing file,
  # which happens if an earlier session's disk/enter/bootstrap was
  # interrupted) — must go first. setup_btrfs_image() (config.sh) only
  # detaches a single, already-known attachment for root.img; do the same
  # (and cover the duplicate case) for both images here explicitly, rather
  # than leaving a human to `losetup -d` + re-disk + re-bootstrap by hand.
  _detach_all_loops "$ROOT_IMG"
  _detach_all_loops "$ESP_IMG"

  log "Setting up root.img (Btrfs, LABEL=shani_root, ${root_size})"
  setup_btrfs_image "$ROOT_IMG" "$root_size"
  local root_loop="$LOOP_DEVICE"
  btrfs filesystem label "$root_loop" shani_root

  log "Setting up esp.img (FAT32, LABEL=shani_boot, ${esp_size})"
  rm -f "$ESP_IMG"
  truncate -s "$esp_size" "$ESP_IMG"
  local esp_loop
  esp_loop=$(losetup --find --show "$ESP_IMG") || die "Failed to set up loop device for $ESP_IMG"
  mkfs.fat -F32 -n shani_boot "$esp_loop" || die "Failed to format $ESP_IMG as FAT32"

  _link_disk_pair "$root_loop" "$esp_loop"

  log "root loop: $root_loop  (LABEL=shani_root)"
  log "esp  loop: $esp_loop  (LABEL=shani_boot)"
  log "Disk images written under: $DATA_DIR"
}

# ------------------------------------------------------------------
# clean — undo everything _ensure_disk_attached/cmd_disk/cmd_enter leave
# behind, without touching root.img/esp.img/install.img themselves.
#
# Nothing else in this file ever calls losetup -d on a successful path:
# _ensure_disk_attached() re-attaches or reuses the existing loop device on
# every invocation (correct — it can't know a later command still needs it),
# and every run_in_container.sh invocation is a fresh --rm'd container, so
# there's no container-exit hook to detach on either. Loop devices just
# accumulate on the host across a testing session unless something
# explicitly tears them down.
# ------------------------------------------------------------------
cmd_clean() {
  local any=0

  local slot work
  for slot in blue green; do
    work="${DATA_DIR}/nspawn-overlay-${slot}"
    if mountpoint -q "${work}/merged" 2>/dev/null; then
      log "Unmounting ${work}/merged"
      umount -R "${work}/merged" 2>/dev/null || warn "Failed to unmount ${work}/merged"
      any=1
    fi
  done

  if mountpoint -q "$ESP_MNT" 2>/dev/null; then
    log "Unmounting $ESP_MNT"
    umount "$ESP_MNT" 2>/dev/null || warn "Failed to unmount $ESP_MNT"
    any=1
  fi

  if mountpoint -q "$MNT" 2>/dev/null; then
    log "Unmounting $MNT"
    umount -R "$MNT" 2>/dev/null || warn "Failed to unmount $MNT"
    any=1
  fi

  local img loop
  for img in "$ROOT_IMG" "$ESP_IMG" "$INSTALL_IMG"; do
    [[ -f "$img" ]] || continue
    # Whole-disk images (install.img) also have the no-'p' partition compat
    # symlinks cmd_install creates for install.sh (_make_loop_partition_compat);
    # drop those, then let _detach_all_loops close any LUKS mapping still
    # backed by the device and detach every attachment.
    while read -r loop; do
      [[ -n "$loop" ]] || continue
      rm -f "${loop}1" "${loop}2"
      any=1
    done < <(_loops_for_image "$img")
    _detach_all_loops "$img"
  done

  rm -f /dev/disk/by-label/shani_root /dev/disk/by-label/shani_boot
  rm -f "${DATA_DIR}/.root_loop" "${DATA_DIR}/.esp_loop" "${DATA_DIR}/.install_loop"

  if (( any )); then
    log "Clean complete — root.img/esp.img/install.img left in place, everything else torn down"
  else
    log "Nothing to clean up"
  fi
}

# install.sh's get_partition_prefix() only special-cases nvme*/mmcblk*
# device names (appending a 'p' before the partition number) — every other
# device path, including /dev/loopN, falls through to the bare
# "${OSI_DEVICE_PATH}<N>" form (e.g. /dev/loop71), which is NOT how the
# kernel actually names loop-device partitions (/dev/loop7p1). Real installs
# never hit this — physical disks are sd*/nvme*/mmcblk* only — but a loop
# device is exactly what this harness has to offer, so bridge the gap with
# compatibility symlinks rather than patch install.sh (the entire point is
# to run it UNMODIFIED). Symlinks resolve lazily, so it's safe to create
# these before the partitions they point at actually exist.
_make_loop_partition_compat() {
  local loop="$1"
  ln -sf "${loop}p1" "${loop}1"
  ln -sf "${loop}p2" "${loop}2"
}

# install.sh/configure.sh mount both partitions exclusively via
# /dev/disk/by-label/{shani_boot,shani_root} (BOOTLABEL/ROOTLABEL, hardcoded
# in both scripts and in bits/part.sfdisk) — on real hardware a live udevd
# creates those from each filesystem's on-disk label; this container runs no
# udevd, same reason cmd_disk creates shani_root/shani_boot's by-label
# symlinks by hand instead of relying on one (see _ensure_disk_attached).
# Safe to create/refresh before the partitions or LUKS mapping actually
# exist — symlinks resolve lazily, and by the time install.sh/configure.sh
# actually dereference them (mount_boot_partition, mount_target), the real
# targets are already in place. shani_root points at the LUKS mapper if one
# is already open (an encrypted install: install.sh opens it as mapper name
# "shani_root", i.e. exactly $ROOTLABEL, and never closes it) or at the raw
# partition otherwise — so this is correct whether called before install.sh
# has run at all or reattaching to an already-encrypted disk later.
_ensure_install_by_label_symlinks() {
  local loop="$1"
  mkdir -p /dev/disk/by-label
  ln -sf "${loop}p1" /dev/disk/by-label/shani_boot
  if [[ -e /dev/mapper/shani_root ]]; then
    ln -sf /dev/mapper/shani_root /dev/disk/by-label/shani_root
  else
    ln -sf "${loop}p2" /dev/disk/by-label/shani_root
  fi
}

# Re-attaches install.img's loop device across separate run_in_container.sh
# invocations (same principle, and same _ensure_single_loop machinery, as
# _ensure_disk_attached uses for root.img/esp.img), and recreates the
# loop-partition compat symlinks + by-label symlinks above (they live under
# /dev, so device NUMBERS don't survive a fresh container, even though the
# symlink files themselves would via the host /dev bind mount). Prints the
# loop device path to stdout.
_ensure_install_attached() {
  [[ -f "$INSTALL_IMG" ]] || die "install.img not found under $DATA_DIR — run '$(basename "$0") install' first"
  local loop
  loop="$(_ensure_single_loop "$INSTALL_IMG")"
  echo "$loop" > "${DATA_DIR}/.install_loop"
  _make_loop_partition_compat "$loop"
  _ensure_install_by_label_symlinks "$loop"
  echo "$loop"
}
