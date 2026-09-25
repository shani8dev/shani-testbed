# lib/app.sh — `app`: run a GUI app inside a slot and drive it like a user.
#
#   app <blue|green> --run="<cmd>" [--local-src=<dir>] [--display=virtual|host]
#       [--size=WxH] [--out-dir=<dir>] [--timeout=SECS]
#       [ACTIONS...] | --script=<file> | --interactive | --control=<dir>
#
# The app runs INSIDE the slot (nspawn, the real installed userspace, with
# --local-src overlays like every other command) and draws on an X display
# that is reached through the harness's existing X11 bind (_nspawn_binds'
# X11_BIND: /tmp/.X11-unix into the slot):
#   --display=virtual (default)  a private Xvfb started in the builder
#                                container. Nothing touches your real screen
#                                or input devices, so clicks/keys are safe.
#   --display=host               the host display run_in_container.sh already
#                                forwards (DISPLAY + /tmp/.X11-unix; needs
#                                `xhost +local:` on the host). You can watch the
#                                app on your real screen — but injected input
#                                then goes to your real X session too.
# Toolkits are pinned to their X11 backends (GDK_BACKEND=x11,
# QT_QPA_PLATFORM=xcb) with software rendering (GSK_RENDERER=cairo,
# LIBGL_ALWAYS_SOFTWARE=1): native-Wayland input injection would need a
# virtual-pointer compositor the image doesn't ship, and there's no GPU here.
# A host Wayland session is still reachable for *viewing* via --display=host
# only if XWayland provides DISPLAY.
#
# Actions (flags on the command line, run in order; the same words, without
# the leading --, in --script files, --interactive stdin and --control):
#   wait-window=REGEX[:SECS]     wait until a visible window title matches
#   expect-window=REGEX          fail unless a matching window exists now
#   expect-gone=REGEX[:SECS]     wait until no window matches
#   windows                      list visible windows: id, geometry, title
#   click=X,Y[:button]           left|middle|right; X,Y absolute pixels, or
#   click=@REGEX:X,Y[:button]      relative to the matching window's origin
#   doubleclick=X,Y | rightclick=X,Y | move=X,Y   (same @REGEX: form)
#   drag=X1,Y1:X2,Y2             press at 1, move, release at 2
#   scroll=up|down|left|right[:N]
#   focus=REGEX                  give keyboard focus to the matching window
#   type=TEXT                    literal text (xdotool type)
#   key=COMBO                    e.g. Return, Escape, Tab, ctrl+a, alt+F4
#                                (type/key first focus the app's newest window
#                                if none of its windows has focus: the virtual
#                                display runs no window manager to do that)
#   screenshot[=FILE.png]        whole display (default: <out-dir>/shot-N.png)
#   sleep=SECS
#   wait-exit[=SECS]             wait for the app to exit; reports its rc
#   tree[=DEPTH]                 accessibility tree (AT-SPI): ref, role, name,
#                                states, screen box — the native-app analogue
#                                of a browser DOM / read_page
#   find=QUERY                   on-screen elements matching QUERY: a regex
#                                on name/role, or ROLE:NAME-REGEX
#                                (e.g. find=button:^OK$)
#   click-element=QUERY[#N]      click the centre of the Nth match (default 1st)
#   doubleclick-element= / rightclick-element=   same, other clicks
#   status                       app running?/rc, display, size
#   quit                         stop the app and end the session
#
# Output: <out-dir> (default disk/app-<slot>-<epoch>/) gets app.stdout,
# app.stderr, app.rc (once it exits) and screenshots. The command's exit code
# is non-zero if any action failed.
#
# --control=<dir>: long-lived session for an external driver (the MCP server
# in test-env/mcp/). Writes <dir>/session.json once ready, then reads
# "<id> <action>" lines from <dir>/cmd.fifo and answers each with
# <dir>/reply.<id>.json ({"ok":bool,"text":...,"file":...}). Ends on `quit`,
# app exit is NOT an end (the driver may still want a final screenshot), or
# after --idle-timeout seconds (default 1800) without a command.

# python-gobject + at-spi2-core: the accessibility-tree client (lib/a11y_client.py).
APP_TOOLS_PKGS=(xorg-server-xvfb xdotool imagemagick python-gobject at-spi2-core)

_app_ensure_tools() {
  local missing=0 t
  for t in Xvfb xdotool import; do command -v "$t" >/dev/null 2>&1 || missing=1; done
  python3 -c 'import gi; gi.require_version("Atspi", "2.0")' 2>/dev/null || missing=1
  (( missing )) || return 0
  command -v pacman >/dev/null 2>&1 || die "app needs Xvfb, xdotool and ImageMagick (import) — install them"
  log "Installing ${APP_TOOLS_PKGS[*]} into the builder container (cached in cache/pacman_cache after the first run)..."
  pacman -Sy --noconfirm --needed "${APP_TOOLS_PKGS[@]}" >/dev/null \
    || die "could not install ${APP_TOOLS_PKGS[*]}"
}

# First display number with no socket or lock file. When the host forwards
# its /tmp/.X11-unix, that directory IS the host's, so this also avoids any
# display the host is using.
_app_free_display() {
  local n
  for (( n=90; n<200; n++ )); do
    [[ -e "/tmp/.X11-unix/X${n}" || -e "/tmp/.X${n}-lock" ]] || { echo "$n"; return 0; }
  done
  die "no free X display number between :90 and :199"
}

_app_start_display() {
  local mode="$1" size="$2"
  if [[ "$mode" == host ]]; then
    [[ -n "${DISPLAY:-}" && -d /tmp/.X11-unix ]] \
      || die "--display=host needs the host's DISPLAY forwarded (run_in_container.sh does this when DISPLAY is set on the host; also run 'xhost +local:' there)"
    APP_DISPLAY="$DISPLAY"
    warn "--display=host: the app draws on your real screen, and every click/key action is injected into your real X session"
    return 0
  fi
  mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
  local n; n="$(_app_free_display)"
  # -ac: no access control — a private throwaway display nobody else can
  # reach; the slot's clients have no Xauthority to present anyway.
  Xvfb ":${n}" -screen 0 "${size}x24" -nolisten tcp -ac >"${APP_OUT}/xvfb.log" 2>&1 &
  APP_XVFB_PID=$!
  local i
  for (( i=0; i<50; i++ )); do
    [[ -S "/tmp/.X11-unix/X${n}" ]] && break
    kill -0 "$APP_XVFB_PID" 2>/dev/null || die "Xvfb exited — see ${APP_OUT}/xvfb.log"
    sleep 0.1
  done
  [[ -S "/tmp/.X11-unix/X${n}" ]] || die "Xvfb :${n} did not come up — see ${APP_OUT}/xvfb.log"
  APP_DISPLAY=":${n}"
}

_app_cleanup() {
  # Runs from an EXIT trap: only globals are visible here.
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    local w=0
    while kill -0 "$APP_PID" 2>/dev/null && (( w < 10 )); do sleep 1; w=$((w + 1)); done
    kill -9 "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "${APP_XVFB_PID:-}" ]]; then kill "$APP_XVFB_PID" 2>/dev/null || true; fi
  if [[ -n "${APP_RT:-}" && -d "$APP_RT" ]]; then
    # The in-slot dbus-daemon was --fork'ed out of the nspawn process tree;
    # it's visible from here (the slot's PID namespace is a child of ours).
    pkill -f "dbus-daemon --session --address=unix:path=${APP_RT}/bus" 2>/dev/null || true
    rm -rf "$APP_RT"
  fi
}

_app_running() { [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; }

# Visible windows matching REGEX (xdotool search is a regex on the title).
_app_find() { xdotool search --onlyvisible --name "$1" 2>/dev/null || true; }

_app_geometry() {  # <window-id> -> sets WX WY WW WH
  local k v
  WX=0 WY=0 WW=0 WH=0
  while IFS='=' read -r k v; do
    case "$k" in X) WX="$v" ;; Y) WY="$v" ;; WIDTH) WW="$v" ;; HEIGHT) WH="$v" ;; esac
  done < <(xdotool getwindowgeometry --shell "$1" 2>/dev/null)
}

# Resolves "X,Y" or "@REGEX:X,Y" to absolute PX/PY. Returns 1 (APP_REPLY set)
# if the window isn't found.
_app_point() {
  local spec="$1" win id
  if [[ "$spec" == @* ]]; then
    win="${spec#@}"; spec="${win##*:}"; win="${win%:*}"
    id="$(_app_find "$win" | head -1)"
    [[ -n "$id" ]] || { APP_REPLY="no visible window matches /${win}/"; return 1; }
    _app_geometry "$id"
    PX=$(( WX + ${spec%%,*} )); PY=$(( WY + ${spec##*,} ))
  else
    PX="${spec%%,*}"; PY="${spec##*,}"
  fi
  [[ "$PX" =~ ^-?[0-9]+$ && "$PY" =~ ^-?[0-9]+$ ]] || { APP_REPLY="bad coordinates: $1"; return 1; }
}

_app_button() {
  case "${1:-left}" in left|1) echo 1 ;; middle|2) echo 2 ;; right|3) echo 3 ;;
    *) return 1 ;; esac
}

_app_wait() {  # <timeout> <check-command...>
  local timeout="$1"; shift
  local deadline=$(( $(date +%s) + timeout ))
  while :; do
    if "$@"; then return 0; fi
    (( $(date +%s) >= deadline )) && return 1
    sleep 0.5
  done
}
_app_has_window() { [[ -n "$(_app_find "$1")" ]]; }

# With no window manager on the virtual display nothing assigns keyboard
# focus (XGetInputFocus reports PointerRoot), so typed keys went to the root
# window and were lost. Before type/key: if the focused window isn't one of
# the visible app windows, focus the newest one.
_app_ensure_focus() {
  local focused ids
  ids="$(_app_find '.')"
  [[ -n "$ids" ]] || return 0
  focused="$(xdotool getwindowfocus 2>/dev/null || true)"
  if [[ -n "$focused" ]] && grep -qx "$focused" <<<"$ids"; then return 0; fi
  xdotool windowfocus --sync "$(tail -1 <<<"$ids")" 2>/dev/null || true
}
_app_no_window()  { [[ -z "$(_app_find "$1")" ]]; }

APP_SHOT_N=0
A11Y_CLIENT="${LIB_DIR}/a11y_client.py"

# Executes one action ("name" or "name=value"). Sets APP_REPLY (human text)
# and APP_FILE (screenshot path, if any). Returns 0 on success.
_app_do() {
  local action="$1" name value
  name="${action%%=*}"; value=""
  [[ "$action" == *=* ]] && value="${action#*=}"
  APP_REPLY="" APP_FILE=""
  local btn t spec
  case "$name" in
    wait-window)
      t="${value##*:}"; spec="$value"
      if [[ "$value" == *:* && "$t" =~ ^[0-9]+$ ]]; then spec="${value%:*}"; else t=30; fi
      if _app_wait "$t" _app_has_window "$spec"; then APP_REPLY="window /${spec}/ is visible"
      else APP_REPLY="no window matching /${spec}/ within ${t}s"; return 1; fi ;;
    expect-window)
      if _app_has_window "$value"; then APP_REPLY="window /${value}/ present"
      else APP_REPLY="expected a window matching /${value}/, found none"; return 1; fi ;;
    expect-gone)
      t="${value##*:}"; spec="$value"
      if [[ "$value" == *:* && "$t" =~ ^[0-9]+$ ]]; then spec="${value%:*}"; else t=10; fi
      if _app_wait "$t" _app_no_window "$spec"; then APP_REPLY="no window matches /${spec}/"
      else APP_REPLY="window /${spec}/ still visible after ${t}s"; return 1; fi ;;
    windows)
      local id out=""
      while read -r id; do
        [[ -n "$id" ]] || continue
        _app_geometry "$id"
        out+="${id} ${WX},${WY} ${WW}x${WH} $(xdotool getwindowname "$id" 2>/dev/null)"$'\n'
      done < <(_app_find '.')
      APP_REPLY="${out:-no visible windows}" ;;
    click|doubleclick|rightclick|move)
      spec="$value"; btn=left
      # Optional trailing :button (only for the plain X,Y form or after the
      # @REGEX:X,Y form's coordinates).
      if [[ "$spec" =~ ^(.*[0-9]),?:(left|middle|right)$ ]]; then spec="${BASH_REMATCH[1]}"; btn="${BASH_REMATCH[2]}"; fi
      [[ "$name" == rightclick ]] && btn=right
      _app_point "$spec" || return 1
      local b; b="$(_app_button "$btn")" || { APP_REPLY="bad button: $btn"; return 1; }
      case "$name" in
        move)        xdotool mousemove "$PX" "$PY" ;;
        doubleclick) xdotool mousemove "$PX" "$PY" click --repeat 2 --delay 120 "$b" ;;
        *)           xdotool mousemove "$PX" "$PY" click "$b" ;;
      esac || { APP_REPLY="xdotool ${name} failed"; return 1; }
      APP_REPLY="${name} at ${PX},${PY}${btn:+ (${btn})}" ;;
    drag)
      local from="${value%%:*}" to="${value#*:}" fx fy
      _app_point "$from" || return 1; fx=$PX; fy=$PY
      _app_point "$to" || return 1
      xdotool mousemove "$fx" "$fy" mousedown 1 sleep 0.15 mousemove "$PX" "$PY" sleep 0.15 mouseup 1 \
        || { APP_REPLY="xdotool drag failed"; return 1; }
      APP_REPLY="dragged ${fx},${fy} -> ${PX},${PY}" ;;
    scroll)
      local dir="${value%%:*}" n=3
      [[ "$value" == *:* ]] && n="${value#*:}"
      case "$dir" in up) b=4 ;; down) b=5 ;; left) b=6 ;; right) b=7 ;;
        *) APP_REPLY="scroll direction must be up|down|left|right"; return 1 ;; esac
      xdotool click --repeat "$n" --delay 40 "$b" || { APP_REPLY="xdotool scroll failed"; return 1; }
      APP_REPLY="scrolled ${dir} x${n}" ;;
    focus)
      local fid; fid="$(_app_find "$value" | tail -1)"
      [[ -n "$fid" ]] || { APP_REPLY="no visible window matches /${value}/"; return 1; }
      xdotool windowfocus --sync "$fid" 2>/dev/null || { APP_REPLY="could not focus ${fid}"; return 1; }
      APP_REPLY="focused ${fid} ($(xdotool getwindowname "$fid" 2>/dev/null))" ;;
    type)
      _app_ensure_focus
      xdotool type --delay 40 -- "$value" || { APP_REPLY="xdotool type failed"; return 1; }
      APP_REPLY="typed ${#value} characters" ;;
    key)
      _app_ensure_focus
      xdotool key --delay 40 -- "$value" || { APP_REPLY="xdotool key ${value} failed (use X keysym names: Return, Escape, ctrl+a)"; return 1; }
      APP_REPLY="key ${value}" ;;
    screenshot)
      APP_SHOT_N=$((APP_SHOT_N + 1))
      APP_FILE="${value:-${APP_OUT}/shot-${APP_SHOT_N}.png}"
      import -display "$APP_DISPLAY" -window root "$APP_FILE" 2>/dev/null \
        || { APP_REPLY="screenshot failed"; APP_FILE=""; return 1; }
      APP_REPLY="screenshot ${APP_FILE}" ;;
    sleep)
      [[ "$value" =~ ^[0-9.]+$ ]] || { APP_REPLY="sleep needs seconds"; return 1; }
      sleep "$value"; APP_REPLY="slept ${value}s" ;;
    wait-exit)
      t="${value:-30}"
      if _app_wait "$t" _app_exited; then APP_REPLY="app exited rc=$(cat "${APP_OUT}/app.rc")"
      else APP_REPLY="app still running after ${t}s"; return 1; fi ;;
    status)
      if _app_running; then APP_REPLY="running (display ${APP_DISPLAY}, ${APP_SIZE})"
      elif [[ -f "${APP_OUT}/app.rc" ]]; then APP_REPLY="exited rc=$(cat "${APP_OUT}/app.rc")"
      else APP_REPLY="not running"; fi ;;
    tree)
      APP_REPLY="$(python3 "$A11Y_CLIENT" tree ${value:+--max-depth "$value"} 2>&1)" \
        || { APP_REPLY="accessibility tree unavailable: ${APP_REPLY}"; return 1; } ;;
    find)
      APP_REPLY="$(python3 "$A11Y_CLIENT" find "$value" 2>&1)" \
        || { APP_REPLY="${APP_REPLY:-no element matches /${value}/}"; return 1; } ;;
    click-element|doubleclick-element|rightclick-element)
      local nth=1 query="$value" center
      if [[ "$value" =~ ^(.*)#([0-9]+)$ ]]; then query="${BASH_REMATCH[1]}"; nth="${BASH_REMATCH[2]}"; fi
      center="$(python3 "$A11Y_CLIENT" center "$query" "$nth" 2>&1)" \
        || { APP_REPLY="${center:-no element matches /${query}/}"; return 1; }
      local cx="${center%% *}" rest="${center#* }"
      local cy="${rest%% *}" label="${rest#* }"
      b=1; [[ "$name" == rightclick-element ]] && b=3
      if [[ "$name" == doubleclick-element ]]; then
        xdotool mousemove "$cx" "$cy" click --repeat 2 --delay 120 1
      else
        xdotool mousemove "$cx" "$cy" click "$b"
      fi || { APP_REPLY="xdotool click failed"; return 1; }
      APP_REPLY="${name%-element} ${label} at ${cx},${cy}" ;;
    quit)
      APP_REPLY="quit" ;;
    *)
      APP_REPLY="unknown action: ${name}"; return 1 ;;
  esac
  return 0
}
_app_exited() { [[ -f "${APP_OUT}/app.rc" ]]; }

_json_str() {  # JSON-encode a string
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

_app_control_loop() {
  local dir="$1" idle="$2" fifo line id action rc tmp
  fifo="${dir}/cmd.fifo"
  # The driver (e.g. the MCP server) runs as the unprivileged HOST user while
  # this runs as root in the builder container: make the FIFO writable and
  # the directory writable+sticky so it can write commands and delete replies.
  chmod 1777 "$dir"
  rm -f "$fifo"; mkfifo -m 0666 "$fifo"
  exec 3<>"$fifo"   # read-write: never sees EOF between writers
  printf '{"display":%s,"size":%s,"out_dir":%s,"slot":%s,"pid":%s}\n' \
    "$(_json_str "$APP_DISPLAY")" "$(_json_str "$APP_SIZE")" "$(_json_str "$APP_OUT")" \
    "$(_json_str "$APP_SLOT")" "$$" > "${dir}/session.json.tmp"
  mv -f "${dir}/session.json.tmp" "${dir}/session.json"
  log "Control session ready: ${dir} (cmd.fifo; idle timeout ${idle}s)"
  while :; do
    if ! read -r -t "$idle" line <&3; then
      log "No command for ${idle}s — ending control session"; break
    fi
    id="${line%% *}"; action="${line#* }"
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    rc=0; _app_do "$action" || rc=$?
    tmp="${dir}/.reply.${id}.tmp"
    printf '{"ok":%s,"text":%s,"file":%s}\n' "$([[ $rc -eq 0 ]] && echo true || echo false)" \
      "$(_json_str "$APP_REPLY")" "$(_json_str "$APP_FILE")" > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "${dir}/reply.${id}.json"
    [[ "${action%%=*}" == quit ]] && break
  done
  exec 3<&-
  rm -f "$fifo" "${dir}/session.json"
}

cmd_app() {
  local usage_app="Usage: $(basename "$0") app <blue|green> --run=\"cmd\" [--local-src=<dir>] [--local-pkg=<name|file>] [--display=virtual|host] [--size=WxH] [--out-dir=<dir>] [--timeout=SECS] [ACTIONS...|--script=<file>|--interactive|--control=<dir>]  (see lib/app.sh)"
  local slot="${1:-}"; shift || true
  _require_slot "$slot" "$usage_app"

  local run="" local_src="" display_mode=virtual size="1280x800" out_dir="" script=""
  local interactive=0 control="" idle=1800 timeout=60 arg
  local -a actions=()
  for arg in "$@"; do
    case "$arg" in
      --run=*)          run="${arg#--run=}" ;;
      --local-src=*)    local_src="${arg#--local-src=}" ;;
      # an unpublished app: overlay its built package first (as enter/desktop)
      --local-pkg=*)    export SHANIOS_TEST_LOCAL_PKGS="${SHANIOS_TEST_LOCAL_PKGS:+${SHANIOS_TEST_LOCAL_PKGS},}${arg#--local-pkg=}" ;;
      --display=*)      display_mode="${arg#--display=}" ;;
      --size=*)         size="${arg#--size=}" ;;
      --out-dir=*)      out_dir="${arg#--out-dir=}" ;;
      --timeout=*)      timeout="${arg#--timeout=}" ;;
      --script=*)       script="${arg#--script=}" ;;
      --interactive)    interactive=1 ;;
      --control=*)      control="${arg#--control=}" ;;
      --idle-timeout=*) idle="${arg#--idle-timeout=}" ;;
      --*)              actions+=("${arg#--}") ;;
      *)                die "$usage_app" ;;
    esac
  done
  [[ -n "$run" ]] || die "$usage_app"
  [[ "$display_mode" =~ ^(virtual|host)$ ]] || die "--display must be virtual or host"
  [[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || die "--size must be WxH"

  APP_SLOT="$slot" APP_SIZE="$size"
  APP_OUT="${out_dir:-${DATA_DIR}/app-${slot}-$(date +%s)}"
  mkdir -p "$APP_OUT"
  rm -f "${APP_OUT}/app.rc"

  _app_ensure_tools
  trap _app_cleanup EXIT
  # The display must exist BEFORE the nspawn binds are built: _nspawn_binds
  # only adds X11_BIND when /tmp/.X11-unix exists.
  _app_start_display "$display_mode" "$size"
  export DISPLAY="$APP_DISPLAY"

  # The app's session bus + XDG_RUNTIME_DIR live in APP_RT, bind-mounted
  # into the slot at the SAME path, so the builder-side accessibility client
  # (lib/a11y_client.py) and the app agree on every socket path: the session
  # bus hands out the AT-SPI bus address, and that address has to resolve on
  # both sides.
  APP_RT="/run/shani-app-${APP_DISPLAY#:}"
  rm -rf "$APP_RT"; mkdir -p -m 700 "$APP_RT"
  EXTRA_BINDS="${EXTRA_BINDS:+${EXTRA_BINDS},}${APP_RT}:${APP_RT}"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${APP_RT}/bus"
  local inner
  printf -v inner 'dbus-daemon --session --address=%q --fork --nopidfile >/dev/null && exec /bin/bash -c %q' \
    "$DBUS_SESSION_BUS_ADDRESS" "$run"
  _ensure_host_machine_id
  _ensure_dbus
  _prepare_enter_args "$slot" "$local_src" /usr/bin/env \
    DISPLAY="$APP_DISPLAY" GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb \
    GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 \
    QT_ACCESSIBILITY=1 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 \
    XDG_RUNTIME_DIR="$APP_RT" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    /bin/bash -c "$inner"

  log "Starting in @${slot} on ${APP_DISPLAY} (${size}): ${run}"
  log "Output: ${APP_OUT}"
  ( systemd-nspawn "${NSPAWN_ENTER_ARGS[@]}" >"${APP_OUT}/app.stdout" 2>"${APP_OUT}/app.stderr"
    echo $? > "${APP_OUT}/app.rc" ) &
  APP_PID=$!

  local failed=0 a rc
  if [[ -n "$control" ]]; then
    mkdir -p "$control"
    _app_control_loop "$control" "$idle"
  else
    if [[ -n "$script" ]]; then
      [[ -f "$script" ]] || die "--script=${script}: no such file"
      while IFS= read -r a || [[ -n "$a" ]]; do
        a="${a#"${a%%[![:space:]]*}"}"
        [[ -z "$a" || "$a" == \#* ]] && continue
        actions+=("${a#--}")
      done < "$script"
    fi
    if (( interactive )); then
      log "Interactive: one action per line on stdin (e.g. screenshot, click=100,200, quit)"
      while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        rc=0; _app_do "${a#--}" || rc=$?
        if (( rc == 0 )); then echo "ok: ${APP_REPLY}"; else echo "FAIL: ${APP_REPLY}"; failed=1; fi
        [[ "${a%%=*}" == quit ]] && break
      done
    fi
    for a in "${actions[@]}"; do
      rc=0; _app_do "$a" || rc=$?
      if (( rc == 0 )); then log "  ok    ${a} — ${APP_REPLY}"
      else warn "  FAIL  ${a} — ${APP_REPLY}"; failed=1; fi
    done
    # Give an app that's closing (e.g. after a final key=Return) a moment to
    # finish writing its output before we report it.
    _app_wait "$timeout" _app_exited >/dev/null 2>&1 || true
  fi

  _app_cleanup
  APP_PID=""
  trap - EXIT
  [[ -f "${APP_OUT}/app.rc" ]] || echo "killed" > "${APP_OUT}/app.rc"
  log "App exit: $(cat "${APP_OUT}/app.rc")   stdout: ${APP_OUT}/app.stdout"
  if [[ -s "${APP_OUT}/app.stdout" ]]; then sed 's/^/  | /' "${APP_OUT}/app.stdout" | head -20; fi
  return "$failed"
}
