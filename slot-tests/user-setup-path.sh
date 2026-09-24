#!/bin/bash
# slot-test-mode: boot
# slot-test-needs: --local-src=/opt/shani-deploy/scripts
#
# user-setup-path — shani-user-setup.path stays active after boot (no
# trigger-limit-hit); the /data/user-setup-needed marker and useradd still
# trigger shani-user-setup.service; a sync that fixes several users at once
# converges with the path unit alive; another spelling of the same zsh is not
# rewritten; re-adding the old PathExists= line reproduces the failure
# (negative control); shani-health --security's "Unit Sandboxing" works.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
svc=shani-user-setup.service; pth=shani-user-setup.path
runs() { journalctl -b -u "$svc" -q --no-pager -o cat | grep -c 'Starting\|Started\|Finished' ; }
# wait until the sync (and anything it re-triggered) is done: fixed sleeps
# were too short once a few users each took seconds (runuser, nix-channel)
settle() {
  local i quiet=0
  for (( i=0; i<120 && quiet<4; i++ )); do
    if [[ $(systemctl is-active "$svc") == activ* ]] || systemctl list-jobs --no-legend | grep -q "$svc"; then quiet=0; else quiet=$((quiet + 1)); fi
    sleep 1
  done
}

echo "== systemd: $(systemctl --version | head -1); state: $(systemctl is-system-running 2>&1)"
echo "== unit as loaded:"; systemctl cat "$pth" | grep -E '^Path|^Trigger'
sleep 5
st=$(systemctl is-active "$pth"); echo "   $pth is-active after boot: $st"
[[ "$st" == active ]] && res path-active-after-boot PASS || res path-active-after-boot "FAIL ($st)"
journalctl -b -u "$pth" -q --no-pager | grep -q 'trigger-limit-hit' && res no-trigger-limit-hit FAIL || res no-trigger-limit-hit PASS

echo "== marker trigger (/data/user-setup-needed)"
before=$(systemctl show -p NRestarts,ExecMainStartTimestampMonotonic --value "$svc" | tail -1)
touch /data/user-setup-needed; sleep 2; settle
after=$(systemctl show -p ExecMainStartTimestampMonotonic --value "$svc")
[[ "$after" != "$before" && ! -e /data/user-setup-needed ]] && res marker-triggers-and-consumed PASS \
    || res marker-triggers-and-consumed "FAIL (before=$before after=$after marker=$( [[ -e /data/user-setup-needed ]] && echo present || echo gone))"

echo "== useradd trigger (PathChanged= on upper passwd)"
before=$(systemctl show -p ExecMainStartTimestampMonotonic --value "$svc")
useradd -m probeuser 2>&1; sleep 2; settle
after=$(systemctl show -p ExecMainStartTimestampMonotonic --value "$svc")
[[ "$after" != "$before" ]] && res useradd-triggers-setup PASS || res useradd-triggers-setup "FAIL ($before -> $after)"
userdel -rf probeuser 2>/dev/null; sleep 2; settle
st=$(systemctl is-active "$pth"); [[ "$st" == active ]] && res path-still-active-after-changes PASS || res path-still-active-after-changes "FAIL ($st)"

echo "== marker with users the sync must change (what every deploy leaves)"
# found by `gate` after a real upgrade (the path unit died of
# trigger-limit-hit): 6 users created and changed in a row, then the marker,
# must converge with the path unit alive
CONV_USERS=(conv1 conv2 conv3 conv4 conv5 conv6)
conv() {  # <label> — users with the wrong shell + the marker; path must survive
  local u n=${#CONV_USERS[@]}
  for u in "${CONV_USERS[@]}"; do useradd -m -s /bin/sh "$u" 2>/dev/null || usermod -s /bin/sh "$u"; done
  settle; systemctl reset-failed "$pth" "$svc" 2>/dev/null; systemctl restart "$pth"; sleep 2
  for u in "${CONV_USERS[@]}"; do usermod -s /bin/sh "$u"; done
  touch /data/user-setup-needed; sleep 2; settle
  CONV_STATE=$(systemctl is-active "$pth")
  CONV_FIXED=0; for u in "${CONV_USERS[@]}"; do [[ $(getent passwd "$u" | cut -d: -f7) == */zsh || $(getent passwd "$u" | cut -d: -f7) == */bash ]] && CONV_FIXED=$((CONV_FIXED + 1)); done
  echo "   $1: path=$CONV_STATE, users fixed=$CONV_FIXED/$n, runs=$(journalctl -u "$svc" -q --no-pager --since '-50s' -o cat | grep -c '^Starting')"
}
conv "as shipped"
[[ $CONV_STATE == active && $CONV_FIXED == ${#CONV_USERS[@]} ]] && res marker-with-changes-converges PASS \
    || res marker-with-changes-converges "FAIL (path=$CONV_STATE fixed=$CONV_FIXED/${#CONV_USERS[@]})"
# (no burst-3 negative control: whether 3 triggers suffice depends on how
# systemd coalesces the passwd events - it died in 1 of 3 runs of exactly
# this scenario, so such a control would be flaky)
echo "== another spelling of the same shell is not a change (/usr/sbin merge)"
# /bin/zsh, /usr/sbin/zsh and /usr/bin/zsh are one binary; comparing names
# rewrote passwd on every run, and every rewrite re-triggered the path unit
zsh_real=$(realpath -e "$(command -v zsh)" 2>/dev/null)
if [[ -n $zsh_real ]]; then
  # path unit off, so the one explicit run below is the only one acting;
  # one full run first, so nothing but the shells could still need a change
  settle; systemctl stop "$pth"; systemctl start "$svc"; settle
  usermod -s /bin/zsh conv1; usermod -s /usr/sbin/zsh conv2; usermod -s "$zsh_real" conv3
  ino=$(stat -c %i:%Y /data/overlay/etc/upper/passwd)
  systemctl start "$svc"; settle
  [[ $(stat -c %i:%Y /data/overlay/etc/upper/passwd) == "$ino" ]] && res alias-shell-no-rewrite PASS \
      || res alias-shell-no-rewrite "FAIL (passwd rewritten: $(getent passwd conv1 conv2 | cut -d: -f7 | tr '\n' ' '))"
  # NEGATIVE control for that detector: a real change must show as a rewrite
  usermod -s /bin/sh conv1
  ino=$(stat -c %i:%Y /data/overlay/etc/upper/passwd)
  systemctl start "$svc"; settle
  [[ $(stat -c %i:%Y /data/overlay/etc/upper/passwd) != "$ino" ]] && res rewrite-detector-control PASS \
      || res rewrite-detector-control "FAIL (a needed change was not seen)"
  systemctl reset-failed "$pth" 2>/dev/null; systemctl start "$pth"
fi
for u in "${CONV_USERS[@]}"; do userdel -rf "$u" 2>/dev/null; done
systemctl reset-failed "$pth" "$svc" 2>/dev/null; systemctl restart "$pth"; sleep 8

echo "== NEGATIVE control: re-add the old PathExists= line"
D=/run/systemd/system/$pth.d; mkdir -p "$D"
printf '[Path]\nPathExists=/data/overlay/etc/upper/passwd\n' > "$D/zz-old.conf"
systemctl daemon-reload; systemctl restart "$pth"; sleep 10
st=$(systemctl is-active "$pth"); echo "   with old line: $st"
journalctl -u "$pth" -q --no-pager --since '-30s' | grep -o "Failed with result '[a-z-]*'" | tail -1
[[ "$st" == failed ]] && res old-line-reproduces-failure PASS || res old-line-reproduces-failure "FAIL ($st)"
rm -f "$D/zz-old.conf"; rmdir "$D"; systemctl daemon-reload
systemctl reset-failed "$pth" "$svc" 2>/dev/null; systemctl restart "$pth"; sleep 5
st=$(systemctl is-active "$pth"); [[ "$st" == active ]] && res restored-after-control PASS || res restored-after-control "FAIL ($st)"

echo "== shani-health --security: Unit Sandboxing"
out=$(shani-health --security 2>&1)
echo "$out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n '/Unit Sandboxing/,/^  *[A-Z][a-z]* [A-Z]/p' | head -16
echo "$out" | grep -q 'Unit Sandboxing' && res security-section-present PASS || res security-section-present FAIL
n=$(echo "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -cE '(shani-|mark-boot-|check-boot-failure|bless-boot|beesd-setup|flatpak-update-system).*[0-9]+\.[0-9] (SAFE|OK|MEDIUM|EXPOSED|UNSAFE)')
(( n >= 5 )) && res security-rows-scored "PASS ($n units)" || res security-rows-scored "FAIL ($n)"
shani-health --security --json 2>/dev/null | jq -e '[.checks[] | select(.section=="unit_exposure")] | length > 0' >/dev/null \
    && res security-json-has-section PASS || res security-json-has-section FAIL
echo "== probe done"
