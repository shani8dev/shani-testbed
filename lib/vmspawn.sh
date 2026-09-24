# lib/vmspawn.sh — `vmspawn`: real UEFI boot under systemd-vmspawn — HOST-ONLY
#
#   vmspawn [--image=PATH | --iso=PATH] [--timeout=SECS] [--until=REGEX]
#           [--fail=REGEX] [--tpm=yes|no] [--secure-boot=no|yes] [--force]
#
# nspawn (enter/probe/verify-boot/app) can't exercise firmware, systemd-boot
# entry selection, the UKI or a TPM; qemu/iso/gui can, but are slow and
# interactive. systemd-vmspawn boots OVMF -> systemd-boot -> UKI with a swtpm
# TPM, and works with --kvm=no: the real shanios-gnome ISO reached its login
# prompt in ~4 minutes on a host with no /dev/kvm (2026-09-23).
#
# Runs the shani-builder image with systemd as PID 1 (vmspawn needs a system
# bus), installs qemu-base/edk2-ovmf/swtpm into it on demand (reusing
# cache/pacman_cache), and boots a qcow2 OVERLAY on top of the image. The
# overlay and the NVRAM/TPM state vmspawn creates next to it all live inside
# that throwaway container, so the image is never written and no new image
# files appear in disk/. Only disk/vmspawn-<name>-console.log is written.
#
# Default image: disk/install.img (from bootstrap). Refuses to boot an image
# that a harness run still has loop-attached, unless --force.
# Exit: 0 = --until matched, 1 = --fail matched / timeout, 2 = usage/setup.

_vmspawn_die() { printf '[vmspawn][ERROR] %s\n' "$*" >&2; exit 2; }

cmd_vmspawn() {
  if _in_container; then
    echo "vmspawn starts its own privileged container — run it on the HOST:" >&2
    echo "  test-env/test.sh vmspawn [--image=PATH|--iso=PATH] [--timeout=SECS]" >&2
    exit 2
  fi
  local image="" iso="" timeout=1200 tpm=yes secure_boot=no force=0 arg
  local until_re='login:|Reached target .*(Multi-User|Graphical)'
  local fail_re='Kernel panic|You are in emergency mode|Entering emergency mode|dracut-initqueue.*timeout|Failed to mount /sysroot'
  for arg in "$@"; do
    case "$arg" in
      --image=*)       image="${arg#--image=}" ;;
      --iso=*)         iso="${arg#--iso=}" ;;
      --timeout=*)     timeout="${arg#--timeout=}" ;;
      --until=*)       until_re="${arg#--until=}" ;;
      --fail=*)        fail_re="${arg#--fail=}" ;;
      --tpm=*)         tpm="${arg#--tpm=}" ;;
      --secure-boot=*) secure_boot="${arg#--secure-boot=}" ;;
      --force)         force=1 ;;
      *) _vmspawn_die "usage: vmspawn [--image=PATH|--iso=PATH] [--timeout=SECS] [--until=REGEX] [--fail=REGEX] [--tpm=yes|no] [--secure-boot=no|yes] [--force]" ;;
    esac
  done
  [[ -n "$image" && -n "$iso" ]] && _vmspawn_die "--image and --iso are mutually exclusive"
  [[ "$timeout" =~ ^[0-9]+$ ]] || _vmspawn_die "--timeout must be seconds"
  command -v docker >/dev/null || _vmspawn_die "docker is required"

  local src
  src="$(realpath -m "${iso:-${image:-$INSTALL_IMG}}")"
  [[ -f "$src" ]] || _vmspawn_die "no such image: $src (bootstrap first, or pass --image/--iso)"
  if (( ! force )) && losetup -j "$src" 2>/dev/null | grep -q .; then
    _vmspawn_die "$src is loop-attached (a harness run is using it, or no 'clean' yet) — clean first, or pass --force"
  fi

  local name; name="$(basename "$src")"; name="${name%.*}"
  local log_file="${DATA_DIR}/vmspawn-${name}-console.log"
  local pacman_cache="${REPO_ROOT}/cache/pacman_cache/pkg"
  local builder="${SHANIOS_TEST_BUILDER_IMAGE:-shrinivasvkumbhar/shani-builder:latest}"
  local overlay="/var/tmp/vmspawn-${name}.qcow2"   # inside the container
  local kvm=no; local -a kvm_dev=()
  if [[ -e /dev/kvm ]]; then kvm=yes; kvm_dev=(--device /dev/kvm); fi
  mkdir -p "$DATA_DIR" "$pacman_cache"

  VMSPAWN_CONTAINER="shanios-vmspawn-$$"
  trap 'docker rm -f "$VMSPAWN_CONTAINER" >/dev/null 2>&1 || true' EXIT
  log "vmspawn: ${src} (kvm=${kvm} tpm=${tpm} secure-boot=${secure_boot} timeout=${timeout}s)"
  log "console: ${log_file}"
  docker run -d --name "$VMSPAWN_CONTAINER" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp \
    -v "$(dirname "$src"):/src:ro" -v "${pacman_cache}:/var/cache/pacman/pkg" "${kvm_dev[@]}" \
    --user root --entrypoint /usr/lib/systemd/systemd "$builder" >/dev/null \
    || _vmspawn_die "could not start the systemd container"

  local state="" i
  for (( i=0; i<60; i++ )); do
    state=$(docker exec "$VMSPAWN_CONTAINER" systemctl is-system-running 2>/dev/null || true)
    [[ "$state" == running || "$state" == degraded ]] && break
    sleep 2
  done
  [[ "$state" == running || "$state" == degraded ]] || _vmspawn_die "container systemd did not come up (${state:-none})"

  log "installing qemu-base edk2-ovmf swtpm openssh (cached after the first run)..."
  docker exec "$VMSPAWN_CONTAINER" pacman -Sy --noconfirm --needed qemu-base edk2-ovmf swtpm openssh >/dev/null \
    || _vmspawn_die "installing qemu/ovmf/swtpm failed"
  docker exec "$VMSPAWN_CONTAINER" qemu-img create -q -f qcow2 -F raw -b "/src/$(basename "$src")" "$overlay" \
    || _vmspawn_die "could not create the qcow2 overlay"

  : > "$log_file"
  # Only an unbuffered `tr` in the live pipe: getty prints "login: " with no
  # trailing newline, and a line-buffered filter (the first version used sed)
  # holds that partial line until the pipe closes, so --until could never
  # match it. ANSI escapes are stripped only when printing the summary.
  docker exec "$VMSPAWN_CONTAINER" systemd-vmspawn --kvm="$kvm" --tpm="$tpm" --secure-boot="$secure_boot" \
      --register=no --console=read-only --cpus=4 --ram=4G --image-format=qcow2 -i "$overlay" 2>&1 \
    | stdbuf -o0 tr -d '\r' >> "$log_file" &
  local vm_pid=$! start rc=1 result
  start=$(date +%s); result="timeout after ${timeout}s"
  while :; do
    if grep -aqE "$fail_re" "$log_file"; then result="FAIL: $(grep -aoE "$fail_re" "$log_file" | head -1)"; rc=1; break; fi
    if grep -aqE "$until_re" "$log_file"; then result="OK: $(grep -aoE "$until_re" "$log_file" | head -1)"; rc=0; break; fi
    kill -0 "$vm_pid" 2>/dev/null || { result="VM exited before a match"; rc=1; break; }
    (( $(date +%s) - start >= timeout )) && break
    sleep 3
  done
  local elapsed=$(( $(date +%s) - start ))
  docker exec "$VMSPAWN_CONTAINER" pkill -f qemu-system >/dev/null 2>&1 || true
  kill "$vm_pid" 2>/dev/null || true
  log "vmspawn ${result} (${elapsed}s)"
  sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$log_file" \
    | grep -aE 'Linux version|systemd-boot|Welcome to|tpm0|Trusted Platform|Reached target|login:|emergency|panic' \
    | cut -c1-140 | tail -12 | sed 's/^/  | /' || true
  return "$rc"
}
