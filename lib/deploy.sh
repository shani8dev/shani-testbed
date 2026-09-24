# Shared by upgrade / update-check / rollback: resolve the current slot, make
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

  # Calls shani-deploy directly, not shani-update: shani-update is only an
  # interactive front-end (GUI dialog / console prompt) that then pkexecs
  # shani-deploy — and unconditionally wraps that in a gnome-terminal
  # window for user visibility, which needs a real display even after the
  # prompt is approved (confirmed live: "Cannot open display" once
  # shani-update tried to launch it, even after the console-approval path
  # was fully proven to work via an allocated pty). shani-deploy is the
  # real script that does the actual work, and its own check_root() only
  # pkexecs/sudo's when EUID != 0 — since this nspawn session already runs
  # as root, calling it directly needs none of that, and shani-deploy has
  # no interactive prompts of its own (verified: no `read -rp` anywhere in
  # it) — it's designed to run fully unattended already, same as
  # shani-update's pkexec'd child and the production systemd timer units.
  # --skip-self-update is essential here, not optional: without it,
  # shani-deploy's OWN self_update() would fetch and exec the "official"
  # published script mid-run, silently discarding the --local-src-overlaid
  # edited copy we're trying to test.
  # Doesn't use cmd_enter directly (which ends in exec, replacing this
  # process) — cmd_cycle needs cmd_upgrade to actually return so its own
  # cmd_reboot afterward still runs. _prepare_enter_args is the same prep
  # cmd_enter itself uses (single source of truth for the nspawn args).
  _prepare_in_current_slot shani-deploy --force --channel latest --skip-self-update "$@"
  log "Running shani-deploy inside @${CURRENT_SLOT} (real deploy — this will actually switch slots on success)"
  systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
}

# ------------------------------------------------------------------
# update-check   [--local-src=<dir>] [extra shani-update args...]
# ------------------------------------------------------------------
# cmd_upgrade calls shani-deploy directly and never touches shani-update.sh
# at all — this command exists specifically to exercise shani-update.sh
# itself for real: its GUI-dialog fallback chain, its console-approval
# prompt, and its decision logic (install/postpone). Complements
# cmd_upgrade, doesn't replace it.
cmd_updatecheck() {
  _take_local_src "$@"
  set -- "${REST_ARGS[@]}"

  _prepare_in_current_slot shani-update --force --skip-self-update "$@"

  # shani-update.sh is real and unmodified — it tries a GUI dialog first
  # (no display here, so yad/zenity/kdialog all correctly fail over), then
  # falls back to a genuine console prompt, but ONLY when
  # `[[ -t 0 && -t 1 ]]` — confirmed live that a plain non-tty invocation
  # always logs "No interactive interface — defaulting to postpone" and
  # never even reaches its decision logic. There's no flag to skip this
  # (by design), so give it exactly what a human at a real terminal would:
  # `script` allocates a genuine pty and relays its own stdin into it like
  # a real keystroke, so feeding it "y\n" is the same input a person
  # approving the update would type.
  #
  # NOTE what this does NOT prove: shani-update's own _launch_deploy (the
  # actual shani-deploy hand-off, and its --rollback path too) always
  # wraps that in a gnome-terminal window for visibility — confirmed live
  # this fails with "Cannot open display" even right after the approval
  # prompt succeeds, in a container with no real display. This command
  # proves shani-update's own dialog/prompt/decision code works; it does
  # NOT complete an actual deploy — use `upgrade` for that (it calls
  # shani-deploy directly, skipping this whole layer).
  if ! command -v script &>/dev/null; then
    warn "'script' (util-linux) not found — can't allocate a pty for shani-update's console approval; it will default to postponing"
    systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
    return $?
  fi

  log "Running shani-update inside @${CURRENT_SLOT} via an allocated pty, answering the update-approval prompt with 'y' (the same input a real interactive session would give)"
  local cmd_str
  printf -v cmd_str '%q ' systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
  printf 'y\n' | script -qec "$cmd_str" /dev/null
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

  # shani-deploy --rollback directly, not shani-update --rollback: same
  # reason as cmd_upgrade — shani-update's _run_rollback() ALSO routes
  # through _launch_deploy (the gnome-terminal wrapper that needs a real
  # display), even though it's not asking for any interactive approval
  # first. shani-deploy's own -r/--rollback flag does the identical real
  # work directly.
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
