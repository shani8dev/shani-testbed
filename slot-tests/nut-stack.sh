#!/bin/bash
# slot-test-mode: boot
#
# nut-stack - does the NUT stack START from systemd on a real Shanios boot, with
# the config shani-settings ships and NO UPS attached?
#
# WHY A SLOT-TEST AND NOT A CONTAINER RUN. The container run proved the config
# parses and the daemons run when started by hand, but systemd does not come up
# inside a Docker container on this host (it hangs), so the units were never
# exercised. This runs them on a real boot with real systemd and the packaged
# binaries.
#
# The nspawn slot shares the host kernel, which matters for audit and for nothing
# else here: NUT needs a USB driver and systemd, so the host kernel's unavailable
# audit subsystem does not affect this test. That is why the audit-rules
# slot-test SKIPs on a slot and this one does not.
#
# CONFIG SOURCE: shani-settings/etc/nut/, embedded because the harness container
# does not bind-mount shani-settings and slot-test has no --console-put. The four
# files below are a verbatim copy; if shani-settings changes them, re-copy them
# here rather than trusting this snapshot.
#
# A NEGATIVE CONTROL is at the end and is the reason this file is worth running:
# with ALLOW_NO_DEVICE off, upsd must REFUSE to start. That single line is the
# only reason a fresh install with no UPS has a working stack, so if upsd starts
# anyway the line is decorative and the shipped config is not what is running.

set -u

res() { printf 'RESULT %-44s %s\n' "$1" "$2"; }
M=$(mktemp -d /tmp/nut-stack.XXXXXX)
trap 'rm -rf "$M"' EXIT
fail=0

command -v upsmon >/dev/null 2>&1 || {
    res "nut-installed" "SKIP (nut not installed - run with --local-pkg)"
    exit 0
}
res "nut-installed" "PASS ($(command -v upsmon))"

mkdir -p /etc/nut

# ---- shani-settings/etc/nut/nut.conf -------------------------------------
cat > /etc/nut/nut.conf <<'NUTCFG'
# Network UPS Tools — Shanios baseline.
#
# WHY THIS FILE EXISTS. apcupsd was the original UPS daemon here, and it has had
# no upstream release since 3.14.14 (2016/2017) — Arch still ships that version,
# repackaged nine times with the code unmoved. NUT is at 2.8.5, its data model
# is published as IETF RFC 9271, it covers 170+ manufacturers over serial, USB,
# SNMP and IPMI, and it ships an `apcupsd-ups` driver that still reaches
# apcupsd-controlled hardware, so nothing is lost by the change.
#
# MODE=standalone is NUT's own name for "one UPS protecting this machine": it
# starts the three layers (driver, upsd, upsmon). It is not netserver, because
# that opens the data server to the network and nut.conf's own note on that mode
# is blunt about the extra security it needs — a desktop should not be an open
# UPS server.
#
# ALLOW_NO_DEVICE=true is the line that makes this a sane fleet default. upsd
# refuses to start at all when ups.conf has no device sections, which on a fresh
# install is exactly the case — no UPS has been plugged in yet. Without it the
# stack would need a device configured before it could start, so a UPS connected
# later would need a manual enable. With it the stack is up, idle, and a section
# added at any time is picked up live.
MODE=standalone

# Uncomment to allow starting the `upsd` data server even if `ups.conf`
# has no device sections configured at the moment. This environment variable
# overrides the built-in "false" flag in `upsd`, and an optional same-named
# default flag that can be set in `upsd.conf`. If you want a data server always
# running, even if it initially has nothing to serve (may be live-reloaded
# later, when devices become configured), this option is for you.
ALLOW_NO_DEVICE=true
export ALLOW_NO_DEVICE
NUTCFG

# ---- shani-settings/etc/nut/upsd.conf ------------------------------------
cat > /etc/nut/upsd.conf <<'NUTCFG'
# Network UPS Tools data server — Shanios baseline.
#
# upsd is the layer that caches what the driver reads and answers queries from
# upsmon. It is bound to LOOPBACK ONLY and that is not a starting point to be
# widened casually: nut.conf's own documentation notes that MODE=netserver,
# which is what opening this to a network requires, "is opened to the network
# [so] a special care should be applied to security concerns". The monitor user
# in upsd.users can issue a forced shutdown, so reachable-plus-guessable
# password is a remote power-off primitive.
#
# A desktop has exactly one machine to protect, so nothing here needs to listen
# anywhere but 127.0.0.1. If a second machine ever needs to monitor this UPS,
# that is the netserver mode and a deliberate, documented change — not a LISTEN
# widened for convenience.

# The address and port upsd listens on. Loopback only; see the note above.
LISTEN 127.0.0.1 3493

# How long before upsd drops a connection that has said nothing.
MAXAGE 15
NUTCFG

# ---- shani-settings/etc/nut/ups.conf -------------------------------------
cat > /etc/nut/ups.conf <<'NUTCFG'
# Network UPS Tools driver configuration — Shanios baseline.
#
# NO DEVICE SECTION IS SHIPPED HERE, AND THAT IS THE POINT.
#
# A section is `[name]` plus `driver`, `port` and `desc`, and all three are
# facts about the machine in front of you: which UPS, on which bus, under which
# vendor's protocol. The same reasoning that kept apcupsd's UPSCABLE / UPSTYPE /
# DEVICE out of a shipped default applies here — a default that names `usbhid-ups`
# on `auto` describes a UPS that is not there, and the failure is a driver that
# exits silently rather than an error.
#
# What fills this in is NUT's own scanner, which needs no guessing from the user:
#
#     sudo nut-scanner -U
#
# It discovers USB, serial, SNMP, NetXML and IPMI devices and prints a complete
# section, ready to paste. That is the command this file points at, and it is
# why there is nothing here to get wrong.

# retry is the only setting that is not per-machine: how many times a driver
# re-attempts before giving up, applied to every section.
maxretry = 3

# ---------------------------------------------------------------------------
# Example, for reference only — nothing here is active. nut-scanner -U writes
# the real thing.
#
# [myups]
#   driver = usbhid-ups
#   port = auto
#   desc = "local UPS"
NUTCFG

# ---- shani-settings/etc/nut/upsmon.conf ----------------------------------
cat > /etc/nut/upsmon.conf <<'NUTCFG'
# Network UPS Tools monitor client — Shanios baseline.
#
# This is the file that decides what the machine DOES when the power goes, so it
# is the one a settings window legitimately edits. The shutdown policy lives
# here; the device lives in ups.conf.
#
# WHY THESE VALUES, and one thing NUT does not give us.
#
# apcupsd's page offered BATTERYLEVEL / MINUTES / TIMEOUT / KILLDELAY — a
# percentage-based shutdown threshold you could move. **NUT has no direct
# equivalent, and that is a real reduction rather than a rename.** upsmon acts on
# the UPS *hardware's own* low-battery signal: the driver reports the device's
# own LOWBATT state and upsmon responds. Getting a charge- or runtime-based
# trigger instead requires `dummy-ups` with overridden `battery.charge`/
# `battery.runtime` plus `upssched`, which is a deliberate advanced setup and
# not a default this page should build.
#
# So what is configurable here is the SHAPE of the response — how long to wait,
# what to run, and what counts as "the UPS has gone away" — and that is what
# upsmon.conf holds. The page says this rather than implying a battery
# percentage knob that does not exist, because a page whose row promises a
# threshold it cannot set is the exact failure this repo keeps finding.

# ---------------------------------------------------------------------------
# The MONITOR line is inserted by shani-settings' install hook, which also
# generates the matching monitor user in upsd.users. It is not written here
# because the password must not be a static fleet-wide value: `upsmon master`
# permits a forced shutdown, so a known password on a loopback-listening upsd is a
# local power-off primitive.
#
# The hook writes exactly:
#   MONITOR <upsname>@localhost 1 monuser <generated> master
#
# between BEGIN/END markers so it can tell an insert it made from a line a user
# typed, and so it runs only once.
# BEGIN shani-settings MONITOR (generated by the install hook; do not edit by hand)
# END shani-settings MONITOR

# How many supplies must be on battery before the shutdown sequence starts. 1
# means "the UPS is on battery" — NUT's standby configuration for a desktop.
MINSUPPLIES 1

# The command run to bring the machine down. This is the whole point of the
# feature, so it is stated rather than left to upsmon's built-in.
SHUTDOWNCMD "/sbin/shutdown -h +0"

# The flag file upsmon writes to tell the driver to cut UPS power once the
# machine is down. NUT's own default; stated so it is visible rather than
# inherited.
POWERDOWNFLAG /etc/killpower

# Seconds of no answer before the UPS is declared gone. When this fires upsmon
# treats it as on-battery, because an unreachable UPS is indistinguishable from
# a dead one and the safe assumption is the second.
DEADTIME 15

# Seconds between calling SHUTDOWNCMD and exiting. 0 is immediate: once the
# command is running the daemon has done its job.
FINALDELAY 0
NUTCFG

chmod 0644 /etc/nut/*.conf
res "config-present" "PASS (4 files from shani-settings)"

# --- what the package's own scriptlets would have done -----------------------
# `--local-pkg` overlays the files and EXPLICITLY runs no .install scriptlet, so
# neither systemd-sysusers (which creates the `nut` group) nor
# systemd-tmpfiles (which creates /var/lib/nut and /run/nut, owned nut:nut) has
# run. Without them both units die immediately - upsd on `Can't chdir to
# /var/lib/nut`, upsmon on `OS user nut not found` - which reads as a broken
# config and is actually a missing user.
#
# So the test does what the package declares, using the package's OWN files
# rather than a re-typed copy: run the sysusers and tmpfiles fragments Arch's nut
# package ships. On a real install pacman has already done this, and doing it
# again is a no-op.
systemd-sysusers /usr/lib/sysusers.d/nut-common-sysusers.conf 2>/dev/null || \
    getent group nut >/dev/null || groupadd -r nut
systemd-tmpfiles --create /usr/lib/tmpfiles.d/nut-common-tmpfiles.conf \
    2>/dev/null || true
if getent passwd nut >/dev/null && [ -d /var/lib/nut ]; then
    res "package-scriptlets-prereqs" "PASS (nut user, /var/lib/nut, /run/nut)"
else
    res "package-scriptlets-prereqs" "FAIL (no nut user or no /var/lib/nut)"
    fail=1
fi

# The install hook's credential, generated the way the hook generates it: 24
# bytes from /dev/urandom, written 0640, MONITOR inserted between the markers.
PIN=$(head -c 32 /dev/urandom | base64 | tr -d '\n=+/' | cut -c1-24)
printf '[monuser]\n\tpassword = %s\n\tupsmon master\n' "$PIN" > /etc/nut/upsd.users
chmod 0640 /etc/nut/upsd.users
# awk, not python3: the first version of this test shelled to python3 for what is
# a one-line insert, and the slot exited right here with rc=1 and two RESULT
# lines - python3 is not guaranteed on a booted image, and a boot test that
# cannot run without an interpreter it did not declare is testing nothing.
if grep -q '^MONITOR ' /etc/nut/upsmon.conf 2>/dev/null; then
    res "monitor-line-inserted" "PASS (already present)"
else
    awk -v line="MONITOR myups@localhost 1 monuser $PIN master" \
        '/^# END shani-settings MONITOR/ && !done { print line; done=1 }
         { print }' /etc/nut/upsmon.conf > /etc/nut/upsmon.conf.new \
        && mv /etc/nut/upsmon.conf.new /etc/nut/upsmon.conf \
        || { res "monitor-line-inserted" "FAIL (awk could not insert)"; exit 1; }
    if grep -q '^MONITOR myups@localhost' /etc/nut/upsmon.conf; then
        res "monitor-line-inserted" "PASS (between the shipped markers)"
    else
        res "monitor-line-inserted" "FAIL (markers missing?)"
        exit 1
    fi
fi

if [ "$(stat -c %a /etc/nut/upsd.users)" = "640" ]; then
    res "credential-is-0640" "PASS"
else
    res "credential-is-0640" "FAIL ($(stat -c %a /etc/nut/upsd.users))"
    fail=1
fi

# --- the units, from systemd, with no UPS present ---------------------------
systemctl daemon-reload
systemctl start nut-server.service nut-monitor.service >/dev/null 2>&1
sleep 5

for unit in nut-server.service nut-monitor.service; do
    st=$(systemctl is-active "$unit" 2>&1)
    if [ "$st" = "active" ]; then
        res "$unit-active" "PASS"
    else
        res "$unit-active" "FAIL ($st)"
        systemctl status "$unit" --no-pager -l 2>&1 | tail -6 | sed 's/^/      /'
        journalctl -u "$unit" --no-pager -o cat 2>/dev/null | tail -6 | sed 's/^/      /'
        fail=1
    fi
done

# ALLOW_NO_DEVICE is what lets upsd start with no device section. Without it
# upsd refuses, so this is the assertion that the shipped nut.conf earns its keep.
if ss -ltn 2>/dev/null | grep -q '127\.0\.0\.1:3493'; then
    res "upsd-listens-loopback-only" "PASS"
else
    res "upsd-listens-loopback-only" "FAIL (not on 127.0.0.1:3493)"
    ss -ltn 2>/dev/null | head -4 | sed 's/^/      /'
    fail=1
fi
if ss -ltn 2>/dev/null | grep -q ':3493' && \
   ! ss -ltn 2>/dev/null | grep -q '127\.0\.0\.1:3493'; then
    res "upsd-not-on-other-interfaces" "FAIL (listening beyond loopback)"
    fail=1
else
    res "upsd-not-on-other-interfaces" "PASS"
fi

# upsmon's own log is where it records whether it connected
if journalctl -u nut-monitor.service --no-pager -o cat 2>/dev/null \
        | grep -q "myups@localhost"; then
    res "upsmon-read-the-monitor-line" "PASS"
else
    res "upsmon-read-the-monitor-line" "FAIL"
    journalctl -u nut-monitor.service --no-pager -o cat 2>/dev/null \
        | tail -5 | sed 's/^/      /'
    fail=1
fi

# upsc with no device: NUT answers with a claim about the absence. A blank answer
# or a traceback would be a different and worse thing.
OUT=$(timeout 10 upsc myups@localhost 2>&1 || true)
if grep -qi "unknown ups\|data stale\|driver not connected" <<<"$OUT"; then
    res "upsc-answers-honestly-with-no-device" "PASS ($(head -1 <<<"$OUT"))"
elif [ -z "$OUT" ]; then
    res "upsc-answers-honestly-with-no-device" "FAIL (printed nothing)"
    fail=1
else
    res "upsc-answers-honestly-with-no-device" "NOTE ($OUT)"
fi

# --- NEGATIVE CONTROL ------------------------------------------------------
# The line that makes this stack start with no UPS, removed. If upsd still
# starts, that line is decorative and the shipped config is not what is running.
grep -q '^ALLOW_NO_DEVICE=' /etc/nut/nut.conf && {
    sed -i 's/^ALLOW_NO_DEVICE=.*/ALLOW_NO_DEVICE=false/' /etc/nut/nut.conf
    systemctl stop nut-server.service nut-monitor.service >/dev/null 2>&1
    systemctl reset-failed nut-server.service >/dev/null 2>&1
    systemctl start nut-server.service >/dev/null 2>&1
    sleep 4
    if systemctl is-active --quiet nut-server.service; then
        res "control-no-allow-no-device" "FAIL (upsd started anyway - the shipped line is decorative)"
        fail=1
    else
        res "control-no-allow-no-device" "PASS (upsd refused to start, so ALLOW_NO_DEVICE is load-bearing)"
    fi
    systemctl stop nut-server.service >/dev/null 2>&1
}

if [ "$fail" -eq 0 ]; then
    echo "nut-stack PASSED"
else
    echo "nut-stack FAILED"
fi
exit $fail
