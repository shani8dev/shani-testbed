#!/bin/bash
# slot-test-mode: boot
#
# service-start — every opt-in service ShaniOS ships disabled must actually
# START on a fresh install the moment a user turns it on (Cassini's Sharing /
# Remote Access / Virtualization pages, or `systemctl enable --now`).
#
# WHY THIS EXISTS: on ShaniOS /var is a tmpfs; persistent state comes from
# @subvolumes and /data/varlib/<name> bind mounts that start out EMPTY. The
# directories a package ships under /var (pacman -Ql) therefore never exist
# unless a tmpfiles.d line creates them. Found by this test's sibling
# config-validators on 2026-10-01: smb.service failed on every fresh install —
# /var/lib/samba is bound from an empty /data/varlib/samba, so smbd died with
# "mkdir failed on directory /var/lib/samba/private/msg.sock". A unit-file
# check cannot see this; only starting the service can.
#
# Each service is started, checked, then stopped again (it was inactive to
# begin with), so the slot is left as it was. A service whose unit is not in
# this image is SKIP. On failure the package-owned /var paths that are missing
# are printed — the usual cause.
#
# NEGATIVE control: a planted service whose ExecStartPre needs a /var path
# that does not exist must be reported as failing by the same start check.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
# pacman's database, also under --volatile (real boots have none at runtime)
source /mnt/testbed/slot-tests/_pacdb.sh

# <unit> <owning package for the /var hint>
SERVICES="
smb.service samba
nmb.service samba
winbind.service samba
nfs-server.service nfs-utils
rpc-statd.service nfs-utils
libvirtd.service libvirt
virtqemud.service libvirt
sshd.service openssh
cups.service cups
avahi-daemon.service avahi
caddy.service caddy
fail2ban.service fail2ban
"

NEG=/etc/systemd/system/zz-shani-negctl-service-start.service
cleanup() { systemctl stop "$(basename "$NEG")" 2>/dev/null; rm -f "$NEG"; systemctl daemon-reload; _pacdb_cleanup; }
trap cleanup EXIT

# <unit> -> 0 if it reached active (or a oneshot exited 0), prints the reason otherwise
try_start() {
    local u=$1 since state
    since=$(date '+%Y-%m-%d %H:%M:%S')
    timeout 60 systemctl start "$u" >/dev/null 2>&1
    sleep 2
    state=$(systemctl is-active "$u" 2>/dev/null)
    if [ "$state" = active ]; then systemctl stop "$u" >/dev/null 2>&1; return 0; fi
    echo "state=$state"
    # the systemd-side cause, wherever it falls among the restart noise
    journalctl -u "$u" --since "$since" -o cat 2>/dev/null | grep -m1 'Failed to set up credentials' || true
    journalctl -u "$u" --since "$since" -o cat 2>/dev/null \
        | grep -vE 'pids\.max|^(Starting|Stopped|Stopping) ' | tail -4 | sed 's/^/    /'
    systemctl stop "$u" >/dev/null 2>&1; systemctl reset-failed "$u" >/dev/null 2>&1
    return 1
}

missing_var() {  # <pkg> -> package-owned /var paths that do not exist
    pacq -Qql "$1" 2>/dev/null | grep '^/var/' | while read -r p; do [ -e "$p" ] || echo "$p"; done
}

# A missing path under a mount point: was that mount up before
# systemd-tmpfiles-setup ran? A nofail mount is not ordered before
# local-fs.target, so tmpfiles can fill the directory underneath and the
# (empty) mount then hides it - the generated tmpfiles.d is right and the
# directories are still missing.
mount_order() {  # <missing path>
    local mp unit m t
    # the deepest existing ancestor's mount (the missing path itself has none)
    local p=$1; while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
    mp=$(findmnt -n -o TARGET -T "$p" 2>/dev/null)
    if [ -z "$mp" ] || [ "$mp" = / ] || [ "$mp" = /var ]; then
        printf '    %s is on %s, not a separate mount (ordering is not the cause)\n' "$p" "${mp:-?}"; return 0
    fi
    unit=$(systemd-escape -p --suffix=mount "$mp")
    m=$(systemctl show -P ActiveEnterTimestampMonotonic "$unit" 2>/dev/null)
    t=$(systemctl show -P ExecMainStartTimestampMonotonic systemd-tmpfiles-setup.service 2>/dev/null)
    if [ -z "$m" ] || [ -z "$t" ] || [ "$m" = 0 ] || [ "$t" = 0 ]; then
        printf '    %s on %s: no timestamps to compare (mount=%s, tmpfiles-setup=%s)\n' "$p" "$unit" "${m:-?}" "${t:-?}"; return 0
    fi
    if (( m > t )); then
        printf '    %s (%s) came up %d ms AFTER systemd-tmpfiles-setup started: it hides what tmpfiles created\n' "$unit" "$(findmnt -n -o SOURCE "$mp")" $(( (m - t) / 1000 ))
    else
        printf '    %s came up before systemd-tmpfiles-setup (ordering is not the cause)\n' "$unit"
    fi
}

while read -r unit pkg; do
    [ -n "$unit" ] || continue
    if ! systemctl cat "$unit" >/dev/null 2>&1; then res "start-$unit" "SKIP (not in this image)"; continue; fi
    if [ "$(systemctl is-active "$unit")" = active ]; then res "start-$unit" "PASS (already running)"; continue; fi
    if why=$(try_start "$unit"); then
        res "start-$unit" "PASS"
    elif grep -q 'Failed to set up credentials' <<<"$why" && [ ! -e /dev/tpmrm0 ]; then
        # LoadCredentialEncrypted= needs the TPM, and an nspawn slot has none:
        # not a verdict on the image. libvirtd does this (its secrets key).
        res "start-$unit" "SKIP (needs a TPM for its encrypted credentials; none in nspawn - use iso-install --boot-only --console-exec)"
    else
        res "start-$unit" "FAIL (${why%%$'\n'*})"
        printf '%s\n' "$why" | tail -n +2
        mv=$(missing_var "$pkg")
        [ -n "$mv" ] && printf '    missing %s-owned: %s\n' "$pkg" "$(tr '\n' ' ' <<<"$mv")"
        [ -n "$mv" ] && mount_order "$(head -1 <<<"$mv")"
    fi
done <<<"$SERVICES"

# --- negative control ----------------------------------------------------------
printf '[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStartPre=/usr/bin/test -d /var/lib/zz-shani-negctl/private\nExecStart=/usr/bin/true\n' > "$NEG"
systemctl daemon-reload
if try_start "$(basename "$NEG")" >/dev/null; then
    res service-start-negative-control "FAIL (service needing a missing /var dir reported as started)"
else
    res service-start-negative-control "PASS (missing /var dir made the start fail)"
fi
