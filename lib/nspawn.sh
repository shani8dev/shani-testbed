# Minimal stand-in for systemd-inhibit inside the test container.
# shani-deploy.sh calls it like:
#   systemd-inhibit --what=... --who=... --why=... [env NAME=VAL ...] <script> <args...>
# There's no logind/session in the container so real inhibitor locks make no
# sense here. Strip the systemd-inhibit-specific tokens and exec the rest.
# Bind-mounted BY PATH into the nspawn container (see cmd_enter below), so it
# has to exist as a real file on disk — written out once here, idempotently.
_ensure_inhibit_stub() {
  [[ -f "$INHIBIT_STUB" ]] && return 0
  mkdir -p "$DATA_DIR"
  cat > "$INHIBIT_STUB" <<'STUBEOF'
#!/bin/bash
set -euo pipefail

cmd=()
for a in "$@"; do
    case "$a" in
        --what=*|--who=*|--why=*|--mode=*) continue ;;
        env) continue ;;
        *=*)
            if [[ ${#cmd[@]} -eq 0 ]]; then
                export "${a?}"
                continue
            fi
            ;;
    esac
    cmd+=("$a")
done

exec "${cmd[@]}"
STUBEOF
  chmod +x "$INHIBIT_STUB"
}

# ------------------------------------------------------------------
# enter   (was 03-enter-slot.sh)
# ------------------------------------------------------------------
# ------------------------------------------------------------------
# Shared enter/boot preparation
# ------------------------------------------------------------------
# Prepares mounts + overlay for entering/booting a slot. Sets globals:
#   SLOT_DIR, ROOT_LOOP, ESP_LOOP, NSPAWN_WORK
#
# Overlay hygiene matters: every run_in_container.sh invocation is a fresh
# container that dies without cleanup, so a previous overlay mount may still
# be present, and an overlay workdir that still holds another mount's
# index/journal MUST NOT be reused — remounting with a dirty workdir yields
# missing/stale views of upper-layer files (files written into upper/ from
# outside appear to vanish). Always tear down leftovers and reset the
# journal before mounting.
#
# NOTE: nspawn-overlay-<slot>/upper and /work are INTERNAL overlay state.
# Do not stage files there from the host — inject scripts via /mnt/repo
# (read-only repo bind) or SHANIOS_TEST_EXTRA_BINDS instead.
_enter_prep() {
  local slot="$1"

  _mount_root

  SLOT_DIR="$MNT/@${slot}"
  [[ -d "$SLOT_DIR" ]] || die "@${slot} does not exist — run '$(basename "$0") bootstrap' first"

  mkdir -p "$ESP_MNT"
  mountpoint -q "$ESP_MNT" || mount /dev/disk/by-label/shani_boot "$ESP_MNT"

  # Resolve directly from the by-label symlinks rather than a cached
  # .root_loop/.esp_loop file — those were only ever written by cmd_disk's
  # (now removed) root.img/esp.img path, never by cmd_install's install.img path (which
  # cmd_bootstrap now always uses), and this naturally does the right thing
  # for an encrypted install too: shani_root then points at the open LUKS
  # mapper (/dev/mapper/shani_root), which is what needs to be bound into
  # nspawn, not the raw underlying partition. _ensure_install_attached already
  # guarantees both symlinks resolve before this point.
  ROOT_LOOP=$(readlink -f /dev/disk/by-label/shani_root)
  ESP_LOOP=$(readlink -f /dev/disk/by-label/shani_boot)

  NSPAWN_WORK="${DATA_DIR}/nspawn-overlay-${slot}"

  # Tear down BOTH slots' overlays, not just this one: an overlay left
  # mounted from an earlier command pins its slot subvolume as lowerdir, and
  # a real machine never has the non-booted slot mounted. Observed live: the
  # suite's `upgrade` left @blue's overlay mounted, so `rollback` (in @green)
  # deleted the old @blue while the harness still held it, and shani-deploy's
  # `btrfs subvolume sync` waited out its whole 900s timeout. Upper-layer
  # state lives on disk, so re-entering a slot is unaffected.
  local _s _m
  for _s in blue green; do
    _m="${DATA_DIR}/nspawn-overlay-${_s}/merged"
    if mountpoint -q "$_m" 2>/dev/null; then
      log "Unmounting stale overlay at ${_m}"
      umount -R "$_m" 2>/dev/null || umount -l "$_m" 2>/dev/null || warn "Failed to unmount ${_m}"
    fi
  done
  rm -rf "$NSPAWN_WORK/work"
  mkdir -p "$NSPAWN_WORK/upper" "$NSPAWN_WORK/work" "$NSPAWN_WORK/merged"
  _revert_local_src_overlay
  mount -t overlay overlay -o "lowerdir=${SLOT_DIR},upperdir=${NSPAWN_WORK}/upper,workdir=${NSPAWN_WORK}/work" "$NSPAWN_WORK/merged"
  [[ -n "${SHANIOS_TEST_LOCAL_PKGS:-}" ]] && _overlay_local_pkgs "$slot" "$SHANIOS_TEST_LOCAL_PKGS"
  return 0
}

# _overlay_local_pkgs <slot> <pkg[,pkg...]>  (--local-pkg / SHANIOS_TEST_LOCAL_PKGS)
# Test an UNPUBLISHED package in a real slot: its files are extracted over
# the slot's overlay (upper layer), recorded in the same list --local-src
# uses, so the next run without it reverts to the image's copies. A booted
# ShaniOS has no pacman, so this is a file overlay: the package's .install
# scriptlet does NOT run, and files a newer version deletes stay present.
# Each entry is a *.pkg.tar.zst path, or a bare package name resolved to the
# newest build under /opt/shani-pkgbuilds/<name>/ (run_in_container.sh
# mounts the sibling shani-pkgbuilds checkout there).
_overlay_local_pkgs() {
  local slot="$1" list="$2" spec pkg tmp rel n
  local -a specs
  IFS=',' read -r -a specs <<<"$list"
  for spec in "${specs[@]}"; do
    [[ -n "$spec" ]] || continue
    if [[ "$spec" == *.pkg.tar.* ]]; then pkg="$spec"
    else pkg=$(ls -t /opt/shani-pkgbuilds/"$spec"/"$spec"-*.pkg.tar.zst 2>/dev/null | grep -v -- '-debug-' | head -1 || true)
    fi
    [[ -n "$pkg" && -f "$pkg" ]] || die "--local-pkg=${spec}: no built package found (build it with shani-pkgbuilds/make_pkg.sh ${spec})"
    tmp=$(mktemp -d)
    tar --zstd -xf "$pkg" -C "$tmp" --exclude=.PKGINFO --exclude=.BUILDINFO --exclude=.MTREE --exclude=.INSTALL --exclude=.CHANGELOG \
      || { rm -rf "$tmp"; die "--local-pkg: cannot extract ${pkg}"; }
    n=0
    while IFS= read -r -d '' rel; do
      rel="${rel#./}"
      mkdir -p "${NSPAWN_WORK}/merged/$(dirname "$rel")"
      cp -a --remove-destination "${tmp}/${rel}" "${NSPAWN_WORK}/merged/${rel}"
      echo "$rel" >> "$(_local_src_record)"
      n=$((n + 1))
    done < <(cd "$tmp" && find . \( -type f -o -type l \) -print0)
    rm -rf "$tmp"
    log "Overlaid $(basename "$pkg") onto @${slot}: ${n} file(s) (no .install scriptlet run; reverted on the next run without --local-pkg)"
  done
}

# Builds nspawn bind arrays shared by `enter` and `verify-boot`.
# Sets globals: FUSE_BIND, REPO_BIND, EXTRA_BIND_ARR, HOSTS_BIND
_nspawn_binds() {
  FUSE_BIND=()
  [[ -e /dev/fuse ]] && FUSE_BIND=(--bind=/dev/fuse)

  # Read-only view of this repo inside the slot — the supported way to run
  # repo scripts against the installed system (e.g. /mnt/repo/test-scripts/foo.sh).
  REPO_BIND=(--bind-ro="${REPO_ROOT}:/mnt/repo" --bind-ro="${TESTBED_ROOT}:/mnt/testbed")

  HOSTS_BIND=(--bind="$(_ensure_test_hosts_file):/etc/hosts")

  # Host-persistent cache for shani-deploy's downloaded update images —
  # run_in_container.sh bind-mounts a host dir at /var/cache/shani-downloads
  # (same convention/path as its own CONTAINER_DOWNLOAD_CACHE; keep both in
  # sync if this ever changes), and this binds it over the slot's real
  # /data/downloads. Without it, a full cmd_bootstrap/cmd_install re-run
  # wipes install.img's @data subvolume from scratch, forcing a full
  # multi-GB re-download every time even though the downloaded image itself
  # has nothing to do with any particular install session. A no-op if that
  # container path isn't present (e.g. running test.sh directly on the host
  # rather than through run_in_container.sh).
  DOWNLOAD_CACHE_BIND=()
  [[ -d /var/cache/shani-downloads ]] && DOWNLOAD_CACHE_BIND=(--bind=/var/cache/shani-downloads:/data/downloads)

  # Bind the host's real X11 socket through (run_in_container.sh already
  # did this one layer up, Docker host -> Docker container, when DISPLAY
  # was set there — this is the SAME bind one layer further in, Docker
  # container -> nspawn container, so a GUI app run inside test-env can
  # render on the host's actual display instead of needing a separate
  # headless compositor set up inside nspawn. See run_in_container.sh's
  # X11_FORWARD_ARGS comment for the full story of why this exists. A
  # no-op if /tmp/.X11-unix isn't present in the Docker container (i.e.
  # run_in_container.sh's own bind was skipped — no host DISPLAY at all).
  X11_BIND=()
  [[ -d /tmp/.X11-unix ]] && X11_BIND=(--bind=/tmp/.X11-unix:/tmp/.X11-unix)

  # Same idea for a Wayland host — see run_in_container.sh's
  # WAYLAND_FORWARD_ARGS comment for the full story. Docker already
  # bound the one socket file through to this same path one layer up; if
  # it's there, forward it one more layer into nspawn.
  WAYLAND_BIND=()
  if [[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" && \
        -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]; then
    WAYLAND_BIND=(--bind="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}:${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}")
  fi

  EXTRA_BIND_ARR=()
  if [[ -n "$EXTRA_BINDS" ]]; then
    local pair rest="$EXTRA_BINDS"
    while [[ -n "$rest" ]]; do
      pair="${rest%%,*}"
      if [[ "$rest" == *,* ]]; then rest="${rest#*,}"; else rest=""; fi
      [[ "$pair" == *:* ]] || die "SHANIOS_TEST_EXTRA_BINDS entry '${pair}' must be host_path:container_path"
      EXTRA_BIND_ARR+=(--bind="$pair")
    done
  fi
}

# Injects a test-only systemd unit that bind-mounts the REAL generated
# cmdline file (/data/overlay/etc/upper/kernel/install_cmdline_<slot> —
# the same real file cmd_enter's non-boot $setup already uses) over
# /proc/cmdline, inside the slot about to be --boot'd. Needed because
# nspawn shares the HOST kernel and never populates a Shanios-real
# /proc/cmdline on its own — without this, get_booted_subvol()-dependent
# real code (check-boot-failure.service, mark-boot-success's
# boot-success-cleanup) always hits its "cannot detect booted subvolume"
# fallback during a --boot test, which doesn't exercise the logic actually
# being tested.
#
# Ordering: nspawn/systemd always mounts a FRESH procfs for the
# container's own PID namespace as part of very-early startup — a
# pre-boot bind-mount at /proc/cmdline (the trick cmd_enter's non-boot
# path uses) would just get shadowed the moment that happens. This unit
# instead runs INSIDE the booted container, ordered after systemd's own
# early mount setup but before sysinit.target — generously early relative
# to mark-boot-success.service (After=multi-user.target) and
# check-boot-failure.timer (WantedBy=timers.target), the two real
# consumers, so both see the fake value already in place whenever they
# actually run. /data itself needs no ordering dependency — it's already
# present from the moment this container's PID 1 starts (an nspawn-level
# --bind, not something systemd mounts itself).
#
# Written to /etc/systemd/system/ (the standard place for host/admin-
# added units, never a real packaged unit name) in the merged overlay,
# not /usr/lib/systemd/system/ (reserved for what --local-src overlays as
# a stand-in for real packaged units).
_inject_fake_cmdline_unit() {
  local slot="$1"
  local unit_dir="${NSPAWN_WORK}/merged/etc/systemd/system"
  local unit_name="shani-test-fake-cmdline.service"
  mkdir -p "$unit_dir" "${unit_dir}/sysinit.target.wants"
  cat > "${unit_dir}/${unit_name}" <<EOF
[Unit]
Description=TEST-ONLY: fake /proc/cmdline from the real generated cmdline file (nspawn shares the host kernel, never populates a real one)
DefaultDependencies=no
After=systemd-remount-fs.service
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'mount --bind /data/overlay/etc/upper/kernel/install_cmdline_${slot} /proc/cmdline 2>/dev/null || true'

[Install]
WantedBy=sysinit.target
EOF
  ln -sf "../${unit_name}" "${unit_dir}/sysinit.target.wants/${unit_name}"
}

# Injects a REAL (not generator-synthesized) data.mount unit file so
# `systemd-analyze verify` can resolve it as a dependency for
# mark-boot-in-progress.service/mark-boot-success.service/
# check-boot-failure.service/shani-auto-rollback.service (all
# Requires=data.mount) — confirmed live this session that
# systemd-fstab-generator refuses to generate ANY unit for
# `LABEL=shani_root ... subvol=@data` under nspawn ("is read-only
# (running in a container?), ignoring mount for
# /dev/disk/by-label/shani_root" — its own built-in container-detection
# skipping device-label lookups it assumes a container can't safely do),
# even during a genuine --boot session. At RUNTIME this is harmless —
# `/data` is already bind-mounted by nspawn's own --bind before systemd
# starts, and systemd's automatic mountinfo-to-transient-unit mechanism
# creates a live, active data.mount reflecting that reality regardless
# (confirmed live: `systemctl status data.mount` shows "Loaded: loaded
# (/proc/self/mountinfo)", "Active: active (mounted)") — so real units
# depending on it work fine under --boot. The gap is purely in STATIC
# analysis: systemd-analyze verify never consults a live manager for
# dependency resolution, only on-disk unit files, so it reports "Unit
# data.mount not found" even though the live unit genuinely exists and
# works. This stub closes that gap for the static tool without touching
# runtime mount behavior at all: `Where=/data` matches what's already
# mounted, so systemd recognizes it as already-satisfied rather than
# attempting a real mount syscall that would conflict with the existing
# nspawn bind-mount.
_inject_data_mount_unit() {
  local unit_dir="${NSPAWN_WORK}/merged/etc/systemd/system"
  mkdir -p "$unit_dir"
  cat > "${unit_dir}/data.mount" <<EOF
[Unit]
Description=TEST-ONLY: real data.mount unit file so systemd-analyze verify can resolve it as a dependency (see comment above _inject_data_mount_unit in test.sh) — /data is already bind-mounted by nspawn itself before systemd starts, this unit performs no mount action of its own at runtime

[Mount]
What=LABEL=shani_root
Where=/data
Type=btrfs
Options=subvol=@data,noatime,compress=zstd,space_cache=v2,autodefrag
EOF
}

# Injects a test-only early-boot unit that creates the
# /dev/disk/by-label/shani_root and /dev/disk/by-label/shani_boot symlinks
# real hardware gets for free from udev. Needed because a --boot session
# has no real udev managing these loop-backed devices' labels — confirmed
# live via shani-auto-rollback.service genuinely running under a real
# --boot probe and shani-deploy --rollback's own `mount ... /dev/disk/
# by-label/shani_root /mnt` failing with "special device ... does not
# exist" (dmesg: no such symlink). The device nodes themselves ARE already
# present inside the container at these exact paths (`--bind="$ROOT_LOOP"`/
# `--bind="$ESP_LOOP"` in both NSPAWN_ENTER_ARGS and
# NSPAWN_FULL_BOOT_ARGS bind them in unchanged, source path == dest path)
# — only the conventional by-label symlink is missing. cmd_enter's
# non-boot $setup already does exactly this same trick for that path; this
# is the --boot-session equivalent, needed because a full boot has no
# single pre-exec shell hook to run it from.
_inject_by_label_unit() {
  local unit_dir="${NSPAWN_WORK}/merged/etc/systemd/system"
  local unit_name="shani-test-by-label.service"
  mkdir -p "$unit_dir" "${unit_dir}/sysinit.target.wants"
  cat > "${unit_dir}/${unit_name}" <<EOF
[Unit]
Description=TEST-ONLY: /dev/disk/by-label/shani_root + shani_boot symlinks (no real udev for these loop-backed devices under nspawn)
DefaultDependencies=no
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'mkdir -p /dev/disk/by-label && ln -sf ${ROOT_LOOP} /dev/disk/by-label/shani_root && ln -sf ${ESP_LOOP} /dev/disk/by-label/shani_boot'

[Install]
WantedBy=sysinit.target
EOF
  ln -sf "../${unit_name}" "${unit_dir}/sysinit.target.wants/${unit_name}"
}

# Populates NSPAWN_FULL_BOOT_ARGS — the common systemd-nspawn flag block
# shared by every "boot this slot with full systemd" invocation. Found
# duplicated near-verbatim (18 flags, byte-for-byte) in 3 separate places
# (cmd_enter's --boot branch, verify-boot, desktop) — exactly the class of
# drift risk get_booted_subvol's duplication in shani-deploy already
# proved real: fix/extend one copy (a new required --bind, a changed
# --system-call-filter), forget the other two. Call _nspawn_binds first
# (this reads its FUSE_BIND/HOSTS_BIND/REPO_BIND/EXTRA_BIND_ARR globals).
# Also injects the fake-/proc/cmdline unit above — every real "boot this
# slot" caller wants it, so it lives here instead of being called
# separately at each of the same 3 call sites.
# cmd_enter's *non*-boot branch is a real variant, not folded in here — it
# has no --boot/--machine=/--private-users=no/FUSE_BIND/--system-call-
# filter at all, plus its own --bind for the systemd-inhibit stub and a
# trailing exec command; forcing it through this same helper would need
# more parameters than it'd save lines. It fakes /proc/cmdline its own
# way already (a runtime `mount --bind` in $setup, safe there since
# nothing re-mounts /proc afterward in non-boot mode).
# Usage: _nspawn_full_boot_args <machine-name> <slot>
_nspawn_full_boot_args() {
  local machine="$1" slot="$2"
  _inject_fake_cmdline_unit "$slot"
  _inject_data_mount_unit
  _inject_by_label_unit
  NSPAWN_FULL_BOOT_ARGS=(
    --quiet
    --register=no
    --keep-unit
    --boot
    --machine="$machine"
    --directory="$NSPAWN_WORK/merged"
    --capability=all
    --private-users=no
    "${FUSE_BIND[@]}"
    --bind="$ROOT_LOOP"
    --bind="$ESP_LOOP"
    --bind="$MNT/@data:/data"
    "${DOWNLOAD_CACHE_BIND[@]}"
    --bind="$MNT/@swap:/swap"
    --bind="$ESP_MNT:/boot/efi"
    "${HOSTS_BIND[@]}"
    "${REPO_BIND[@]}"
    "${EXTRA_BIND_ARR[@]}"
    "${X11_BIND[@]}"
    "${WAYLAND_BIND[@]}"
    --resolv-conf=bind-host
    --system-call-filter='add_key keyctl bpf'
  )
}

# ------------------------------------------------------------------
# Local source overlay for `enter --local-src=<dir>`
# ------------------------------------------------------------------
# Copies edited shani-deploy/gen-efi/shani-update/check-boot-failure scripts
# over the package-installed versions inside the slot that's about to be
# entered — the thing both agents used to do by hand (stage files under
# test-env/edited-*/, then `cp` them into the running slot from inside an
# nspawn session) every time they needed to test an unreleased fix.
#
# Naming convention: <dir>/<name>.sh, where <name> matches EXACTLY what
# shani-pkgbuilds/shani-deploy/PKGBUILD installs at /usr/local/bin/<name> —
# its package() step strips the .sh extension at build time. So:
#   shani-deploy.sh        -> /usr/local/bin/shani-deploy
#   shani-update.sh        -> /usr/local/bin/shani-update
#   gen-efi.sh             -> /usr/local/bin/gen-efi
#   check-boot-failure.sh  -> /usr/local/bin/check-boot-failure
# run_in_container.sh bind-mounts the sibling shani-deploy checkout
# read-only at /opt/shani-deploy (same optional convention as
# /opt/os-installer-config) — always current, nothing to keep in sync by
# hand. Pass its scripts/ dir directly:
#   enter blue --local-src=/opt/shani-deploy/scripts
# Any other *.sh file in the directory is applied the same way (basename
# minus .sh) IF a same-named file already exists at /usr/local/bin in the
# slot; anything that doesn't match an existing installed script is skipped
# with a warning rather than silently ignored (protects against a typo'd
# filename looking like it worked).
#
# Lands in the nspawn overlay's upper layer (via _enter_prep, same as any
# other write made from inside a session) — NOT the real @blue/@green
# subvolume, and NOT test-env/edited-*/ itself. Plain `cp -f`, so running
# this twice (or twenty times) just re-copies the same files: no doubling,
# no error, no state to reset — genuinely idempotent.
# ------------------------------------------------------------------
# State file listing every path (relative to the slot root) a --local-src
# overlay wrote into this slot's persistent overlay upper layer.
_local_src_record() { echo "${NSPAWN_WORK}/.local-src-overlaid"; }

# Undo the previous run's --local-src overlay. The overlay upper layer
# persists across runs on purpose (session state), but overlaid scripts/units
# used to persist with it, so a later run WITHOUT --local-src silently kept
# booting the old overlaid copies (hit live: a "baseline" probe still had an
# OnFailure= line from the previous run's units). Deleting each recorded
# file from upper/ (while the overlay is NOT mounted) makes the image's own
# copy in the lower layer visible again; a file that only ever existed as an
# overlay ([NEW]) simply disappears. Only recorded paths are touched.
_revert_local_src_overlay() {
  local record rel n=0
  record="$(_local_src_record)"
  [[ -f "$record" ]] || return 0
  while IFS= read -r rel; do
    [[ -n "$rel" && "$rel" != /* && "$rel" != *..* ]] || continue
    if [[ -e "${NSPAWN_WORK}/upper/${rel}" || -L "${NSPAWN_WORK}/upper/${rel}" ]]; then
      rm -f "${NSPAWN_WORK}/upper/${rel}"
      n=$((n + 1))
    fi
  done < <(sort -u "$record")
  rm -f "$record"
  (( n == 0 )) || log "Reverted ${n} file(s) overlaid by a previous --local-src run (image copies visible again)"
}

# Copies one --local-src file into the merged slot view, if the image already
# ships a file at that path (or SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC=1), and
# records it for _revert_local_src_overlay. Returns 0 if copied.
# Usage: _overlay_one <slot> <src> <dest-in-merged> <path-as-shown> [chmod-mode]
#
# The ALLOW_NEW opt-in is deliberately not the default: introducing a name
# that was never in the image is indistinguishable, in the default path, from
# a typo'd filename silently no-op'ing. It's for testing an in-progress,
# not-yet-packaged new script or unit — confirmed useful live:
# mark-boot-success.service's ExecStart=/usr/local/bin/boot-success-cleanup
# failed with "No such file" precisely because the script existed only as an
# untracked local file.
_overlay_one() {
  local slot="$1" src="$2" dest="$3" shown="$4" mode="${5:-}" tag=""
  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    if [[ "${SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC:-0}" != "1" ]]; then
      warn "  skipping ${src}: no existing ${shown} in @${slot} (not a recognized packaged file — set SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC=1 to overlay it anyway)"
      return 1
    fi
    tag="[NEW] "
  fi
  cp -f "$src" "$dest"
  if [[ -n "$mode" ]]; then chmod "$mode" "$dest"; fi
  echo "${dest#"${NSPAWN_WORK}/merged/"}" >> "$(_local_src_record)"
  log "  ${tag}${src} -> ${shown}"
  return 0
}

_overlay_local_src() {
  local slot="$1" src_dir="$2"
  [[ -d "$src_dir" ]] || die "--local-src=${src_dir}: not a directory"

  local target_bin="${NSPAWN_WORK}/merged/usr/local/bin"
  [[ -d "$target_bin" ]] || die "${target_bin} not found inside @${slot} — run '$(basename "$0") bootstrap' first"

  log "Overlaying local sources from ${src_dir} onto @${slot}'s /usr/local/bin:"
  local applied=0 f base
  shopt -s nullglob
  for f in "$src_dir"/*.sh; do
    base="$(basename "$f" .sh)"
    if _overlay_one "$slot" "$f" "${target_bin}/${base}" "/usr/local/bin/${base}" 755; then
      applied=$((applied + 1))
    fi
  done
  shopt -u nullglob
  (( applied > 0 )) || warn "--local-src=${src_dir}: nothing overlaid (no *.sh under it matched an existing /usr/local/bin script in @${slot})"
  log "Local source overlay complete: ${applied} file(s) applied (this session's overlay only, see ${NSPAWN_WORK}/upper)"

  # Also overlay systemd unit files, if the caller's repo follows the
  # convention `<repo>/scripts/*.sh` + `<repo>/systemd/{system,user}/*` —
  # i.e. $src_dir's own parent has a sibling `systemd/` dir (shani-deploy's
  # actual real layout). Found the hard way: a *.sh-only overlay tests
  # edited *script logic* under `--boot`/`verify-boot`, but any edit to a
  # unit file itself (a hardening directive, a Requires=/After= change)
  # was silently invisible to those same commands — the real, packaged
  # unit files baked into the image are what systemd actually reads at
  # boot, and no verification command touched them. Same safety rule as
  # scripts: only overlay a unit whose name already exists in the image
  # (never introduce a unit that wasn't already packaged there).
  local systemd_root="$(dirname "$src_dir")/systemd"
  [[ -d "$systemd_root" ]] || return 0
  local scope target_units applied_units=0
  for scope in system user; do
    [[ -d "${systemd_root}/${scope}" ]] || continue
    target_units="${NSPAWN_WORK}/merged/usr/lib/systemd/${scope}"
    [[ -d "$target_units" ]] || continue
    for f in "${systemd_root}/${scope}"/*; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      if _overlay_one "$slot" "$f" "${target_units}/${base}" "/usr/lib/systemd/${scope}/${base}"; then
        applied_units=$((applied_units + 1))
      fi
    done
  done
  if (( applied_units > 0 )); then
    log "Local systemd unit overlay complete: ${applied_units} file(s) applied — takes effect on the next --boot/verify-boot (fresh PID 1 reads units from disk at startup, no daemon-reload needed since nothing is running yet)"
  fi
}

# Shared by cmd_enter's plain (non---boot) path and cmd_upgrade: does every
# bit of prep a non-boot nspawn entry needs (mount/overlay setup, inhibit
# stub, --local-src overlay, the real-cmdline bind-mount, nspawn binds) and
# sets global array NSPAWN_ENTER_ARGS, without executing anything — the
# caller decides how to actually run it (cmd_enter execs it directly and
# replaces this process; cmd_upgrade needs to run it, get a real exit code,
# AND return control to its own caller for cmd_cycle's subsequent
# cmd_reboot step, so it can't use exec).
_prepare_enter_args() {
  local slot="$1"; shift
  local local_src="$1"; shift

  _enter_prep "$slot"

  _ensure_inhibit_stub

  [[ -n "$local_src" ]] && _overlay_local_src "$slot" "$local_src"

  if [[ ${#} -eq 0 ]]; then
    set -- /bin/bash
  fi

  # /proc/cmdline is bind-mounted from the REAL generated cmdline file —
  # not fabricated content, the exact string gen-efi/configure.sh actually
  # write and that would really be embedded in this slot's UKI. Needed
  # because nspawn shares the HOST kernel and was never going to reflect
  # Shanios's real boot cmdline here on its own — without this,
  # get_booted_subvol()-dependent real code (check-boot-failure.service,
  # mark-boot-success's boot-success-cleanup) always hits its "cannot
  # detect booted subvolume" fallback during a test boot, which doesn't
  # exercise anything about the logic actually being tested. Source is
  # `/data/overlay/etc/upper/kernel/install_cmdline_<slot>`, NOT the plain
  # `/etc/kernel/install_cmdline_<slot>` path a real running system would
  # use — confirmed live that the latter only resolves correctly once the
  # real /etc overlay (a dracut pre-pivot hook on real hardware) is
  # actually mounted, which a plain `enter`/`--boot` session here does not
  # set up on its own; the /data bind-mount (already present in every
  # session) reaches the same real file directly regardless.
  local setup='mkdir -p /dev/disk/by-label && ln -sf '"$ROOT_LOOP"' /dev/disk/by-label/shani_root && ln -sf '"$ESP_LOOP"' /dev/disk/by-label/shani_boot && mount --bind /data/overlay/etc/upper/kernel/install_cmdline_'"$slot"' /proc/cmdline 2>/dev/null || true && exec "$@"'

  _nspawn_binds

  # --register=no: skip registering the new machine with systemd-machined
  # over D-Bus (see _ensure_dbus above for why a bus needs to exist at all).
  # --keep-unit: place the container in the CALLING process's own cgroup
  # instead of asking systemd (over that same bus) to allocate a transient
  # scope unit for it — there's no real systemd manager listening as
  # org.freedesktop.systemd1 on this bus, so that request would otherwise
  # fail with "Failed to allocate scope: Failed to execute program
  # org.freedesktop.systemd1: Permission denied".
  NSPAWN_ENTER_ARGS=(
      --quiet
      --register=no
      --keep-unit
      --directory="$NSPAWN_WORK/merged"
      --capability=all
      --bind="$ROOT_LOOP"
      --bind="$ESP_LOOP"
      --bind="$MNT/@data:/data"
      "${DOWNLOAD_CACHE_BIND[@]}"
      --bind="$MNT/@swap:/swap"
      --bind="$ESP_MNT:/boot/efi"
      "${HOSTS_BIND[@]}"
      --bind="${INHIBIT_STUB}:/usr/bin/systemd-inhibit"
      "${REPO_BIND[@]}"
      "${EXTRA_BIND_ARR[@]}"
      "${X11_BIND[@]}"
      "${WAYLAND_BIND[@]}"
      --resolv-conf=bind-host
      --
      /bin/bash -c "$setup" -- "$@"
  )
}

# ------------------------------------------------------------------
# enter   <blue|green> [--boot] [--local-src=<dir>] [cmd...]
# ------------------------------------------------------------------
# _ensure_by_label_dir — guard the nspawn boot commands against a missing
# /dev/disk/by-label before systemd-nspawn is even invoked.
#
# Why this exists: cmd_enter --boot, verify-boot, desktop and probe all build
# their container's /dev from the host, and the by-label mount path
# (/dev/disk/by-label/shani_root, used both by the slot's own data.mount and
# by shani-deploy's by-label mount) is created HERE on the host by `cmd_disk`
# (see _ensure_by_label_dir) as root:root. These four commands do
# NOT require `disk` to have been run first, so on an unprivileged host user
# where that dir simply does not exist yet, systemd-nspawn's own setup dies
# one layer deep with the opaque, non-actionable:
#
#     mkdir: cannot create directory '/dev/disk/by-label': Permission denied
#
# That message names neither the real prerequisite nor the command that
# satisfies it. This converts it into a fast, actionable pointer instead of
# letting the harness fail inside the container setup. Under nspawn with the
# host kernel only root can create that dir, so a plain unprivileged user
# hitting the missing dir cannot self-heal — the fix is to run `test disk`
# first (or the equivalent sudo one-liner below).
_ensure_by_label_dir() {
  if [[ ! -d /dev/disk/by-label ]]; then
    die "/dev/disk/by-label does not exist — systemd-nspawn boot commands need it (root:root). Run 'test disk' first, or: sudo mkdir -p /dev/disk/by-label && sudo chown root:root /dev/disk/by-label"
  fi
  if [[ ! -w /dev/disk/by-label && "$(id -u)" != "0" ]]; then
    die "/dev/disk/by-label is not writable by root — systemd-nspawn boot commands need it (root:root). Run 'test disk' first, or: sudo mkdir -p /dev/disk/by-label && sudo chown root:root /dev/disk/by-label"
  fi
  return 0
}


# ------------------------------------------------------------------
# Shared "boot this slot" plumbing for enter --boot / verify-boot / probe /
# desktop / app. These used to repeat the same prep block, reached-target
# check, leader-PID loop and (only in desktop) graceful shutdown.
# ------------------------------------------------------------------

# Everything a full --boot (or a GUI `app` session) needs before nspawn runs.
# Usage: _prepare_boot <slot> [local_src]
_prepare_boot() {
  local slot="$1" local_src="${2:-}"
  _ensure_host_machine_id
  _ensure_dbus
  _ensure_by_label_dir
  _enter_prep "$slot"
  if [[ -n "$local_src" ]]; then _overlay_local_src "$slot" "$local_src"; fi
  _nspawn_binds
  _ensure_inhibit_stub
}

# True once a console log shows userspace is up. Accepts either standard
# final target, or Basic System + Network (a slot may boot a custom
# default.target that never prints Multi-User/Graphical at all).
_boot_reached() {
  local logfile="$1"
  grep -aq "Reached target Graphical Interface" "$logfile" \
    || grep -aq "Reached target Multi-User System" "$logfile" \
    || { grep -aq "Reached target Basic System" "$logfile" \
         && grep -aq "Reached target Network" "$logfile"; }
}

BOOT_BG_PIDFILE_NAME="nspawn-boot.pid"

# Starts a full --boot of the prepared slot in the background, console to
# <logfile>. Sets BOOT_PID and installs an EXIT trap that shuts it down
# gracefully (see _boot_bg_stop). Call _prepare_boot first.
# Usage: _boot_bg_start <machine-name> <slot> <logfile>
_boot_bg_start() {
  local machine="$1" slot="$2" logfile="$3"
  _nspawn_full_boot_args "$machine" "$slot"
  systemd-nspawn "${NSPAWN_FULL_BOOT_ARGS[@]}" >"$logfile" 2>&1 &
  BOOT_PID=$!
  echo "$BOOT_PID" > "${DATA_DIR}/${BOOT_BG_PIDFILE_NAME}"
  trap _boot_bg_stop EXIT
  kill -0 "$BOOT_PID" 2>/dev/null || die "boot process failed to start — see ${logfile}"
}

# Gives the container up to 30s to power off GRACEFULLY (SIGTERM to
# systemd-nspawn becomes a clean poweroff of the real systemd inside) before
# SIGKILL. This matters: a hard kill of a live systemd mid-write to the real
# btrfs filesystem once left BOTH @blue and @green missing (needed a fresh
# bootstrap). Reads the pid back from a file because an EXIT trap runs after
# the caller's locals are gone. Any caller (CI included) must budget its own
# outer timeout comfortably above its boot timeout plus this 30s.
_boot_bg_stop() {
  local pidfile="${DATA_DIR}/${BOOT_BG_PIDFILE_NAME}" bp waited=0
  bp=$(cat "$pidfile" 2>/dev/null) || return 0
  [[ -n "$bp" ]] || { rm -f "$pidfile"; return 0; }
  if kill -0 "$bp" 2>/dev/null; then
    kill "$bp" 2>/dev/null || true
    while kill -0 "$bp" 2>/dev/null; do
      if (( waited >= 30 )); then
        warn "boot process ${bp} did not shut down gracefully within 30s — force-killing." \
             "If a later run dies with '@<slot> does not exist', re-run bootstrap."
        kill -9 "$bp" 2>/dev/null || true
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done
    wait "$bp" 2>/dev/null || true
  fi
  rm -f "$pidfile"
}

# Finds the container's PID 1 (systemd, a child of the nspawn supervisor).
# Sets LEADER_PID. The `|| true` on the assignment is load-bearing: with
# pipefail, `pgrep (no match) | head -1` fails and an assignment from a
# failing command substitution would kill the script under set -e on the
# (normal) iterations before the child has forked.
_wait_for_leader() {
  local logfile="$1" i
  LEADER_PID=""
  for (( i=0; i<20; i++ )); do
    LEADER_PID=$(pgrep -x systemd -P "$BOOT_PID" 2>/dev/null | head -1) || true
    if [[ -n "$LEADER_PID" ]]; then return 0; fi
    kill -0 "$BOOT_PID" 2>/dev/null || die "boot process exited early — see ${logfile}"
    sleep 1
  done
  die "could not find the container's init PID within 20s — see ${logfile}"
}

# Waits until <check-fn> <logfile> succeeds, up to <timeout> seconds.
# Usage: _wait_boot <logfile> <timeout> <what> <check-fn>
_wait_boot() {
  local logfile="$1" timeout="$2" what="$3" check="$4" waited=0
  while (( waited < timeout )); do
    if "$check" "$logfile"; then return 0; fi
    kill -0 "$BOOT_PID" 2>/dev/null || die "boot process exited early — see ${logfile}"
    sleep 1
    waited=$((waited + 1))
  done
  tail -30 "$logfile" || true
  die "never reached ${what} within ${timeout}s — see ${logfile}"
}
