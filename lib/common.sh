# lib/common.sh — paths, shared state and small helpers used by every module.
# Sourced by test-env/test.sh after config/config.sh (which provides
# log/warn/die, OUTPUT_DIR, OS_NAME, setup_btrfs_image, check_dependencies_*).

# realpath -m'd (not just interpolated, unlike a plain "${SCRIPT_DIR}/disk"
# concat) so an override left as a relative path (SHANIOS_TEST_DATA, now
# forwarded from the host by run_in_container.sh) can't silently resolve
# against whatever the current CWD happens to be and land somewhere
# unintended — SCRIPT_DIR/REPO_ROOT already get this same realpath
# treatment; DATA_DIR was the one path in this file that didn't. Prompted
# by finding a stray root-owned
# shani-install-media/shani-install-media/test-env/disk/... nested one
# level too deep on disk (the **/test-env/disk/* .gitignore fallback
# already covers it existing, but not why) — the exact original trigger
# wasn't confirmed, but this closes the one concrete CWD-dependent gap
# actually found in this file, and the fallback below now clarifies it's
# a real, previously-unexplained artifact rather than purely hypothetical.
DATA_DIR="$(realpath -m "${SHANIOS_TEST_DATA:-${SCRIPT_DIR}/disk}")"
# Deliberately NOT under /mnt: the real install.sh/configure.sh hardcode
# /mnt as their own install target, and configure.sh's mount_target()
# mounts subvol=@<slot> directly AT /mnt (not /mnt/@<slot>) — a read-only
# snapshot once configure.sh finishes, matching a real booted system's ro
# rootfs. A test-harness mountpoint nested under /mnt (as this used to be)
# gets silently shadowed by install.sh's own mount, then finds itself
# inside a read-only filesystem after configure.sh's — confirmed live
# ("mkdir: cannot create directory '/mnt/shanios-toplevel': Read-only file
# system" from cmd_bootstrap's post-install/configure step). Same fix as
# OSI_ROOT below: keep the harness's own mountpoints off /mnt entirely.
MNT="$(realpath -m "${SHANIOS_TEST_MNT:-/opt/shanios-toplevel}")"
ESP_MNT="$(realpath -m "${SHANIOS_TEST_ESP_MNT:-/opt/shanios-esp}")"
CA_DIR="${DATA_DIR}/ca"
ROOT_IMG="${DATA_DIR}/root.img"
ESP_IMG="${DATA_DIR}/esp.img"
INSTALL_IMG="${DATA_DIR}/install.img"
INHIBIT_STUB="${DATA_DIR}/.systemd-inhibit-stub.sh"
# Repo root (shani-install-media). Inside the builder container this is the
# same tree that run_in_container.sh bind-mounts at /home/builduser/build.
# It is bound READ-ONLY into every nspawn slot at /mnt/repo so tests can run
# repo scripts (scripts/, test-scripts/, etc.) inside the installed system
# without copying files into slot overlays by hand.
REPO_ROOT="$MEDIA_ROOT"   # the image repo (shani-install-media)
# Optional extra nspawn binds: "host_src:ctr_dst[,host_src2:ctr_dst2,...]"
# Applied read-write to both `enter` and `verify-boot` invocations.
EXTRA_BINDS="${SHANIOS_TEST_EXTRA_BINDS:-}"

# True once this shell is PID 1's descendant inside the docker/podman builder
# container (see run_in_container.sh) — used only to keep `qemu` from trying
# to boot without a GPU when someone runs it via build.sh by mistake.
_in_container() {
  [[ -f /.dockerenv || -f /run/.containerenv ]] && return 0
  command -v systemd-detect-virt &>/dev/null && systemd-detect-virt --container -q && return 0
  return 1
}

_get_profile() {
  local _prev="" _profile=""
  for _arg in "$@"; do
    [[ "${_prev}" == "-p" ]] && { _profile="$_arg"; _prev="$_arg"; continue; }
    _prev="$_arg"
  done
  echo "$_profile"
}

# systemd-nspawn derives its own internal identifiers (machine naming,
# cgroup/network naming) from the CALLING environment's /etc/machine-id via
# sd_id128_get_machine_app_specific() — not from the target slot's machine-id,
# which is fine and untouched. The published builder image has no
# /etc/machine-id at all (it's not meant to run systemd services), so every
# nspawn invocation used to fail immediately with "Failed to retrieve machine
# ID: No such file or directory" before ever reaching the target rootfs.
_ensure_host_machine_id() {
  [[ -s /etc/machine-id ]] && return 0
  systemd-machine-id-setup >/dev/null 2>&1 \
    || die "Could not initialize /etc/machine-id in the builder container (needed by systemd-nspawn itself, not the target image)"
}

# Even with --register=no (which skips systemd-machined registration) and
# --keep-unit (which skips asking systemd to allocate a transient scope),
# nspawn still tries to connect to the system bus at startup — with no bus
# present at all, that connection failure makes nspawn's PARENT kill its own
# container-setup child outright, surfacing only the uninformative "Parent
# died too early". The builder image has dbus installed but nothing starts
# it. A private, otherwise-unused system bus is enough to satisfy this.
_ensure_dbus() {
  [[ -S /run/dbus/system_bus_socket ]] && return 0
  mkdir -p /run/dbus
  dbus-daemon --system --fork \
    || die "Could not start dbus-daemon in the builder container (needed by systemd-nspawn itself)"
}

# install.sh/configure.sh (os-installer-config) call every privileged
# operation through `sudo <cmd>`, on the assumption they're run as an
# unprivileged user during a real install. Inside this container we're
# already root — `sudo` as UID 0 normally succeeds anyway via pam_rootok.so
# (no password, no sudoers entry needed), but the published builder image is
# built for image/ISO assembly, not for running an installer, so `sudo`
# itself may not even be installed (check_dependencies_install handles
# that) and its default sudoers may be more restrictive in some base image
# variant. Belt-and-suspenders: add an explicit NOPASSWD entry for root too,
# idempotently — this only ever touches the throwaway container's own
# /etc/sudoers, never anything that leaves the container.
_ensure_root_sudo() {
  command -v sudo &>/dev/null || return 0
  grep -qxF 'root ALL=(ALL) NOPASSWD: ALL' /etc/sudoers 2>/dev/null \
    || echo 'root ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
}

# ------------------------------------------------------------------
# Argument helpers — each replaces a loop that used to be copy-pasted into
# several commands.
# ------------------------------------------------------------------

# Pulls --local-src=<dir> out of "$@" (it may appear anywhere). Sets globals
# LOCAL_SRC (empty if absent) and REST_ARGS (every other argument, in order).
# Callers then do: set -- "${REST_ARGS[@]}".
_take_local_src() {
  LOCAL_SRC=""
  REST_ARGS=()
  local a
  for a in "$@"; do
    case "$a" in
      --local-src=*) LOCAL_SRC="${a#--local-src=}" ;;
      *) REST_ARGS+=("$a") ;;
    esac
  done
}

# Pulls --encrypted out of "$@". Sets ENCRYPTED (0/1) and REST_ARGS.
_take_encrypted() {
  ENCRYPTED=0
  REST_ARGS=()
  local a
  for a in "$@"; do
    case "$a" in
      --encrypted) ENCRYPTED=1 ;;
      *) REST_ARGS+=("$a") ;;
    esac
  done
}

# Leaf cert/key paths for a hostname minted by `ca`. downloads.shani.dev
# keeps its historical server.crt/server.key names (run_in_container.sh's
# --add-host and older docs refer to them); every other host gets
# <host>.crt/<host>.key. Sets LEAF_CRT / LEAF_KEY.
_leaf_cert_paths() {
  if [[ "$1" == "downloads.shani.dev" ]]; then
    LEAF_CRT="${CA_DIR}/server.crt"; LEAF_KEY="${CA_DIR}/server.key"
  else
    LEAF_CRT="${CA_DIR}/$1.crt"; LEAF_KEY="${CA_DIR}/$1.key"
  fi
}

# Validates a slot name (blue|green) or dies with the given usage line.
_require_slot() {
  [[ "${1:-}" =~ ^(blue|green)$ ]] || die "${2:-slot must be 'blue' or 'green'}"
}
