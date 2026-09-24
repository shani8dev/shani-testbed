#!/bin/bash
# slot-test-mode: boot
# slot-test-needs: --local-src=/opt/shani-deploy/scripts
#
# user-setup-path — shani-user-setup.path stays active after boot (no
# trigger-limit-hit), the /data/user-setup-needed marker and useradd still
# trigger shani-user-setup.service, re-adding the old PathExists= line
# reproduces the failure (negative control), and shani-health --security's
# "Unit Sandboxing" section works.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
svc=shani-user-setup.service; pth=shani-user-setup.path
runs() { journalctl -b -u "$svc" -q --no-pager -o cat | grep -c 'Starting\|Started\|Finished' ; }

echo "== systemd: $(systemctl --version | head -1); state: $(systemctl is-system-running 2>&1)"
echo "== unit as loaded:"; systemctl cat "$pth" | grep -E '^Path|^Trigger'
sleep 5
st=$(systemctl is-active "$pth"); echo "   $pth is-active after boot: $st"
[[ "$st" == active ]] && res path-active-after-boot PASS || res path-active-after-boot "FAIL ($st)"
journalctl -b -u "$pth" -q --no-pager | grep -q 'trigger-limit-hit' && res no-trigger-limit-hit FAIL || res no-trigger-limit-hit PASS

echo "== marker trigger (/data/user-setup-needed)"
before=$(systemctl show -p NRestarts,ExecMainStartTimestampMonotonic --value "$svc" | tail -1)
touch /data/user-setup-needed; sleep 6
after=$(systemctl show -p ExecMainStartTimestampMonotonic --value "$svc")
[[ "$after" != "$before" && ! -e /data/user-setup-needed ]] && res marker-triggers-and-consumed PASS \
    || res marker-triggers-and-consumed "FAIL (before=$before after=$after marker=$( [[ -e /data/user-setup-needed ]] && echo present || echo gone))"

echo "== useradd trigger (PathChanged= on upper passwd)"
before=$(systemctl show -p ExecMainStartTimestampMonotonic --value "$svc")
useradd -m probeuser 2>&1; sleep 6
after=$(systemctl show -p ExecMainStartTimestampMonotonic --value "$svc")
[[ "$after" != "$before" ]] && res useradd-triggers-setup PASS || res useradd-triggers-setup "FAIL ($before -> $after)"
userdel -r probeuser 2>/dev/null; sleep 6
st=$(systemctl is-active "$pth"); [[ "$st" == active ]] && res path-still-active-after-changes PASS || res path-still-active-after-changes "FAIL ($st)"

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
