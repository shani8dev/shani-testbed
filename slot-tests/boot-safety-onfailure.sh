#!/bin/bash
# slot-test-mode: boot
# slot-test-needs: --local-src=/opt/shani-deploy/scripts SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC=1
#
# boot-safety-onfailure — shani-deploy's OnFailure= wiring on the boot-safety
# units (shani-boot-safety-failed@.service) and shani-health --boot's
# "Safety units" / "Kernel crash" rows, in a real booted slot.
# Run: testbed slot-test blue boot-safety-onfailure --local-src=/opt/shani-deploy/scripts
#      (with SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC=1 until the template unit is packaged)
set -u
M=/data/boot_safety_failed
D=/run/systemd/system/check-boot-failure.service.d
res() { printf 'RESULT %-44s %s\n' "$1" "$2"; }

echo "== systemd: $(systemctl --version | head -1)"
for u in mark-boot-in-progress mark-boot-success check-boot-failure shani-auto-rollback bless-boot; do
    echo "   $u: $(systemctl show -p OnFailure --value $u.service)"
done
systemctl cat shani-boot-safety-failed@.service >/dev/null 2>&1 && res template-loaded PASS || res template-loaded FAIL
echo "== boot state: $(systemctl is-system-running 2>&1); failed units:"; systemctl --failed --no-legend

rm -f "$M"
had_bip=0; [[ -e /data/boot_in_progress ]] && had_bip=1
mkdir -p "$D"

run_cbf() {  # $1 = replacement ExecStart
    printf '[Service]\nExecStart=\nExecStart=%s\n' "$1" > "$D/zz-probe.conf"
    systemctl daemon-reload
    systemctl reset-failed check-boot-failure.service 'shani-boot-safety-failed@*' 2>/dev/null
    touch /data/boot_in_progress   # ConditionPathExists= of the unit
    systemctl start check-boot-failure.service; echo "   start rc=$?"
    sleep 3
}

echo "== NEGATIVE control: check-boot-failure succeeds (/bin/true)"
since=$(date '+%Y-%m-%d %H:%M:%S')
run_cbf /bin/true
[[ -e "$M" ]] && res neg-no-marker FAIL || res neg-no-marker PASS
n=$(journalctl -t shani-boot-safety --since "$since" -q --no-pager | wc -l)
[[ $n -eq 0 ]] && res neg-no-journal PASS || res neg-no-journal "FAIL ($n lines)"

echo "== POSITIVE: check-boot-failure fails (/bin/false)"
since=$(date '+%Y-%m-%d %H:%M:%S')
run_cbf /bin/false
systemctl status --no-pager 'shani-boot-safety-failed@check-boot-failure.service.service' 2>&1 | head -8
[[ -s "$M" ]] && grep -q 'check-boot-failure.service' "$M" && res pos-marker "PASS ($(cat "$M"))" || res pos-marker FAIL
journalctl -t shani-boot-safety --since "$since" -q --no-pager -p crit
journalctl -t shani-boot-safety --since "$since" -q --no-pager -p crit | grep -q 'check-boot-failure.service failed' \
    && res pos-journal-crit PASS || res pos-journal-crit FAIL

echo "== shani-health --boot with marker present"
out=$(shani-health --boot 2>&1); echo "$out" | grep -E 'Safety units|Kernel crash' || true
echo "$out" | grep -q 'Safety units.*failure(s) recorded' && res health-shows-marker PASS || res health-shows-marker FAIL

echo "== marker capped at 20 lines"
for i in $(seq 1 25); do systemctl start 'shani-boot-safety-failed@probe-cap.service.service' 2>/dev/null; done
lines=$(wc -l < "$M"); [[ $lines -eq 20 ]] && res marker-cap-20 PASS || res marker-cap-20 "FAIL ($lines)"

rm -f "$D/zz-probe.conf"; rmdir "$D" 2>/dev/null; systemctl daemon-reload
systemctl reset-failed check-boot-failure.service 'shani-boot-safety-failed@*' 2>/dev/null
rm -f "$M"; (( had_bip )) || rm -f /data/boot_in_progress

echo "== shani-health --boot with marker removed (negative)"
out=$(shani-health --boot 2>&1)
echo "$out" | grep -q 'Safety units' && res health-no-marker FAIL || res health-no-marker PASS

echo "== pstore row"
P=/var/lib/systemd/pstore; pre_existing=0; [[ -n "$(ls -A $P 2>/dev/null)" ]] && pre_existing=1
echo "   pstore pre-existing entries: $pre_existing"
out=$(shani-health --boot 2>&1)
if (( pre_existing == 0 )); then
    echo "$out" | grep -q 'Kernel crash' && res pstore-absent-no-row FAIL || res pstore-absent-no-row PASS
fi
mkdir -p "$P/1758000000000"; echo fake > "$P/1758000000000/dmesg.txt"
out=$(shani-health --boot 2>&1); echo "$out" | grep 'Kernel crash' || true
echo "$out" | grep -q 'Kernel crash.*1758000000000' && res pstore-present-row PASS || res pstore-present-row FAIL
rm -rf "$P/1758000000000"

echo "== shani-health --boot --json still valid"
shani-health --boot --json 2>/dev/null | jq -e . >/dev/null && res boot-json-valid PASS || res boot-json-valid FAIL
echo "== probe done"
