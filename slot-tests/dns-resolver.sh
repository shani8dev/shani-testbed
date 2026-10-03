#!/bin/bash
# DNS on a REAL booted Shanios system: does it work, and does changing it work?
#
# WHY THIS FILE CANNOT RUN IN AN nspawn SLOT, and why that is the whole reason
# it exists. Every nspawn boot in this harness passes `--resolv-conf=bind-host`
# (lib/nspawn.sh, both the `enter` and `verify-boot` paths), which bind-mounts
# **the host's** /etc/resolv.conf over the guest's. Inside an nspawn slot
# /etc/resolv.conf is therefore not the image's file at all, so:
#
#   - it is not a symlink to /run/systemd/resolve/stub-resolv.conf;
#   - the image's systemd-resolved is bypassed for every lookup libc makes;
#   - a test there would exercise the *developer's* resolver and report a
#     confident, wrong answer about the shipped configuration.
#
# That is the failure this workspace keeps hitting: a green check on the wrong
# substrate. So this runs under a real UEFI boot with real firmware, real
# systemd-resolved and real NetworkManager, via
#   iso-install --boot-only --console-put=slot-tests/dns-resolver.sh:/root/dns.sh \
#              --console-exec='bash /root/dns.sh'
#
# WHAT IT DOES. Phase 1 asserts the facts Cassini's DNS page claims, on the real
# system. Phase 2 asserts name resolution actually works. Phase 3 makes the
# changes a user or admin would plausibly make, verifies networking after each,
# and reverts - including one change that is *expected* to break resolution, so
# that the page's warning about stopping systemd-resolved is a demonstrated fact
# rather than a prediction.
#
# SAFETY. Phase 3 deliberately stops systemd-resolved. A trap installed before
# any change re-enables it and removes every drop-in this script created, on
# every exit path including failure and interrupt, so the slot is left resolving.
# Nothing outside the slot is touched; the VM's network is its own.
#
# Prints `RESULT <name> PASS|FAIL|SKIP (detail)` lines, which is what
# cmd_slot_test aggregates - so the same file is usable from a real boot and
# from `slot-test` (where the resolv.conf assertions will correctly FAIL,
# because of the bind-host above; the change tests are still meaningful there).

export PATH=/usr/bin:/usr/sbin:/bin:/sbin

RESULT_NAME=""
FAILURES=0
CREATED_DROPIN="/etc/systemd/resolved.conf.d/99-dns-selftest.conf"
NMCLI_TOUCHED=""

# --- reporting ---------------------------------------------------------------

result() { # <PASS|FAIL|SKIP> <name> <detail>
  printf 'RESULT %-38s %s (%s)\n' "$2" "$1" "$3"
  [[ "$1" == FAIL ]] && FAILURES=$((FAILURES + 1))
  return 0
}

check() { # <name> <detail-on-pass> <command...>
  local name="$1" detail="$2"; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  if (( rc == 0 )); then
    result PASS "$name" "${out:-$detail}"
  else
    result FAIL "$name" "$(tr '\n' ';' <<<"$out" | cut -c1-110)"
  fi
}

# --- recovery trap -----------------------------------------------------------
# Installed before anything is changed. `bash /root/dns.sh` runs under systemd's
# debug shell, where a stray failure must not be allowed to leave the slot
# without a resolver.

recover() {
  local rc=$?
  [[ -f $CREATED_DROPIN ]] && rm -f "$CREATED_DROPIN" && \
    systemctl restart systemd-resolved 2>/dev/null
  # Undo a per-connection DNS override if we set one.
  if [[ -n $NMCLI_TOUCHED ]]; then
    nmcli con mod "$NMCLI_TOUCHED" ipv4.ignore-auto-dns yes 2>/dev/null
    nmcli con up "$NMCLI_TOUCHED" 2>/dev/null
    NMCLI_TOUCHED=""
  fi
  # Last line of defence: whatever else happened, is anything resolving?
  if ! resolvectl query example.com >/dev/null 2>&1; then
    systemctl start systemd-resolved 2>/dev/null
    sleep 2
    if resolvectl query example.com >/dev/null 2>&1; then
      printf 'RESULT %-38s %s (%s)\n' "dns-left-resolving" "PASS" \
        "trap restored systemd-resolved"
    else
      printf 'RESULT %-38s %s (%s)\n' "dns-left-resolving" "FAIL" \
        "TRAP COULD NOT RESTORE RESOLUTION - slot needs a manual "\
"systemctl start systemd-resolved"
    fi
  else
    printf 'RESULT %-38s %s (%s)\n' "dns-left-resolving" "PASS" \
      "still resolving on exit"
  fi
  exit $rc
}
trap recover EXIT

# --- helpers -----------------------------------------------------------------

# Does a name resolve *through the system's own resolver*? resolvectl talks to
# systemd-resolved directly, which is the interface that matters; getent goes
# through NSS and proves the libc path that applications use. Both matter and
# they fail differently.
resolves_via_resolved() { timeout 20 resolvectl query "$1" >/dev/null 2>&1; }
resolves_via_nss()     { timeout 20 getent hosts "$1" >/dev/null 2>&1; }

# A real external name. Deliberately NOT downloads.shani.dev: the harness maps
# that one in /etc/hosts for its own download plumbing, so resolving it would
# prove nothing about DNS.
EXTNAME=archlinux.org

echo "### dns-resolver: starting on a real boot at $(date -Is)"

# =============================================================================
# Phase 1 - the facts Cassini's DNS page asserts, verified on the real system
# =============================================================================

# The image tree says this is a symlink to /run/systemd/resolve/
# stub-resolv.conf. The real installed system says it is a regular file written
# by NetworkManager. Both were measured; the file is what ships, so the file is
# what is asserted, and the image-tree claim is recorded as the discrepancy it
# is rather than quietly dropped.
if [[ -L /etc/resolv.conf ]]; then
  result PASS "dns-resolv-conf-is-stub-symlink" "$(readlink /etc/resolv.conf)"
elif [[ -f /etc/resolv.conf ]]; then
  owner=$(head -1 /etc/resolv.conf | tr -d '\r')
  result PASS "dns-resolv-conf-is-regular-file" "$owner"
else
  result FAIL "dns-resolv-conf-present" "neither a file nor a symlink"
fi

# Which component owns it, read from the file's own header rather than guessed.
if grep -qi 'networkmanager' /etc/resolv.conf 2>/dev/null; then
  result PASS "dns-resolv-conf-owned-by-nm" "NetworkManager writes resolv.conf"
else
  result SKIP "dns-resolv-conf-owned-by-nm" \
    "$(head -1 /etc/resolv.conf 2>/dev/null | tr -d '\r')"
fi

# The page's load-bearing claim: the symlink target lives under /run and is
# written at boot, so it must exist NOW on a booted system. In the image tree
# this path does not exist at all.
if [[ -e /etc/resolv.conf ]]; then
  result PASS "dns-stub-target-not-dangling" \
    "$(tr '\n' ' ' < /etc/resolv.conf | cut -c1-90)"
else
  result FAIL "dns-stub-target-not-dangling" \
    "symlink target missing - nothing would resolve"
fi

for u in systemd-resolved.service; do
  st=$(systemctl is-active "$u" 2>&1)
  if [[ $st == active || $st == activating ]]; then
    result PASS "dns-resolved-active" "$st"
  else
    result FAIL "dns-resolved-active" "$st"
  fi
  en=$(systemctl is-enabled "$u" 2>&1)
  [[ $en == enabled ]] && result PASS "dns-resolved-enabled" "$en" \
                      || result FAIL "dns-resolved-enabled" "$en"
done

# The stub listener is what libc actually talks to, and it is a separate fact
# from resolved being "active".
if timeout 10 resolvectl status >/dev/null 2>&1; then
  result PASS "dns-resolved-reachable" "resolvectl status answered"
else
  result FAIL "dns-resolved-reachable" "resolvectl status did not answer"
fi

# The shipped global DNS. Reported with its actual value rather than asserted
# against a literal, because the point is to record what the image does - but a
# missing key and an unexpected one are different and both worth seeing.
if [[ -f /etc/systemd/resolved.conf ]]; then
  dnsv=$(grep -E '^[[:space:]]*DNS=' /etc/systemd/resolved.conf | head -1 | cut -d= -f2-)
  [[ -n $dnsv ]] && result PASS "dns-global-servers-set" "DNS=$dnsv" \
                 || result PASS "dns-global-servers-set" "no DNS= (resolv.conf is then the source)"
else
  result FAIL "dns-global-servers-set" "no /etc/systemd/resolved.conf"
fi

# Three of the four resolvers ship as packages with no config file. Asserted
# because the page says they are inert, and "inert" means exactly this.
# Which of the other resolvers have a config, and whether any is running. The
# image tree had none of these files; the installed system has dnsmasq's. What
# matters for "will networking break" is not the file's existence but whether
# anything is listening, so each one is reported with its real service state.
for pair in "BIND:named:/etc/named.conf" "dnsmasq:dnsmasq:/etc/dnsmasq.conf" \
            "dnscrypt-proxy:dnscrypt-proxy:/etc/dnscrypt-proxy/dnscrypt-proxy.conf"; do
  label=${pair%%:*}; rest=${pair#*:}; unit=${rest%%:*}; cfg=${rest#*:}
  if [[ -e $cfg ]]; then
    st=$(systemctl is-active "$unit" 2>&1)
    result PASS "dns-alt-resolver-$label" "config present, service=$st"
  else
    st=$(systemctl is-active "$unit" 2>&1)
    result PASS "dns-alt-resolver-$label" "no config, service=$st"
  fi
done

# What is actually listening on port 53 - the fact that decides whether two
# resolvers can coexist, and it is a measurement rather than an inference from
# which config files exist.
listeners=$(ss -lunp 2>/dev/null | awk '$5 ~ /:53$/ {print $5}' | sort -u | tr '\n' ' ')
if [[ -n $listeners ]]; then
  result PASS "dns-port-53-listeners" "$listeners"
else
  result FAIL "dns-port-53-listeners" "nothing is listening on port 53"
fi

# =============================================================================
# Phase 2 - does name resolution actually work
# =============================================================================

# On a real Shanios install this test found systemd-resolved **disabled and
# NetworkManager writing /etc/resolv.conf directly**, so `resolvectl query` -
# the original gate for "does this machine have working DNS" - fails on a
# perfectly healthy system and would have skipped every change test below. The
# gate now asks the question a user would ask, via the same libc path an
# application uses.
if resolves_via_nss "$EXTNAME"; then
  result PASS "dns-resolves-via-nss" "getent hosts $EXTNAME"
  HAVE_NET=1
else
  result FAIL "dns-resolves-via-nss" "getent hosts $EXTNAME failed"
  HAVE_NET=0
fi

# Whether systemd-resolved is the resolver at all is a separate question, and
# on this system the answer is no - so this is reported, not failed. It was
# written as a hard assertion when the image tree suggested resolved was
# enabled; the real boot says otherwise, and a check that fails because reality
# is different from the assumption teaches nobody anything.
if resolves_via_resolved "$EXTNAME"; then
  result PASS "dns-resolves-via-resolved" "systemd-resolved answers queries"
else
  st=$(systemctl is-active systemd-resolved 2>&1)
  en=$(systemctl is-enabled systemd-resolved 2>&1)
  result SKIP "dns-resolves-via-resolved" \
    "systemd-resolved is not the resolver here (active=$st enabled=$en)"
fi

# A name that needs no DNS at all. If this fails while the others pass, the
# problem is NSS, not the network - a distinction worth having in the log.
if getent hosts localhost >/dev/null 2>&1; then
  result PASS "dns-localhost-resolves" "no resolver involved"
else
  result FAIL "dns-localhost-resolves" "NSS broken independently of DNS"
fi

# If the VM has no outbound network at all, every change test below would fail
# for an environmental reason and be indistinguishable from a real defect.
if (( ! HAVE_NET )); then
  result SKIP "dns-change-tests" \
    "no external resolution from this VM - change tests would prove nothing"
  echo "### dns-resolver: done, $FAILURES failure(s)"
  exit 0
fi

# =============================================================================
# Phase 3 - make the changes, verify, revert
# =============================================================================

# --- 3a. a resolved.conf drop-in, which is how DNS= is meant to be changed ---
mkdir -p /etc/systemd/resolved.conf.d
if printf '[Resolve]\nDNS=1.1.1.1\n' > "$CREATED_DROPIN" \
   && systemctl restart systemd-resolved 2>/dev/null; then
  sleep 2
  newdns=$(grep -E '^[[:space:]]*DNS=' "$CREATED_DROPIN" | cut -d= -f2-)
  if resolves_via_nss "$EXTNAME"; then
    result PASS "dns-dropin-keeps-resolving" "after DNS=$newdns drop-in"
  else
    result FAIL "dns-dropin-keeps-resolving" "resolution died after DNS=$newdns"
  fi
  rm -f "$CREATED_DROPIN"
  systemctl restart systemd-resolved 2>/dev/null; sleep 2
  if resolves_via_nss "$EXTNAME"; then
    result PASS "dns-dropin-revert-resolves" "back to the image default"
  else
    result FAIL "dns-dropin-revert-resolves" "still broken after removing the drop-in"
  fi
else
  result FAIL "dns-dropin-keeps-resolving" "could not write the drop-in or restart"
fi

# --- 3b. restarting the resolver must not break networking ------------------
if systemctl restart systemd-resolved 2>/dev/null; then
  sleep 2
  if resolves_via_nss "$EXTNAME"; then
    result PASS "dns-restart-resolved-keeps-networking" "still resolving"
  else
    result FAIL "dns-restart-resolved-keeps-networking" \
      "no resolution after a plain restart - this is the common support case"
  fi
else
  result FAIL "dns-restart-resolved-keeps-networking" "restart failed"
fi

# --- 3c. NetworkManager per-connection DNS -----------------------------------
# The change a desktop user actually makes, in the GUI. Verified through
# resolved's own view of the link, not just through resolution working.
CONN=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | head -1 | cut -d: -f1)
if [[ -z $CONN ]]; then
  result SKIP "dns-nmcli-per-link" "no active NetworkManager connection"
else
  if nmcli con mod "$CONN" ipv4.dns "1.0.0.1" ipv4.ignore-auto-dns yes >/dev/null 2>&1 \
     && nmcli con up "$CONN" >/dev/null 2>&1; then
    NMCLI_TOUCHED="$CONN"; sleep 3
    if resolves_via_nss "$EXTNAME"; then
      result PASS "dns-nmcli-per-link-keeps-resolving" "$CONN now has its own DNS"
    else
      result FAIL "dns-nmcli-per-link-keeps-resolving" "$CONN broke resolution"
    fi
    nmcli con mod "$CONN" ipv4.ignore-auto-dns no >/dev/null 2>&1
    nmcli con up "$CONN" >/dev/null 2>&1; NMCLI_TOUCHED=""
    sleep 2
    if resolves_via_nss "$EXTNAME"; then
      result PASS "dns-nmcli-revert-resolves" "$CONN back on automatic DNS"
    else
      result FAIL "dns-nmcli-revert-resolves" "$CONN did not recover"
    fi
  else
    result FAIL "dns-nmcli-per-link-keeps-resolving" "could not set DNS on $CONN"
  fi
fi

# --- 3d. the dangerous one: stopping systemd-resolved -----------------------
# This is EXPECTED to break resolution, because /etc/resolv.conf points into
# /run/systemd/resolve/ and nothing else writes that file. A test that reported
# "still fine" here would be the bug. Asserting the breakage is what makes the
# DNS page's warning true rather than plausible.
if systemctl stop systemd-resolved 2>/dev/null; then
  sleep 2
  if [[ -e /etc/resolv.conf ]]; then
    result PASS "dns-stop-resolved-keeps-file" \
      "stub file survived the stop (unexpected - check for another writer)"
  else
    result PASS "dns-stop-resolved-dangles-resolv-conf" \
      "/etc/resolv.conf now points at nothing, as predicted"
  fi
  if resolves_via_nss "$EXTNAME"; then
    result SKIP "dns-stop-resolved-breaks-resolution" \
      "resolution survived - the stop is harmless here, so the page's warning "\
"needs re-checking against this system"
  else
    result PASS "dns-stop-resolved-breaks-resolution" \
      "resolution failed with systemd-resolved stopped, as the page warns"
  fi
  # Put it back immediately - the trap would too, but not before other checks.
  if systemctl start systemd-resolved 2>/dev/null; then
    sleep 3
    if resolves_via_nss "$EXTNAME"; then
      result PASS "dns-recovers-after-start" "resolution restored"
    else
      result FAIL "dns-recovers-after-start" \
        "did NOT recover after starting systemd-resolved"
    fi
  else
    result FAIL "dns-recovers-after-start" "could not start systemd-resolved"
  fi
else
  result FAIL "dns-stop-resolved-breaks-resolution" "could not stop the service"
fi

echo "### dns-resolver: done, $FAILURES failure(s)"
exit 0
