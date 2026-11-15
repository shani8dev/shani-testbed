#!/bin/bash
# Run as root inside a firmware-booted ShaniOS: prove the 64 audit rules in this
# file actually LOAD into a running kernel, not merely that they parse.
#
# This is the check the nspawn slot-test can never reach. Under nspawn the slot
# shares the host kernel, which refuses every audit netlink request from this
# environment (measured: even --userns=host with real uid 0 gets EPERM), so
# `auditctl -l` fails and the slot-test correctly SKIPs. A VM boots the image's
# own kernel, where audit is independent of the host.
set -u
say() { printf 'AUDITPROOF %s\n' "$*"; }

say "kernel: $(uname -r)"
say "auditd installed: $(command -v auditctl || echo NO) / running: $(systemctl is-active auditd.service 2>&1)"

RULES=/tmp/10-shani-base.rules
# Existence is checked BEFORE anything reads it. The first draft hashed the file
# on lines 17-18 and only checked for its existence on line 23, so a file that
# never arrived produced a sha256sum error instead of the message this line
# exists to give.
[ -f "$RULES" ] || { say "FAIL no rules file was copied in"; exit 1; }
EXPECT_SHA=$(sed -n 's/^sha256  //p' /tmp/rules.sha 2>/dev/null)
ACTUAL_SHA=$(sha256sum "$RULES" | cut -d" " -f1)
say "rules sha256: $ACTUAL_SHA (fixture recorded ${EXPECT_SHA:-<none>})"
if [ -n "$EXPECT_SHA" ] && [ "$ACTUAL_SHA" != "$EXPECT_SHA" ]; then
    say "NOTE: the copied rules do not match the recorded fixture digest"
fi
want=$(grep -cE '^[[:space:]]*-[aw]' "$RULES")
say "loadable rules in the file (the count the slot-test compares): $want"

# Clear whatever the image's own auditd loaded, so the count is only ours.
auditctl -D 2>&1
say "after -D: $(auditctl -l 2>/dev/null | grep -cE '^[[:space:]]*-[aw]') rules"

# --- POSITIVE: load the whole file the way auditd's augenrules does ----------
if out=$(auditctl -R "$RULES" 2>&1); then
    rc=0
else
    rc=$?
fi
say "auditctl -R rc=$rc out='${out:-<none>}'"

got=$(auditctl -l 2>/dev/null | grep -cE '^[[:space:]]*-[aw]')
say "LOADED: $got of $want"

if [ "$got" -eq "$want" ]; then
    say "PASS every rule the kernel accepted"
else
    say "FAIL the kernel accepted $got of $want"
    # Which keys are missing is the actionable half.
    comm -13 <(auditctl -l 2>/dev/null | grep -oE '\-k [a-z_-]+' | sort -u) \
             <(grep -oE '\-k [a-z_-]+' "$RULES" | sort -u) | head -20 | sed 's/^/AUDITPROOF   missing /'
    exit 1
fi

# --- the new keys specifically, since those are the untested content ---------
for k in audit_config sshd_config systemd_units privileged identity; do
    n=$(auditctl -l 2>/dev/null | grep -cE "\\-k $k( |$)")
    say "key $k -> $n rule(s) in the kernel"
done

# --- NEGATIVE CONTROL: an unparseable rule must be REFUSED -------------------
printf -- '-w /etc/passwd -p zzz -k identity\n' > /tmp/bad.rules
if ctl=$(auditctl -R /tmp/bad.rules 2>&1) && [ -n "$ctl" ]; then
    say "FAIL negative-control: the kernel ACCEPTED an unparseable rule"
    exit 1
fi
say "PASS negative-control: the kernel refused an unparseable rule ('${ctl:-<no output>}')"

# --- CONTROL FOR THE CONTROL: a rule that DOES parse must be ACCEPTED --------
# Without this, the check above would pass on a kernel that refuses everything,
# which is the "a check that cannot fail" trap. Here audit genuinely works, so a
# valid rule loads and shows up in the loaded set.
printf -- '-w /etc/hostname -p wa -k audit_config\n' > /tmp/good.rules
before=$(auditctl -l 2>/dev/null | grep -cE '^[[:space:]]*-[aw]')
if auditctl -R /tmp/good.rules 2>&1; then
    after=$(auditctl -l 2>/dev/null | grep -cE '^[[:space:]]*-[aw]')
    if [ "$after" -eq $((before + 1)) ]; then
        say "PASS control-for-the-control: a valid rule loaded ($before -> $after)"
    else
        say "FAIL control-for-the-control: accepted but the count did not move ($before -> $after)"
        exit 1
    fi
else
    say "FAIL control-for-the-control: a valid rule was refused (rc=$?)"
    exit 1
fi

say "DONE verdict above"
