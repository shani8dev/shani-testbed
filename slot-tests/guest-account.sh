#!/bin/bash
# slot-test-mode: boot
#
# guest-account — the guest account of a classroom board or a shared computer
# (shani-shell's Settings > Users > Guest, made by bridge/shani-admin.py;
# shani-desktop-niri's guest-reset, run by a user-runtime-dir@.service drop-in),
# in a really booted slot: real systemd, logind and PAM.
#
#   - turned on through the real shani-admin.py (as pkexec runs it): an account
#     with no password, not an administrator, the greeter lists it
#   - a real login session (runuser -l: PAM -> pam_systemd -> logind, so
#     systemd starts user-runtime-dir@UID): the home is new when it starts -
#     what the last session left is gone - and new again once it ends
#   - NEGATIVE control: anyone else's session leaves their home alone
#   - logind ends the guest's programs at sign-out (KillOnlyUsers=guest)
#   - turned off: the account and its home go
#
# Needs shani-shell and shani-desktop-niri with the guest account in the slot:
#   slot-test blue guest-account --local-pkg=shani-desktop-niri,shani-shell
set -u
res() { printf 'RESULT %-44s %s\n' "$1" "$2"; }
A=/usr/lib/shani-shell/shani-admin.py
R=/usr/lib/shani-desktop-niri/guest-reset
if [ ! -f "$A" ] || [ ! -x "$R" ] || ! grep -q '"guest"' "$A"; then
    res guest-account-installed "SKIP (no guest account in this slot's shani-shell / shani-desktop-niri: --local-pkg=shani-desktop-niri,shani-shell)"
    exit 0
fi
res guest-account-installed PASS

# the admin who turns it on (polkit made them prove it; pkexec passes their UID)
id tbadmin >/dev/null 2>&1 || useradd -m -G wheel tbadmin
echo 'tbadmin:tb-admin-pw' | chpasswd
admin() { PKEXEC_UID=$(id -u tbadmin) python3 "$A" guest; }

out=$(echo '{"on": true}' | admin 2>&1)
if getent passwd guest >/dev/null && [ "$(passwd -S guest | awk '{print $2}')" = NP ] && ! id -nG guest | grep -qw wheel \
    && [ "$(head -n1 /etc/shani/guest 2>/dev/null)" = guest ]; then
    res guest-on-no-password-no-admin PASS
else
    res guest-on-no-password-no-admin "FAIL ($out; $(passwd -S guest 2>&1))"
fi
# the greeter lists accounts with a UID 1000-59999 and a login shell
if getent passwd guest | awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { ok = 1 } END { exit !ok }'; then
    res guest-listed-by-the-greeter PASS
else
    res guest-listed-by-the-greeter "FAIL ($(getent passwd guest))"
fi

g=$(id -u guest)
gone() { local i=0; while systemctl is-active -q "user-runtime-dir@$1.service" && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done; ! systemctl is-active -q "user-runtime-dir@$1.service"; }

# what a last lesson left; then a real session
touch /home/guest/left-by-the-last-lesson
inside=$(runuser -l guest -c 'ls -A ~; touch ~/written-this-lesson' 2>&1)
if ! printf '%s\n' "$inside" | grep -qx 'left-by-the-last-lesson'; then
    res guest-home-new-when-a-session-starts PASS
else
    res guest-home-new-when-a-session-starts "FAIL (the session saw: $(printf '%s' "$inside" | tr '\n' ' '))"
fi
# the session over: systemd stops user-runtime-dir@ once the user's manager goes (UserStopDelaySec)
if gone "$g" && [ ! -e /home/guest/written-this-lesson ] && [ -d /home/guest ] && [ "$(stat -c %U /home/guest)" = guest ]; then
    res guest-home-new-when-the-session-ends PASS
else
    res guest-home-new-when-the-session-ends "FAIL (user-runtime-dir@$g $(systemctl is-active "user-runtime-dir@$g.service"); $(ls -A /home/guest | tr '\n' ' '))"
fi

# NEGATIVE control: someone else's session leaves their home alone
a=$(id -u tbadmin); touch /home/tbadmin/keep-me
runuser -l tbadmin -c true >/dev/null 2>&1
if gone "$a" && [ -e /home/tbadmin/keep-me ]; then
    res guest-reset-leaves-others-alone PASS
else
    res guest-reset-leaves-others-alone "FAIL ($(ls -A /home/tbadmin | tr '\n' ' '))"
fi

ko=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager KillOnlyUsers 2>&1)
[ "$ko" = 'as 1 "guest"' ] && res guest-programs-end-at-sign-out PASS || res guest-programs-end-at-sign-out "FAIL (KillOnlyUsers: $ko)"

out=$(echo '{"on": false}' | admin 2>&1)
if ! getent passwd guest >/dev/null && [ ! -e /etc/shani/guest ] && [ ! -d /home/guest ]; then
    res guest-off-gone PASS
else
    res guest-off-gone "FAIL ($out)"
fi
userdel -r tbadmin >/dev/null 2>&1 || true
