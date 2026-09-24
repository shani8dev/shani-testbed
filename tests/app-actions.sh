#!/bin/bash
# Unit-level test of lib/app.sh's action executor (_app_do) and
# lib/a11y_client.py against a REAL Xvfb + a REAL GTK app (yad), without the
# slot/nspawn layer. Run inside archlinux:latest with the new lib/ at /lib-under-test.
set -u
LIB_DIR=/lib-under-test
log()  { echo "[log] $*"; }
warn() { echo "[warn] $*" >&2; }
die()  { echo "[die] $*" >&2; exit 2; }
source "$LIB_DIR/app.sh"
res() { printf 'RESULT %-34s %s\n' "$1" "$2"; }

pacman -Sy --noconfirm --needed "${APP_TOOLS_PKGS[@]}" yad ttf-dejavu >/dev/null 2>&1 || { echo "pkg install failed"; exit 1; }
APP_OUT=$(mktemp -d); APP_SIZE=1024x768
_app_start_display virtual "$APP_SIZE"; export DISPLAY="$APP_DISPLAY"
echo "display: $APP_DISPLAY"
APP_RT=/run/shani-app-test; mkdir -p -m 700 "$APP_RT"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${APP_RT}/bus" XDG_RUNTIME_DIR="$APP_RT"
dbus-daemon --session --address="$DBUS_SESSION_BUS_ADDRESS" --fork --nopidfile >/dev/null
( GDK_BACKEND=x11 yad --entry --title="Harness Entry Test" --text="Type a name:" \
    --button=Cancel:1 --button=OK:0 >"$APP_OUT/app.stdout" 2>"$APP_OUT/app.stderr"; echo $? > "$APP_OUT/app.rc" ) &
APP_PID=$!

step() { local rc=0; _app_do "$1" || rc=$?; printf '   %-44s rc=%d  %s\n' "$1" "$rc" "$(echo "$APP_REPLY" | head -1 | cut -c1-90)"; return $rc; }

step "wait-window=Harness Entry Test:20" && res wait-window PASS || res wait-window FAIL
step "windows"; echo "$APP_REPLY" | sed 's/^/      /' | head -5
step "screenshot" && [[ -s "$APP_FILE" ]] && file "$APP_FILE" | grep -q PNG && res screenshot-png PASS || res screenshot-png FAIL
step "tree=12" && res a11y-tree PASS || res a11y-tree FAIL
echo "$APP_REPLY" | grep -E "push button|text|entry|dialog|frame" | head -8 | sed 's/^/      /'
step "find=button:^OK$" && res a11y-find-OK PASS || res a11y-find-OK FAIL
step "find=^nonexistent-zzz$"; [[ $? -ne 0 ]] && res a11y-find-negative PASS || res a11y-find-negative FAIL
step "type=Shani Tester" && res type PASS || res type FAIL
step "tree=12" >/dev/null; echo "$APP_REPLY" | grep -q "Shani Tester" && res a11y-sees-typed-text PASS || res a11y-sees-typed-text FAIL
step "click-element=button:^OK$" && res click-element PASS || res click-element FAIL
step "wait-exit=10" && res app-exited PASS || res app-exited FAIL
out=$(cat "$APP_OUT/app.stdout" 2>/dev/null); echo "   app stdout: [$out]  rc=$(cat "$APP_OUT/app.rc" 2>/dev/null)"
[[ "$out" == "Shani Tester" ]] && res app-stdout-equals-typed PASS || res app-stdout-equals-typed FAIL
step "expect-gone=Harness Entry Test:5" && res expect-gone PASS || res expect-gone FAIL
step "click=@nowindow:1,1"; [[ $? -ne 0 ]] && res click-missing-window-negative PASS || res click-missing-window-negative FAIL
step "bogus-action"; [[ $? -ne 0 ]] && res unknown-action-negative PASS || res unknown-action-negative FAIL

# Second app: coordinate click (not element) + key action, Cancel path.
rm -f "$APP_OUT/app.rc"
( GDK_BACKEND=x11 yad --entry --title="Second" --button=Cancel:1 --button=OK:0 >"$APP_OUT/app.stdout" 2>/dev/null; echo $? > "$APP_OUT/app.rc" ) &
APP_PID=$!
step "wait-window=Second:20" >/dev/null
c=$(python3 "$A11Y_CLIENT" center 'button:^Cancel$'); echo "   cancel center: $c"
step "click=${c%% *},$(echo $c | cut -d' ' -f2)" && step "wait-exit=10" >/dev/null
[[ "$(cat "$APP_OUT/app.rc")" == 1 ]] && res coordinate-click-cancel-rc1 PASS || res coordinate-click-cancel-rc1 "FAIL (rc=$(cat "$APP_OUT/app.rc"))"
rm -f "$APP_OUT/app.rc"
( GDK_BACKEND=x11 yad --entry --title="Third" --button=OK:0 >"$APP_OUT/app.stdout" 2>/dev/null; echo $? > "$APP_OUT/app.rc" ) &
APP_PID=$!
step "wait-window=Third:20" >/dev/null; step "type=via-key" >/dev/null; step "key=Return"
step "wait-exit=10" >/dev/null
[[ "$(cat "$APP_OUT/app.stdout")" == "via-key" ]] && res key-Return-submits PASS || res key-Return-submits "FAIL ($(cat "$APP_OUT/app.stdout"))"
APP_PID=""; _app_cleanup
echo done
