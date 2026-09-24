#!/bin/bash
# slot-test-mode: boot
#
# boot-health — every unit that failed in this boot is either on the list
# of failures systemd-nspawn itself causes (each with the evidence that
# proved it), or it is reported as a real failure. `systemctl
# is-system-running` alone says "degraded" in every nspawn boot, which hides
# a new failure among the expected ones.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }

# unit glob -> reason (and the log line that proved it, 2026-09-24).
# Not here on purpose: beesd@ (the harness now makes /dev/disk/by-uuid, so
# it runs) and shani-user-setup.path (the harness now mounts /etc as the
# real overlay) - both used to fail only because of the harness.
declare -A EXPECTED=(
  ['auditd.service']='no audit netlink in nspawn ("start-limit-hit")'
  ['audit-rules.service']='needs auditd'
  ['bless-boot.service']='"Marking a boot is not supported in containers."'
  ['systemd-bless-boot.service']='same as bless-boot'
)

sleep 5
state=$(systemctl is-system-running 2>/dev/null)
echo "== system state: ${state}"
mapfile -t failed < <(systemctl --failed --no-legend --plain | awk '{print $1}')
unexpected=0
for u in "${failed[@]}"; do
  [[ -n "$u" ]] || continue
  why=""
  for pat in "${!EXPECTED[@]}"; do
    # shellcheck disable=SC2053  # glob match is intended
    [[ "$u" == $pat ]] && { why="${EXPECTED[$pat]}"; break; }
  done
  if [[ -n "$why" ]]; then
    echo "   expected under nspawn: ${u} - ${why}"
  else
    unexpected=$((unexpected + 1))
    echo "   UNEXPECTED: ${u}"
    journalctl -b -u "$u" -o cat --no-pager 2>/dev/null | grep -v '^$' | tail -4 | sed 's/^/      /'
  fi
done
(( unexpected == 0 )) && res no-unexpected-failed-units "PASS (${#failed[@]} failed, all nspawn-only)" \
  || res no-unexpected-failed-units "FAIL (${unexpected} unexpected)"

# NEGATIVE control: a unit that really fails must be reported
systemd-run --unit=boot-health-negctl --service-type=oneshot /bin/false >/dev/null 2>&1
sleep 1
systemctl --failed --no-legend --plain | grep -q '^boot-health-negctl' \
  && res negative-control-detected PASS || res negative-control-detected FAIL
systemctl reset-failed boot-health-negctl 2>/dev/null
echo "== probe done"
