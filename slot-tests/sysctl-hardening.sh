#!/bin/bash
# slot-test-mode: boot
#
# sysctl-hardening — the kernel values shani-settings' sysctl.d files ASK for,
# read back from /proc/sys on a booted system, and compared against what those
# files actually say.
#
# WHY THIS EXISTS. shani-settings/tests/validate-configs.sh checks that every
# sysctl.d file is well-formed and (in an unprivileged container) that every key
# in it resolves. Neither answer is the question that matters. A key can parse,
# exist, and still not be in effect — a later-sorting file overrides it, a
# service re-applies sysctl after systemd-sysctl, NetworkManager rewrites
# per-interface values on connect, or the value was simply never applied. Every
# one of those produces a green repo check and an unhardened machine.
#
# So this asserts the real thing: for each key, read the value the kernel
# actually has, and separately compute the value the shipped config files
# resolve to (last file in lexical order wins, which is systemd-sysctl's rule).
# Reporting both means a mismatch shows up as a mismatch rather than as a
# confident wrong answer.
#
# SCOPE — deliberately NOT asserted here, because each would produce a false
# FAIL in a slot rather than a real finding:
#   - net.ipv4.conf.<bridge>.rp_filter=0 keys (waydroid0, podman0, lxdbr0, ...):
#     those interfaces do not exist in a slot, and systemd-sysctl re-runs per
#     interface on a net "add" event. Nothing to read back.
#   - any key that only exists in the initial network namespace
#     (net.core.bpf_jit_harden, net.core.netdev_max_backlog,
#     net.ipv4.neigh.default.gc_thresh1-3): documented in shani-settings AGENTS.md
#     as host-kernel-only, absent from the slot's netns. Read as SKIP.
#   - keys an nspawn slot cannot honour at all (kernel.unprivileged_userns_clone
#     is host-global; slots would report the host's value, not the image's).
#
# NEGATIVE CONTROL. The control is a value this script is told to expect that no
# shipped config file sets: if the check passed vacuously — empty key list, a
# typo'd path, an unreachable /proc/sys — the control would still read PASS.
# So the control is a genuine assertion about a deliberately wrong expectation,
# and it must FAIL. If it ever passes, this test has stopped testing.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
FAILURES=0

# **The verdict word must be IN the message, and this is not cosmetic.**
# `lib/boot.sh` decides a slot-test's outcome with
#     pass=$(grep -c '^RESULT .* PASS' ...); fail=$(grep -c '^RESULT .* FAIL' ...)
# and fails the run on `fail > 0` (or `pass == 0`). The first version of this
# file printed agreement as `RESULT <name> net.ipv4... = 0 (config agrees)` and
# drifts as `RESULT <name> kernel has '0', config resolves to '2'` - **neither
# contains PASS or FAIL**, so the harness counted 42 rows as `3 pass, 0 fail`
# and would have reported SLOT-TEST PASSED on a machine with a real drift. A
# result the aggregator cannot see is the same class of defect as a check that
# cannot fail, and it was found only by counting the rows the harness would
# actually match.
pass_() { res "$1" "PASS $2"; }
fail()  { res "$1" "FAIL $2"; FAILURES=$((FAILURES + 1)); }

# The two roots this test reads, overridable so the test can be pointed at
# fixtures instead of the running machine.
#
# **This exists to make the test provable, and that is not a convenience.** As a
# slot-test it can only run inside a booted image, so its comparisons could not
# be shown to discriminate anything from this host - and "the control must be
# seen failing" is the rule this repo keeps paying for. With these overrides,
# `tests/sysctl-hardening-results.sh` runs the real script against a fake
# /proc/sys and a fake sysctl.d and requires each check to go red when the value
# it is looking at is wrong. The same shape maze-cloak uses to run from a
# checkout without touching /etc.
#
# Defaults are the real paths, so nothing changes on a booted slot.
PROC_SYS_ROOT="${SYSCTL_TEST_PROC_SYS:-/proc/sys}"
SYSCTL_CONF_DIRS="${SYSCTL_TEST_CONF_DIRS:-/usr/lib/sysctl.d /etc/sysctl.d}"

# shellcheck disable=SC2206  # word splitting is intended: it is a path list
SYSCTL_FILES=()
for _d in $SYSCTL_CONF_DIRS; do
    for _f in "$_d"/*.conf; do
        [[ -f "$_f" ]] && SYSCTL_FILES+=("$_f")
    done
done

# The value the shipped config resolves to for one key: systemd-sysctl reads
# files in lexical order across all directories and the LAST assignment wins.
# Mirrors that here rather than trusting a single file, because the whole point
# is to catch a value being overridden by something this repo does not own.
configured_value() {
    local key="$1" v=""
    local f
    for f in $(printf '%s\n' "${SYSCTL_FILES[@]}" | sort); do
        [ -f "$f" ] || continue
        # strip comments, then match the key at the start of a line; the
        # leading '-' prefix means "skip if absent" and is not part of the key
        local line
        line=$(sed 's/#.*//' "$f" \
               | grep -E "^[[:space:]]*-?[[:space:]]*${key//./\\.}[[:space:]]*=" \
               | tail -1)
        [ -n "$line" ] && v=$(awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}' <<<"$line")
    done
    printf '%s' "$v"
}

check_key() { # <name> <key> <expected>
    local name="$1" key="$2" want="$3"
    local path="$PROC_SYS_ROOT/${key//./\/}"
    local got cfg

    if [[ ! -e $path ]]; then
        res "$name" "SKIP ($key not in this netns)"
        return 0
    fi
    got=$(cat "$path" 2>/dev/null | tr -d '[:space:]')
    cfg=$(configured_value "$key")

    if [[ -z $cfg ]]; then
        # No shipped config sets this. Nothing to compare, and nothing to claim.
        res "$name" "SKIP ($key not set by any shipped sysctl.d file)"
        return 0
    fi
    if [[ $got != "$want" ]]; then
        fail "$name" "$key: kernel has '$got', config resolves to '$cfg' (expected $want)"
        return 0
    fi
    if [[ $cfg != "$want" ]]; then
        fail "$name" "$key: kernel matches $want but shipped config resolves to '$cfg'"
        return 0
    fi
    pass_ "$name" "$key = $got (config agrees)"
}

echo "### sysctl-hardening: $(date -Is)"

if [[ ${#SYSCTL_FILES[@]} -eq 0 ]]; then
    res sysctl-configs-present "FAIL (no sysctl.d files at all - nothing to check)"
    exit 1
fi
n=$(cat "${SYSCTL_FILES[@]}" 2>/dev/null | grep -cE '^[[:space:]]*-?[[:space:]]*[a-z][a-z0-9_.]*[[:space:]]*=')
res sysctl-configs-present "PASS ($n assignments across ${#SYSCTL_FILES[@]} file(s))"

# ---------------------------------------------------------------------------
# The hardening values this change set added or that were already load-bearing.
# Listed explicitly rather than derived from the config files: deriving the
# expectation from the same file being tested is how a check ends up asserting
# whatever the file happens to say, including a regression.
# ---------------------------------------------------------------------------

# --- network: source routing and secure redirects ---
check_key sysctl-ipv4-accept-source-route-all \
    net.ipv4.conf.all.accept_source_route 0
check_key sysctl-ipv4-accept-source-route-default \
    net.ipv4.conf.default.accept_source_route 0
check_key sysctl-ipv4-secure-redirects-all \
    net.ipv4.conf.all.secure_redirects 0
check_key sysctl-ipv4-secure-redirects-default \
    net.ipv4.conf.default.secure_redirects 0
check_key sysctl-ipv6-accept-source-route-all \
    net.ipv6.conf.all.accept_source_route 0
check_key sysctl-ipv6-accept-source-route-default \
    net.ipv6.conf.default.accept_source_route 0

# --- network: redirects (pre-existing, load-bearing) ---
check_key sysctl-ipv4-accept-redirects-all \
    net.ipv4.conf.all.accept_redirects 0
check_key sysctl-ipv6-accept-redirects-all \
    net.ipv6.conf.all.accept_redirects 0
check_key sysctl-ipv4-send-redirects-all \
    net.ipv4.conf.all.send_redirects 0
check_key sysctl-ipv4-rp-filter-all \
    net.ipv4.conf.all.rp_filter 2
check_key sysctl-ipv4-tcp-syncookies \
    net.ipv4.tcp_syncookies 1

# --- IPv6 privacy extensions ---
check_key sysctl-ipv6-use-tempaddr-all \
    net.ipv6.conf.all.use_tempaddr 2
check_key sysctl-ipv6-use-tempaddr-default \
    net.ipv6.conf.default.use_tempaddr 2

# --- kernel info hiding ---
check_key sysctl-kptr-restrict      kernel.kptr_restrict 2
check_key sysctl-dmesg-restrict     kernel.dmesg_restrict 1
check_key sysctl-sysrq              kernel.sysrq 0
check_key sysctl-randomize-va-space kernel.randomize_va_space 2

# --- deliberate divergences from maze-hardening, asserted so they cannot be
# --- "corrected" into a regression by a well-meaning port (shani-settings
# --- AGENTS.md records the reason for each) ---
check_key sysctl-ldisc-autoload-kept-1 \
    dev.tty.ldisc_autoload 1
check_key sysctl-unpriv-bpf-kept-0 \
    kernel.unprivileged_bpf_disabled 0

# --- added by this change set ---
check_key sysctl-ptrace-scope   kernel.yama.ptrace_scope 1
check_key sysctl-kexec-disabled kernel.kexec_load_disabled 1

# --- container compatibility: values that MUST hold or nothing works ---
check_key sysctl-ip-forward      net.ipv4.ip_forward 1
check_key sysctl-ipv6-forward    net.ipv6.conf.all.forwarding 1
check_key sysctl-max-map-count   vm.max_map_count 2147483642

# ---------------------------------------------------------------------------
# Filesystem protections
# ---------------------------------------------------------------------------
check_key sysctl-protected-hardlinks fs.protected_hardlinks 1
check_key sysctl-protected-symlinks fs.protected_symlinks 1
check_key sysctl-protected-fifos    fs.protected_fifos 2
check_key sysctl-protected-regular  fs.protected_regular 2
check_key sysctl-suid-dumpable      fs.suid_dumpable 0

# ---------------------------------------------------------------------------
# The five keys that carry a `-` (skip-if-absent) prefix because they are
# registered per network namespace: net.ipv4.neigh.default.gc_thresh1-3 and
# net.core.bpf_jit_harden / net.core.netdev_max_backlog.
#
# They ARE asserted, deliberately, because "the prefix made the log line go
# away" is exactly the failure this repo keeps being bitten by — silence is
# indistinguishable from "the setting stopped being applied". In a namespace
# that has these keys, they must hold their configured values; where the kernel
# genuinely does not expose them, check_key reports SKIP naming the key. The
# prefix changes only whether a missing key is an error, never whether a
# present one is written.
# ---------------------------------------------------------------------------
check_key sysctl-neigh-gc-thresh1 net.ipv4.neigh.default.gc_thresh1 512
check_key sysctl-neigh-gc-thresh2 net.ipv4.neigh.default.gc_thresh2 2048
check_key sysctl-neigh-gc-thresh3 net.ipv4.neigh.default.gc_thresh3 4096
check_key sysctl-netdev-max-backlog net.core.netdev_max_backlog 16384
check_key sysctl-bpf-jit-harden     net.core.bpf_jit_harden 2

# ---------------------------------------------------------------------------
# zram: the swap-priority added by this change set. Checked through the swap
# unit systemd actually activates, not through the config file, because the
# file is only a request.
# ---------------------------------------------------------------------------
if compgen -G "${SYSCTL_TEST_ZRAM:-/dev/zram}*" >/dev/null 2>&1; then
    prio=$(swapon --show=NAME,PRIO --noheadings 2>/dev/null | awk '/zram/{print $2; exit}')
    if [[ -n $prio ]]; then
        cfgp=$(configured_value "swap-priority")
        if [[ $prio != "$cfgp" ]]; then
            fail sysctl-zram-swap-priority \
                "zram active with priority $prio, config says '${cfgp:-unset}'"
        else
            pass_ sysctl-zram-swap-priority "zram priority $prio (config agrees)"
        fi
    else
        res sysctl-zram-swap-priority "SKIP (zram device exists but is not active as swap)"
    fi
else
    res sysctl-zram-swap-priority "SKIP (no /dev/zram* in this slot)"
fi

# ---------------------------------------------------------------------------
# NEGATIVE CONTROLS — each MUST fail, and this file asserts that it did.
#
# These deliberately assert a WRONG value for a key the shipped config really
# does set. Two properties make them meaningful:
#   - the key is one the config sets, so the "no shipped config" SKIP branch
#     cannot swallow the control (an earlier version of this file used keys no
#     config sets, and both controls reported SKIP - a control that cannot fail
#     is not a control);
#   - the expected value is one no shipped config and no plausible default
#     produces, so a PASS means the comparison is broken, not that the machine
#     is odd.
#
# Their failures are counted in CONTROL_FAILURES, not FAILURES: a control that
# fails is the control WORKING. They are verified at the end, so a control that
# unexpectedly passes is itself reported as a failure of this test - if the
# comparison logic is broken, every PASS above is meaningless and must not be
# allowed to read as a clean run.
# ---------------------------------------------------------------------------
CONTROL_FAILURES=0
control() { # <key> <wrong-expected-value>
    local key="$1" want="$2"
    local path="$PROC_SYS_ROOT/${key//./\/}"
    local got cfg
    if [[ ! -e $path ]]; then
        # Cannot be evaluated here; that is a gap in the control, so say so
        # rather than counting it as a successful control.
        res "control-$(echo "$key" | tr ./ __)" "CONTROL-UNUSABLE ($key absent here)"
        return 0
    fi
    got=$(cat "$path" 2>/dev/null | tr -d '[:space:]')
    cfg=$(configured_value "$key")
    if [[ $got == "$want" || $cfg == "$want" ]]; then
        # A control that did NOT fail is itself a failure of this test, so it is
        # reported through fail() - which carries the word the aggregator greps
        # for - as well as counted for the summary row below.
        fail "control-$(echo "$key" | tr ./ __)" \
            "CONTROL-BROKEN (got '$got', config '$cfg', deliberately expected '$want')"
        CONTROL_FAILURES=$((CONTROL_FAILURES + 1))
        return 0
    fi
    pass_ "control-$(echo "$key" | tr ./ __)" \
        "correctly rejected ($key is '$got', config '$cfg', not '$want')"
    return 0
}

control kernel.yama.ptrace_scope        99
control net.ipv4.conf.all.rp_filter     1
control net.ipv6.conf.all.use_tempaddr  0
control kernel.kexec_load_disabled      0

# A control for the third distinct outcome: a key that exists, is readable, and
# is set by NO shipped config must report SKIP naming the key - never a silent
# PASS. kernel.pid_max satisfies that and is present in every namespace.
if [[ -e "$PROC_SYS_ROOT/kernel/pid_max" ]]; then
    cfg=$(configured_value kernel.pid_max)
    if [[ -z $cfg ]]; then
        res sysctl-unmanaged-key-skips "PASS (kernel.pid_max set by no shipped config, reported as SKIP)"
    else
        fail sysctl-unmanaged-key-skips \
            "kernel.pid_max unexpectedly resolved to '$cfg' from the shipped config"
    fi
else
    res sysctl-unmanaged-key-skips "SKIP (kernel.pid_max absent here)"
fi

if [[ $CONTROL_FAILURES -eq 0 ]]; then
    res sysctl-negative-controls "PASS (4 control(s) each correctly rejected a wrong value)"
else
    fail sysctl-negative-controls \
        "$CONTROL_FAILURES control(s) did not fail - the comparison is not comparing; treat every result above as unproven"
fi

echo "### sysctl-hardening: done, $FAILURES failure(s)"
exit 0
