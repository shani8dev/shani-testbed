#!/bin/bash
# slot-test-mode: boot
#
# launchers — what the shipped desktop pins is really there. Plasma dock
# `launchers` must all resolve to an installed .desktop file (a missing one
# is a blank icon - e.g. a Flatpak whose layer was not installed, which a
# screenshot alone doesn't flag). GNOME `favorite-apps` / COSMIC favorites
# that aren't installed are hidden by the shell, so they are listed, not
# failed; but an empty dock fails. NEGATIVE control: a bogus id is reported.
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

# Plasma dock launchers: a missing one is a blank icon - a real defect.
plasma=()
for f in /usr/share/plasma/layout-templates/*/contents/layout.js; do
    [[ -f $f ]] || continue
    # launchers are "applications:<id>", "file://<path>" or "preferred://<x>"
    # (resolved through mimeapps, not a fixed file - not checked here)
    while IFS= read -r l; do
        [[ $l == preferred://* ]] && continue
        plasma+=("${l#applications:}")
    done < <(grep -o '"launchers", *"[^"]*"' "$f" | sed 's/.*, *"//; s/"$//' | tr ',' '\n')
done
# GNOME favorite-apps / COSMIC dock favorites: GNOME Shell and COSMIC hide a
# favorite that is not installed (it appears pinned once the user installs
# the app), so a missing one is a pre-pin, not a visible defect - reported,
# not failed. An empty dock (nothing pinned installed) still fails.
hidden=()
for f in /usr/share/glib-2.0/schemas/*.gschema.override; do
    [[ -f $f ]] || continue
    while IFS= read -r l; do hidden+=("$l"); done \
        < <(grep -h '^favorite-apps=' "$f" | grep -o "'[^']*'" | tr -d "'")
done
f=/etc/skel/.config/cosmic/com.system76.CosmicAppList/v1/favorites
[[ -f $f ]] && while IFS= read -r l; do hidden+=("$l"); done < <(grep -o '"[^"]*"' "$f" | tr -d '"')

total=$(( ${#plasma[@]} + ${#hidden[@]} ))
if (( total == 0 )); then
    res pinned-launchers-installed "PASS (no pinned launchers on this profile)"
else
    missing=() prepins=() shown=0
    for id in "${plasma[@]}"; do if found "$id"; then shown=$((shown + 1)); else missing+=("${id##*/}"); fi; done
    for id in "${hidden[@]}"; do if found "$id"; then shown=$((shown + 1)); else prepins+=("$id"); fi; done
    (( ${#prepins[@]} )) && echo "   pinned but not installed, hidden until installed: ${prepins[*]}"
    if (( ${#missing[@]} )); then
        res pinned-launchers-installed "FAIL (${#missing[@]} dock launcher(s) missing, shown as blank icons: ${missing[*]})"
    elif (( shown == 0 )); then
        res pinned-launchers-installed "FAIL (none of ${total} pinned apps is installed - empty dock)"
    else
        res pinned-launchers-installed "PASS (${shown}/${total} shown${prepins:+, ${#prepins[@]} hidden pre-pins})"
    fi
fi
found org.shani.DoesNotExist && res launchers-negative-control FAIL || res launchers-negative-control PASS
echo "== probe done"
