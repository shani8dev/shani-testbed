#!/bin/bash
# A check of the harness itself: the test-disk lock in `testbed`, and the
# children that used to keep holding it after the command that took it exited.
#
# WHY: one harness run at a time on the test disk is real and necessary (two
# overlapping iso-install runs once corrupted swtpm's state, another deadlocked
# on qemu's image lock). But the lock was taken on a descriptor every child
# inherited, and flock is released only when the LAST descriptor on that open
# file description closes - so any child that outlives its command kept the disk
# locked. `_ensure_dbus`'s system bus is exactly that child by design (the next
# command in the same container reuses it). Observed on 2026-10-03: a
# `slot-test` printed its PASS summary and exited 0, and the `enter` that
# followed it in the same container invocation was refused with "another harness
# run holds .../disk: pid 45, `slot-test ...`", naming a pid that no longer
# existed. The cost was not one refused command: it made "one container, several
# harness commands" - the workspace's own cost habit - impossible, and it taught
# a reader to disbelieve a lock message that was reporting the truth.
#
# The lock is NOT a stale-lock problem to work around with -9 or by ignoring the
# message; it is a descriptor leak, and it is fixed by closing the descriptor in
# the children that outlive the command.
#
# This test has its own control: it runs the same scenario twice, once with the
# close and once without, and requires the un-closed one to FAIL. A test that
# cannot tell the fixed behaviour from the broken one is not guarding anything.
#
#   tests/lock-release.sh      (no root, no disks, no network)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL %s -- %s\n' "$1" "$2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; pkill -f "[s]leep 37" 2>/dev/null' EXIT
LOCK="$TMP/disk.lock"

# One harness command's worth of lock-taking, in a child shell, with a
# long-lived grandchild exactly like _ensure_dbus's --fork daemon.
#   $1 = close | inherit
# Prints "second-acquired" or "second-refused".
scenario() {
  bash -c '
    lock="$1"; mode="$2"
    exec 9>"$lock"
    flock -n 9 || { echo "first-refused"; exit 1; }
    # The outliving child. `setsid` stands in for `dbus-daemon --fork`: what
    # matters is that it is not waited for and does not die with this shell.
    # Its output goes to /dev/null for the same reason a real daemon does: a
    # child holding this command stdout open would make the caller $(...) block
    # until it exits, which is a 37-second test rather than a wrong answer.
    if [[ "$mode" == close ]]; then
      setsid sleep 37 >/dev/null 2>&1 9>&- &
    else
      setsid sleep 37 >/dev/null 2>&1 &
    fi
    sleep 0.3
    exit 0                       # the harness command finishes here
  ' _ "$LOCK" "$1"
  # ...and the NEXT command, in a fresh process, tries to take the same lock.
  if flock -n "$LOCK" -c true 2>/dev/null; then echo second-acquired; else echo second-refused; fi
}

# --- 1. the behaviour, with the close ---------------------------------------
got="$(scenario close)"
if [[ "$got" == "second-acquired" ]]; then
  ok "a command that closes the descriptor in its outliving child releases the lock"
else
  no "a command that closes the descriptor in its outliving child releases the lock" \
     "the next command was $got - a child still holds the descriptor"
fi

# --- 2. the control: the same scenario WITHOUT the close must fail ----------
got="$(scenario inherit)"
if [[ "$got" == "second-refused" ]]; then
  ok "control: without the close the next command IS locked out (the guard can fail)"
else
  no "control: without the close the next command IS locked out (the guard can fail)" \
     "got '$got', so check 1 cannot distinguish fixed from broken and proves nothing"
fi

# --- 3. the descriptor is the number the children close ----------------------
# Check 1 closes 9 because that is what the harness uses. If `testbed` moved the
# lock to another number, every `9>&-` below would become a no-op that still
# looked deliberate - and `exec {_TB_LOCK}>&-` in a child is NOT equivalent
# (measured on this bash: the brace form leaves the lock held).
if grep -qE '^ *exec 9>"\$\{DATA_DIR\}/\.testbed\.lock"' "$ROOT/testbed"; then
  ok "the lock is taken on descriptor 9, the number the children close"
else
  no "the lock is taken on descriptor 9, the number the children close" \
     "testbed no longer opens the lock on 9 - update every 9>&- in lib/ or the closes are silent no-ops"
fi

# --- 4. every child that can outlive its command closes it -------------------
# A table, not a grep for the string "9>&-": the failure mode being guarded is
# one site quietly missing while the others are fine, and a single grep would go
# green on the ones that are there.
missing=""
check_site() {
  local file="$1" pattern="$2" what="$3"
  grep -qE -- "$pattern" "$ROOT/$file" || missing+=" ${what} (${file})"
}
# Same, for a spawn whose command is wrapped across lines with a backslash (the
# close lands on the continuation line, not on the line naming the program).
check_site_continued() {
  local file="$1" start="$2" what="$3"
  grep -A3 -E -- "$start" "$ROOT/$file" | grep -q '9>&-' || missing+=" ${what} (${file})"
}
check_site lib/common.sh    'dbus-daemon --system --fork 9>&-'   "_ensure_dbus's system bus"
check_site lib/nspawn.sh    'systemd-nspawn .*9>&- &'            "_boot_bg_start's boot container"
check_site lib/app.sh       'Xvfb .*9>&- &'                      "Xvfb"
check_site lib/app.sh       'ollama serve .*9>&- &'              "the --llm server"
check_site_continued lib/isoinstall.sh 'swtpm socket'             "swtpm"
check_site lib/isoinstall.sh 'qemu-.*9>&- &'                     "the firmware-boot VM"
check_site lib/install.sh   '9>&- &'                             "the chroot's systemd-{hostnamed,localed,timedated}"
if [[ -z "$missing" ]]; then
  ok "every long-lived child closes the lock descriptor"
else
  no "every long-lived child closes the lock descriptor" "still inheriting:${missing}"
fi

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]