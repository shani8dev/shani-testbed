# ------------------------------------------------------------------
# QMP / qemu-guest-agent helpers for `gui` — thin wrappers around the one
# shared client, lib/qmp_client.py (was five near-identical inline python3
# copies). QGA needs no capabilities handshake, just JSON lines; QMP needs a
# greeting read + qmp_capabilities before any real command.
# ------------------------------------------------------------------
QMP_CLIENT="${LIB_DIR}/qmp_client.py"

_qga_wait_ready() {
  local sock="$1" timeout="${2:-300}" waited=0
  log "Waiting for qemu-guest-agent to respond (timeout ${timeout}s)..."
  while (( waited < timeout )); do
    if python3 "$QMP_CLIENT" qga-ping "$sock" >/dev/null 2>&1; then
      log "guest-agent responded after ${waited}s."
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

_qga_exec()       { python3 "$QMP_CLIENT" qga-exec "$1" "$2" "${3:-60}"; }
_qmp_screendump() { python3 "$QMP_CLIENT" screendump "$1" "$2"; }
_qmp_click()      { python3 "$QMP_CLIENT" click "$1" "$2" "$3" "${4:-left}"; }
_qmp_move()       { python3 "$QMP_CLIENT" move "$1" "$2" "$3"; }
_qmp_key()        { python3 "$QMP_CLIENT" key "$1" "$2"; }
_qmp_type()       { python3 "$QMP_CLIENT" type "$1" "$2"; }


# ------------------------------------------------------------------
# gui   (headless real-desktop verification) — HOST-ONLY
#
# Boots the same resolved image set as `cmd_qemu` (see its header — same
  # real UKI/kernel/bootloader, resolved by _resolve_qemu_boot_drives), but
  # with `-display none` instead of a GTK window,
# plus a QMP control socket alongside the qemu-guest-agent one `cmd_qemu`
# already wires up. This is the answer to "can we verify a GUI app or a
# desktop theme change actually renders, without a distrobox dependency":
#   1. wait for qemu-guest-agent to respond (boot reached a running desktop)
#   2. optionally run --exec="..." inside the live guest over guest-exec —
#      launch a real GUI app, flip a real theme setting via its real config
#      tool, whatever the check calls for
#   3. let the compositor settle briefly, then QMP screendump the real
#      framebuffer to a .ppm file
# No new runtime dependency on the guest side (qemu-guest-agent is already
# shipped and enabled — see cmd_qemu's comment above); only the HOST needs
# python3 (already required by run_in_container.sh's own tooling) to speak
# the QMP/QGA JSON protocols — no socat, no separate helper script.
# ------------------------------------------------------------------
cmd_gui() {
  if _in_container; then
    echo "gui boots a real headless QEMU instance — it can't run inside the build container." >&2
    echo "Run this file directly on the HOST instead, from the repo root:" >&2
    echo "  test-env/test.sh gui [--exec=CMD] [--click=X,Y[:button]] [--doubleclick=X,Y]" >&2
    echo "                       [--move=X,Y] [--type=TEXT] [--key=COMBO] [--sleep=SECS]" >&2
    echo "                       [--screenshot=<file.ppm>] [--out=<file.ppm>] [--timeout=N]" >&2
    exit 1
  fi

  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required for gui's QMP/guest-agent control (pacman -S python / apt install python3)."

  _resolve_qemu_boot_drives

  # Actions run in the exact order given on the command line — a UI test is
  # a script (click, then type, then screenshot), so order must survive
  # arg parsing. ACTIONS holds "kind\x1fvalue" pairs; out_file/timeout are
  # order-independent scalars.
  local -a ACTIONS=()
  local out_file="" boot_timeout=300 arg saw_screenshot=0
  for arg in "$@"; do
    case "$arg" in
      --exec=*)        ACTIONS+=("exec"$'\x1f'"${arg#--exec=}") ;;
      --click=*)       ACTIONS+=("click"$'\x1f'"${arg#--click=}") ;;
      --doubleclick=*) ACTIONS+=("doubleclick"$'\x1f'"${arg#--doubleclick=}") ;;
      --move=*)        ACTIONS+=("move"$'\x1f'"${arg#--move=}") ;;
      --type=*)        ACTIONS+=("type"$'\x1f'"${arg#--type=}") ;;
      --key=*)         ACTIONS+=("key"$'\x1f'"${arg#--key=}") ;;
      --sleep=*)       ACTIONS+=("sleep"$'\x1f'"${arg#--sleep=}") ;;
      --screenshot=*)  ACTIONS+=("screenshot"$'\x1f'"${arg#--screenshot=}"); saw_screenshot=1 ;;
      --out=*)         out_file="${arg#--out=}" ;;
      --timeout=*)     boot_timeout="${arg#--timeout=}" ;;
      *)
        echo "Usage: $(basename "$0") gui [--exec=CMD] [--click=X,Y[:button]] [--doubleclick=X,Y]" >&2
        echo "                       [--move=X,Y] [--type=TEXT] [--key=COMBO] [--sleep=SECS]" >&2
        echo "                       [--screenshot=<file.ppm>] [--out=<file.ppm>] [--timeout=N]" >&2
        exit 1
        ;;
    esac
  done
  [[ -n "$out_file" ]] || out_file="${DATA_DIR}/gui-screenshot-$(date +%s).ppm"

  # Own NVRAM copy: headless/unattended, shouldn't share (or clobber) the
  # interactive `qemu` session's EFI vars.
  _qemu_base_args OVMF_VARS_gui.fd

  local qga_sock="${DATA_DIR}/qga-gui.sock"
  local qmp_sock="${DATA_DIR}/qmp-gui.sock"
  local pid_file="${DATA_DIR}/qemu-gui.pid"
  local console_log="${DATA_DIR}/gui-console.log"
  rm -f "$qga_sock" "$qmp_sock" "$pid_file"

  # NOTE: an EXIT trap runs after bash unwinds the function's call frame, so
  # it can't see cmd_gui's own `local` variables (confirmed live: reusing
  # the local $pid_file here raised "pid_file: unbound variable" under
  # `set -u` the moment qemu failed and this trap fired) — recompute the
  # path from the global $DATA_DIR instead.
  _gui_cleanup() {
    local _pid_file="${DATA_DIR}/qemu-gui.pid"
    if [[ -f "$_pid_file" ]]; then
      kill "$(cat "$_pid_file")" 2>/dev/null || true
      rm -f "$_pid_file"
    fi
  }
  trap _gui_cleanup EXIT

  log "Booting headless ($QEMU_BOOT_DESC, no display window — QMP+guest-agent control only)..."
  qemu-system-x86_64 \
      "${QEMU_BASE_ARGS[@]}" \
      "${QEMU_BOOT_DRIVES[@]}" \
      "${QEMU_COMMON_DEVICES[@]}" \
      -display none \
      -chardev socket,path="$qga_sock",server=on,wait=off,id=qga0 \
      -device virtio-serial \
      -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
      -qmp unix:"$qmp_sock",server=on,wait=off \
      -serial file:"$console_log" \
      -daemonize -pidfile "$pid_file"

  if ! _qga_wait_ready "$qga_sock" "$boot_timeout"; then
    die "guest-agent never responded within ${boot_timeout}s — see ${console_log}"
  fi

  log "Letting the compositor settle for 5s before running actions..."
  sleep 5

  local action kind value
  for action in "${ACTIONS[@]}"; do
    kind="${action%%$'\x1f'*}"
    value="${action#*$'\x1f'}"
    case "$kind" in
      exec)
        log "Running inside guest: ${value}"
        _qga_exec "$qga_sock" "$value" || warn "guest-exec exited non-zero (output above, if any)"
        ;;
      click)
        local cx cy cbtn="left"
        IFS=':' read -r value cbtn <<<"$value"
        IFS=',' read -r cx cy <<<"$value"
        [[ -n "$cbtn" ]] || cbtn="left"
        log "Click (${cx},${cy}) button=${cbtn}"
        _qmp_click "$qmp_sock" "$cx" "$cy" "$cbtn" || warn "click failed"
        ;;
      doubleclick)
        local dx dy
        IFS=',' read -r dx dy <<<"$value"
        log "Double-click (${dx},${dy})"
        _qmp_click "$qmp_sock" "$dx" "$dy" left || warn "click 1/2 failed"
        sleep 0.15
        _qmp_click "$qmp_sock" "$dx" "$dy" left || warn "click 2/2 failed"
        ;;
      move)
        local mx my
        IFS=',' read -r mx my <<<"$value"
        log "Move pointer to (${mx},${my})"
        _qmp_move "$qmp_sock" "$mx" "$my" || warn "move failed"
        ;;
      type)
        log "Typing: ${value}"
        _qmp_type "$qmp_sock" "$value" || warn "type failed"
        ;;
      key)
        log "Key: ${value}"
        _qmp_key "$qmp_sock" "$value" || warn "key failed"
        ;;
      sleep)
        log "Sleeping ${value}s"
        sleep "$value"
        ;;
      screenshot)
        _qmp_screendump "$qmp_sock" "$value" || warn "screenshot failed"
        log "Screenshot saved: ${value}"
        ;;
    esac
  done

  if [[ "$saw_screenshot" -eq 0 ]]; then
    _qmp_screendump "$qmp_sock" "$out_file" || die "screendump failed"
    log "Screenshot saved: ${out_file}"
  fi
}
