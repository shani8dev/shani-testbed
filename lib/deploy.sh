# Shared by update-check / upgrade / rollback: resolve the current slot, make
# sure the container can run nspawn, and build NSPAWN_ENTER_ARGS for <cmd...>
# (honouring --local-src via LOCAL_SRC, set by _take_local_src). Sets
# CURRENT_SLOT. Doesn't exec: cycle needs control back afterwards.
_prepare_in_current_slot() {
  CURRENT_SLOT="$(_current_slot)"
  log "Current slot marker: @${CURRENT_SLOT}"
  _ensure_host_machine_id
  _ensure_dbus
  _prepare_enter_args "$CURRENT_SLOT" "${LOCAL_SRC:-}" "$@"
}

# ------------------------------------------------------------------
# upgrade / reboot / rollback   (was 04/05/06-*.sh)
# ------------------------------------------------------------------
cmd_upgrade() {
  # --local-src=<dir> can appear anywhere among the args — same convention
  # as cmd_enter/cmd_verifyboot: pull it out, forward everything else
  # straight through to shani-deploy. Without it, this only ever exercises
  # whatever shani-deploy got baked into the bootstrapped image at build
  # time, which can be stale relative to a repo's current working tree —
  # pass --local-src=/opt/shani-deploy/scripts (the sibling checkout
  # run_in_container.sh bind-mounts) to always run the current one, units
  # included (_overlay_local_src picks up its sibling systemd/ dir too).
  _take_local_src "$@"
  set -- "${REST_ARGS[@]}"
  # --self-update: let shani-deploy update itself first (GitHub main,
  # SHA-256 + GPG checked, re-exec) - what a real machine does, and what
  # `gate` tests. Incompatible with --local-src (it would replace the
  # overlaid copy).
  # --channel=<latest|stable> (default latest) and --no-force: `gate` runs
  # an update the way the update timer does - the system's channel, no
  # --force, so an older remote is "no update needed", never a downgrade.
  local skip_self=--skip-self-update channel=latest force=--force a
  local -a rest=()
  for a in "$@"; do
    case "$a" in
      --self-update) skip_self="" ;;
      --channel=*)   channel="${a#--channel=}" ;;
      --no-force)    force="" ;;
      *)             rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"
  [[ -z "$skip_self" && -n "${LOCAL_SRC:-}" ]] && die "upgrade: --self-update and --local-src contradict each other"

  # Calls shani-deploy directly. The deploy engine is the production path;
  # its status contract is also what Shani Cassini and its agent consume.
  # shani-deploy's own check_root() only pkexecs/sudo's when EUID != 0 —
  # since this nspawn session already runs as root, calling it directly
  # needs none of that, and shani-deploy has no interactive prompts of its
  # own (verified: no `read -rp` anywhere in it) — it's designed to run
  # fully unattended, same as the production systemd timer units.
  # --skip-self-update is essential here, not optional: without it,
  # shani-deploy's OWN self_update() would fetch and exec the "official"
  # published script mid-run, silently discarding the --local-src-overlaid
  # edited copy we're trying to test.
  # Doesn't use cmd_enter directly (which ends in exec, replacing this
  # process) — cmd_cycle needs cmd_upgrade to actually return so its own
  # cmd_reboot afterward still runs. _prepare_enter_args is the same prep
  # cmd_enter itself uses (single source of truth for the nspawn args).
  _prepare_in_current_slot shani-deploy ${force:+"$force"} --channel "$channel" ${skip_self:+"$skip_self"} "$@"
  log "Running shani-deploy inside @${CURRENT_SLOT} (real deploy — this will actually switch slots on success)"
  systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
}


# ------------------------------------------------------------------
# update-check   [--local-src=<dir>]
# ------------------------------------------------------------------
# Compatibility smoke check for the replacement update path. It runs the
# read-only status contract used by Shani Cassini and its agent; it never
# installs, switches slots, or runs the notification agent.
cmd_updatecheck() {
  _take_local_src "$@"
  set -- "${REST_ARGS[@]}"
  [[ $# -eq 0 ]] || die "update-check takes no extra arguments; it is a read-only status check"
  _prepare_in_current_slot shani-deploy --status --check --json
  log "Checking shani-deploy's read-only status consumed by Shani Cassini's update agent"
  systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
}

cmd_reboot() {
  local current_slot
  current_slot="$(_current_slot)"
  log "'Rebooting' into @${current_slot} (per /data/current-slot)"
  cmd_enter "$current_slot" "$@"
}

cmd_rollback() {
  # --local-src=<dir> — same convention as cmd_upgrade, see there for why.
  _take_local_src "$@"
  set -- "${REST_ARGS[@]}"

  # shani-deploy --rollback directly. Rollback is a deploy-engine operation,
  # just like upgrade; no interactive update front-end is involved.
  _prepare_in_current_slot shani-deploy --rollback "$@"
  log "Rolling back FROM @${CURRENT_SLOT} (this restores the *other* slot and repoints boot at it)"
  systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
}

# ------------------------------------------------------------------
# cycle -p <profile> [-d <sel>] [--encrypted] [--local-src=<dir>]
# ------------------------------------------------------------------
# ca (if missing) -> bootstrap -> serve (background) -> upgrade -> reboot.
# No cmd_disk preflight: bootstrap runs the real install.sh via cmd_install,
# which creates its own install.img and repoints the by-label symlinks at it.
# --local-src is now passed through to upgrade (it used to be dropped, so
# cycle only ever tested the image's baked-in shani-deploy).
cmd_cycle() {
  _take_local_src "$@"
  local cycle_local_src="$LOCAL_SRC"
  set -- "${REST_ARGS[@]}"
  local profile
  profile="$(_get_profile "$@")"
  [[ -n "$profile" ]] || die "cycle requires -p <profile>"

  [[ -f "${CA_DIR}/ca.crt" ]] || cmd_ca
  cmd_bootstrap "$@"

  cmd_serve &
  local serve_pid=$!
  # shellcheck disable=SC2064  # expand now: the local is gone by EXIT time
  trap "kill ${serve_pid} 2>/dev/null || true" EXIT
  sleep 1

  if [[ -n "$cycle_local_src" ]]; then
    cmd_upgrade "--local-src=${cycle_local_src}"
  else
    cmd_upgrade
  fi
  cmd_reboot
}
