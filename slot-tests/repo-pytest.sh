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

# Start a Broadway display and **prove it came up**.
#
# Broadway display :N also binds TCP port 8080+N, and this used to be a hardcoded
# `:5`. When 8085 was already taken, gtk4-broadwayd logged
#   Unable to listen to port 8085: Error binding to address [::]:8085: Address already in use
# and **exited** - leaving no socket. GDK_BACKEND=broadway then found no display,
# `gtk_icon_theme_get_for_display` asserted on a NULL GdkDisplay, and the first
# widget in every suite died with signal 11.
#
# What made that expensive to read is that the only diagnostic was
# `command -v gtk4-broadwayd`: a daemon that is present but cannot listen
# reported **nothing at all**, and three suites crashing at their first widget
# looks like "the apps are broken on Arch" rather than "there was no display".
# So the check is now on the socket, not the binary - the absence-shaped guard
# was the bug.
#
# Candidates are tried in order and the first that produces a live socket wins.
BWDIAG=""
for n in 5 9 14 21 30; do
    BPID=""
    gtk4-broadwayd ":$n" >"$T/broadwayd.log" 2>&1 & BPID=$!
    sleep 1
    sock="$XDG_RUNTIME_DIR/broadway$((n + 1)).socket"
    if [ -S "$sock" ] && kill -0 "$BPID" 2>/dev/null; then
        export GDK_BACKEND=broadway BROADWAY_DISPLAY=":$n"
        break
    fi
    BWDIAG="$BWDIAG :$n=$(tr '\n' ' ' <"$T/broadwayd.log" 2>/dev/null | tail -c 120)"
    kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null; BPID=""
done
if [ -z "${BROADWAY_DISPLAY:-}" ]; then
    res broadway "FAIL (no display: gtk4-broadwayd could not listen on any candidate.$BWDIAG)"
    echo "  | Every GTK suite below would die at its first widget with signal 11"
    echo "  | and that is a MISSING DISPLAY, not an application fault."
    exit 1
fi
res broadway "PASS (GDK_BACKEND=broadway BROADWAY_DISPLAY=$BROADWAY_DISPLAY)"
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
        # **Why** each one failed, not only which. Listing the ids is enough to
        # see THAT something is wrong and not enough to do anything about it: on
        # 2026-10-04 this suite reported 25 Arch-only failures whose ids all said
        # "a machine without <tool> says so", and every one of those tests is
        # about a tool the image actually ships - so the ids pointed at the
        # opposite of the cause. Triaging that needed 25 separate runs, one test
        # each, because this loop printed no reason at all.
        #
        # The `E   ` lines are pytest's own assertion output, already filtered to
        # the failure sections; `--tb=line` (if the caller passed it) is even
        # terser. Capped, because a wholly broken suite can emit thousands and
        # then the detail is as unreadable as the id list was - but the cap was
        # 20, which is below one suite's worth of failures on its own, so a
        # third of the reasons were still cut.
        if grep -qE '^(FAILED|ERROR) ' <<<"$out"; then
            echo "  | --- why (assertion output, capped) ---"
            grep -E '^E +' <<<"$out" | head -60 | sed 's/^/  | /'
        fi
    fi
done
