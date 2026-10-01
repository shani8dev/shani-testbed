#!/bin/bash
# slot-test-mode: boot
#
# config-validators — every security/system config in the INSTALLED image
# checked by its own real validator, after every package, overlay and
# configure.sh step has touched it.
#
# WHY THIS EXISTS: shani-settings/tests/validate-configs.sh runs visudo,
# testparm, udevadm verify and node --check against that repo's own tree. The
# image's /etc is not that tree: it is the union of shani-settings, every other
# package, image_profiles overlays and what configure.sh wrote at install
# time, so a fragment from anywhere else, or two fragments that are each fine
# but conflict, is invisible to the repo check. Here nothing is copied.
#
# A validator that is not installed is SKIP naming it, not PASS. Every
# validator gets a NEGATIVE control (a deliberately broken copy in /tmp) so a
# validator that accepts anything cannot pass this test.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
# pacman's database, also under --volatile (real boots have none at runtime)
source /mnt/testbed/slot-tests/_pacdb.sh
T=$(mktemp -d /tmp/shani-negctl-cfg.XXXXXX)
trap 'rm -rf "$T"; _pacdb_cleanup' EXIT
have() { command -v "$1" >/dev/null 2>&1; }

# --- sudoers: the whole include tree, as sudo itself reads it ---------------
if have visudo; then
    if out=$(visudo -c 2>&1); then res sudoers-visudo "PASS ($(grep -c 'parsed OK' <<<"$out") file(s) parsed OK)"
    else res sudoers-visudo "FAIL"; printf '  | %s\n' "$out" | grep -v 'parsed OK' | head -10; fi
    printf 'root ALL=(ALL ALL\n' > "$T/sudoers"; chmod 440 "$T/sudoers"
    if visudo -c -f "$T/sudoers" >/dev/null 2>&1; then res sudoers-negative-control "FAIL (broken sudoers accepted)"
    else res sudoers-negative-control "PASS (broken sudoers rejected)"; fi
else res sudoers-visudo "SKIP (visudo not installed)"; fi

# --- udev: every rules file udevd actually loads -----------------------------
# Only rules ShaniOS ships (shani-* packages, or no owner = image overlay) can
# fail this; upstream packages' style nits (usb_modeswitch, Argyll, qemu-ga)
# are not ours. Names are resolved as udevd does: --resolve-names=never turns
# every GROUP=/OWNER= into "has no effect" and fails upstream's own rules.
if have udevadm && udevadm verify --help >/dev/null 2>&1; then
    ours=$( { pacq -Qql $(pacq -Qq | grep '^shani') 2>/dev/null; } | grep -E '/rules\.d/.*\.rules$')
    allown=$(pacq -Qql 2>/dev/null | grep -E '/rules\.d/.*\.rules$')
    files=()
    for f in /usr/lib/udev/rules.d/*.rules /etc/udev/rules.d/*.rules; do
        [ -f "$f" ] || continue
        if grep -qxF "$f" <<<"$ours" || ! grep -qxF "$f" <<<"$allown"; then files+=("$f"); fi
    done
    if [ "${#files[@]}" -eq 0 ]; then res udev-rules-verify "SKIP (no ShaniOS-shipped rules files)"
    elif out=$(udevadm verify "${files[@]}" 2>&1); then res udev-rules-verify "PASS (${#files[@]} ShaniOS rules files)"
    else
        bad=$(grep -vE '^\s*(Success|Fail):|checked\.|^\s*$' <<<"$out")
        # the one deliberately-accepted exception (shani-settings AGENTS.md):
        # 40-hpet-permissions.rules names 'realtime', which only profiles with
        # shani-multimedia create
        if getent group realtime >/dev/null; then real=$bad
        else real=$(grep -vE "40-hpet-permissions\.rules(:[0-9]+ Failed to resolve group 'realtime'|: udev rules check failed)" <<<"$bad"); fi
        if [ -z "$real" ]; then res udev-rules-verify "PASS (${#files[@]} ShaniOS rules files; realtime-group exception only)"
        else res udev-rules-verify "FAIL"; printf '  | %s\n' "$real" | head -15; fi
    fi
    printf 'ACTION=="add" GOTO="x"\n' > "$T/99-bad.rules"
    if udevadm verify "$T/99-bad.rules" >/dev/null 2>&1; then res udev-negative-control "FAIL (broken rules accepted)"
    else res udev-negative-control "PASS (broken rules rejected)"; fi
else res udev-rules-verify "SKIP (udevadm verify unavailable)"; fi

# --- Samba --------------------------------------------------------------------
if [ -f /etc/samba/smb.conf ]; then
    if have testparm; then
        # testparm exits 0 on unknown parameters; its stderr names them
        out=$(testparm -s /etc/samba/smb.conf 2>&1 >/dev/null)
        bad=$(grep -iE 'unknown parameter|ignoring|error' <<<"$out")
        if [ -z "$bad" ]; then res samba-testparm "PASS"
        else res samba-testparm "FAIL"; printf '  | %s\n' "$bad" | head -10; fi
        printf '[global]\n  no such samba option = yes\n' > "$T/smb.conf"
        if testparm -s "$T/smb.conf" 2>&1 >/dev/null | grep -qi 'unknown parameter'; then
            res samba-negative-control "PASS (unknown parameter reported)"
        else res samba-negative-control "FAIL (unknown parameter not reported)"; fi
    else res samba-testparm "SKIP (smb.conf shipped but testparm not installed)"; fi
else res samba-testparm "SKIP (no /etc/samba/smb.conf in this image)"; fi

# --- sshd -----------------------------------------------------------------------
if have sshd; then
    # sshd -t needs host keys; a fresh slot may not have generated them yet
    keyopt=()
    if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
        ssh-keygen -q -t ed25519 -N '' -f "$T/hostkey" && keyopt=(-h "$T/hostkey")
    fi
    if out=$(sshd -t "${keyopt[@]}" 2>&1); then res sshd-config "PASS"
    else res sshd-config "FAIL"; printf '  | %s\n' "$out" | head -10; fi
    printf 'NoSuchSshdOption yes\n' > "$T/sshd_config"
    if sshd -t -f "$T/sshd_config" "${keyopt[@]}" >/dev/null 2>&1; then res sshd-negative-control "FAIL (bad option accepted)"
    else res sshd-negative-control "PASS (bad option rejected)"; fi
else res sshd-config "SKIP (sshd not installed)"; fi

# --- polkit: polkitd compiles every rules file when it starts ---------------
# node --check only checks JS syntax; polkitd's own engine also catches a
# runtime error at load. Restart it and read what it logged.
if systemctl cat polkit.service >/dev/null 2>&1; then
    since=$(date '+%Y-%m-%d %H:%M:%S')
    systemctl restart polkit.service 2>/dev/null; sleep 2
    out=$(journalctl -u polkit.service --since "$since" -o cat _COMM=polkitd 2>/dev/null)
    bad=$(grep -iE 'error|exception|failed' <<<"$out")
    # polkitd 127 logs only "Started polkitd version N" and reports a rules
    # file only when it fails to compile/run; older ones also logged a
    # "Finished loading ... N rules" line
    started=$(grep -oE 'Started polkitd version [0-9.]+|Finished loading, compiling and executing [0-9]+ rules' <<<"$out" | tail -1)
    if [ -n "$bad" ]; then res polkit-rules-load "FAIL"; printf '  | %s\n' "$bad" | head -10
    elif [ -n "$started" ] && systemctl is-active -q polkit.service; then res polkit-rules-load "PASS ($started, no rule errors)"
    else res polkit-rules-load "FAIL (polkitd did not come back after restart)"; fi
else res polkit-rules-load "SKIP (no polkit.service)"; fi

# --- tmpfiles / sysusers: dry-runs of what boot applies --------------------
if out=$(systemd-tmpfiles --create --dry-run 2>&1 | grep -viE '^would ' ); [ -z "$out" ]; then
    res tmpfiles-config "PASS"
else res tmpfiles-config "FAIL"; printf '  | %s\n' "$out" | head -10; fi
if out=$(systemd-sysusers --dry-run 2>&1 | grep -viE '^would |^creating|^Creating' ); [ -z "$out" ]; then
    res sysusers-config "PASS"
else res sysusers-config "FAIL"; printf '  | %s\n' "$out" | head -10; fi

# --- firewalld (offline check of the permanent config) ------------------------
if have firewall-offline-cmd; then
    if out=$(firewall-offline-cmd --check-config 2>&1); then res firewalld-config "PASS"
    else res firewalld-config "FAIL"; printf '  | %s\n' "$out" | head -10; fi
else res firewalld-config "SKIP (firewalld not installed)"; fi

# --- dconf: system databases compile ---------------------------------------
if have dconf && compgen -G '/etc/dconf/db/*.d' >/dev/null; then
    bad=0 n=0
    for d in /etc/dconf/db/*.d; do
        [ -d "$d" ] || continue
        n=$((n+1))
        o=$(dconf compile "$T/x.db" "$d" 2>&1) || { bad=1; printf '  | %s: %s\n' "$d" "$o"; }
    done
    [ "$bad" -eq 0 ] && res dconf-keyfiles "PASS ($n database dir(s))" || res dconf-keyfiles "FAIL"
    mkdir -p "$T/bad.d"; printf '[org/x\nkey=1\n' > "$T/bad.d/00"
    if dconf compile "$T/bad.db" "$T/bad.d" >/dev/null 2>&1; then res dconf-negative-control "FAIL (broken keyfile accepted)"
    else res dconf-negative-control "PASS (broken keyfile rejected)"; fi
else res dconf-keyfiles "SKIP (no dconf system databases)"; fi
