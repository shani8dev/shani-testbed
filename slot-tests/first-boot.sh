#!/bin/bash
# slot-test-mode: boot
#
# first-boot — what a new install shows when it is switched on. The ISO
# installer creates no account (`skip_user: yes`), so the first screen is not
# a login screen but the desktop's own first setup, which creates the account:
#
#   niri    greetd -> the greeter niri (/etc/greetd/shani-niri.toml) -> its
#           spawn-at-startup finds no account and runs `qs -c shani-setup`,
#           which creates it through pkexec first-account.py (polkit grants
#           exactly that to the greeter user)
#   GNOME   GDM runs gnome-initial-setup when no account exists, unless
#           /etc/gdm/custom.conf says InitialSetupEnable=false
#   Plasma  plasma-setup.service, before plasmalogin
#
# Each check is on the image as installed: the display manager that
# display-manager.service really resolves to, that desktop's first setup
# present and reachable, and for niri the greeter's own "no account yet" test
# run against a passwd with and without an account (NEGATIVE control: an
# account must turn the setup off, or a set-up machine would show it again).
#
# Order matters in `gate`: run it before fresh-user, which adds an account.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
has() { [ -e "$1" ]; }

# the desktop this image is: what its display manager is
dm=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)
dm=${dm##*/}
if [ -z "$dm" ]; then
    if systemctl get-default 2>/dev/null | grep -q graphical; then
        res first-boot-display-manager "FAIL (graphical.target is the default but no display-manager.service is enabled - a new install boots to a black screen)"
    else
        res first-boot-display-manager "SKIP (no display manager: a headless profile, nothing to set up graphically)"
    fi
    exit 0
fi
res first-boot-display-manager "PASS ($dm is the display manager)"

# accounts as the niri greeter counts them (UID 1000-59999, a login shell)
accounts() { awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { n++ } END { print n + 0 }' "${1:-/etc/passwd}"; }
n=$(getent passwd | accounts /dev/stdin)
if [ "$n" -eq 0 ]; then
    res first-boot-no-account "PASS (no account yet: the first setup is what this machine shows)"
else
    res first-boot-no-account "SKIP ($n account(s) already exist - not a fresh install, so the first setup will not show; checking the path anyway)"
fi

case "$dm" in
greetd.service)
    # which config greetd really starts with: the niri drop-in's --config, or its default
    cfg=$(systemctl cat greetd.service 2>/dev/null | sed -n 's/^ExecStart=.*--config[= ]\([^ ]*\).*/\1/p' | tail -1)
    cfg=${cfg:-/etc/greetd/config.toml}
    if ! has "$cfg"; then
        res first-boot-greetd-config "FAIL (greetd starts with $cfg, which does not exist)"; exit 0
    fi
    if python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$cfg" 2>/dev/null; then
        res first-boot-greetd-config "PASS ($cfg parses)"
    else
        res first-boot-greetd-config "FAIL ($cfg is not valid TOML - greetd will not start)"; exit 0
    fi
    guser=$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["default_session"].get("user","greeter"))' "$cfg" 2>/dev/null)
    if getent passwd "${guser:-greeter}" >/dev/null; then
        res first-boot-greeter-user "PASS (the greeter runs as ${guser:-greeter}, which exists)"
    else
        res first-boot-greeter-user "FAIL (the greeter user ${guser:-greeter} does not exist)"
    fi
    # greetd starts the greeter with no sign-in but still calls pam_setcred,
    # which replays the auth stack: anything but success and greetd exits, and
    # a new machine shows no setup screen (2026-11-15: shani-greetd's
    # fingerprint jump made it IGNORE). The same three calls greetd makes.
    psvc=$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb")).get("general",{}).get("service","greetd"))' "$cfg" 2>/dev/null)
    pam_out=$(python3 - "${psvc:-greetd}" "${guser:-greeter}" <<'PY' 2>&1
import ctypes, sys
pam = ctypes.CDLL("libpam.so.0"); pam.pam_strerror.restype = ctypes.c_char_p
CONV = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)
class C(ctypes.Structure): _fields_ = [("conv", CONV), ("a", ctypes.c_void_p)]
c = C(CONV(lambda *a: 19), None); h = ctypes.c_void_p()
if pam.pam_start(sys.argv[1].encode(), sys.argv[2].encode(), ctypes.byref(c), ctypes.byref(h)):
    print("pam_start failed"); sys.exit(1)
for name, call in (("acct_mgmt", lambda: pam.pam_acct_mgmt(h, 0)), ("setcred", lambda: pam.pam_setcred(h, 2))):
    rc = call()
    if rc:
        print(f"pam_{name} -> {rc} {pam.pam_strerror(h, rc).decode()}"); sys.exit(1)
print("acct_mgmt and setcred succeed")
PY
)
    if [ $? -eq 0 ]; then
        res first-boot-greeter-pam "PASS (${psvc:-greetd}: $pam_out)"
    else
        res first-boot-greeter-pam "FAIL (${psvc:-greetd} for the greeter: $pam_out - greetd cannot start it)"
    fi
    kdl=$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["default_session"]["command"])' "$cfg" 2>/dev/null | sed -n 's/.*-c \([^ ]*\).*/\1/p')
    if [ -z "$kdl" ] || ! grep -q 'shani-setup' "$kdl" 2>/dev/null; then
        res first-boot-setup-wired "SKIP (the greeter is not the shani-shell one: ${kdl:-no niri -c config})"; exit 0
    fi
    res first-boot-setup-wired "PASS ($kdl starts qs -c shani-setup when there is no account)"
    for c in shani-setup shani-greeter; do
        if has "/etc/xdg/quickshell/$c/shell.qml"; then res "first-boot-qs-$c" "PASS (/etc/xdg/quickshell/$c)"
        else res "first-boot-qs-$c" "FAIL (qs -c $c has no /etc/xdg/quickshell/$c/shell.qml)"; fi
    done
    # the greeter's own test, lifted from its config, against two passwd files
    test_cmd=$(grep -o "if getent passwd | awk -F: '[^']*'" "$kdl" | head -1 | sed "s/^if getent passwd | //")
    if [ -z "$test_cmd" ]; then
        res first-boot-account-test "FAIL (could not find the greeter's account test in $kdl)"
    else
        t=$(mktemp -d)
        printf 'root:x:0:0::/root:/bin/bash\ngreeter:x:964:964::/var/lib/greeter:/usr/bin/nologin\n' > "$t/none"
        { cat "$t/none"; printf 'ana:x:1000:1000::/home/ana:/bin/zsh\n'; } > "$t/one"
        # the greeter's awk exits 0 when it finds NO account (it then runs the setup)
        if sh -c "$test_cmd" < "$t/none" && ! sh -c "$test_cmd" < "$t/one"; then
            res first-boot-account-test "PASS (no account -> setup; one account -> login screen)"
        else
            res first-boot-account-test "FAIL (the greeter's test does not tell a new machine from a set-up one)"
        fi
        rm -rf "$t"
    fi
    fa=/usr/lib/shani-shell/first-account.py
    if [ -x "$fa" ] || [ -f "$fa" ]; then res first-boot-account-creator "PASS ($fa)"
    else res first-boot-account-creator "FAIL ($fa missing: the setup cannot create the account)"; fi
    if grep -rqs "$fa" /usr/share/polkit-1/rules.d/ /etc/polkit-1/rules.d/; then
        res first-boot-polkit "PASS (the greeter may run first-account.py)"
    else
        res first-boot-polkit "FAIL (no polkit rule lets the greeter run first-account.py)"
    fi
    ;;
gdm.service)
    gis=""
    for p in /usr/lib/gnome-initial-setup /usr/libexec/gnome-initial-setup; do has "$p" && gis=$p; done
    if [ -n "$gis" ]; then res first-boot-setup-present "PASS ($gis)"
    else res first-boot-setup-present "FAIL (gnome-initial-setup is not installed: GDM shows a login screen with no account to log in to)"; fi
    if grep -Eiqs '^[[:space:]]*InitialSetupEnable[[:space:]]*=[[:space:]]*false' /etc/gdm/custom.conf; then
        res first-boot-setup-enabled "FAIL (/etc/gdm/custom.conf disables InitialSetupEnable)"
    else
        res first-boot-setup-enabled "PASS (GDM's initial setup is not disabled)"
    fi
    if grep -Eqs '^[[:space:]]*AutomaticLoginEnable[[:space:]]*=[[:space:]]*[Tt]rue' /etc/gdm/custom.conf \
       && ! getent passwd "$(sed -n 's/^[[:space:]]*AutomaticLogin[[:space:]]*=[[:space:]]*//p' /etc/gdm/custom.conf)" >/dev/null; then
        res first-boot-no-stale-autologin "FAIL (GDM autologs into an account that does not exist - the live ISO's setting leaked)"
    else
        res first-boot-no-stale-autologin "PASS"
    fi
    if getent passwd gnome-initial-setup >/dev/null; then
        res first-boot-setup-user "PASS (gnome-initial-setup's system user exists)"
    else
        res first-boot-setup-user "FAIL (no gnome-initial-setup user: GDM cannot start the setup session)"
    fi
    ;;
plasmalogin.service|sddm.service)
    if systemctl is-enabled plasma-setup.service >/dev/null 2>&1; then
        res first-boot-setup-enabled "PASS (plasma-setup.service is enabled)"
        exe=$(systemctl show -P ExecStart plasma-setup.service | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1)
        if [ -n "$exe" ] && [ -x "$exe" ]; then res first-boot-setup-present "PASS ($exe)"
        else res first-boot-setup-present "FAIL (plasma-setup.service runs ${exe:-nothing}, which is not installed)"; fi
        # plasma-setup runs only while /etc/plasma-setup-done is absent (its unit's
        # ConditionPathExists); one baked into the image or left by a reinstall
        # skips the setup on a machine that has no account
        if [ "$n" -eq 0 ] && [ -e /etc/plasma-setup-done ]; then
            res first-boot-setup-flag "FAIL (/etc/plasma-setup-done exists with no account: plasma-setup will not run)"
        else
            res first-boot-setup-flag "PASS (no plasma-setup-done flag on a machine without an account)"
        fi
        # its own conditions must not already be met on a machine that has never run it
        if [ "$n" -eq 0 ] && [ "$(systemctl show -P ConditionResult plasma-setup.service)" = no ]; then
            res first-boot-setup-condition "FAIL (plasma-setup.service's condition is false on a machine with no account - it was skipped)"
        else
            res first-boot-setup-condition "PASS"
        fi
    else
        res first-boot-setup-enabled "FAIL (plasma-setup.service is not enabled: a new install shows a login screen with no account)"
    fi
    ;;
*)
    res first-boot-setup-present "SKIP ($dm: no first-setup check written for this display manager yet)"
    ;;
esac
exit 0
