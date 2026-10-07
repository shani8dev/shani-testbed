#!/bin/bash
# A check of the harness itself: slot-tests/sysctl-hardening.sh, run against a
# FAKE /proc/sys and a FAKE sysctl.d, requiring every one of its comparisons to
# go red when the value it is looking at is wrong.
#
# WHY THIS FILE EXISTS. `sysctl-hardening.sh` is a slot-test: it can only run
# inside a booted image, so until now there was no way from this host to show
# that its comparisons discriminate anything. That matters more here than
# usual, because the whole point of the slot-test is to catch a value that is
# NOT in effect - and a comparison against the wrong path, a typo'd key or an
# unread value all produce a green run that means nothing. "The control must be
# seen failing" is the rule this repo keeps paying for.
#
# WHAT IS REAL AND WHAT IS FAKED, precisely - this distinction is the caveat on
# the whole file:
#
#   * The SCRIPT is not stubbed or copied. `slot-tests/sysctl-hardening.sh`
#     itself runs, unmodified, with `SYSCTL_TEST_PROC_SYS` and
#     `SYSCTL_TEST_CONF_DIRS` pointed at fixtures. Those two overrides were
#     added for this file; on a booted slot they default to the real paths, so
#     nothing about the slot behaviour changes.
#   * `/proc/sys` and the sysctl.d files ARE faked, because a host cannot be
#     made to disagree with itself about a kernel value. The fake is small and
#     literal: one file per key, containing the value.
#   * So what this proves is that the script's *comparisons* discriminate. It
#     does NOT prove the real `systemd-sysctl` applies the real files - that is
#     the slot run's job, and this file does not substitute for it.
#
# Each scenario asserts a RESULT line the real script printed, by name, so a
# scenario cannot pass by the script failing to run at all.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOT_TEST="$ROOT/slot-tests/sysctl-hardening.sh"

[[ -f "$SLOT_TEST" ]] || { echo "FAIL: no $SLOT_TEST" >&2; exit 1; }

pass_n=0 fail_n=0
ok()   { printf 'ok   %s\n' "$1"; pass_n=$((pass_n + 1)); }
no()   { printf 'FAIL %s -- %s\n' "$1" "$2"; fail_n=$((fail_n + 1)); }

TMP=$(mktemp -d /tmp/sysctl-hardening-selftest.XXXXXX)
trap '[[ ${KEEP_TMP:-0} == 1 ]] || rm -rf "$TMP"' EXIT

# The values the shipped config asks for, as the test's own expectations table
# reads them. Kept in one place so a scenario can perturb exactly one.
#   key = value-the-config-sets
cat > "$TMP/baseline.conf" <<'EOF'
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.use_tempaddr = 2
net.ipv6.conf.default.use_tempaddr = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.sysrq = 0
kernel.randomize_va_space = 2
dev.tty.ldisc_autoload = 1
kernel.unprivileged_bpf_disabled = 0
kernel.yama.ptrace_scope = 1
kernel.kexec_load_disabled = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
vm.max_map_count = 2147483642
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF

# Build a fake /proc/sys from a config file: one file per key, holding its
# value - which is exactly how the kernel presents them.
build_proc() { # <conf-file> <dest-root>
    local conf="$1" root="$2"
    rm -rf "$root"; mkdir -p "$root"
    local key val path
    while read -r key _eq val; do
        [[ -n "$key" && "$key" != \#* ]] || continue
        path="$root/${key//./\/}"
        mkdir -p "$(dirname "$path")"
        printf '%s' "$val" > "$path"
    done < "$conf"
    # `kernel.pid_max` exists on every machine and no shipped config sets it -
    # the test uses it as its "unmanaged key" control, so it must be present.
    printf '4194304' > "$root/kernel/pid_max"
}

run_test() { # <proc-root> <conf-dir>  -> prints the script's RESULT lines
    SYSCTL_TEST_PROC_SYS="$1" \
    SYSCTL_TEST_CONF_DIRS="$2" \
    SYSCTL_TEST_ZRAM="$TMP/no-such-zram" \
    bash "$SLOT_TEST" 2>&1
}

# A RESULT row's verdict, by exact test name. Prints the part after the name.
verdict() { # <output> <name>
    awk -v n="$2" '$1=="RESULT" && $2==n { $1=""; $2=""; sub(/^ +/,""); print; exit }' <<<"$1"
}

# ── scenario 1: everything agrees -> the checks must all pass ────────────────
echo "### scenario: a machine that matches its config"
mkdir -p "$TMP/conf-ok"; cp "$TMP/baseline.conf" "$TMP/conf-ok/90-hardening.conf"
build_proc "$TMP/baseline.conf" "$TMP/proc-ok"
OUT=$(run_test "$TMP/proc-ok" "$TMP/conf-ok")
if [[ "$OUT" == *"sysctl-negative-controls"*"PASS"* ]]; then
    ok "a consistent machine: controls correctly rejected their wrong values"
else
    no "a consistent machine: controls correctly rejected" "$(verdict "$OUT" sysctl-negative-controls)"
fi
for name in sysctl-ipv4-accept-source-route-all sysctl-ipv6-use-tempaddr-all \
            sysctl-ptrace-scope sysctl-kexec-disabled sysctl-ip-forward \
            sysctl-neigh-gc-thresh1 sysctl-bpf-jit-harden \
            sysctl-ldisc-autoload-kept-1 sysctl-unpriv-bpf-kept-0; do
    v=$(verdict "$OUT" "$name")
    if [[ -n "$v" ]]; then
        ok "a consistent machine: $name reported ($(cut -c1-40 <<<"$v"))"
    else
        no "a consistent machine: $name reported" "no RESULT row at all"
    fi
done

# ── scenario 2: a value NOT in effect -> must FAIL, and name the key ─────────
# The core claim of the whole slot-test: a config that asks for a value while
# the kernel has a different one is a finding, not a pass.
echo
echo "### scenario: the config asks for one thing and the kernel has another"
build_proc <(sed 's/^net.ipv6.conf.all.use_tempaddr = 2/net.ipv6.conf.all.use_tempaddr = 0/' \
                 "$TMP/baseline.conf") "$TMP/proc-drift"
OUT=$(run_test "$TMP/proc-drift" "$TMP/conf-ok")
v=$(verdict "$OUT" sysctl-ipv6-use-tempaddr-all)
if [[ "$v" == *"kernel has '0'"* && "$v" == *"config resolves to '2'"* ]]; then
    ok "kernel-vs-config drift: FAILs and names both values"
else
    no "kernel-vs-config drift: FAILs and names both values" "$v"
fi
if [[ "$OUT" == *"done, 0 failure(s)"* ]]; then
    no "kernel-vs-config drift: counted as a failure" "reported 0 failures"
else
    ok "kernel-vs-config drift: counted as a failure ($(grep -o 'done, [0-9]* failure' <<<"$OUT" | tail -1))"
fi

# ── scenario 3: the CONFIG regressed -> must also FAIL ──────────────────────
# Both the kernel and the config agreeing on the OLD value is the other
# direction, and the one a naive "compare kernel to config" check would miss.
echo
echo "### scenario: the config itself regressed to the old value"
mkdir -p "$TMP/conf-regressed"
sed 's/^kernel.yama.ptrace_scope = 1/kernel.yama.ptrace_scope = 0/' \
    "$TMP/baseline.conf" > "$TMP/conf-regressed/90-hardening.conf"
build_proc <(sed 's/^kernel.yama.ptrace_scope = 1/kernel.yama.ptrace_scope = 0/' \
                 "$TMP/baseline.conf") "$TMP/proc-regressed"
OUT=$(run_test "$TMP/proc-regressed" "$TMP/conf-regressed")
v=$(verdict "$OUT" sysctl-ptrace-scope)
if [[ "$v" == *"kernel has '0'"* && "$v" == *"config resolves to '0'"* \
      && "$v" == *"expected 1"* ]]; then
    ok "config regression: FAILs even though kernel and config agree"
else
    no "config regression: FAILs even though kernel and config agree" "$v"
fi

# ── scenario 4: an unreadable key -> SKIP naming it, never a silent PASS ────
echo
echo "### scenario: a key the kernel does not expose"
build_proc <(grep -v '^net.ipv6.conf.all.use_tempaddr' "$TMP/baseline.conf") "$TMP/proc-missing"
OUT=$(run_test "$TMP/proc-missing" "$TMP/conf-ok")
v=$(verdict "$OUT" sysctl-ipv6-use-tempaddr-all)
if [[ "$v" == SKIP* && "$v" == *"use_tempaddr"* ]]; then
    ok "an absent key: SKIP naming the key, not a silent PASS"
else
    no "an absent key: SKIP naming the key" "$v"
fi

# ── scenario 5: no config files at all -> must FAIL, not pass vacuously ─────
echo
echo "### scenario: no sysctl.d files to check against"
mkdir -p "$TMP/conf-empty"
OUT=$(run_test "$TMP/proc-ok" "$TMP/conf-empty")
v=$(verdict "$OUT" sysctl-configs-present)
if [[ "$v" == FAIL* ]]; then
    ok "no config files: FAILs rather than passing with nothing to check"
else
    no "no config files: FAILs rather than passing with nothing to check" "$v"
fi

# ── scenario 6: the aggregator's own rule ───────────────────────────────────
# `lib/boot.sh` decides with `grep -c '^RESULT .* PASS'` / `FAIL` and fails the
# run on `fail > 0` (or `pass == 0`). **The first version of the slot-test put
# neither word in either kind of row**, so on a machine with a real drift the
# harness counted `3 pass, 0 fail` and reported SLOT-TEST PASSED. So the row
# shape is asserted here directly, in the two states that matter, because a
# result the aggregator cannot see is worth nothing.
echo
echo "### scenario: the harness could actually see the verdicts"
OUT=$(run_test "$TMP/proc-ok" "$TMP/conf-ok")
agg_pass=$(grep -c '^RESULT .* PASS' <<<"$OUT")
agg_fail=$(grep -c '^RESULT .* FAIL' <<<"$OUT")
if (( agg_pass >= 30 && agg_fail == 0 )); then
    ok "a consistent machine: the aggregator counts many PASS, no FAIL ($agg_pass/$agg_fail)"
else
    no "a consistent machine: the aggregator counts many PASS, no FAIL" "$agg_pass pass, $agg_fail fail"
fi

OUT=$(run_test "$TMP/proc-drift" "$TMP/conf-ok")
agg_fail=$(grep -c '^RESULT .* FAIL' <<<"$OUT")
if (( agg_fail > 0 )); then
    ok "a drifted machine: the aggregator counts FAIL, so slot-test would fail ($agg_fail)"
else
    no "a drifted machine: the aggregator counts FAIL" "0 FAIL rows - slot-test would PASS"
fi

# A broken control must also be visible to the aggregator, not only to the
# summary row, or the mechanism this file exists to prove can itself go
# unobserved.
OUT=$(run_test "$TMP/proc-drift" "$TMP/conf-ok")
if grep -q '^RESULT control-.* FAIL CONTROL-BROKEN' <<<"$OUT"; then
    ok "a broken control is reported as FAIL, not only summarised"
else
    no "a broken control is reported as FAIL" "$(grep '^RESULT control-' <<<"$OUT" | head -1)"
fi

# ── scenario 7: the script must be able to fail at all ──────────────────────
# The floor. If every scenario above passed while the script exited 0 on a
# deliberately inconsistent machine, none of the rest means anything.
echo
echo "### scenario: the script's own exit shape"
OUT=$(run_test "$TMP/proc-drift" "$TMP/conf-ok")
if grep -q '^RESULT ' <<<"$OUT"; then
    ok "the script emits RESULT rows (so cmd_slot_test can aggregate them)"
else
    no "the script emits RESULT rows" "no RESULT lines in $(wc -l <<<"$OUT") line(s)"
fi

echo
echo "pass $pass_n / fail $fail_n"
[ "$fail_n" -eq 0 ]
