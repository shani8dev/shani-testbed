#!/bin/bash
# slot-test-mode: boot
#
# Can systemd 262 sign a fleet report with the TPM2 on this machine?
#
# WHY THIS FILE EXISTS. `shani-fleet`'s agent has an experimental spike that
# reads a systemd report over Varlink and, in its own words, calls the signed
# form "the only path that gives an attestable report, which is the point of
# this for fleet management". It was written against systemd 261.3, where the
# comment records: it ships `systemd-report-basic.socket` and
# `systemd-report-cgroup.socket` but NOT `systemd-report.socket` - "so on 261.x
# this frontend socket does not exist and the field is always null".
#
# systemd 262 - which Shanios ships - DOES ship `systemd-report.socket`, and a
# family of signers including `systemd-report-sign-tpm2.socket`. That socket
# carries `ConditionSecurity=measured-uki`, so TPM2 signing only activates on a
# measured-UKI boot. Shanios builds UKIs with dracut and enforces Secure Boot
# via gen-efi, so it is one of the few desktops that could satisfy it.
#
# Every one of those claims was read off a package file or a comment. None of
# them was observed on a booted machine, which is what this is for.
#
# NOTE this is deliberately NOT the nspawn path: an nspawn slot bind-mounts the
# host's resolv.conf and is not a UEFI boot, so `ConditionSecurity=measured-uki`
# cannot be meaningfully evaluated there. Run it under:
#   iso-install --boot-only \
#     --console-put=slot-tests/systemd-report-signing.sh:/root/sr.sh \
#     --console-exec='bash /root/sr.sh'

export PATH=/usr/bin:/usr/sbin:/bin:/sbin

result() { printf 'RESULT %-40s %s (%s)\n' "$2" "$1" "$3"; }
note()  { printf 'DETAIL  %s\n' "$1"; }

echo "### systemd-report signing: starting at $(date -Is)"
SDVER=$(systemctl --version | head -1)
note "systemd: $SDVER"

# --- 1. is the aggregator even present? ------------------------------------
# NOT on PATH, same trap as systemd-measure: it lives in /usr/lib/systemd.
AGG=$(command -v systemd-report || true)
[[ -z $AGG ]] && [[ -x /usr/lib/systemd/systemd-report ]] && AGG=/usr/lib/systemd/systemd-report
if [[ -n $AGG ]]; then
  result PASS "sr-aggregator-present" "$AGG"
else
  result FAIL "sr-aggregator-present" "no systemd-report binary found"
fi

# --- 2. the units, and whether anything enabled them -----------------------
for u in systemd-report.socket systemd-report-sign-tpm2.socket; do
  path=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null)
  en=$(systemctl is-enabled "$u" 2>&1)
  st=$(systemctl is-active "$u" 2>&1)
  note "$u: enabled=$en active=$st path=${path:-none}"
  # Shipped-but-disabled is the correct posture for an experimental attestation
  # path and is NOT a failure; it is reported so a future enable is deliberate.
  if [[ $en == enabled || $en == enabled-runtime ]]; then
    result PASS "sr-enabled-$u" "enabled and active=$st"
  else
    result SKIP "sr-enabled-$u" "not enabled ($en) - the fleet spike stays dormant"
  fi
done

# --- 3. the condition that actually gates TPM2 signing ---------------------
# ConditionSecurity=measured-uki is evaluated against the kernel's EFI
# measurement result, so the evidence is the securityfs layout plus
# /sys/kernel/security/lockdown - NOT anything a package file claims.
SEC=$(ls -d /sys/kernel/security 2>/dev/null)
if [[ -n $SEC ]]; then
  result PASS "sr-securityfs-present" "$SEC"
  for f in tpm0/binary_bpms measure/binary_policy_miss; do
    [[ -e $SEC/$f ]] && note "securityfs: $f present"
  done
  ls $SEC 2>/dev/null | tr '\n' ' ' | sed 's/^/  securityfs entries: /'
  echo
else
  result FAIL "sr-securityfs-present" "no /sys/kernel/security - cannot evaluate measured-uki"
fi
lock=$(cat /sys/kernel/security/lockdown 2>/dev/null)
note "lockdown: ${lock:-absent}"
[[ -e /dev/tpm0 ]] && result PASS "sr-tpm-device" "/dev/tpm0 present" \
                   || result SKIP "sr-tpm-device" "no /dev/tpm0 (swtpm is the test harness)"

# --- 4. does the UKI actually get measured? --------------------------------
# If the kernel was booted from a signed+measured UKI there is a per-arch
# measurement structure. Its absence with lockdown=none is not a defect; it
# just means nothing is being measured, which is the honest answer.
if [[ -e /sys/firmware/efi/efivars ]] || [[ -d /sys/firmware/efi ]]; then
  result PASS "sr-booted-via-efi" "EFI firmware present - UKI measurement is in scope"
else
  result SKIP "sr-booted-via-efi" "not an EFI boot; measured-uki cannot apply"
fi

# --- 5. what the agent would actually call, and whether the interface moved --
# This is the risk the release notes imply: 261 and 262 are not the same
# Varlink interface, and the agent's GenerateSigned signature was written
# against 261. Report what the interface looks like NOW so the comparison can be
# made from evidence rather than from the comment.
if [[ -S /run/systemd/io.systemd.Report ]]; then
  result PASS "sr-report-socket-live" "the frontend socket exists - the agent's guard would pass"
  if command -v varlinkctl >/dev/null 2>&1; then
    timeout 20 varlinkctl --more /run/systemd/io.systemd.Report introspect 2>&1 \
      | head -40 | sed 's/^/  /' | tee /tmp/sr-introspect.txt >/dev/null
    if grep -q "GenerateSigned" /tmp/sr-introspect.txt 2>/dev/null; then
      result PASS "sr-generatesigned-present" "GenerateSigned is still in the interface"
      grep -A3 "GenerateSigned" /tmp/sr-introspect.txt | sed 's/^/    /'
    else
      result FAIL "sr-generatesigned-present" \
        "GenerateSigned ABSENT - the agent's mode string may not match 262"
    fi
  else
    result SKIP "sr-generatesigned-present" "varlinkctl not installed; cannot introspect"
  fi
else
  result SKIP "sr-report-socket-live" \
    "socket absent - which is what the agent expects on a system without it"
fi

echo "### systemd-report signing: done"
exit 0
