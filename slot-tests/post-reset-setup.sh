#!/bin/bash
# slot-test-mode: boot
# slot-test-needs: --local-src=/opt/shani-deploy/scripts
#
# post-reset-setup — the state a factory reset leaves behind, and the one hook
# that has to clean it up.
#
# Why this exists. shani-reset wipes /data, which takes the /etc overlay upper
# layer with it: every user account goes, because /etc/passwd only ever lived
# there. It writes /data/user-setup-needed on the way out, and
# shani-user-setup.path watches that marker — so shani-user-setup.service is the
# one thing that runs on the next boot and has to put the system back into a
# usable state. Until 2026-10-16 it did not seed /etc/skel at all, while its own
# .service Description, its .path watch, shani-reset's usage text and
# AUDIT-HISTORY.md all said it did.
#
# A real shani-reset is NOT run here. It ends in `systemctl reboot`, and this
# session is a container without a real PID 1 to reboot — the harness's own
# notes record that step failing with "Failed to connect to system scope bus".
# What is exercised instead is both halves that a real reset would hand over:
# the script's real output text via --dry-run (the same code path, no wipe), and
# the real service reacting to the real marker.
#
# Checks, with the negative control named in the last one:
#   - shani-reset --dry-run names the wizard that actually creates the account
#     (plasma-setup), never plasma-welcome, which is an in-session tips app
#     that is installed and never enabled;
#   - it states plainly that no account survives, including root;
#   - shani-user-setup.service seeds a skel file deleted from an existing home,
#     triggered by the real marker through the real path unit;
#   - it does NOT revert a file the user edited;
#   - the first-login pair (.bashrc_shani + its autostart entry) is not seeded
#     into a home that already has a .bashrc, because that autostart runs
#     `mv ~/.bashrc_shani ~/.bashrc` and would clobber it on next login;
#   - plasma-setup.service is enabled and its completion flag is absent, i.e.
#     the condition that re-arms user creation after a reset holds;
#   - NEGATIVE CONTROL: removing the never-overwrite guard from the live
#     script really does clobber the user's file, so the check above is not
#     vacuous.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }

svc=shani-user-setup.service
SCRIPT=/usr/local/bin/shani-user-setup
PROFILE=$(cat /etc/shani-profile 2>/dev/null || echo unknown)

# Wait for the service (and anything it re-triggered) to finish. Fixed sleeps
# were too short once several users each took seconds.
# When a check fails here, the reason is almost always in the unit's journal
# and nowhere else. Both of this file's real defects were found by reading it,
# and the first version had no way to read it at all - so three failures came
# back as bare verdicts with no cause attached, which is the worst possible
# form of a failing test. Unconditional: journal lines are cheap next to the
# multi-minute boot they came from.
dump_journal() {
  local unit="$1"
  echo "  -- journal: $unit --"
  journalctl -u "$unit" -n 40 --no-pager 2>/dev/null | sed 's/^/     /'
  echo "  -- result: $unit Result=$(systemctl show -p Result --value "$unit" 2>/dev/null)"
}

settle() {
  local i quiet=0
  for (( i=0; i<120 && quiet<4; i++ )); do
    if [[ $(systemctl is-active "$svc") == activ* ]] || systemctl list-jobs --no-legend 2>/dev/null | grep -q "$svc"; then
      quiet=0
    else
      quiet=$((quiet + 1))
    fi
    sleep 1
  done
}

echo "== profile: $PROFILE; systemd: $(systemctl --version | head -1)"

# ══ 1. What shani-reset tells the user ═══════════════════════════════════════
# --dry-run --yes is the same code path through the messaging; only the wipe is
# skipped. --yes is required or it blocks on a prompt with no tty to answer.
echo "== shani-reset --dry-run output"
DRY=$(shani-reset --dry-run --yes 2>&1)

# plasma-welcome is NOT what creates the account. shani-desktop-plasma.install
# enables plasmalogin.service and plasma-setup.service; plasma-welcome is an
# in-session tips app and is referenced nowhere else in the workspace. Naming
# it sent the reader looking for a wizard that never runs.
# The message is profile-aware, so the assertion has to be too. Checking only
# for 'plasma-setup' made this check pass on plasma and fail on gnome - where
# naming the KDE wizard would have been the actual bug. The right wizard per
# profile is the one shani-reset.sh itself resolves.
case "$PROFILE" in
  plasma)  WANT_WIZARD='plasma-setup' ;;
  cosmic)  WANT_WIZARD='cosmic-initial-setup' ;;
  *)       WANT_WIZARD='gnome-initial-setup' ;;
esac
if printf '%s' "$DRY" | grep -q 'plasma-welcome'; then
  res reset-names-no-wrong-wizard "FAIL (output still names plasma-welcome)"
elif printf '%s' "$DRY" | grep -q "$WANT_WIZARD"; then
  res reset-names-no-wrong-wizard PASS
else
  res reset-names-no-wrong-wizard "FAIL (names neither wizard; profile=$PROFILE want=$WANT_WIZARD)"
fi

# And the sharpest form of it: name a wizard belonging to ANOTHER profile and
# the message is wrong, however plausible it reads. plasma-welcome above is
# one instance of this; the cross-profile case is the general one.
foreign=""
for OTHER in plasma-setup cosmic-initial-setup gnome-initial-setup; do
  [[ "$OTHER" == "$WANT_WIZARD" ]] && continue
  if printf '%s' "$DRY" | grep -q "$OTHER"; then foreign="$foreign $OTHER"; fi
done
# One result, not one per wizard examined. The loop above emitted three rows
# sharing a name, so a run where one foreign wizard was named and another was
# not produced two identically-labelled rows with different verdicts - and a
# summary that cannot tell them apart is worse than no check.
if [[ -n "$foreign" ]]; then
  res reset-names-only-this-profiles-wizard \
     "FAIL (profile=$PROFILE wants $WANT_WIZARD, but also names:$foreign)"
else
  res reset-names-only-this-profiles-wizard PASS
fi

# The account is gone from /etc, and so is the root password, because both
# lived in the same overlay. Saying only "users must be re-created" is what
# let someone conclude they could log in and fix it themselves.
if printf '%s' "$DRY" | grep -qi 'no user account'; then
  res reset-states-no-account-survives PASS
else
  res reset-states-no-account-survives "FAIL (does not say the account is gone)"
fi

if printf '%s' "$DRY" | grep -qi 'not even root'; then
  res reset-warns-root-is-gone-too PASS
else
  res reset-warns-root-is-gone-too "FAIL (no mention of root)"
fi

# ══ 2. The wizard that creates the account is armed ═════════════════════════
echo "== first-boot wizard reachability"
if systemctl is-enabled plasma-setup.service >/dev/null 2>&1; then
  res plasma-setup-enabled PASS
else
  # Not a failure on a non-plasma profile: gnome-initial-setup is a per-user
  # app with no system unit to enable. Reported so the state is on the record.
  [[ "$PROFILE" == plasma ]] \
    && res plasma-setup-enabled "FAIL (enabled on the plasma profile)" \
    || res plasma-setup-enabled "SKIP (profile=$PROFILE, no system unit to enable)"
fi

# The guard is ConditionPathExists=!/etc/plasma-setup-done, and that flag lives
# in the /etc overlay upper — which is exactly what a reset deletes. So the
# condition must hold after a reset. If the flag were baked into the read-only
# root instead, the wizard would never re-arm and a reset would be a one-way
# trip on the plasma profile.
if [[ -e /etc/plasma-setup-done ]]; then
  res wizard-rearms-after-reset "FAIL (/etc/plasma-setup-done exists — reset would not clear it)"
elif printf '%s' "$DRY" | grep -qi 'plasma-setup-done'; then
  res wizard-rearms-after-reset PASS
else
  # Non-plasma profile: nothing to assert about this flag.
  res wizard-rearms-after-reset "SKIP (profile=$PROFILE)"
fi

# ══ 3. shani-user-setup seeds skel into an EXISTING home ═══════════════════
# This is the whole point. useradd -m only copies /etc/skel when it CREATES a
# home; after a reset the home survives in @home and the account is created
# onto it, so without this pass the user lands on an empty-looking home.
echo "== skel seeding through the real marker"
# Diagnostic first. seed_skel() returns immediately when /etc/skel is absent,
# and without this the two checks below would both fail for a reason that has
# nothing to do with the code under test.
if [[ -d /etc/skel ]] && [[ -n "$(ls -A /etc/skel 2>/dev/null)" ]]; then
    res skel-dir-is-populated PASS
else
    res skel-dir-is-populated "FAIL (/etc/skel missing or empty - seed_skel cannot run)"
fi
U=skelprobe
userdel -rf "$U" 2>/dev/null
useradd -m -s /bin/zsh "$U" 2>&1 | head -2
H=$(getent passwd "$U" | cut -d: -f6)
echo "   home: $H"

if [[ -f "$H/.zshrc" ]]; then
  res useradd-copies-skel PASS
else
  res useradd-copies-skel "FAIL (.zshrc absent right after useradd -m)"
fi

# Delete a skel file to simulate a home that never received the defaults, and
# edit another to prove the pass is add-only.
rm -f "$H/.inputrc"
printf '# EDITED BY THE USER\n' > "$H/.bashrc"

# The first-login pair must be REMOVED before the check about it means
# anything. `useradd -m` already copied it out of /etc/skel, so on a freshly
# created home the pair is present from the start, and asserting "the pair is
# absent" then tests only the fact that skel contains it — which is why the
# first run of this file reported a failure for a file it had never removed.
# The condition under test is "a home that already has a .bashrc and no
# pending first-login pair", which only exists once the pair is taken away.
rm -f "$H/.bashrc_shani" "$H/.config/autostart/bashrc-setup.desktop"

# Settle FIRST. `useradd` above changes /etc/passwd, which is itself one of
# this unit's triggers, so the service was already running when the timestamp
# was sampled and the comparison below was racing a run in flight - it read the
# same timestamp both times and called a real trigger a failure.
rm -f /data/user-setup-needed
settle
before=$(systemctl show -p ExecMainStartTimestampMonotonic --value "$svc")
touch /data/user-setup-needed
# Wait for the marker to be CONSUMED, not for a fixed interval. The service
# does real work per user (skel walk, runuser for the flatpak remote, subuid
# ranges) and ExecStartPost is what removes the marker, so a fixed sleep can
# sample before that work is done - which is how the first run reported
# "marker still present" for a service that simply had not finished.
_waited=0
while [[ -e /data/user-setup-needed ]] && (( _waited < 90 )); do
  sleep 1
  _waited=$(( _waited + 1 ))
done
settle
after=$(systemctl show -p ExecMainStartTimestampMonotonic --value "$svc")

if [[ "$after" != "$before" ]]; then
  res marker-triggers-the-service PASS
else
  res marker-triggers-the-service "FAIL ($before -> $after)"
fi

if [[ ! -e /data/user-setup-needed ]]; then
  res marker-is-consumed PASS
else
  res marker-is-consumed "FAIL (marker still present after ${_waited}s)"
fi
dump_journal "$svc"
# Reported, not asserted. This unit writes into user homes (the stamp, the
# skel pass, the flatpak remote) and ProtectHome=yes makes /home read-only for
# it, which would make every one of those writes fail while the unit still
# exited 0 - each failure being a `|| warn`. That is exactly the shape of the
# three failures below, so the setting is printed where the symptom is.
echo "     sandbox: ProtectHome=$(systemctl show -p ProtectHome --value "$svc" 2>/dev/null)"
echo "     sandbox: Result=$(systemctl show -p Result --value "$svc" 2>/dev/null) ExecMainStatus=$(systemctl show -p ExecMainStatus --value "$svc" 2>/dev/null)"

if [[ -f "$H/.inputrc" ]]; then
  res missing-skel-file-is-seeded PASS
else
  res missing-skel-file-is-seeded "FAIL (.inputrc not seeded into an existing home)"
fi

if [[ "$(cat "$H/.bashrc" 2>/dev/null)" == "# EDITED BY THE USER" ]]; then
  res user-file-is-never-reverted PASS
else
  res user-file-is-never-reverted "FAIL (.bashrc was overwritten)"
fi

# The destructive case. bashrc-setup.desktop runs
#   mv ~/.bashrc_shani ~/.bashrc; rm <itself>
# so seeding the pair into a home that already has a .bashrc would replace it on
# the next graphical login — from a pass whose whole contract is that it cannot
# touch what the user has.
if [[ -e "$H/.bashrc_shani" || -e "$H/.config/autostart/bashrc-setup.desktop" ]]; then
  res first-login-pair-not-seeded-over-bashrc "FAIL (the mv-on-login pair was seeded anyway)"
else
  res first-login-pair-not-seeded-over-bashrc PASS
fi

# ══ 4. NEGATIVE CONTROL ════════════════════════════════════════════════════
# Break the never-overwrite guard in the LIVE script and confirm the check
# above stops being true. Without this, "user-file-is-never-reverted" could be
# passing because the seeding never ran at all — which is exactly what the
# first version of this file did, and exactly what it reported as a pass.
echo "== negative control: remove the never-overwrite guard"
if [[ ! -f "$SCRIPT" ]]; then
  res nc-overwrite-guard-is-load-bearing "FAIL ($SCRIPT not found)"
else
  cp -a "$SCRIPT" "$SCRIPT.nc.bak"
  # Escaped brackets: this sed treats an unescaped '[' as a bracket expression.
  sed -i 's/if \[\[ -e "\$_dst" \]\]; then/if false; then/' "$SCRIPT"
  if grep -q 'if false; then' "$SCRIPT"; then
    printf 'zsh default\n' > /etc/skel/.ncmarker
    chmod 0644 /etc/skel/.ncmarker
    printf 'sentinel\n' > "$H/.zshrc"
    touch /data/user-setup-needed
    sleep 2; settle
    if [[ "$(cat "$H/.zshrc" 2>/dev/null)" != "sentinel" ]]; then
      res nc-overwrite-guard-is-load-bearing PASS
    else
      res nc-overwrite-guard-is-load-bearing "FAIL (guard removed, file still intact — the check above may be vacuous)"
    fi
    rm -f /etc/skel/.ncmarker
  else
    res nc-overwrite-guard-is-load-bearing "FAIL (guard pattern not found — control cannot run)"
  fi
  mv -f "$SCRIPT.nc.bak" "$SCRIPT"
  # Prove the restore actually happened rather than assuming it.
  if grep -q 'if \[\[ -e "\$_dst" \]\]; then' "$SCRIPT"; then
    res nc-script-restored PASS
  else
    res nc-script-restored "FAIL (script left mutated — this slot is now untrustworthy)"
  fi
fi

# ══ 5. The stranding repair, against a real orphaned home ══════════════════
# This is the branch that used to have no answer at all. A plain shani-reset on
# the gnome profile leaves a machine with no account AND a gnome-initial-setup
# that still believes it ran, because its "already done" flag lives in the
# user's dconf database inside @home — the one directory a reset does not touch.
#
# The home below is built to be genuinely orphaned: owned by a uid that has no
# /etc/passwd entry, carrying a REAL gvdb database written by dconf (a text
# fixture would be declared corrupt and moved aside, which would make the test
# pass for the wrong reason — that was the first version of this check).
echo "== stranding repair (shani-first-boot)"

# Section 3 above creates a regular account (`skelprobe`) to test skel seeding,
# and it is still in /etc/passwd here. shani-first-boot's very first act is to
# look for a regular account and exit if it finds one - so the stray home below
# was repaired by a script that correctly decided the machine was NOT stranded.
# Every check in this section then reported the healthy-machine behaviour as if
# it were the stranded-machine behaviour, and the one that mattered most
# (`firstuse-guard-is-cleared`) failed for a reason that had nothing to do with
# the repair.
#
# The precondition is therefore established explicitly rather than assumed, and
# asserted: if an account survives here, the whole section is invalid and says
# so instead of quietly producing wrong verdicts.
# userdel refuses while anything runs as the account, and the service above has
# just been `runuser`-ing into it. `|| true` hid that: the entry survived, the
# stranding section below then found a "healthy" machine, and three checks
# reported the healthy path as the stranded one.
#
# SIGKILL plus a real wait, because SIGTERM to a process the service spawned
# seconds earlier is a race, and a lost race here costs a whole 12-minute boot.
# userdel's own stderr is kept and reported: the previous version discarded it,
# so `userdel could not remove skelprobe (8)` was the entire evidence available
# and 8 is not a self-explanatory code.
#
# Never a `|| echo 0` fallback on the uid. `pkill -u 0` means "every process
# owned by root" - it would kill the harness, the slot shell, and this script,
# turning a bookkeeping bug into a mysterious truncated run.
probe_uid=$(id -u skelprobe 2>/dev/null || echo "")
if [[ -n "$probe_uid" ]]; then
    loginctl terminate-user skelprobe 2>/dev/null || true
    pkill -KILL -u "$probe_uid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        getent passwd skelprobe >/dev/null || break
        ps -o pid= -u "$probe_uid" >/dev/null 2>&1 || break
        pkill -KILL -u "$probe_uid" 2>/dev/null || true
        sleep 1
    done
    userdel -r skelprobe 2>/tmp/opencode-userdel.err || \
        userdel skelprobe 2>>/tmp/opencode-userdel.err
fi
rm -rf "/home/skelprobe" 2>/dev/null || true

regular_accounts=$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $7 !~ /(nologin|false|sync|halt|shutdown)$/{print $1}')
if [[ -z "$regular_accounts" ]]; then
    res stranded-precondition-no-account PASS
else
    survivors=""
    if [[ -n "$probe_uid" ]]; then
        survivors=$(ps -o pid=,comm= -u "$probe_uid" 2>/dev/null | tr '\n' ' ')
    fi
    # Also whether the home is a mountpoint. On this OS homes can be Btrfs
    # subvolumes, and `userdel -r` refuses to remove an account whose home it
    # cannot delete - which presents as the same refusal a busy process causes.
    hm="no"
    mountpoint -q /home/skelprobe 2>/dev/null && hm="YES (a mountpoint)"
    res stranded-precondition-no-account \
       "FAIL (accounts present: $regular_accounts; home is a mountpoint: $hm; uid $probe_uid processes: ${survivors:-none}; userdel said: $(tr '\n' ' ' </tmp/opencode-userdel.err 2>/dev/null))"
fi

STRAY_UID=3999
STRAY_HOME=/home/stranded
rm -rf "$STRAY_HOME"
mkdir -p "$STRAY_HOME/.config"
chown -R "$STRAY_UID:$STRAY_UID" "$STRAY_HOME"

# Write a real first-run flag plus an unrelated setting that MUST survive.
# This runs as ROOT with HOME pointed at the stray home, NOT via `setpriv` to
# the stray uid. That is not a style choice: dbus-daemon resolves its own uid
# with getpwuid() while starting and aborts when there is no entry, and this
# home's owner deliberately has none. Doing it the obvious way produced, on
# the first run of this file:
#   dbus[1440]: Could not get password database information for UID of current
#   process: Looking up user ID 3999: not found
#   dbus[1440]: Failed to start message bus
# and every assertion downstream then compared that error text instead of a
# dconf answer. The product script hit exactly the same wall; both are fixed
# the same way.
as_stray() {
    HOME="$STRAY_HOME" XDG_CONFIG_HOME="$STRAY_HOME/.config" \
    XDG_CACHE_HOME="$STRAY_HOME/.cache" \
        dbus-run-session -- dconf "$@" 2>&1 \
        | grep -vE 'dbus\[|dbus-run-session|dconf-WARNING'
}
as_stray write /org/gnome/desktop/firstuse/gnome-initial-setup true
as_stray write /org/gnome/desktop/interface/color-scheme "'prefer-dark'"

pre_flag=$(as_stray read /org/gnome/desktop/firstuse/gnome-initial-setup)
pre_scheme=$(as_stray read /org/gnome/desktop/interface/color-scheme)
if [[ "$pre_flag" == "true" && -n "$pre_scheme" ]]; then
    res stranded-fixture-is-real PASS
else
    res stranded-fixture-is-real "FAIL (flag='$pre_flag' scheme='$pre_scheme' — dconf did not take)"
fi

# Run it the way the machine would: as the unit's ExecStart.
if /usr/local/bin/shani-first-boot >/tmp/firstboot.log 2>&1; then
    res first-boot-runs-cleanly PASS
else
    res first-boot-runs-cleanly "FAIL (log: $(tail -5 /tmp/firstboot.log | tr '\n' ' '))"
fi
echo "     log: $(tail -6 /tmp/firstboot.log 2>/dev/null | tr '\n' '|')"

post_flag=$(as_stray read /org/gnome/desktop/firstuse/gnome-initial-setup)
post_scheme=$(as_stray read /org/gnome/desktop/interface/color-scheme)
if [[ -z "$post_flag" ]]; then
    res firstuse-guard-is-cleared PASS
else
    res firstuse-guard-is-cleared "FAIL (still '$post_flag' — the wizard would stay silent)"
fi
# The scope half. A reset wide enough to also clear this would be a data-loss
# bug that still satisfies every check above.
if [[ "$post_scheme" == "$pre_scheme" && -n "$post_scheme" ]]; then
    res unrelated-settings-survive-the-repair PASS
else
    res unrelated-settings-survive-the-repair "FAIL ('$pre_scheme' -> '$post_scheme')"
fi

# And the healthy-system path: with a real account present the script must do
# nothing at all. Its own unit test covers the gate; here it is checked against
# this slot's real /etc/passwd, where an account does exist.
# The account is created here rather than inherited, because the section above
# now has to delete every account to be valid - so this half needs one back,
# and asking a leftover to provide it couples two unrelated checks.
useradd -m -s /bin/bash healthyprobe 2>/dev/null
if getent passwd healthyprobe >/dev/null; then
    res healthy-precondition-account-exists PASS
    out=$(/usr/local/bin/shani-first-boot 2>&1)
    if printf '%s' "$out" | grep -q "an account exists"; then
        res healthy-system-is-left-alone PASS
    else
        res healthy-system-is-left-alone "FAIL (a real account exists but the script said: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120))"
    fi
    userdel -r healthyprobe 2>/dev/null || true
else
    skip "healthy-system-is-left-alone" "this slot has no regular account to be healthy about"
fi

# NEGATIVE CONTROL: widen the reset in the live script and confirm the scope
# check above is real. Without this, "unrelated settings survive" would pass
# just as well against a reset that wipes the whole desktop subtree — which is
# precisely the destructive version of this repair.
echo "== negative control: widen the dconf reset"
FB=/usr/local/bin/shani-first-boot
if [[ ! -f "$FB" ]]; then
    res nc-reset-scope-is-load-bearing "FAIL ($FB not found)"
else
    cp -a "$FB" "$FB.nc.bak"
    sed -i 's#/org/gnome/desktop/firstuse/#/org/gnome/desktop/#' "$FB"
    if grep -q 'dconf reset -f /org/gnome/desktop/' "$FB"; then
        # Re-seed the innocent setting the widened reset is about to eat.
        as_stray write /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
        before_wide=$(as_stray read /org/gnome/desktop/interface/color-scheme)
        "$FB" >/dev/null 2>&1
        after_wide=$(as_stray read /org/gnome/desktop/interface/color-scheme)
        if [[ "$before_wide" == "$after_wide" ]]; then
            res nc-reset-scope-is-load-bearing "FAIL (widened reset changed nothing — the scope check may be vacuous)"
        else
            res nc-reset-scope-is-load-bearing PASS
        fi
    else
        res nc-reset-scope-is-load-bearing "FAIL (guard pattern not found — control cannot run)"
    fi
    mv -f "$FB.nc.bak" "$FB"
    if grep -q 'dconf reset -f /org/gnome/desktop/firstuse/' "$FB"; then
        res nc-script-restored PASS
    else
        res nc-script-restored "FAIL (script left widened — this slot is now untrustworthy)"
    fi
fi

rm -rf "$STRAY_HOME"
userdel -rf "$U" 2>/dev/null
echo "== done"
