#!/bin/bash
# slot-test-mode: boot
#
# repo-pytest — run the GUI apps' OWN test suites (shani-cassini, shani-chronoa,
# shani-backup) against the Python, PyGObject, GTK and libadwaita this image
# ships, not the CI runner's.
#
# WHY THIS EXISTS: all three run their suites in CI on Ubuntu 24.04 (PyGObject
# 3.48, libadwaita 1.5); ShaniOS is Arch (PyGObject 3.56, libadwaita 1.9). On
# 2026-10-01 Cassini's suite had 13 failures on Arch that its green CI never
# showed (a /usr/sbin-is-a-symlink assumption among them). A green suite on the
# wrong distribution is no evidence about this one — see "Slot tests cannot
# all be unit tests" in AGENTS.md.
#
# The checkouts come from run_in_container.sh (/opt/<repo>, read-only) through
# the slot bind /mnt/src/<repo>; a repo that is not mounted is SKIP. Nothing is
# installed into the slot: pytest (pure Python) is fetched with a COPY of the
# pacman database into /tmp and put on PYTHONPATH, and widgets render on GTK's
# own Broadway backend (gtk4-broadwayd, part of gtk4), so no Xvfb is needed.
# Tests that need X11 tooling (xdotool, an X display) are deselected by the
# suites' own markers/fixtures, or show up here as failures to look at.
#
# Each repo's result is PASS only if its whole suite passes; on FAIL the
# failing test ids are printed. SHANIOS_TEST_PYTEST_ARGS adds pytest options
# (e.g. "-k storage").
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
source /mnt/testbed/slot-tests/_pacdb.sh
T=$(mktemp -d /tmp/shani-repo-pytest.XXXXXX)
trap 'kill $BPID 2>/dev/null; rm -rf "$T"; _pacdb_cleanup' EXIT
BPID=""

# --- pytest without touching the slot's package database --------------------
PYT="$T/pyt"
if ! python3 -c 'import pytest' 2>/dev/null; then
    cp -a "$PACDB" "$T/db" 2>/dev/null; mkdir -p "$T/pkg"
    # pacman 7 downloads as its unprivileged DownloadUser (alpm): it must be
    # able to reach and write the copied sync dir and the cache dir
    chmod 755 "$T"
    getent passwd alpm >/dev/null && chown -R alpm: "$T/db/sync" "$T/pkg"
    if pacman --dbpath "$T/db" --cachedir "$T/pkg" --noconfirm -Syw \
            python-pytest python-pluggy python-iniconfig python-packaging >"$T/pacman.log" 2>&1; then
        mkdir -p "$PYT"
        for p in "$T"/pkg/*.pkg.tar.*; do bsdtar -xf "$p" -C "$PYT" usr/lib 2>/dev/null; done
        export PYTHONPATH="$(ls -d "$PYT"/usr/lib/python3*/site-packages | tr '\n' ':')${PYTHONPATH:-}"
    fi
fi
if ! python3 -c 'import pytest' 2>/dev/null; then
    res repo-pytest "FAIL (could not provide pytest without installing it: $(grep -m1 -iE 'error|fail' "$T/pacman.log" 2>/dev/null | cut -c1-160))"
    tail -5 "$T/pacman.log" 2>/dev/null | sed 's/^/  | /'
    exit 0
fi
res pytest-available "PASS (pytest $(python3 -c 'import pytest; print(pytest.__version__)') on python $(python3 -c 'import sys; print(sys.version.split()[0])'))"

# --- a display: GTK's Broadway backend --------------------------------------
# Broadway's socket lives in the runtime dir (else ~/.cache): fix one for the
# daemon AND every suite, which each get their own HOME - with the socket
# looked up under a different HOME, GTK had no display and the first widget
# segfaulted (rc 139, 2026-10-01)
export XDG_RUNTIME_DIR="$T/rt"; mkdir -p -m 700 "$XDG_RUNTIME_DIR"
if command -v gtk4-broadwayd >/dev/null; then
    gtk4-broadwayd :5 >/dev/null 2>&1 & BPID=$!
    sleep 1
    export GDK_BACKEND=broadway BROADWAY_DISPLAY=:5
else
    res broadway "SKIP (no gtk4-broadwayd; GUI tests will fail for want of a display)"
fi
export GSETTINGS_BACKEND=memory NO_AT_BRIDGE=1 PYTHONDONTWRITEBYTECODE=1

# --- the suites -----------------------------------------------------------
for repo in shani-cassini shani-chronoa shani-backup; do
    src=/mnt/src/$repo
    if [ ! -d "$src/tests" ]; then res "pytest-$repo" "SKIP (/mnt/src/$repo not mounted)"; continue; fi
    # a writable copy: the suites write fixtures/caches next to themselves
    cp -a "$src" "$T/$repo"
    # -v so a crash (a segfault takes the whole run down) can be pinned on the
    # test that was running; faulthandler prints the Python side of it
    out=$(cd "$T/$repo" && HOME="$T/home-$repo" timeout 1200 python3 -X faulthandler -m pytest tests/ -v -p no:cacheprovider \
          ${SHANIOS_TEST_PYTEST_ARGS:-} 2>&1)
    rc=$?
    summary=$(grep -E '^(=+ )?[0-9]+ (passed|failed)|(passed|failed|error).* in [0-9.]+s' <<<"$out" | tail -1 | sed 's/=//g; s/^ *//')
    if [ "$rc" -ge 128 ]; then
        last=$(grep -oE '^tests/[^ ]+::[^ ]+' <<<"$out" | tail -1)
        res "pytest-$repo" "FAIL (crashed, signal $((rc - 128)), in or after ${last:-the first test}; $(grep -cE ' PASSED' <<<"$out") passed before it)"
        grep -A3 -E '^(Fatal Python error|Current thread)' <<<"$out" | head -8 | sed 's/^/  | /'
        grep -E '^  File "[^"]*/(tests|shani_)' <<<"$out" | head -6 | sed 's/^/  | /'
        continue
    fi
    if [ "$rc" -eq 0 ]; then
        res "pytest-$repo" "PASS (${summary:-rc=0})"
    else
        res "pytest-$repo" "FAIL (${summary:-rc=$rc})"
        grep -E '^(FAILED|ERROR) ' <<<"$out" | head -25 | sed 's/^/  | /'
        [ -z "$(grep -E '^(FAILED|ERROR) ' <<<"$out")" ] && tail -15 <<<"$out" | sed 's/^/  | /'
    fi
done
