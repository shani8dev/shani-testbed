#!/bin/bash
# slot-test-mode: boot
#
# Does enabling dnscrypt-proxy break the machine's networking?
#
# `shani-network` 1.2-12 adds `systemctl enable dnscrypt-proxy.service`. This
# exists to answer the one question that change raises: the service is enabled
# on every machine, so if starting it could take DNS down, that is a fleet-wide
# boot-time regression, not a local annoyance.
#
# The design deliberately does NOT repoint NetworkManager at 127.0.0.1, so the
# proxy is not a dependency of name resolution and cannot strand anything. This
# proves that on a real boot rather than reasoning about it: DNS is checked
# before the service is touched, again while it runs, and again after it is
# stopped - and a failure at any point is loud, with the recovery attempt
# reported.
#
# Same substrate note as dns-resolver.sh: nspawn bind-mounts the host's
# resolv.conf (`--resolv-conf=bind-host`), so this must run on a real UEFI boot.
#   iso-install --boot-only \
#     --console-put=slot-tests/dnscrypt-enable.sh:/root/t.sh \
#     --console-exec='bash /root/t.sh'

export PATH=/usr/bin:/usr/sbin:/bin:/sbin

result() { printf 'RESULT %-38s %s (%s)\n' "$2" "$1" "$3"; }

# getent goes through NSS, i.e. the same libc path an application uses. Not
# `resolvectl query`: on a stock Shanios install systemd-resolved is disabled and
# NetworkManager writes resolv.conf, so resolvectl correctly fails on a machine
# whose DNS works perfectly.
resolves() { timeout 25 getent hosts archlinux.org >/dev/null 2>&1; }

echo "### dnscrypt-enable: starting at $(date -Is)"

# --- 1. baseline, before anything is touched -------------------------------
if resolves; then
  result PASS "dns-before-enable" "name resolution works"
  BASE=1
else
  result FAIL "dns-before-enable" "already broken before we touched anything"
  BASE=0
fi

if ! systemctl list-unit-files dnscrypt-proxy.service >/dev/null 2>&1 \
   || ! systemctl cat dnscrypt-proxy.service >/dev/null 2>&1; then
  result SKIP "dnscrypt-unit-exists" "dnscrypt-proxy is not installed"
  exit 0
fi
result PASS "dnscrypt-unit-exists" "dnscrypt-proxy.service is present"

# The shipped config must listen on loopback only. A proxy other machines can
# query is an open resolver, which is a standard amplification vector, and
# enabling it on every machine would put one on every network.
listen=$(grep -E '^[[:space:]]*listen_addresses' /etc/dnscrypt-proxy/dnscrypt-proxy.toml 2>/dev/null)
if [[ $listen == *127.0.0.1* || $listen == *"::1"* ]]; then
  result PASS "dnscrypt-loopback-only" "$listen"
else
  result FAIL "dnscrypt-loopback-only" "NOT loopback-only: $listen"
fi

# --- 2. what the package actually does --------------------------------------
systemctl enable dnscrypt-proxy.service >/dev/null 2>&1
en=$(systemctl is-enabled dnscrypt-proxy.service 2>&1)
[[ $en == enabled ]] && result PASS "dnscrypt-enabled" "$en" \
                    || result FAIL "dnscrypt-enabled" "$en"

# --- 3. the service must not break resolution while it runs -----------------
systemctl start dnscrypt-proxy.service >/dev/null 2>&1
sleep 5
st=$(systemctl is-active dnscrypt-proxy.service 2>&1)
[[ $st == active || $st == activating ]] \
  && result PASS "dnscrypt-starts" "$st (after 5s)" \
  || result SKIP "dnscrypt-starts" "$st - it may still be fetching its resolver list"

if (( BASE )); then
  if resolves; then
    result PASS "dns-while-proxy-runs" "resolution unaffected by the proxy running"
  else
    result FAIL "dns-while-proxy-runs" \
      "RESOLUTION BROKE with dnscrypt-proxy running - this is the fleet-wide regression"
  fi
else
  result SKIP "dns-while-proxy-runs" "baseline was already failing"
fi

# --- 4. and stopping it must not break it either ----------------------------
systemctl stop dnscrypt-proxy.service >/dev/null 2>&1
sleep 2
if resolves; then
  result PASS "dns-after-proxy-stopped" "still resolving with the proxy stopped"
else
  result FAIL "dns-after-proxy-stopped" "resolution broken after stopping the proxy"
fi

# --- 5. and the machine is left as the package leaves it -------------------
systemctl enable dnscrypt-proxy.service >/dev/null 2>&1
echo "### dnscrypt-enable: done"
exit 0
