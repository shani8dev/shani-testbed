#!/bin/bash
# var-lib-survey - which /var folders of a BOOTED system survive a reboot?
#
# A real boot runs with systemd.volatile=state: /var is a tmpfs, so a folder
# under /var/lib keeps nothing across a reboot unless it is a mountpoint - a
# bind from /data/var*/<name> (fstab) or a subvolume of its own. This lists
# every top-level folder of /var, and every folder in /var/lib and /var/spool:
#
#   SURVEY <path> <kept|RAM|inside> <how> <size> <owner>
#
#   kept  bind (from /data/varlib) or subvol (its own subvolume)
#   RAM   on the tmpfs: emptied at every boot
#   inside not a mountpoint itself, but under one (e.g. /var/lib/x on a kept /var/lib/x/..)
#   size  du -sh of what is in it NOW (after the system has run a while)
#   owner the package that ships the folder (pacman -Qo), or "runtime" when no
#         package does - a service made it while running
#
# A RAM folder that is non-empty after a normal boot is a candidate for the
# persisted list: some service writes state there and loses it at every boot.
# Whether it SHOULD persist (state, or a cache that is fine to lose?) is a
# judgement this does not make.
#
# Usage: iso-install --boot-only --console-put=boot-probes/var-lib-survey.sh:/tmp/vls.sh
#        --console-exec="bash /tmp/vls.sh"
set -u
timeout 600 systemctl is-system-running --wait >/dev/null 2>&1
echo "SURVEY-BEGIN $(systemctl is-system-running 2>/dev/null) uptime=$(cut -d' ' -f1 /proc/uptime)s"
survey() {  # PATH
    local d=$1 src how state size owner
    src=$(findmnt -no SOURCE --mountpoint "$d" 2>/dev/null)
    if [[ -n $src ]]; then
        if [[ $src == *"/varlib/"* || $src == *"/varspool/"* || $src == *"/data/"* ]]; then how=bind; else how=subvol; fi
        state=kept
    else
        how=-; state=RAM
        # under something kept (only /var itself is the tmpfs)
        [[ $(findmnt -no TARGET -T "$d" 2>/dev/null) != /var ]] && state=inside
    fi
    size=$(du -sh "$d" 2>/dev/null | cut -f1)
    owner=$(pacman -Qoq "$d" 2>/dev/null | paste -sd, -)
    printf 'SURVEY %-36s %-6s %-6s %6s %s\n' "$d" "$state" "$how" "${size:-?}" "${owner:-runtime}"
}
echo "/var itself: $(findmnt -no FSTYPE /var)"
for d in /var/*/ /var/lib/*/ /var/spool/*/; do
    [[ -d $d ]] && survey "${d%/}"
done
echo "SURVEY-END"
