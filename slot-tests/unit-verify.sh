#!/bin/bash
# slot-test-mode: boot
#
# unit-verify — `systemd-analyze verify` over every unit ShaniOS itself ships,
# in the installed image, plus every load-time complaint PID 1 logged this boot.
#
# WHY THIS EXISTS: shani-deploy and shani-fleet each run verify-units.sh in a
# throwaway Arch container, installing their own units and STUBBING the
# /usr/local/bin scripts and data.mount they point at. That proves the unit
# files are well-formed against some systemd; it cannot prove the image's
# systemd accepts them, that the binary an ExecStart= names is really in the
# image, or that a unit from a package/overlay those repos don't know about
# (image_profiles overlays, shani-settings, other shani-* packages) is clean.
# In the booted slot nothing is stubbed.
#
# verify exits 0 on an ignored unknown key ("..., ignoring."), and a silently
# ignored directive is exactly the bug class, so ANY line about one of our
# units is a failure — the same rule verify-units.sh uses.
#
# Scope: units owned by a shani-* package, plus unit files no package owns
# (image overlays). Upstream packages' units are not ours to fix here; PID 1's
# own journal check below still covers them.
#
# NEGATIVE control: a planted unit naming a missing binary and an unknown key
# must be reported by the same check, then is removed.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
# pacman's database, also under --volatile (real boots have none at runtime)
source /mnt/testbed/slot-tests/_pacdb.sh

UNIT_RE='\.(service|socket|timer|path|mount|automount|target|slice|swap)$'
NEG=/etc/systemd/system/zz-shani-negctl-unit-verify.service
cleanup() { rm -f "$NEG"; _pacdb_cleanup; }
trap cleanup EXIT

# <scope> -> unit file paths we own, one per line
our_units() {
    local dirs owned
    if [ "$1" = user ]; then dirs="/usr/lib/systemd/user /etc/systemd/user"
    else dirs="/usr/lib/systemd/system /etc/systemd/system"; fi
    owned=$(pacq -Qql $(pacq -Qq | grep '^shani') 2>/dev/null | grep -E "$UNIT_RE")
    local all; all=$(pacq -Qql 2>/dev/null | grep -E "$UNIT_RE")
    for d in $dirs; do
        [ -d "$d" ] || continue
        # -maxdepth 1 and -type f: enablement symlinks and *.wants/ are not units
        find "$d" -maxdepth 1 -type f | grep -E "$UNIT_RE"
    done | while read -r f; do
        if grep -qxF "$f" <<<"$owned"; then echo "$f"
        elif ! grep -qxF "$f" <<<"$all"; then echo "$f"; fi
    done
}

# <scope> <unit path...> -> verify's output lines that are about these units
verify_lines() {
    local scope=$1; shift
    local flag=() f out names=()
    [ "$scope" = user ] && flag=(--user)
    for f in "$@"; do names+=("$(basename "$f")"); done
    # one call per unit: a hard error in one unit aborts verify for the rest
    for f in "$@"; do
        out=$(XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/0} \
              systemd-analyze verify "${flag[@]}" --man=no "$f" 2>&1)
        # verify also reports on the units this one pulls in; keep only lines
        # naming one of ours, so an upstream unit's noise is not blamed on us
        printf '%s\n' "$out" | grep -F -f <(printf '%s\n' "${names[@]}") || true
    done | sort -u
}

for scope in system user; do
    mapfile -t units < <(our_units "$scope")
    if [ "${#units[@]}" -eq 0 ]; then
        res "unit-verify-$scope" "FAIL (no shani-owned or unowned $scope units found - scope detection broke)"
        continue
    fi
    lines=$(verify_lines "$scope" "${units[@]}")
    if [ -z "$lines" ]; then
        res "unit-verify-$scope" "PASS (${#units[@]} units, no complaints)"
    else
        res "unit-verify-$scope" "FAIL ($(wc -l <<<"$lines") complaint line(s) over ${#units[@]} units)"
        printf '  | %s\n' "$lines" | head -40
    fi
done

# --- PID 1's own load-time complaints, this boot ---------------------------
# Covers every unit actually loaded, upstream included: systemd logs an unknown
# key/section or a bad value once, at load, and then carries on without it.
pid1=$(journalctl -b -o cat _PID=1 2>/dev/null \
       | grep -E 'Unknown (key|section) name|Unknown lvalue|Failed to parse|Invalid (argument|value)|is not executable|ignoring\.$' \
       | grep -v 'zz-shani-negctl' | sort -u)
if [ -z "$pid1" ]; then
    res pid1-unit-load-complaints "PASS (none logged this boot)"
else
    res pid1-unit-load-complaints "FAIL ($(wc -l <<<"$pid1") distinct line(s))"
    printf '  | %s\n' "$pid1" | head -30
fi

# --- negative control --------------------------------------------------------
printf '[Unit]\nDescription=negative control\n[Service]\nExecStart=/usr/bin/zz-no-such-binary\nNoSuchKeyAnywhere=1\n' > "$NEG"
neg=$(verify_lines system "$NEG")
if grep -q 'zz-no-such-binary\|NoSuchKeyAnywhere' <<<"$neg"; then
    res unit-verify-negative-control "PASS (planted bad unit reported)"
else
    res unit-verify-negative-control "FAIL (planted bad unit NOT reported: '${neg:-no output}')"
fi
neg_scope=$(our_units system | grep -c 'zz-shani-negctl')
if [ "$neg_scope" -eq 1 ]; then
    res unit-verify-scope-control "PASS (an unowned unit in /etc is in scope)"
else
    res unit-verify-scope-control "FAIL (planted unowned unit not picked up by scope)"
fi
