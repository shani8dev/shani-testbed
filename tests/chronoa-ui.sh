#!/bin/bash
# shani-chronoa's ui_elements skill (AT-SPI) against a REAL Xvfb + GTK4 window,
# on a private session bus and a private accessibility bus. Runs inside
# archlinux:latest with the chronoa package at /chronoa (read-only).
set -u
res() { printf 'RESULT %-36s %s\n' "$1" "$2"; }
pacman -Sy --noconfirm --needed xorg-server-xvfb python-gobject at-spi2-core gtk4 gtk3 ttf-dejavu dbus python-httpx >/dev/null 2>&1 \
    || { echo "pkg install failed"; exit 1; }
export XDG_RUNTIME_DIR=/run/ui-test HOME=/tmp/home; mkdir -p -m 700 "$XDG_RUNTIME_DIR" "$HOME"
Xvfb :9 -screen 0 1024x768x24 >/dev/null 2>&1 & sleep 1; export DISPLAY=:9
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
dbus-daemon --session --address="$DBUS_SESSION_BUS_ADDRESS" --fork --nopidfile >/dev/null
/usr/lib/at-spi-bus-launcher --launch-immediately >/dev/null 2>&1 &
sleep 1
GDK_BACKEND=x11 GSK_RENDERER=cairo python3 /fixtures/ui_probe.py > /tmp/app.out 2>/tmp/app.err &
sleep 3
export PYTHONPATH=/chronoa PYTHONDONTWRITEBYTECODE=1 GSETTINGS_BACKEND=memory
run() { python3 -c "import json,sys; from shani_chronoa.skills import ui_elements as u; u._consent=lambda c:(True,''); print(u._run(json.loads(sys.argv[1])))" "$1"; }
echo "--- apps";    a=$(run '{"action":"apps"}'); echo "$a"
grep -q "ui_probe\|python3\|UiProbe" <<<"$a" && res ui-apps PASS || res ui-apps "FAIL ($a)"
app=$(grep -oE "ui_probe[^,]*|UiProbe[^,]*|python3" <<<"$a" | head -1)
echo "--- inspect"; t=$(run "{\"action\":\"inspect\",\"app\":\"$app\"}"); echo "$t" | head -30
id_of() { grep -m1 -E "$1" <<<"$t" | grep -oE '\[[0-9/]+\]' | tr -d '[]'; }
save=$(id_of "button 'Save'"); field=$(id_of "'Name'.*editable|text 'Name'|entry 'Name'"); chk=$(id_of "check box 'Remember me'")
[[ -n "$save" && -n "$field" && -n "$chk" ]] && res ui-inspect-finds-controls PASS || res ui-inspect-finds-controls "FAIL (save=$save field=$field check=$chk)"
o=$(run "{\"action\":\"set_text\",\"app\":\"$app\",\"id\":\"$field\",\"text\":\"Shani Tester\"}"); echo "$o"
grep -q "read back" <<<"$o" && res ui-set-text-reads-back PASS || res ui-set-text-reads-back "FAIL ($o)"
o=$(run "{\"action\":\"press\",\"app\":\"$app\",\"id\":\"$save\"}"); echo "$o"; sleep 0.5
grep -q "^SAVED Shani Tester$" /tmp/app.out && res ui-press-runs-the-button PASS || res ui-press-runs-the-button "FAIL ($(cat /tmp/app.out))"
o=$(run "{\"action\":\"press\",\"app\":\"$app\",\"id\":\"$chk\"}"); echo "$o"; sleep 0.5
grep -q "^CHECKED True$" /tmp/app.out && grep -q "checked" <<<"$o" && res ui-press-toggles-checkbox PASS || res ui-press-toggles-checkbox "FAIL ($o)"
o=$(run "{\"action\":\"read\",\"app\":\"$app\",\"id\":\"$field\"}"); echo "$o"
grep -q "Shani Tester" <<<"$o" && res ui-read PASS || res ui-read "FAIL ($o)"
o=$(run "{\"action\":\"press\",\"app\":\"$app\",\"id\":\"$save\",\"query\":\"Delete\"}")
grep -q "inspect again" <<<"$o" && res ui-stale-id-refused PASS || res ui-stale-id-refused "FAIL ($o)"
o=$(run "{\"action\":\"set_text\",\"app\":\"$app\",\"id\":\"$save\",\"text\":\"x\"}")
grep -q "not an editable field" <<<"$o" && res ui-set-text-on-button-refused PASS || res ui-set-text-on-button-refused "FAIL ($o)"
o=$(run "{\"action\":\"menu\",\"app\":\"$app\",\"path\":\"File > Export\"}"); echo "$o"
# GTK4 popover menus publish unnamed items: the skill must say so, not pick one blindly
grep -q "no accessible names" <<<"$o" && ! grep -q "^EXPORTED$" /tmp/app.out && res ui-gtk4-menu-honest PASS || res ui-gtk4-menu-honest "FAIL ($o)"
# GTK3 menus are named and have actions: the path works for real
GDK_BACKEND=x11 python3 /fixtures/ui_probe3.py > /tmp/app3.out 2>/tmp/app3.err &
sleep 3
a3=$(run '{"action":"apps"}'); app3=$(grep -oE "ui_probe3[^,]*" <<<"$a3" | head -1); app3=${app3:-ui_probe3.py}
o=$(run "{\"action\":\"menu\",\"app\":\"$app3\",\"path\":\"File > Export\"}"); echo "$a3 / $o"; sleep 0.5
grep -q "^EXPORTED$" /tmp/app3.out && res ui-menu-path-gtk3 PASS || res ui-menu-path-gtk3 "FAIL ($o)"
o=$(run "{\"action\":\"menu\",\"app\":\"$app3\",\"path\":\"File > Nope\"}")
grep -q "No menu entry 'Nope'" <<<"$o" && res ui-menu-missing-negative PASS || res ui-menu-missing-negative "FAIL ($o)"
o=$(python3 -c "import json; from shani_chronoa.skills import ui_elements as u; print(u._run({'action':'apps'}))")
grep -q "Refusing" <<<"$o" && res ui-gate-default-off PASS || res ui-gate-default-off "FAIL ($o)"
