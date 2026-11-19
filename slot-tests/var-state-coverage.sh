#!/bin/bash
# slot-test-mode: boot
#
# var-state-coverage — every /var place the IMAGE could write state to is
# either kept by /etc/fstab or declared '# ram:' there.
#
# WHY THIS EXISTS: a real boot runs systemd.volatile=state - /var is an empty
# tmpfs and only what fstab mounts survives a reboot. boot-probes/
# var-lib-survey.sh looks at a booted system, so it only sees folders whose
# service already ran (an off-by-default service, or state written at shutdown
# like alsa's asound.state, never shows). This asks the image itself instead:
#
#   unit     StateDirectory= of every system unit (DynamicUser= ones live
#            in /var/lib/private, which is declared)
#   home     a system user's home under /var (cosmic-greeter, gdm, sddm ...)
#   tmpfiles a systemd-tmpfiles line for a path under /var
#   content  a NON-EMPTY file a package ships under /var - it is under the
#            tmpfs at runtime, so it is missing there whatever fstab says,
#            unless gen-var-tmpfiles.sh put a /usr/share/factory copy and a
#            C line for it in the image (images before 2026-11-19 did not)
#
# Each place is folded to its top folder (/var/lib/<x>, /var/spool/<x>,
# /var/<x>). Output:
#   PLACE <path> <kept|ram|LOST> <sources>
#   CONTENT <file> <size> <restored|MISSING-AT-BOOT>
#   BIND-OWNER <source> want <image mode/owner> has <shanios-data-binds.conf>
# and RESULT lines: var-state-places FAILs on any LOST place.
#
# FSTAB=<file> checks another fstab than the slot's own (an edited profile
# fstab, with the image's units): put it under /mnt/testbed and pass the path.
#
# NEGATIVE control: a planted unit with StateDirectory=shani-negctl-vsc must
# come out LOST, then is removed.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
PACDB_SUBVOL=1  # read the image's own /var, not the binds over it
source /mnt/testbed/slot-tests/_pacdb.sh
NEG=/etc/systemd/system/zz-shani-negctl-vsc.service
cleanup() { rm -f "$NEG"; _pacdb_cleanup; }
trap cleanup EXIT
FSTAB=${FSTAB:-/etc/fstab}

kept=$(grep -vE '^[[:space:]]*(#|$)' "$FSTAB" | awk '$2 ~ /^\/var(\/|$)/ {print $2}')
ram=$(sed -n 's/^# ram: \([^ ]*\) .*/\1/p' "$FSTAB")

top() {  # PATH -> its top folder under /var, or nothing if not under /var
    local p=${1%/}
    case $p in
        /var/lib/*|/var/spool/*|/var/cache/*|/var/log/*) cut -d/ -f1-4 <<<"$p" ;;
        /var/lib|/var/spool|/var|/var/run|/var/lock) ;;   # run/lock: symlinks to /run
        /var/*) cut -d/ -f1-3 <<<"$p" ;;
    esac
}
state_of() {  # TOP -> kept|ram|LOST (a place under a kept or ram path is that)
    local p=$1 k
    for k in $kept; do [[ $p == "$k" || $p == "$k"/* ]] && { echo kept; return; }; done
    for k in $ram;  do [[ $p == "$k" || $p == "$k"/* ]] && { echo ram;  return; }; done
    echo LOST
}

collect() {
    # unit: StateDirectory= (relative to /var/lib; several per line allowed)
    local f
    for f in /usr/lib/systemd/system/*.service /etc/systemd/system/*.service \
             /usr/lib/systemd/system/*.service.d/*.conf /etc/systemd/system/*.service.d/*.conf; do
        [[ -f $f ]] || continue
        grep -q '^DynamicUser=\(yes\|true\|1\)' "$f" && continue
        sed -n 's/^StateDirectory=//p' "$f" | tr ' ' '\n' | sed 's/:.*//' \
            | while read -r d; do [[ -n $d ]] && echo "/var/lib/${d} unit:$(basename "${f%.d/*}")"; done
    done
    # home: system users whose home is under /var
    awk -F: '$3 < 1000 && $6 ~ /^\/var\// {print $6 " home:" $1}' /etc/passwd
    # tmpfiles: every line's path under /var (specifiers expanded, system scope)
    systemd-tmpfiles --cat-config 2>/dev/null | awk '!/^[[:space:]]*(#|$)/ {print $2 " tmpfiles:" $1}' \
        | sed -e 's|%S|/var/lib|; s|%C|/var/cache|; s|%L|/var/log|; s|%V|/var/tmp|' | grep '^/var/'
}

# negative control first, so it is in the same pass
printf '[Service]\nType=oneshot\nExecStart=/bin/true\nStateDirectory=shani-negctl-vsc\n' > "$NEG"

lost=0; neg=no
while read -r p srcs; do
    s=$(state_of "$p")
    printf 'PLACE %-36s %-5s %s\n' "$p" "$s" "$srcs"
    if [[ $p == /var/lib/shani-negctl-vsc ]]; then [[ $s == LOST ]] && neg=yes; continue; fi
    [[ $s == LOST ]] && lost=$((lost + 1))
done < <(collect | while read -r p src; do t=$(top "$p"); [[ -n $t ]] && echo "$t $src"; done \
         | sort -u | awk '{a[$1] = a[$1] (a[$1] ? "," : "") $2} END {for (k in a) print k, a[k]}' | sort)

# content: non-empty regular files packages ship under /var, read from the
# slot's own subvolume (on a real or --volatile boot /var is the tmpfs)
root=${_PACDB_MNT:-}; nm=0
[[ -n $root ]] || { res var-state-image "FAIL could not mount the slot's subvolume"; exit 1; }
nc=0
while read -r f; do
    [[ $f == /var/* && $f != */ ]] || continue
    case $f in /var/cache/*|/var/log/*) continue ;; esac
    sz=$(stat -c %s "${root}${f}" 2>/dev/null) || continue
    [[ -f ${root}${f} && $sz -gt 0 ]] || continue
    nc=$((nc + 1))
    if cmp -s "${root}${f}" "${root}/usr/share/factory${f}" \
       && grep -qE "^C[+]?[[:space:]]+${f//./\\.}([[:space:]]|$)" "${root}"/usr/lib/tmpfiles.d/*.conf 2>/dev/null; then
        echo "CONTENT $f $sz restored"
    else
        echo "CONTENT $f $sz MISSING-AT-BOOT"; nm=$((nm + 1))
    fi
done < <(pacq -Qlq 2>/dev/null | sort -u)

# links: a symlink a package ships under /var needs an L line (filesystem's
# /var/lock and /var/mail were missing on a real boot)
nl=0
while read -r f; do
    f=${f%/}; [[ $f == /var/* && -L ${root}${f} ]] || continue
    if grep -qhE "^L[+!]*[[:space:]]+${f//./\\.}[[:space:]]" "${root}"/usr/lib/tmpfiles.d/*.conf 2>/dev/null; then
        echo "LINK $f restored"
    else echo "LINK $f MISSING-AT-BOOT"; nl=$((nl + 1)); fi
done < <(pacq -Qlq 2>/dev/null | sort -u)

# bind owner: the image's shanios-data-binds.conf must give each /data source
# the mode and owner the image gives the folder mounted over it - the
# installer makes sources root 0755, which is what shows at /var/... otherwise
# (/var/spool/samba and /var/spool/mail lost their 1777 that way).
bo=0; DB=/usr/lib/tmpfiles.d/shanios-data-binds.conf
while read -r src dst; do
    img="${root}${dst}"
    [[ -d $img && ! -L $img ]] || continue
    want="$(stat -c '%a %U %G' "$img")"
    have=$(awk -v s="$src" '$2 == s {sub(/^0/, "", $3); print $3, $4, $5}' "$DB" 2>/dev/null)
    if [[ $have != "$want" ]]; then
        echo "BIND-OWNER $src want '$want' has '${have:-no line}'"; bo=$((bo + 1))
    fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$FSTAB" | awk '$4 ~ /bind/ && $1 ~ /^\/data\// {print $1, $2}' | sort -u)

res var-state-places "$( ((lost)) && echo "FAIL ${lost} /var place(s) neither kept nor declared ram" || echo PASS)"
res var-state-negctl "$( [[ $neg == yes ]] && echo PASS || echo 'FAIL planted StateDirectory= not reported LOST')"
res var-state-bind-owner "$( ((bo)) && echo "FAIL ${bo} bind source(s) without the image's mode/owner" || echo PASS)"
res var-state-links "$( ((nl)) && echo "FAIL ${nl} packaged /var symlink(s) with no L line" || echo PASS)"
res var-state-content "$( ((nm)) && echo "FAIL ${nm} of ${nc} packaged /var file(s) have no /usr/share/factory copy + C line (absent on a real boot)" || echo "PASS ${nc} packaged /var file(s) restored from /usr/share/factory")"
