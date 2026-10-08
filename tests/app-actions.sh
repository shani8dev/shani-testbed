#!/bin/bash
# Unit-level test of lib/app.sh's action executor (_app_do) and
# lib/a11y_client.py against a REAL Xvfb + a REAL GTK4/libadwaita app
# (tests/fixtures/adw_fixture.py - the widgets Shani Cassini is built from),
# without the slot/nspawn layer. Run inside archlinux:latest with the new lib/ at /lib-under-test.
set -u
LIB_DIR=/lib-under-test
log()  { echo "[log] $*"; }
warn() { echo "[warn] $*" >&2; }
die()  { echo "[die] $*" >&2; exit 2; }
source "$LIB_DIR/app.sh"
res() { printf 'RESULT %-34s %s\n' "$1" "$2"; }

# -Syu, not -Sy: archlinux:latest already has glib2, and --needed kept that
# older copy while installing the newest gtk4 - libgtk-4.so.1 then failed to
# load (undefined symbol g_timeout_source_new_ns) and 17 of 30 checks went red.
pacman -Syu --noconfirm --needed "${APP_TOOLS_PKGS[@]}" gtk4 libadwaita ttf-dejavu tesseract tesseract-data-eng >/dev/null 2>&1 || { echo "pkg install failed"; exit 1; }
APP_OUT=$(mktemp -d); APP_SIZE=1024x768
_app_start_display virtual "$APP_SIZE"; export DISPLAY="$APP_DISPLAY"
echo "display: $APP_DISPLAY"
APP_RT=/run/shani-app-test; mkdir -p -m 700 "$APP_RT"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${APP_RT}/bus" XDG_RUNTIME_DIR="$APP_RT"
dbus-daemon --session --address="$DBUS_SESSION_BUS_ADDRESS" --fork --nopidfile >/dev/null
( GDK_BACKEND=x11 GSK_RENDERER=cairo python3 /fixtures/adw_fixture.py entry "Harness Entry Test" --text="Type a name:" >"$APP_OUT/app.stdout" 2>"$APP_OUT/app.stderr"; echo $? > "$APP_OUT/app.rc" ) &
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
( GDK_BACKEND=x11 GSK_RENDERER=cairo python3 /fixtures/adw_fixture.py entry Second >"$APP_OUT/app.stdout" 2>/dev/null; echo $? > "$APP_OUT/app.rc" ) &
APP_PID=$!
step "wait-window=Second:20" >/dev/null
c=$(python3 "$A11Y_CLIENT" center 'button:^Cancel$'); echo "   cancel center: $c"
step "click=${c%% *},$(echo $c | cut -d' ' -f2)" && step "wait-exit=10" >/dev/null
[[ "$(cat "$APP_OUT/app.rc")" == 1 ]] && res coordinate-click-cancel-rc1 PASS || res coordinate-click-cancel-rc1 "FAIL (rc=$(cat "$APP_OUT/app.rc"))"
rm -f "$APP_OUT/app.rc"
( GDK_BACKEND=x11 GSK_RENDERER=cairo python3 /fixtures/adw_fixture.py entry Third >"$APP_OUT/app.stdout" 2>/dev/null; echo $? > "$APP_OUT/app.rc" ) &
APP_PID=$!
step "wait-window=Third:20" >/dev/null; step "type=via-key" >/dev/null; step "key=Return"
step "wait-exit=10" >/dev/null
[[ "$(cat "$APP_OUT/app.stdout")" == "via-key" ]] && res key-Return-submits PASS || res key-Return-submits "FAIL ($(cat "$APP_OUT/app.stdout"))"

# Fourth: pixel assertions, masks, OCR, a11y lint, monkey, log check — each
# with the negative control that proves it can fail.
rm -f "$APP_OUT/app.rc"
( GDK_BACKEND=x11 GSK_RENDERER=cairo python3 /fixtures/adw_fixture.py entry Fourth --text="Harness OCR Probe" --unnamed-button \
    >"$APP_OUT/app.stdout" 2>"$APP_OUT/app.stderr"; echo $? > "$APP_OUT/app.rc" ) &
APP_PID=$!
step "wait-window=Fourth:20" >/dev/null; sleep 1
step "screenshot=$APP_OUT/base.png" >/dev/null
step "expect-same=$APP_OUT/base.png" && res expect-same-unchanged PASS || res expect-same-unchanged FAIL
step "type=pixels changed here" >/dev/null; sleep 0.5
step "expect-changed=$APP_OUT/base.png:0.01" && res expect-changed-after-typing PASS || res expect-changed-after-typing FAIL
step "expect-same=$APP_OUT/base.png:0.01"; [[ $? -ne 0 ]] && res expect-same-negative PASS || res expect-same-negative FAIL
step "mask=0,0,${APP_SIZE}" >/dev/null
step "expect-changed=$APP_OUT/base.png:0.01"; [[ $? -ne 0 ]] && res mask-hides-change PASS || res mask-hides-change FAIL
step "mask=" >/dev/null
step "expect-changed=$APP_OUT/base.png:0.01" && res mask-cleared PASS || res mask-cleared FAIL
step "expect-text=OCR Probe" && res expect-text PASS || res expect-text FAIL
step "expect-text=zzqx not on screen"; [[ $? -ne 0 ]] && res expect-text-negative PASS || res expect-text-negative FAIL
step "a11y-lint"; lrc=$?; echo "$APP_REPLY" | sed 's/^/      /' | head -6
[[ $lrc -ne 0 ]] && grep -qE "^\[[0-9]+\] button ''" <<<"$APP_REPLY" && res a11y-lint-catches-icon-only-button PASS || res a11y-lint-catches-icon-only-button FAIL
[[ $lrc -ne 0 ]] && grep -qE "^\[[0-9]+\] entry ''" <<<"$APP_REPLY" && res a11y-lint-catches-placeholder-only-search PASS || res a11y-lint-catches-placeholder-only-search FAIL
# glycin (GTK's image loader) warns when it cannot sandbox itself, which is
# every container: the one accepted warning, named
IGN='Glycin running without sandbox'
step "expect-clean-log" >/dev/null; raw_rc=$?
step "expect-clean-log=$IGN" >/dev/null; clean_rc=$?
echo "(adw_fixture.py:1): Gtk-CRITICAL **: 12:00:00.000: planted critical" >> "$APP_OUT/app.stderr"
step "expect-clean-log=$IGN"; [[ $? -ne 0 ]] && res expect-clean-log-negative PASS || res expect-clean-log-negative FAIL
if grep -q "$IGN" "$APP_OUT/app.stderr"; then
  [[ $raw_rc -ne 0 ]] && res expect-clean-log-sees-glycin PASS || res expect-clean-log-sees-glycin FAIL
fi
[[ $clean_rc -eq 0 ]] && res expect-clean-log-before-plant PASS || res expect-clean-log-before-plant "FAIL (the fixture itself warns: $(head -2 "$APP_OUT/app.stderr" | tr '\n' ' '))"
# monkey on a window whose buttons close it: the app must be reported gone
# OK and Cancel both end this app (the header bar's Close is skipped by
# design): enough clicks that the seeded run reaches one of them
step "monkey=25:42"; [[ $? -ne 0 ]] && grep -q 'seed 42' <<<"$APP_REPLY" && res monkey-detects-exit PASS || res monkey-detects-exit FAIL
step "wait-exit=5" >/dev/null
kill "$APP_PID" 2>/dev/null; pkill -f '[a]dw_fixture.py' 2>/dev/null; sleep 1   # nothing left over for the next lint

# Fifth: monkey on controls that do not close the app (check boxes, no buttons)
rm -f "$APP_OUT/app.rc"
( GDK_BACKEND=x11 GSK_RENDERER=cairo python3 /fixtures/adw_fixture.py form Fifth \
    >"$APP_OUT/app.stdout" 2>/dev/null; echo $? > "$APP_OUT/app.rc" ) &
APP_PID=$!
step "wait-window=Fifth:20" >/dev/null; sleep 1
step "monkey=12:7" && grep -q 'still running' <<<"$APP_REPLY" && res monkey-survives PASS || res monkey-survives FAIL
# the combo row's selected value is an unnamed list item around a named label:
# named by its content, not an unnamed control
step "a11y-lint" && res a11y-lint-named-checkboxes-and-combo PASS || res a11y-lint-named-checkboxes-and-combo "FAIL ($(head -3 <<<"$APP_REPLY" | tr '\n' ' '))"
kill "$APP_PID" 2>/dev/null; pkill -f '[a]dw_fixture.py' 2>/dev/null

# Sixth: an element far below the window must be scrolled into view, then clicked
rm -f "$APP_OUT/app.rc"
( GDK_BACKEND=x11 GSK_RENDERER=cairo python3 /fixtures/adw_fixture.py long Sixth >"$APP_OUT/app.stdout" 2>/dev/null; echo $? > "$APP_OUT/app.rc" ) &
APP_PID=$!
step "wait-window=Sixth:20" >/dev/null; sleep 1
step "click-element=button:^Item 40$" >/dev/null; step "wait-exit=10" >/dev/null
[[ "$(cat "$APP_OUT/app.stdout" 2>/dev/null)" == "clicked 40" ]] && res click-element-scrolls-into-view PASS || res click-element-scrolls-into-view "FAIL ($(cat "$APP_OUT/app.stdout" 2>/dev/null))"
APP_PID=""; _app_cleanup
echo done
