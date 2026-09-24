cmd_enter() {
  _ensure_host_machine_id
  _ensure_dbus
  _ensure_by_label_dir
  local slot="${1:?Usage: $(basename "$0") enter <blue|green> [--boot] [--local-src=<dir>] [command...]}"
  shift || true
  [[ "$slot" =~ ^(blue|green)$ ]] || die "slot must be 'blue' or 'green'"

  local boot=0 local_src=""
  while [[ "${1:-}" == "--boot" || "${1:-}" == --local-src=* ]]; do
    case "$1" in
      --boot) boot=1; shift ;;
      --local-src=*) local_src="${1#--local-src=}"; shift ;;
    esac
  done

  if (( boot )); then
    _prepare_boot "$slot" "$local_src"
    log "Booting @${slot} (full systemd boot via nspawn --boot)"
    _nspawn_full_boot_args "shanios-${slot}" "$slot"
    exec systemd-nspawn "${NSPAWN_FULL_BOOT_ARGS[@]}"
  fi

  _prepare_enter_args "$slot" "$local_src" "$@"
  log "Entering @${slot} via systemd-nspawn (writable overlay, ephemeral upper layer persists across runs in ${NSPAWN_WORK}/upper)"
  exec systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}"
}

# ------------------------------------------------------------------
# Console output during --boot shows each unit's Description= text, never
# its raw file basename (confirmed live: "Finished Mark Boot In Progress
# for Shani OS.", never "Finished mark-boot-in-progress.service.") — so
# aggregate target-reached + failed-unit-count (what verify-boot already
# checked) can't tell you whether a SPECIFIC shani-deploy unit actually
# ran; a WantedBy= symlink typo or a missing enablement would pass that
# check silently. This greps for each one's real Description= text
# instead — never a hard failure on its own (`die` stays reserved for
# emergency-mode/target-not-reached).
#
# IMPORTANT CAVEAT, found the hard way with `probe` (see cmd_probe below):
# the console-log CAPTURE is not a fully reliable proxy for what actually
# happened — mark-boot-success.service and bless-boot.service both
# genuinely started AND failed (confirmed directly via `systemctl status`
# through a live probe), yet NEITHER their "Starting..." nor their
# "Failed to start..." lines appear anywhere in the captured console log.
# So "not observed" here means exactly that — not seen in this capture —
# never "confirmed absent". Treat every "not observed" below as "run
# `probe <slot> --exec=\"systemctl status <unit> --no-pager -l\"` for a
# real answer", not as proof of a problem.
#
# Real, confirmed-via-probe status of the two that never show up here:
#   - mark-boot-success.service DOES start, and fails on its third
#     ExecStart= line: `Unable to locate executable
#     '/usr/local/bin/boot-success-cleanup': No such file or directory`.
#     Not a hardening-directive issue (ProtectSystem=full only blocks
#     WRITES under /usr, never hides or blocks executing a file that's
#     actually there — this is a plain ENOENT) — it's the same image-
#     staleness case as the "boot-success-cleanup.sh skipped" --local-src
#     warning: this script is real and present in the current shani-deploy
#     checkout, but the currently-bootstrapped test image predates it, and
#     --local-src correctly refuses to introduce a binary that isn't
#     already installed. A fresh `build.sh image` would include it.
#   - bless-boot.service DOES start, and fails with
#     `systemd-bless-boot[…]: Marking a boot is not supported in
#     containers.` — systemd-bless-boot's own explicit, deliberate
#     container-refusal (virtualization detection, not a permission
#     check) — would fail identically with zero hardening directives, in
#     any container runtime. Matches the extensive comment already in
#     bless-boot.service about the known upstream systemd-boot regression;
#     not fixable from this side.
# Both confirm multi-user.target IS genuinely reached in this environment
# (also confirmed via probe: "Reached target Multi-User System." in the
# journal) even on boots where the console-log capture doesn't show that
# exact line either.
_verifyboot_check_units() {
  local logfile="$1"
  # unit description; NOTE-if-absent (empty = warn like the others)
  local -a checks=(
    "mark-boot-in-progress.service|Finished Mark Boot In Progress for Shani OS.|"
    "beesd-setup.service|Finished Bees BTRFS deduplication setup.|"
    "shani-user-setup.path|Started Watch for new users and skel changes.|"
    "check-boot-failure.timer|Started Run Boot Failure Check 15 Minutes After Boot.|"
    "flatpak-update-system.timer|Started Periodic Flatpak Update (System).|"
    "mark-boot-success.service|Finished Mark Boot Success for Shani OS.|console capture unreliable for this one — confirmed via probe it actually starts then fails on a missing /usr/local/bin/boot-success-cleanup (image staleness, not a hardening issue)"
    "bless-boot.service|Finished Bless Current Boot - Shani OS Boot Counting.|console capture unreliable for this one — confirmed via probe it actually starts then fails: systemd-bless-boot refuses inside any container (expected, not fixable here)"
  )
  log "── shani-deploy unit checks (by Description=, not file basename — see comment above) ──"
  local entry unit desc note
  for entry in "${checks[@]}"; do
    IFS='|' read -r unit desc note <<<"$entry"
    if grep -aqF "$desc" "$logfile"; then
      log "  [confirmed]     ${unit}"
    elif [[ -n "$note" ]]; then
      warn "  [not observed]  ${unit} (${note})"
    else
      warn "  [not observed]  ${unit} — expected to fire in every boot reaching this point; check its WantedBy= enablement and ConditionPathExists= gates"
    fi
  done
}

# ------------------------------------------------------------------
# verify-boot   [blue|green] [seconds] [--local-src=<dir>]
# ------------------------------------------------------------------
# Headless boot smoke test: boots the slot with full systemd (--boot),
# captures the console to disk for <seconds> (default 90), then reports
# whether the system reached Multi-User/Graphical target and whether any
# units failed. Designed for CI/non-interactive use — never opens a window,
# never needs a TTY. rc=124 from `timeout` is EXPECTED (a healthy boot keeps
# running until the cutoff); any other non-zero rc is a hard failure.
#
# --local-src=<dir> (same flag as `enter`): overlays edited *.sh scripts
# from <dir> onto /usr/local/bin, AND — if <dir>'s parent has a sibling
# systemd/{system,user}/ directory (e.g. pass shani-deploy's scripts/ and
# its systemd/ siblings come along automatically) — overlays edited unit
# files onto /usr/lib/systemd/{system,user} too. Without this, verify-boot
# only ever exercises whatever scripts/units are baked into the bootstrapped
# image, which can be stale relative to a repo's current working tree —
# confirmed live: an image built before a script/unit fix silently boots
# the OLD behavior here with no indication anything is out of date.
cmd_verifyboot() {
  # --local-src=<dir> can appear anywhere among the positional args —
  # pull it out first, then treat what's left as [slot] [seconds] as before.
  _take_local_src "$@"
  set -- "${REST_ARGS[@]}"
  local local_src="$LOCAL_SRC"

  local slot="${1:-blue}"
  local timeout_secs="${2:-90}"
  _require_slot "$slot"
  [[ "$timeout_secs" =~ ^[0-9]+$ ]] || die "timeout must be numeric seconds"

  _prepare_boot "$slot" "$local_src"

  local logfile="${DATA_DIR}/boot-${slot}-console.log"
  log "Booting @${slot} headless (max ${timeout_secs}s) — console captured to ${logfile}"

  local rc=0
  _nspawn_full_boot_args "shanios-${slot}" "$slot"
  timeout "$timeout_secs" systemd-nspawn "${NSPAWN_FULL_BOOT_ARGS[@]}" \
      >"$logfile" 2>&1 || rc=$?

  if [[ $rc -ne 0 && $rc -ne 124 ]]; then
    warn "systemd-nspawn exited with rc=$rc before the timeout elapsed"
    tail -30 "$logfile" || true
    die "boot of @${slot} failed (nspawn rc=$rc)"
  fi
  # Health heuristics (distro-target agnostic): a slot may boot a custom
  # default.target (e.g. shanios-vm-guest.target) that never prints
  # "Multi-User System" or "Graphical Interface". Accept any of:
  #   - the two standard final targets, or
  #   - evidence of full userspace: Basic System + Network both reached.
  # A clean halt right at the cutoff is ALSO success: timeout's SIGTERM makes
  # nspawn power the machine off gracefully (rc=0), so the console ends with
  # a shutdown sequence even for perfectly healthy boots.
  local reached="no" failures=0 emergency=0
  if _boot_reached "$logfile"; then reached="yes"; fi
  failures=$(grep -ac "\[FAILED\]" "$logfile" 2>/dev/null || true)
  grep -aqE "Reached target (Emergency|Rescue) Mode" "$logfile" && emergency=1

  log "── verify-boot @${slot} ──────────────────────────────"
  log "  target reached : ${reached}"
  log "  failed units   : ${failures}"
  log "  emergency mode : ${emergency}"
  log "  nspawn rc      : ${rc} (0 after clean halt at cutoff / 124 = still running, both expected)"
  log "  full console   : ${logfile}"

  if [[ "$emergency" == "1" || "$reached" == "no" ]]; then
    tail -40 "$logfile" || true
    die "verify-boot FAILED for @${slot}"
  fi
  if [[ "${failures:-0}" -gt 0 ]]; then
    warn "${failures} unit(s) reported [FAILED] during boot — review ${logfile}"
  fi

  _verifyboot_check_units "$logfile"

  log "verify-boot PASSED for @${slot}"
}

# ------------------------------------------------------------------
# desktop   <blue|green> — real desktop verification via nspawn, no VM
#
# Answers the same question `gui` (QEMU) does — did a GUI app or theme
# change actually render — but runs entirely inside the build container:
# no host GPU/display, no /dev/kvm, no sudo/permission dance over root-owned
# disk images (see `gui`'s own comment above for why that bit HOST-side).
# Confirmed live before writing this: gdm.service genuinely starts under a
# real `--boot` nspawn session and survives 90-180s with zero crashes or
# [FAILED] markers, logging only "Gdm: It appears that your system does not
# have a primary GPU! Proceeding with any GPU" — but GDM's own greeter
# session doesn't log to the systemd journal at all, so this doesn't hook
# into GDM's session. Instead it boots the slot for real (so
# systemd-logind genuinely exists — a plain, non-`--boot` `enter` crashed
# gnome-shell's own JS init on a missing logind connection when this was
# tried first), nsenter's into the live container's namespaces once boot
# settles, and runs its own controlled `gnome-shell --headless
# --virtual-monitor=WxH` session (proven standalone before this: it starts
# a real Wayland compositor with a software/surfaceless renderer, no GPU
# needed) — then screenshots THAT session over its own D-Bus
# (org.gnome.Shell.Screenshot), avoiding GDM's private session bus
# entirely. Plasma/Cosmic would need this same recipe's compositor swapped
# for kwin_wayland --virtual / cosmic-comp's own headless mode respectively
# — not yet done, only GNOME has been proven end-to-end.
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# _desktop_plasma — `desktop` for Plasma slots
# ------------------------------------------------------------------
# A real, fresh-user Plasma session inside the booted slot: the display
# manager is stopped, a user is created from /etc/skel (what a new install's
# first login gets), and kwin_wayland runs NESTED on an X11 display with
# plasmashell inside it. The screenshot is an X-side `import` of that display
# - KWin's own org.kde.KWin.ScreenShot2 is NOT used: on a headless virtual
# output every capture (spectacle, or a direct call) either never returned
# or came back "Cancelled" (QPainter) / blocked (OpenGL), confirmed live.
#   --display=virtual  a private Xvfb in the builder (reuses app's helpers)
#   --display=host     your real screen (the display run_in_container.sh
#                      forwards; run `xhost +local:` on the host first) - the
#                      desktop appears in a window you can use; --hold=N keeps
#                      it up N seconds after the screenshot.
# The GPU render node, when the host has one, is bound in so KWin composites
# with real OpenGL (the fresh user is added to its group). Every wait is
# bounded; the slot is always stopped via _boot_bg_stop.
_desktop_plasma() {
  local slot="$1" exec_cmd="$2" out_file="$3" boot_timeout="$4" settle="$5" local_src="$6"
  local display_mode="$7" size="$8" hold="$9"
  [[ "$display_mode" == virtual || "$display_mode" == host ]] || die "--display must be virtual or host"
  [[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || die "--size must be WxH"
  [[ "$hold" =~ ^[0-9]+$ ]] || die "--hold must be a number of seconds"
  APP_OUT="${DATA_DIR}/desktop-${slot}"; mkdir -p "$APP_OUT"
  _app_ensure_tools
  _app_start_display "$display_mode" "$size"
  local disp="$APP_DISPLAY"
  local rnode
  for rnode in /dev/dri/renderD*; do
    [[ -c "$rnode" ]] || continue
    export SHANIOS_TEST_EXTRA_BINDS="${SHANIOS_TEST_EXTRA_BINDS:+${SHANIOS_TEST_EXTRA_BINDS},}${rnode}:${rnode}"
    break
  done

  _prepare_boot "$slot" "$local_src"
  local logfile="${DATA_DIR}/desktop-${slot}-console.log"
  local tag="desktop-$$" data_host="${MNT}/@data"
  rm -rf "${data_host}/.${tag}"
  log "Booting @${slot} (real systemd/logind) for a live Plasma desktop on ${disp} (${display_mode})..."
  _boot_bg_start "shanios-desktop-${slot}" "$slot" "$logfile"
  _wait_for_leader "$logfile"
  _wait_boot "$logfile" "$boot_timeout" "Login Prompts" _desktop_login_reached

  local w="${size%x*}" h="${size#*x}"
  nsenter --target "$LEADER_PID" --all -- bash -s -- "$disp" "$w" "$h" "$settle" "$hold" "$exec_cmd" "/data/.${tag}" \
    >"${APP_OUT}/session.log" 2>&1 <<'PLASMA_EOF' &
set -u
disp="$1" w="$2" h="$3" settle="$4" hold="$5" exec_cmd="$6" dir="$7"
systemctl stop display-manager.service >/dev/null 2>&1 || true
u=shanidesk
userdel -r "$u" >/dev/null 2>&1
groups=""; [[ -c /dev/dri/renderD128 ]] && groups="-G $(stat -c %G /dev/dri/renderD128)"
useradd -m $groups -s /bin/zsh "$u"
uid=$(id -u "$u"); rt="/run/user/${uid}"
mkdir -p "$rt"; chown "$u:" "$rt"; chmod 700 "$rt"
# handshake + logs: a dir the session user owns (/data itself is root-only)
mkdir -p "$dir"; chown "$u:" "$dir"; flag="$dir/s"
# kded's Bluetooth module re-activates org.bluez.obex in a loop without
# bluetoothd (14k activations in 2 min, observed live) - off for this user
runuser -u "$u" -- kwriteconfig6 --file kded5rc --group Module-bluedevil --key autoload false
runuser -u "$u" -- env -i HOME="/home/$u" USER="$u" LOGNAME="$u" SHELL=/bin/zsh PATH=/usr/local/bin:/usr/bin \
  XDG_RUNTIME_DIR="$rt" LANG=C.UTF-8 DISPLAY="$disp" \
  DP_W="$w" DP_H="$h" DP_SETTLE="$settle" DP_HOLD="$hold" DP_EXEC="$exec_cmd" DP_FLAG="$flag" \
  dbus-run-session -- bash -c '
  export XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE KDE_FULL_SESSION=true KDE_SESSION_VERSION=6 XDG_SESSION_TYPE=wayland
  # what startplasma does at a first login: apply the user'"'"'s global theme
  # (skel kdeglobals LookAndFeelPackage) into ~/.config/kdedefaults and put
  # that first in XDG_CONFIG_DIRS - without it the shell comes up stock Breeze
  lnf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)
  [ -n "$lnf" ] && QT_QPA_PLATFORM=offscreen plasma-apply-lookandfeel -a "$lnf" >/dev/null 2>&1
  export XDG_CONFIG_DIRS="$HOME/.config/kdedefaults:${XDG_CONFIG_DIRS:-/etc/xdg}"
  echo "look-and-feel: ${lnf:-none}" > "$DP_FLAG.lnf"
  kwin_wayland --x11-display="$DISPLAY" --width "$DP_W" --height "$DP_H" --no-lockscreen --xwayland >"$DP_FLAG.kwin.log" 2>&1 &
  KW=$!
  for i in $(seq 1 40); do [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; kill -0 $KW 2>/dev/null || break; sleep 1; done
  [ -S "$XDG_RUNTIME_DIR/wayland-0" ] || { echo "kwin_wayland did not start"; exit 1; }
  export WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland
  dbus-update-activation-environment --all >/dev/null 2>&1
  plasmashell >"$DP_FLAG.shell.log" 2>&1 &
  sleep "$DP_SETTLE"
  if [ -n "$DP_EXEC" ]; then bash -c "$DP_EXEC" || echo "--exec exited non-zero (continuing)"; sleep 3; fi
  dbus-send --session --print-reply --dest=org.kde.KWin /KWin org.kde.KWin.supportInformation 2>/dev/null \
    | grep -m2 -iE "Compositing Type|OpenGL renderer" > "$DP_FLAG.info"
  touch "$DP_FLAG.ready"
  for i in $(seq 1 60); do [ -e "$DP_FLAG.shot" ] && break; sleep 1; done
  sleep "$DP_HOLD"
  pkill -x plasmashell; kill $KW 2>/dev/null; wait $KW 2>/dev/null; true'
PLASMA_EOF
  local sess=$!
  local ready=0 i
  for (( i=0; i<settle+120; i++ )); do
    [[ -e "${data_host}/.${tag}/s.ready" ]] && { ready=1; break; }
    kill -0 "$sess" 2>/dev/null || break
    sleep 1
  done
  local rc=0
  if (( ready )); then
    cat "${data_host}/.${tag}/s.lnf" "${data_host}/.${tag}/s.info" 2>/dev/null | sed 's/^ */  /' | while IFS= read -r l; do log "$l"; done
    if [[ "$display_mode" == host ]]; then
      local wid; wid=$(DISPLAY="$disp" xdotool search --name "KDE Wayland Compositor" 2>/dev/null | tail -1 || true)
      if [[ -n "$wid" ]]; then import -display "$disp" -window "$wid" "$out_file" || rc=$?
      else import -display "$disp" -window root "$out_file" || rc=$?; fi
      (( hold > 0 )) && log "Plasma is on your screen for ${hold}s (--hold) - the slot stops after that"
    else
      import -display "$disp" -window root "$out_file" || rc=$?
    fi
  else
    warn "Plasma session never became ready; last lines of its logs (agents: don't read disk/ by hand):"
    { grep -v -iE 'bluez|obex' "${APP_OUT}/session.log" 2>/dev/null | tail -8
      grep -v -iE 'bluez|obex' "${data_host}/.${tag}/s.kwin.log" 2>/dev/null | tail -5; } | sed 's/^/    /' >&2
    rc=1
  fi
  touch "${data_host}/.${tag}/s.shot"
  for (( i=0; i<hold+60; i++ )); do kill -0 "$sess" 2>/dev/null || break; sleep 1; done
  kill "$sess" 2>/dev/null || true
  cp -f "${data_host}/.${tag}/s.kwin.log" "${APP_OUT}/kwin.log" 2>/dev/null || true
  cp -f "${data_host}/.${tag}/s.shell.log" "${APP_OUT}/plasmashell.log" 2>/dev/null || true
  rm -rf "${data_host}/.${tag}"
  _boot_bg_stop
  trap - EXIT
  [[ -n "${APP_XVFB_PID:-}" ]] && kill "$APP_XVFB_PID" 2>/dev/null
  [[ $rc -eq 0 && -s "$out_file" ]] || die "no Plasma screenshot produced (logs: ${APP_OUT}/)"
  log "Screenshot saved: ${out_file}"
}

# ------------------------------------------------------------------
# probe   <blue|green> --exec="cmd" [--timeout=N] [--settle=N] [--local-src=<dir>]
# ------------------------------------------------------------------
# Generic live-boot diagnostic: boots a slot for real (--boot), waits for
# a Multi-User/Graphical target, then nsenter's into the live container's
# namespaces and runs an arbitrary command — e.g. `systemctl status
# data.mount mark-boot-success.service --no-pager -l`. Same
# leader-pid-finding/nsenter mechanism as `desktop`, generalized to any
# command instead of hardcoding a gnome-shell session. Built to
# investigate why a specific unit doesn't show up in a plain verify-boot
# console log — aggregate target-reached/failed-count (and even grepping
# the console for a unit's Description=) can't tell you WHY a unit never
# started, only THAT it didn't; this can actually ask systemd.
cmd_probe() {
  local slot="${1:?Usage: $(basename "$0") probe <blue|green> --exec=\"cmd\" [--timeout=N] [--settle=N] [--local-src=<dir>]}"
  shift || true
  _require_slot "$slot"
  command -v nsenter >/dev/null 2>&1 || die "nsenter is required (util-linux) — should already be present."

  local exec_cmd="" boot_timeout=180 settle=15 local_src="" arg
  for arg in "$@"; do
    case "$arg" in
      --exec=*)      exec_cmd="${arg#--exec=}" ;;
      --timeout=*)   boot_timeout="${arg#--timeout=}" ;;
      --settle=*)    settle="${arg#--settle=}" ;;
      --local-src=*) local_src="${arg#--local-src=}" ;;
      --local-pkg=*) export SHANIOS_TEST_LOCAL_PKGS="${SHANIOS_TEST_LOCAL_PKGS:+${SHANIOS_TEST_LOCAL_PKGS},}${arg#--local-pkg=}" ;;
      *) die "Usage: $(basename "$0") probe <blue|green> --exec=\"cmd\" [--timeout=N] [--settle=N] [--local-src=<dir>]" ;;
    esac
  done
  [[ -n "$exec_cmd" ]] || die "probe requires --exec=\"cmd\""

  _prepare_boot "$slot" "$local_src"

  local logfile="${DATA_DIR}/probe-${slot}-console.log"
  log "Booting @${slot} in the background (real systemd, no display) for a live probe..."
  _boot_bg_start "shanios-probe-${slot}" "$slot" "$logfile"
  _wait_for_leader "$logfile"
  log "Container init is PID ${LEADER_PID} — waiting up to ${boot_timeout}s for Multi-User/Graphical target..."
  _wait_boot "$logfile" "$boot_timeout" "Multi-User/Graphical target" _boot_reached
  sleep "$settle"

  log "Running probe command inside the live container via nsenter: ${exec_cmd}"
  local probe_rc=0
  nsenter --target "$LEADER_PID" --all -- bash -c "$exec_cmd" || probe_rc=$?

  # Graceful poweroff (was a bare kill — the hard-kill hazard _boot_bg_stop
  # documents).
  _boot_bg_stop
  trap - EXIT
  return "$probe_rc"
}

_desktop_login_reached() { grep -aq "Reached target Login Prompts" "$1" 2>/dev/null; }

cmd_desktop() {
  local slot="${1:?Usage: $(basename "$0") desktop <blue|green> [--exec=\"cmd\"] [--out=<file.png>] [--timeout=N] [--settle=N]}"
  shift || true
  _require_slot "$slot"

  command -v nsenter >/dev/null 2>&1 || die "nsenter is required (util-linux) — should already be present."

  local exec_cmd="" out_file="" boot_timeout=180 settle=25 local_src="" arg
  local de=auto display_mode=virtual size=1600x900 hold=0
  for arg in "$@"; do
    case "$arg" in
      --local-src=*) local_src="${arg#--local-src=}" ;;
      --exec=*)    exec_cmd="${arg#--exec=}" ;;
      --out=*)     out_file="${arg#--out=}" ;;
      --timeout=*) boot_timeout="${arg#--timeout=}" ;;
      --settle=*)  settle="${arg#--settle=}" ;;
      --de=*)      de="${arg#--de=}" ;;
      --local-pkg=*) export SHANIOS_TEST_LOCAL_PKGS="${SHANIOS_TEST_LOCAL_PKGS:+${SHANIOS_TEST_LOCAL_PKGS},}${arg#--local-pkg=}" ;;
      --display=*) display_mode="${arg#--display=}" ;;
      --size=*)    size="${arg#--size=}" ;;
      --hold=*)    hold="${arg#--hold=}" ;;
      *)
        echo "Usage: $(basename "$0") desktop <blue|green> [--de=auto|gnome|plasma] [--display=virtual|host] [--size=WxH] [--hold=SECONDS] [--local-pkg=<name|file>] [--exec=\"cmd\"] [--out=<file.png>] [--timeout=N] [--settle=N] [--local-src=<dir>]" >&2
        exit 1
        ;;
    esac
  done
  # default outside disk/: that directory is loop images + state nobody should
  # have to browse; screenshots are for looking at
  if [[ -z "$out_file" ]]; then
    mkdir -p "${SCRIPT_DIR}/shots"
    out_file="${SCRIPT_DIR}/shots/desktop-${slot}-$(date +%s).png"
  fi
  if [[ "$de" == auto ]]; then
    _mount_root
    de=$(tr -d '[:space:]' < "${MNT}/@${slot}/etc/shani-profile" 2>/dev/null || true)
    [[ "$de" == plasma ]] || de=gnome
    log "desktop: @${slot} is a '${de}' slot"
  fi
  if [[ "$de" == plasma ]]; then
    _desktop_plasma "$slot" "$exec_cmd" "$out_file" "$boot_timeout" "$settle" "$local_src" "$display_mode" "$size" "$hold"
    return
  fi
  [[ "$display_mode" == virtual && "$hold" == 0 ]] \
    || die "--display=host / --hold are Plasma-only so far (GNOME uses gnome-shell --headless and its own Screenshot API)"

  _prepare_boot "$slot" "$local_src"

  local logfile="${DATA_DIR}/desktop-${slot}-console.log"
  local container_out="/data/.desktop-probe-$$.png"

  log "Booting @${slot} in the background (real systemd/logind, no display) for a live desktop probe..."
  _boot_bg_start "shanios-desktop-${slot}" "$slot" "$logfile"
  log "Locating the container's init PID (child of ${BOOT_PID})..."
  _wait_for_leader "$logfile"
  log "Container init is PID ${LEADER_PID} — waiting up to ${boot_timeout}s for a login prompt..."
  _wait_boot "$logfile" "$boot_timeout" "Login Prompts" _desktop_login_reached

  log "Running the desktop probe inside the live container via nsenter..."
  local probe_rc=0
  nsenter --target "$LEADER_PID" --all -- bash -s -- "$exec_cmd" "$container_out" "$settle" <<'PROBE_EOF' || probe_rc=$?
set -uo pipefail
exec_cmd="$1"; out_file="$2"; settle="$3"

# gdm.service's own real greeter session already runs its own gnome-shell
# in this real --boot — confirmed live: running our own separate headless
# instance alongside it made the fresh instance crash off the bus about a
# second after finishing D-Bus activation (no segfault message captured,
# just a clean disappearance — consistent with resource/seat contention
# between two concurrent Wayland compositors, not a bug in the retry loop
# below). Stop GDM's session first so ours is the only compositor running.
systemctl stop gdm.service >/dev/null 2>&1 || true

cat > /tmp/desktop-probe-inner.sh <<'INNER_EOF'
#!/bin/bash
set -uo pipefail
# Root cause found live (matches the Xwayland/EGL crash seen much earlier
# testing plain `gnome-shell --headless` standalone): this environment has
# a broken/conflicting NVIDIA EGL vendor library even though there's no
# real NVIDIA GPU anywhere in this path. Mutter eagerly starts Xwayland for
# X11-client compat; Xwayland's glamor init walks into that library and
# crashes, and losing its own embedded Xwayland takes gnome-shell down with
# it a moment later ("Gdk-Message: Error reading events from display:
# Broken pipe" right before org.gnome.Shell disappears from the bus). We
# only need the native Wayland compositor + its Screenshot D-Bus API, no
# X11 client support, so disable Xwayland entirely via Mutter's own debug
# env var instead of fixing the EGL library.
#
# WAYLAND_DISPLAY exported so it can be propagated into the D-Bus
# activation environment below — confirmed live this matters:
# gnome-shell's OWN Screenshot D-Bus method works with no explicit
# propagation at all (it's a method on the compositor process itself,
# already running, not a separate D-Bus activation), but ANY other client
# needing the display — a manually launched `yad` dialog, or gnome-shell's
# own D-Bus-activated org.gnome.Shell.Screencast service — failed with
# "Gtk-WARNING: cannot open display" every time, because WAYLAND_DISPLAY
# was never in dbus-run-session's activation environment, only in the one
# shell that happened to launch gnome-shell itself.
#
# Fixed value "wayland-0", NOT a custom name: confirmed live that
# gnome-shell --headless ignores a pre-set WAYLAND_DISPLAY env var
# entirely and always creates its socket at the compositor's own default
# name regardless (`ls $XDG_RUNTIME_DIR` after startup showed `wayland-0`
# even with WAYLAND_DISPLAY=wayland-shani-probe exported beforehand) — so
# this just reflects that reality rather than attempting to override it.
export WAYLAND_DISPLAY=wayland-0
MUTTER_NO_XWAYLAND=1 gnome-shell --headless --virtual-monitor=1280x800 >/tmp/desktop-probe-shell.log 2>&1 &
GSPID=$!
ready=0
for i in $(seq 1 "$DESKTOP_PROBE_SETTLE"); do
  gdbus introspect --session --dest org.gnome.Shell --object-path /org/gnome/Shell >/dev/null 2>&1 \
    && { ready=1; break; }
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "gnome-shell never registered on the session bus" >&2
  cat /tmp/desktop-probe-shell.log >&2 || true
  kill "$GSPID" 2>/dev/null; wait 2>/dev/null
  exit 1
fi
# Propagate WAYLAND_DISPLAY (and XDG_RUNTIME_DIR, already exported by the
# caller) into the D-Bus session's OWN activation environment — without
# this, any client dbus-activates (or that --exec launches fresh) never
# sees it, only the process tree that happened to launch gnome-shell does.
dbus-update-activation-environment --verbose WAYLAND_DISPLAY XDG_RUNTIME_DIR >/tmp/desktop-probe-dbusenv.log 2>&1 || true
if [ -n "${DESKTOP_PROBE_EXEC:-}" ]; then
  bash -c "$DESKTOP_PROBE_EXEC" || echo "probe --exec command exited non-zero (continuing)" >&2
fi
# Introspecting /org/gnome/Shell/Screenshot succeeds (false-positive "ready")
# before the Screenshot method is actually callable — confirmed live: the
# introspect check passed immediately, yet the very next call still hit
# "Object does not exist at path /org/gnome/Shell/Screenshot" every time.
# Retry the REAL call itself instead of trusting introspection as a proxy.
rc=1
for i in $(seq 1 "$DESKTOP_PROBE_SETTLE"); do
  call_err=$(gdbus call --session --dest org.gnome.Shell \
    --object-path /org/gnome/Shell/Screenshot \
    --method org.gnome.Shell.Screenshot.Screenshot \
    false false "$DESKTOP_PROBE_OUT" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    break
  fi
  echo "screenshot attempt $i/$DESKTOP_PROBE_SETTLE failed: $call_err" >&2
  sleep 1
done
kill "$GSPID" 2>/dev/null
wait 2>/dev/null
exit $rc
INNER_EOF
chmod +x /tmp/desktop-probe-inner.sh

export XDG_RUNTIME_DIR="/run/probe-$$"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export DESKTOP_PROBE_EXEC="$exec_cmd"
export DESKTOP_PROBE_OUT="$out_file"
export DESKTOP_PROBE_SETTLE="$settle"
dbus-run-session -- /tmp/desktop-probe-inner.sh
PROBE_EOF

  if [[ $probe_rc -ne 0 ]]; then
    warn "desktop probe exited non-zero (rc=${probe_rc}) — see above for gnome-shell's own log"
  fi

  local host_container_out="${MNT}/@data/$(basename "$container_out")"
  if [[ -f "$host_container_out" ]]; then
    cp -f "$host_container_out" "$out_file"
    rm -f "$host_container_out"
    log "Screenshot saved: ${out_file}"
  else
    die "probe finished but no screenshot was produced at ${host_container_out} (rc=${probe_rc})"
  fi
}

# ------------------------------------------------------------------
# slot-test <blue|green> <name...|all> [--local-src=<dir>] [--timeout=N] [--settle=N]
# ------------------------------------------------------------------
# Runs in-slot checks from slot-tests/ (visible in every slot at
# /mnt/testbed/slot-tests). A file takes part when its header declares
#   # slot-test-mode: boot    run inside ONE shared full --boot of the slot
# (the same background-boot lifecycle probe uses, graceful stop included).
# Each test prints `RESULT <name> PASS|FAIL ...` lines; this aggregates them
# and fails if any line is FAIL or a test exits non-zero.
#
# This is where a new in-slot check belongs: add a file here instead of a
# one-off script (see AGENTS.md).
_slot_test_mode() { sed -n 's/^# slot-test-mode: *\([a-z]*\).*/\1/p' "$1" | head -1; }

cmd_slot_test() {
  local usage_st="Usage: $(basename "$0") slot-test <blue|green> <name...|all> [--local-src=<dir>] [--timeout=N] [--settle=N]"
  local slot="${1:-}"; shift || true
  _require_slot "$slot" "$usage_st"
  local local_src="" boot_timeout=240 settle=20 arg
  local -a wanted=()
  for arg in "$@"; do
    case "$arg" in
      --local-src=*) local_src="${arg#--local-src=}" ;;
      --timeout=*)   boot_timeout="${arg#--timeout=}" ;;
      --settle=*)    settle="${arg#--settle=}" ;;
      --*)           die "$usage_st" ;;
      *)             wanted+=("$arg") ;;
    esac
  done
  (( ${#wanted[@]} > 0 )) || die "$usage_st"

  local dir="${TESTBED_ROOT}/slot-tests" f name mode
  local -a tests=()
  if [[ "${wanted[0]}" == all ]]; then
    for f in "$dir"/*.sh; do
      [[ "$(_slot_test_mode "$f")" == boot ]] && tests+=("$f")
    done
  else
    for name in "${wanted[@]}"; do
      f="${dir}/${name%.sh}.sh"
      [[ -f "$f" ]] || die "no such slot test: ${name} (see ${dir})"
      mode="$(_slot_test_mode "$f")"
      [[ "$mode" == boot ]] || die "${name}: header has no '# slot-test-mode: boot' — run it via enter/probe instead"
      tests+=("$f")
    done
  fi
  (( ${#tests[@]} > 0 )) || die "no slot tests selected"

  _prepare_boot "$slot" "$local_src"
  local logfile="${DATA_DIR}/slot-test-${slot}-console.log"
  log "Booting @${slot} once for ${#tests[@]} slot test(s)..."
  _boot_bg_start "shanios-slottest-${slot}" "$slot" "$logfile"
  _wait_for_leader "$logfile"
  _wait_boot "$logfile" "$boot_timeout" "Multi-User/Graphical target" _boot_reached
  sleep "$settle"

  local -a summary=()
  local failed=0 out rc pass fail
  for f in "${tests[@]}"; do
    name="$(basename "$f" .sh)"
    log "── slot-test ${name} ──"
    rc=0
    out="$(nsenter --target "$LEADER_PID" --all -- bash "/mnt/testbed/slot-tests/$(basename "$f")" 2>&1)" || rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    pass=$(grep -c '^RESULT .* PASS' <<<"$out" || true)
    fail=$(grep -c '^RESULT .* FAIL' <<<"$out" || true)
    if (( rc != 0 || fail > 0 || pass == 0 )); then failed=1; fi
    summary+=("$(printf '%-28s %3d pass %3d fail  rc=%d' "$name" "$pass" "$fail" "$rc")")
  done

  _boot_bg_stop
  trap - EXIT
  log "── slot-test summary (@${slot}) ──"
  local line
  for line in "${summary[@]}"; do log "  ${line}"; done
  (( failed == 0 )) || die "slot-test FAILED"
  log "slot-test PASSED"
}
