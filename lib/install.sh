# ------------------------------------------------------------------
# pacstrap — real signature-verification smoke test for a profile's
# pacman.conf, independent of a full `build.sh image` run (30+ min).
#
# Runs an actual `pacstrap -cC image_profiles/<profile>/pacman.conf` against
# a throwaway target directory with a small, real package set — this is the
# same command build-base-image.sh uses, just pointed at a scratch dir
# instead of the real build's subvolume mount, so a SigLevel/mirror/keyring
# change can be proven to actually work (or fail) in minutes, using the
# real builder container's already-populated pacman keyring, without
# waiting for or discarding a full image build.
# ------------------------------------------------------------------
cmd_pacstrap() {
  local profile
  profile="$(_get_profile "$@")"
  [[ -n "$profile" ]] || die "pacstrap requires -p <profile>"

  local conf="${REPO_ROOT}/image_profiles/${profile}/pacman.conf"
  [[ -f "$conf" ]] || die "No such profile pacman.conf: $conf"

  local target
  target="$(mktemp -d "${DATA_DIR}/pacstrap-check.XXXXXX")"
  log "Real pacstrap smoke test — profile: ${profile}  config: ${conf}"
  log "Target (throwaway, removed after): ${target}"

  # Everything except `-p <profile>` is an extra package to install on top
  # of base (documented usage; this used to be silently ignored).
  local -a extra_pkgs=()
  local arg skip_next=0
  for arg in "$@"; do
    if (( skip_next )); then skip_next=0; continue; fi
    if [[ "$arg" == "-p" ]]; then skip_next=1; continue; fi
    extra_pkgs+=("$arg")
  done
  (( ${#extra_pkgs[@]} == 0 )) || log "Extra packages: ${extra_pkgs[*]}"

  local rc=0
  pacstrap -cC "$conf" "$target" base "${extra_pkgs[@]}" 2>&1 | tee "${target}.log" || rc=$?

  if (( rc == 0 )) && [[ -x "${target}/usr/bin/bash" ]]; then
    log "pacstrap OK — real packages installed and signature-verified under ${conf}'s SigLevel."
    rm -rf "$target" "${target}.log"
    return 0
  fi

  warn "pacstrap did NOT produce a working target — see ${target}.log for the real pacman/GPG error."
  # Never rm -rf across a mount pacstrap failed to tear down (proc/sys/dev).
  if grep -qF " ${target}" /proc/self/mountinfo; then
    warn "(exit code from pacstrap: ${rc}; ${target} still has mounts under it — left in place)"
  else
    rm -rf "$target"
    warn "(exit code from pacstrap: ${rc}; partial target removed, log kept: ${target}.log)"
  fi
  return 1
}

# Resolves -p <profile> -d <latest|stable|<date>> to a concrete
# <profile>-<version>.zst path under OUTPUT_DIR — shared by cmd_bootstrap and
# cmd_install so both ever pick the exact same build for a given selector.
# Prints the resolved path to stdout; dies with a pointer to the right
# `./build.sh release` invocation if nothing matches.
# _reset_slot_overlays — a fresh install creates new @blue/@green, so any
# overlay upper layer from an earlier install is stale: its copied-up files
# came from a different image and would shadow the new slot's own (found
# 2026-09-24: /usr copies from 09-17 over a 09-24 slot, 13 GB).
_reset_slot_overlays() {
  local s d
  for s in blue green; do
    d="${DATA_DIR}/nspawn-overlay-${s}"
    [[ -d "$d" ]] || continue
    if mountpoint -q "$d/merged" 2>/dev/null; then
      umount -R "$d/merged" 2>/dev/null || umount -l "$d/merged" 2>/dev/null || die "cannot unmount ${d}/merged"
    fi
    rm -rf "$d"
    log "Reset stale overlay for @${s} (new install)"
  done
  # (the --local-src/--local-pkg revert record lives inside that dir, so it
  # goes with it)
}

# ------------------------------------------------------------------
# _fetch_published <profile> <latest|stable|YYYYMMDD>
# ------------------------------------------------------------------
# Pull a PUBLISHED release from Cloudflare R2 into the same local layout a
# local build writes (${OUTPUT_DIR}/<profile>/<date>/ + <sel>.txt), so every
# profile can be installed and tested without first building it here - only
# gnome had ever been built locally, so plasma/cosmic/server/kiosk could not
# be bootstrapped at all. Same layout and trust rules as
# scripts/build-iso.sh --from-r2: files come from R2's public endpoint
# (R2_PUBLIC_BASE, default https://downloads.shani.dev - no credentials), the
# pointer falls back to the authenticated r2: rclone remote when R2_BUCKET is
# set, and the image (plus flatpakfs/snapfs when published) must pass SHA-256
# and a GPG signature by GPG_KEY_ID (gpg_prepare_keyring, config.sh) or it is
# deleted and the command dies.
#
# Downloads are resumable (<file>.part, `curl -C -`), and a transfer that
# drops below 100 KB/s for 60 s is abandoned and resumed. rclone was tried
# first and is NOT used for the large files: a multi-thread object download
# can't resume, and one stalled stream crawled at ~13 KB/s for the last 55 MB
# of 3.1 GB (default 5 min idle timeout, stats hidden below INFO).
_r2_get() {  # <url> <dest> <required:1|0>
  local url="$1" dest="$2" required="$3" try
  if [[ -f "$dest" ]]; then return 0; fi
  if ! curl -fsSI --max-time 30 "$url" >/dev/null 2>&1; then
    (( required )) && die "Not found on R2: ${url}"
    return 1
  fi
  local pid rc
  for try in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
      --speed-limit 102400 --speed-time 60 -C - -o "${dest}.part" "$url" &
    pid=$!
    # progress in the log (a silent multi-GB fetch looks hung)
    while kill -0 "$pid" 2>/dev/null; do
      sleep 30
      kill -0 "$pid" 2>/dev/null && log "  $(basename "$dest"): $(du -h "${dest}.part" 2>/dev/null | cut -f1) so far"
    done
    rc=0; wait "$pid" || rc=$?
    if (( rc == 0 )); then mv -f "${dest}.part" "$dest"; return 0; fi
    warn "download of $(basename "$dest") stopped (curl rc=${rc}, try ${try}/10) - resuming"
    sleep 5
  done
  die "Could not download ${url} after 10 tries"
}

_fetch_published() {
  local profile="$1" sel="$2" base filename date_dir dest f layer
  base="${R2_PUBLIC_BASE:-https://downloads.shani.dev}/${profile}"
  if [[ "$sel" == latest || "$sel" == stable ]]; then
    filename=$(curl -fsS --max-time 30 "${base}/${sel}.txt" 2>/dev/null | tr -d '[:space:]') || true
    if [[ -z "$filename" && -n "${R2_BUCKET:-}" ]] && command -v rclone >/dev/null 2>&1; then
      filename=$(rclone cat "r2:${R2_BUCKET}/${profile}/${sel}.txt" 2>/dev/null | tr -d '[:space:]') || true
    fi
    [[ -n "$filename" ]] || die "No ${sel}.txt for '${profile}' at ${base} - has it been released?"
    date_dir=$(grep -oE '[0-9]{8}' <<<"$filename" | head -n1) || true
    [[ -n "$date_dir" ]] || die "Couldn't parse a date out of '${filename}' (${base}/${sel}.txt)"
  else
    [[ "$sel" =~ ^[0-9]{8}$ ]] || die "--from-r2 -d wants latest, stable or YYYYMMDD (got '${sel}')"
    date_dir="$sel"; filename="${OS_NAME}-${sel}-${profile}.zst"
  fi
  dest="${OUTPUT_DIR}/${profile}/${date_dir}"
  mkdir -p "$dest"
  log "Fetching ${filename} from ${base}/${date_dir} (resumable)"
  for f in "$filename" flatpakfs.zst snapfs.zst; do
    local required=0; [[ "$f" == "$filename" ]] && required=1
    _r2_get "${base}/${date_dir}/${f}" "${dest}/${f}" "$required" || { log "  ${f}: not published - skipped"; continue; }
    _r2_get "${base}/${date_dir}/${f}.sha256" "${dest}/${f}.sha256" 1
    _r2_get "${base}/${date_dir}/${f}.asc" "${dest}/${f}.asc" 1
  done

  gpg_prepare_keyring
  for f in "${dest}/${filename}" "${dest}/flatpakfs.zst" "${dest}/snapfs.zst"; do
    [[ -f "$f" ]] || continue
    ( cd "$dest" && sha256sum --check --status "$(basename "$f").sha256" ) \
      || { rm -f "$f"; die "SHA-256 mismatch for $(basename "$f") (deleted) - re-run to download again"; }
    gpg --homedir "${BUILDER_GNUPGHOME}" --batch --verify "${f}.asc" "$f" 2>/dev/null \
      || { rm -f "$f"; die "GPG signature check failed for $(basename "$f") (deleted)"; }
    log "  verified $(basename "$f") (SHA-256 + GPG ${GPG_KEY_ID: -8})"
  done
  if [[ "$sel" == latest || "$sel" == stable ]]; then
    printf '%s\n' "$filename" > "${OUTPUT_DIR}/${profile}/${sel}.txt"
  fi
}

_resolve_build_image() {
  local profile="$1" date_sel="$2"
  local image

  if [[ "$date_sel" == "latest" || "$date_sel" == "stable" ]]; then
    local pointer="${OUTPUT_DIR}/${profile}/${date_sel}.txt"
    [[ -f "$pointer" ]] || die "No ${date_sel}.txt for profile '${profile}' — build/release it first (./build.sh release -p ${profile} ${date_sel})."
    local filename date_dir
    filename=$(tr -d '[:space:]' < "$pointer")
    # `|| true`: under `set -e -o pipefail`, if grep finds no match the
    # pipeline's exit status is 1, and — a real, easy-to-miss bash gotcha —
    # an assignment whose sole content is a command substitution propagates
    # that status to the assignment itself, which set -e treats as fatal.
    # Without the guard, a malformed pointer file would silently kill the
    # script right here instead of ever reaching the friendly die() below.
    date_dir=$(echo "$filename" | grep -oE '[0-9]{8}' | head -n1) || true
    [[ -n "$date_dir" ]] || die "Couldn't parse a date out of '${filename}' from ${pointer}"
    image="${OUTPUT_DIR}/${profile}/${date_dir}/${filename}"
  else
    image=$(find "${OUTPUT_DIR}/${profile}/${date_sel}" -maxdepth 1 -name "*-${profile}.zst" | head -n1)
    [[ -n "$image" ]] || die "No .zst found under ${OUTPUT_DIR}/${profile}/${date_sel}"
  fi

  [[ -f "$image" ]] || die "Image not found: $image"
  echo "$image"
}

# ------------------------------------------------------------------
# bootstrap   (was 01-bootstrap-rootfs.sh)
# ------------------------------------------------------------------
cmd_bootstrap() {
  # This used to be a fast, hand-rolled alternative to a real install —
  # receiving a pre-built .zst directly and snapshotting it, skipping
  # install.sh entirely, then separately reimplementing install.sh's own
  # create_subvolumes()/create_swapfile() lists, configure.sh's gen-efi
  # invocation, AND shani-deploy.sh's own loader-entry-writing conventions
  # by hand. Three separate parallel reimplementations of real production
  # logic living in this ONE file, none of them able to notice when the
  # real thing they were copying changed. Replaced entirely: this now
  # just calls the REAL install.sh/configure.sh via cmd_install/
  # cmd_configure — slower (a genuine partition+format+extract, not a
  # quick btrfs receive), but this now genuinely IS what a real install
  # produces, not a hand-maintained lookalike of it. The only step kept
  # here is the one thing that's genuinely test-only and has no
  # production equivalent to call instead: trust-anchoring this session's
  # throwaway CA into each slot, so cmd_serve's local HTTPS mirror
  # verifies for real inside a booted/entered slot.
  local usage_bootstrap="Usage: $(basename "$0") bootstrap -p <profile> [-d latest|stable|<date>] [--encrypted] [--from-r2]"
  _take_from_r2 "$@"
  set -- "${REST_ARGS[@]}"
  local from_r2="$FROM_R2"
  _take_encrypted "$@"
  set -- "${REST_ARGS[@]}"
  local encrypted="$ENCRYPTED"

  local profile="" date_sel="latest" opt OPTARG OPTIND=1
  while getopts "p:d:" opt "$@"; do
    case "$opt" in
      p) profile="$OPTARG" ;;
      d) date_sel="$OPTARG" ;;
      *) die "$usage_bootstrap" ;;
    esac
  done
  [[ -n "$profile" ]] || die "$usage_bootstrap"

  local ca_crt="${CA_DIR}/ca.crt"
  [[ -f "$ca_crt" ]] || die "Test CA not found at ${ca_crt} — run '$(basename "$0") ca' first."

  local -a install_args=(-p "$profile" -d "$date_sel")
  (( encrypted )) && install_args+=(--encrypted)
  (( from_r2 )) && install_args+=(--from-r2)
  cmd_install "${install_args[@]}"
  local -a configure_args=(-p "$profile")
  (( encrypted )) && configure_args+=(--encrypted)
  cmd_configure "${configure_args[@]}"

  log "Trust-anchoring this session's throwaway CA into @blue/@green (test-only — no production equivalent)"
  _mount_root
  local slot
  for slot in @blue @green; do
    if [[ -x "$MNT/$slot/usr/bin/trust" ]]; then
      btrfs property set -f -ts "$MNT/$slot" ro false
      cp "$ca_crt" "$MNT/$slot/etc/ca-certificates/trust-source/anchors/shanios-test-ca.crt"
      chroot "$MNT/$slot" trust extract-compat
      btrfs property set -f -ts "$MNT/$slot" ro true
    else
      warn "'trust' not found in @${slot#@} — local-mirror TLS verification will fail."
    fi
  done

  log "Bootstrap complete (via real install.sh + configure.sh)."
  log "Next: $(basename "$0") enter blue"
}

# configure.sh's setup_hostname_target/setup_locale_target/
# setup_keyboard_target/setup_timezone_target all end each `run_in_target`
# command with a real hostnamectl/localectl/timedatectl call in a `&&`
# chain — on a genuinely booted live-ISO install these succeed because the
# live session's own already-running systemd/hostnamed/localed/timedated get
# rbind-mounted into the chroot along with /run. Two things are missing here
# for that to work: (1) sd_booted() — which every one of those tools checks
# FIRST, unconditionally — only returns true if /run/systemd/system exists,
# which no real systemd instance in this container ever creates since none
# is running as PID 1; and (2) an actual hostnamed/localed/timedated
# registered on the bus to answer the D-Bus call itself. Faking both here
# (rather than in configure.sh, which must stay unmodified) is enough: the
# preceding half of each chained command (a plain `echo ... > /etc/...`
# inside the chroot) already writes the REAL value into the target
# correctly regardless — these three daemons only need to make the SECOND
# half of the chain return 0 instead of aborting the whole script via
# configure.sh's ERR trap. They're started unchrooted (this container's own
# /etc, thrown away on exit) since configure.sh's mount_target() runs later
# and would make a pre-chroot invocation moot anyway.
_ensure_systemd_target_services() {
  _ensure_dbus
  mkdir -p /run/systemd/system

  # Docker bind-mounts this container's own /etc/hostname as a single-file
  # mount point (a normal Docker behavior, unrelated to anything test.sh
  # does) — systemd-hostnamed (see below) writes a NEW static hostname via
  # unlink+rename, which fails with EBUSY against a live mount point.
  # systemd-hostnamed only ever touches the outer container's OWN /etc here
  # (see the comment above), which this harness has no use for anyway, so
  # freeing that mountpoint is harmless.
  umount -l /etc/hostname 2>/dev/null || true

  local svc bin
  for svc in hostnamed localed timedated; do
    bin="/usr/lib/systemd/systemd-${svc}"
    pgrep -f "systemd-${svc}" &>/dev/null && continue
    if [[ -x "$bin" ]]; then
      "$bin" &>/dev/null &
      disown
    else
      warn "$bin not found — hostnamectl/localectl/timedatectl inside configure.sh's chroot may fail"
    fi
  done
  sleep 1
}

# ------------------------------------------------------------------
# install / configure
# ------------------------------------------------------------------
# Closes the exact gap this README used to call out under "What this does
# NOT simulate": cmd_bootstrap used to fabricate @blue/@green directly
# (btrfs receive + snapshot, then a manual gen-efi call and a hand-rolled
# copy of shani-deploy.sh's loader-entry conventions) and skip
# install.sh/configure.sh entirely — fine for exercising shani-deploy/
# shani-update/gen-efi against an already-installed system, but it never
# actually ran the real install path, and left three separate hand-
# maintained reimplementations of real production logic in this file with
# no way to notice when the real thing they copied changed. cmd_install/
# cmd_configure instead run THOSE two scripts — unmodified, from the
# sibling os-installer-config checkout — driven purely by OSI_*
# environment variables, exactly how the real os-installer GUI invokes
# them. No GUI is involved or needed; every OSI_* variable each command
# sets was found by reading install.sh/configure.sh in full (see the
# comments below), not guessed. cmd_bootstrap is now just these two
# commands plus one genuinely test-only step (see cmd_bootstrap itself).
#
# Unlike cmd_disk's pre-partitioned ESP+root image pair, install.sh does its
# OWN partitioning (bits/part.sfdisk via sfdisk) against a whole-disk device
# — so this needs its own blank disk image, loop-attached with partition
# scanning (`losetup -P`) so /dev/loopNp1 / p2 appear once install.sh's own
# sfdisk+partprobe run.
# ------------------------------------------------------------------

# Resolves the os-installer-config checkout providing install.sh/
# configure.sh. run_in_container.sh bind-mounts it (read-only) at a fixed
# container path if it finds the sibling checkout on the host; falls back to
# the literal sibling-directory path for anyone running test.sh directly
# on the host. Override with SHANIOS_TEST_OSI_HOST_DIR (host side, read by
# run_in_container.sh) and/or SHANIOS_TEST_OSI_ROOT (this side). Sets global
# OSI_ROOT; dies with where it looked if nothing matches.
#
# Deliberately NOT under /mnt: the real install.sh/configure.sh hardcode
# /mnt (and /mnt/boot/efi) as their own install target and mount over it —
# a checkout bind-mounted under /mnt would be silently shadowed as soon as
# install.sh runs, breaking a same-session cmd_configure call right after
# cmd_bootstrap's cmd_install. Once resolved, OSI_ROOT is cached for the
# rest of this process/container invocation (rather than re-probed) for the
# same reason: caching just the string wouldn't be enough if the path were
# still under /mnt, but since it never is, a resolved OSI_ROOT stays valid
# for the whole run regardless of what install.sh mounts afterward.
_find_osi_root() {
  [[ -n "${OSI_ROOT:-}" && -f "${OSI_ROOT}/scripts/install.sh" && -f "${OSI_ROOT}/scripts/configure.sh" ]] && return 0
  local candidate
  for candidate in "${SHANIOS_TEST_OSI_ROOT:-}" /opt/os-installer-config "${REPO_ROOT}/../os-installer-config"; do
    [[ -n "$candidate" && -f "${candidate}/scripts/install.sh" && -f "${candidate}/scripts/configure.sh" ]] || continue
    OSI_ROOT="$(realpath "$candidate")"
    return 0
  done
  die "os-installer-config not found (checked \$SHANIOS_TEST_OSI_ROOT, /opt/os-installer-config, ${REPO_ROOT}/../os-installer-config) — check it out as a sibling of this repo (or set SHANIOS_TEST_OSI_HOST_DIR on the run_in_container.sh invocation / SHANIOS_TEST_OSI_ROOT here to point elsewhere)."
}

# ------------------------------------------------------------------
# install   -p <profile> [-d latest|stable|<date>] [--encrypted]
# ------------------------------------------------------------------
# OSI_USE_ENCRYPTION / OSI_ENCRYPTION_PIN exactly as install.sh and
# configure.sh read them. Sets TEST_LUKS_PIN (the passphrase in use).
_export_osi_encryption() {
  TEST_LUKS_PIN="${SHANIOS_TEST_LUKS_PIN:-shanios-test-passphrase}"
  export OSI_USE_ENCRYPTION=0
  unset OSI_ENCRYPTION_PIN
  if (( $1 )); then
    export OSI_USE_ENCRYPTION=1
    export OSI_ENCRYPTION_PIN="$TEST_LUKS_PIN"
  fi
}

cmd_install() {
  check_dependencies_install

  _take_from_r2 "$@"
  set -- "${REST_ARGS[@]}"
  local from_r2="$FROM_R2"
  _take_encrypted "$@"
  set -- "${REST_ARGS[@]}"
  local encrypted="$ENCRYPTED"

  local profile="" date_sel="latest" opt OPTARG OPTIND=1
  while getopts "p:d:" opt "$@"; do
    case "$opt" in
      p) profile="$OPTARG" ;;
      d) date_sel="$OPTARG" ;;
      *) ;;
    esac
  done
  [[ -n "$profile" ]] || die "Usage: $(basename "$0") install -p <profile> [-d latest|stable|<date>] [--encrypted] [--from-r2]"

  (( from_r2 )) && _fetch_published "$profile" "$date_sel"
  _reset_slot_overlays
  local image
  image="$(_resolve_build_image "$profile" "$date_sel")"

  _find_osi_root
  local sfdisk_layout="${OSI_ROOT}/bits/part.sfdisk"
  [[ -f "$sfdisk_layout" ]] || die "part.sfdisk not found at ${sfdisk_layout}"

  _ensure_root_sudo

  # Fresh whole-disk image (NOT cmd_disk's pre-partitioned pair — see the
  # comment above this section) — always wiped and recreated, so detach
  # whatever loop devices (if any, however many) are already attached to it
  # first, same preflight principle as cmd_disk.
  local size="${INSTALL_DISK_SIZE:-24G}"
  mkdir -p "$DATA_DIR"
  _detach_all_loops "$INSTALL_IMG"
  rm -f "$INSTALL_IMG"
  truncate -s "$size" "$INSTALL_IMG"
  local disk_loop
  disk_loop=$(losetup -P --find --show "$INSTALL_IMG") || die "Failed to attach loop device for $INSTALL_IMG"
  echo "$disk_loop" > "${DATA_DIR}/.install_loop"
  _make_loop_partition_compat "$disk_loop"
  log "install.img attached at ${disk_loop} (partitions land at ${disk_loop}p1/${disk_loop}p2, aliased to ${disk_loop}1/${disk_loop}2 for install.sh's loop-naming gap — see _make_loop_partition_compat)"

  # By-label symlinks install.sh/configure.sh mount through — see
  # _ensure_install_by_label_symlinks for why this container can't rely on
  # udev to create them. This call is the "before encryption is even set up"
  # case: shani_root aliases the raw partition for now; a later
  # `configure`'s _ensure_install_attached call re-points it at the LUKS
  # mapper automatically once install.sh (with --encrypted) has opened it.
  _ensure_install_by_label_symlinks "$disk_loop"

  # Stage the fixed paths install.sh hardcodes and can't be pointed
  # elsewhere via env — OSIDIR=/etc/os-installer, and
  # ROOTFSZST_SOURCE=/run/archiso/bootmnt/<os>/x86_64/rootfs.zst (normally
  # provided by the live ISO environment). Faked at the exact paths
  # install.sh reads, same principle as _ensure_inhibit_stub faking
  # systemd-inhibit for shani-deploy.sh.
  mkdir -p /etc/os-installer/bits
  cp -f "$sfdisk_layout" /etc/os-installer/bits/part.sfdisk
  [[ -f "${OSI_ROOT}/config.yaml" ]] && cp -f "${OSI_ROOT}/config.yaml" /etc/os-installer/config.yaml

  # Bind-mount, don't symlink: install.sh's extract_image() pipes each source
  # straight through `zstd -d` (no -f/--force), which refuses to follow a
  # symlink at all ("... is a symbolic link, ignoring") and silently feeds
  # btrfs receive an empty stream instead — confirmed live. A bind mount
  # looks like a plain regular file at that path, which is all zstd needs,
  # with no multi-GB copy.
  local archiso_dir="/run/archiso/bootmnt/${OS_NAME}/x86_64"
  mkdir -p "$archiso_dir"
  local profile_dir
  profile_dir="$(dirname "$image")"
  : > "${archiso_dir}/rootfs.zst"
  mount --bind "$image" "${archiso_dir}/rootfs.zst"
  if [[ -f "${profile_dir}/flatpakfs.zst" ]]; then
    : > "${archiso_dir}/flatpakfs.zst"
    mount --bind "${profile_dir}/flatpakfs.zst" "${archiso_dir}/flatpakfs.zst"
  fi
  if [[ -f "${profile_dir}/snapfs.zst" ]]; then
    : > "${archiso_dir}/snapfs.zst"
    mount --bind "${profile_dir}/snapfs.zst" "${archiso_dir}/snapfs.zst"
  fi

  # The full, realistic OSI_* environment install.sh reads (enumerated by
  # reading install.sh itself, not guessed): OSI_DEVICE_PATH,
  # OSI_DEVICE_IS_PARTITION, OSI_USE_ENCRYPTION, and (only when encryption is
  # on) OSI_ENCRYPTION_PIN. OSI_DEVICE_EFI_PARTITION is read only when
  # OSI_DEVICE_IS_PARTITION=1 — not our case, we hand it the whole disk.
  export OSI_DEVICE_PATH="$disk_loop"
  export OSI_DEVICE_IS_PARTITION=0
  unset OSI_DEVICE_EFI_PARTITION
  _export_osi_encryption "$encrypted"
  local test_pin="$TEST_LUKS_PIN"
  if (( encrypted )); then
    log "Encryption requested — LUKS passphrase for this disk: '${test_pin}' (override with SHANIOS_TEST_LUKS_PIN)"
  fi

  log "Running the REAL install.sh from ${OSI_ROOT} against ${disk_loop} (profile=${profile}, image=$(basename "$image"), encrypted=${encrypted})"
  bash "${OSI_ROOT}/scripts/install.sh"

  log "install.sh finished — /mnt holds the freshly-partitioned target (a real GPT disk, $( (( encrypted )) && echo "LUKS-encrypted " )Btrfs @blue/@green, exactly like a real install)."
  log "Next: $(basename "$0") configure -p ${profile}$( (( encrypted )) && echo ' --encrypted')"
}

# ------------------------------------------------------------------
# configure   -p <profile> [--encrypted]
# ------------------------------------------------------------------
# configure.sh does its own chrooting internally — run_in_target() is
# `sudo chroot "$TARGET" /bin/bash -c ...` per command — so this just needs
# to invoke the real script with a realistic environment, not wrap it in an
# outer arch-chroot of its own.
# ------------------------------------------------------------------
cmd_configure() {
  check_dependencies_install

  # configure.sh's mount_target() rbinds the CALLING environment's /run into
  # the chroot target (`mount --rbind /run "${TARGET}/run"`) — on a real
  # install this is the live ISO's already-booted systemd/dbus, which is how
  # hostnamectl/localectl/timedatectl (all D-Bus calls) work from inside a
  # plain `chroot`, no nspawn involved. This container has no live systemd
  # either, so without a bus at /run/dbus/system_bus_socket BEFORE
  # configure.sh runs, every one of those calls dies with "Failed to connect
  # to system scope bus via local transport: Host is down" — confirmed live.
  # Same class of fix cmd_enter already needed for systemd-nspawn
  # (_ensure_dbus) — see _ensure_systemd_target_services for the rest of it.
  _ensure_systemd_target_services

  _take_encrypted "$@"
  set -- "${REST_ARGS[@]}"
  local encrypted="$ENCRYPTED"

  local profile="" opt OPTARG OPTIND=1
  while getopts "p:" opt "$@"; do
    case "$opt" in
      p) profile="$OPTARG" ;;
      *) ;;
    esac
  done

  _find_osi_root
  _ensure_root_sudo

  local disk_loop
  disk_loop="$(_ensure_install_attached)"

  export OSI_DEVICE_PATH="$disk_loop"
  export OSI_DEVICE_IS_PARTITION=0
  export OSI_DEVICE_EFI_PARTITION="${disk_loop}p1"
  _export_osi_encryption "$encrypted"
  local test_pin="$TEST_LUKS_PIN"

  # Every other OSI_* variable configure.sh reads — its own required_vars
  # list (OSI_LOCALE/OSI_FORMATS/OSI_TIMEZONE/OSI_KEYBOARD_LAYOUT/
  # OSI_USER_NAME/OSI_USER_AUTOLOGIN) plus OSI_USER_USERNAME/
  # OSI_USER_PASSWORD/OSI_ROOT_PASSWORD read later in setup_user_target/
  # set_root_password — realistic defaults, all overridable via env for
  # anyone testing something specific (a particular locale, keyboard
  # layout, autologin, ...).
  export OSI_LOCALE="${SHANIOS_TEST_OSI_LOCALE:-en_US.UTF-8}"
  export OSI_FORMATS="${SHANIOS_TEST_OSI_FORMATS:-en_US.UTF-8}"
  export OSI_TIMEZONE="${SHANIOS_TEST_OSI_TIMEZONE:-UTC}"
  export OSI_KEYBOARD_LAYOUT="${SHANIOS_TEST_OSI_KEYBOARD:-us}"
  export OSI_USER_NAME="${SHANIOS_TEST_OSI_USER_NAME:-Test User}"
  export OSI_USER_USERNAME="${SHANIOS_TEST_OSI_USERNAME:-testuser}"
  export OSI_USER_PASSWORD="${SHANIOS_TEST_OSI_USER_PASSWORD:-testpass123}"
  export OSI_USER_AUTOLOGIN="${SHANIOS_TEST_OSI_AUTOLOGIN:-0}"
  export OSI_ROOT_PASSWORD="${SHANIOS_TEST_OSI_ROOT_PASSWORD:-}"

  log "Running the REAL configure.sh from ${OSI_ROOT} (user=${OSI_USER_USERNAME}, locale=${OSI_LOCALE}, encrypted=${encrypted})"
  bash "${OSI_ROOT}/scripts/configure.sh"

  # A real install ends in a reboot, which releases what install.sh and
  # configure.sh mounted at /mnt (top level, then subvol=@blue on top). The
  # harness never reboots, so those mounts stayed live in this namespace for
  # the rest of the run - observed live: the suite's rollback deleted the old
  # @blue while /mnt still held it (mountinfo: /mnt rooted at /@blue//deleted)
  # and shani-deploy's `btrfs subvolume sync` sat out its 900s timeout.
  # Detach them here, as the reboot would (loop: /mnt is stacked).
  local _i
  for _i in 1 2 3 4 5; do
    findmnt -M /mnt >/dev/null 2>&1 || break
    umount -R /mnt 2>/dev/null || umount -l /mnt 2>/dev/null || break
  done
  findmnt -M /mnt >/dev/null 2>&1 && warn "/mnt is still mounted after configure.sh - later slot deletions may be pinned"

  log "configure.sh finished. Verify, e.g.:"
  log "  mount -o subvol=@blue /dev/disk/by-label/shani_root /mnt && grep ^${OSI_USER_USERNAME}: /mnt/etc/passwd && cat /mnt/etc/hostname; umount /mnt"
  if (( encrypted )); then
    log "  cryptsetup open --test-passphrase /dev/disk/by-label/shani_root   (passphrase: ${test_pin})"
  fi
}
