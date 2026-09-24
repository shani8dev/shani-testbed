#!/bin/bash
# slot-test-mode: boot
#
# launchers — every app the shipped desktop pins (Plasma dock layout
# `launchers`, GNOME `favorite-apps`, COSMIC dock favorites) resolves to an
# installed .desktop file in this boot. A pinned Flatpak whose layer
# (flatpakfs) wasn't installed shows as a blank dock icon on Plasma and
# silently disappears on GNOME/COSMIC — the desktop still renders, so a
# screenshot alone passes it. NEGATIVE control: a bogus id is reported.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
DIRS=(/usr/share/applications /usr/local/share/applications
      /var/lib/flatpak/exports/share/applications /var/lib/snapd/desktop/applications)

found() {  # <desktop-id | file:///path>
    local id="$1" d
    [[ $id == file://* ]] && { [[ -f ${id#file://} ]]; return; }
    [[ $id == *.desktop ]] || id+=.desktop
    for d in "${DIRS[@]}"; do [[ -f $d/$id ]] && return 0; done
    return 1
}

ids=()
for f in /usr/share/plasma/layout-templates/*/contents/layout.js; do
    [[ -f $f ]] || continue
    # launchers are "applications:<id>", "file://<path>" or "preferred://<x>"
    # (resolved through mimeapps, not a fixed file - not checked here)
    while IFS= read -r l; do
        [[ $l == preferred://* ]] && continue
        ids+=("${l#applications:}")
    done < <(grep -o '"launchers", *"[^"]*"' "$f" | sed 's/.*, *"//; s/"$//' | tr ',' '\n')
done
for f in /usr/share/glib-2.0/schemas/*.gschema.override; do
    [[ -f $f ]] || continue
    while IFS= read -r l; do ids+=("$l"); done \
        < <(grep -h '^favorite-apps=' "$f" | grep -o "'[^']*'" | tr -d "'")
done
f=/etc/skel/.config/cosmic/com.system76.CosmicAppList/v1/favorites
[[ -f $f ]] && while IFS= read -r l; do ids+=("$l"); done < <(grep -o '"[^"]*"' "$f" | tr -d '"')

if (( ${#ids[@]} == 0 )); then
    res pinned-launchers-installed "PASS (no pinned launchers on this profile)"
else
    missing=()
    for id in "${ids[@]}"; do found "$id" || missing+=("${id##*/}"); done
    if (( ${#missing[@]} == 0 )); then
        res pinned-launchers-installed "PASS (${#ids[@]} launchers)"
    else
        res pinned-launchers-installed "FAIL (${#missing[@]}/${#ids[@]} missing: ${missing[*]})"
    fi
fi
found org.shani.DoesNotExist && res launchers-negative-control FAIL || res launchers-negative-control PASS
echo "== probe done"
