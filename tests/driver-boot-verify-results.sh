#!/bin/bash
# driver-boot-verify-results — proves tests/driver-boot-verify.sh can go red,
# on the host, with no slot, no VM and no boot.
#
# WHY THIS FILE EXISTS. `tests/audit-boot-proof.sh`'s practice, restated: the
# audit script "was dry-run against a stub kernel in both directions before the
# boot (a kernel refusing the capset rules made it report FAIL 62 of 64), so the
# boot was confirming a check already known to discriminate". **A checker whose
# first ever run is a real boot has not been shown it can say no** — and this one
# exists to police claims that are already written down, so a checker that only
# ever says PASS is worse than none: it reads as the platform still being
# measured when nothing is.
#
# Three streams are driven:
#   1. the facts MEASURED on the real firmware boot of 2026-10-10, which must
#      pass - so the file is known to accept what the machine actually says;
#   2. doctored streams that must FAIL, each one a way the documented claim
#      could go stale without anyone noticing;
#   3. an incomplete stream, which must FAIL as a failure of the measurement
#      rather than as a verdict about the image - the empty-value trap, which
#      the measurement script itself fell into on its first run.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VERIFY="$HERE/driver-boot-verify.sh"

pass=0; fail=0
ok()  { printf 'ok %d - %s\n' "$((++pass))" "$1"; }
no()  { printf 'not ok %d - %s\n' "$((++fail))" "$1"; }
verdict() { grep -qE "RESULT ${2} +${3}\b" <<<"$1"; }
check() {
  if verdict "$2" "$3" "$4"; then ok "$1"; else
    no "$1"; printf '#   %s expected %s, got: %s\n' "$3" "$4" \
      "$(grep -oE "RESULT ${3} +\S+" <<<"$2" | head -1)"
  fi
}
absent() {
  if verdict "$2" "$3" "$4"; then no "$1 - ${3} reported ${4} when it must not"; else ok "$1"; fi
}

T=$(mktemp -d /var/tmp/drv-verify-XXXXXX); trap 'rm -rf "$T"' EXIT

# --- the stream the real boot produced, 2026-10-10 ---------------------------
# Copied verbatim from the boot's console output, not retyped from memory: a
# fixture reconstructed from what the code was supposed to print is the
# "completing a fixture by hand" trap this repo has hit twice.
cat >"$T/real.facts" <<'EOF'
DRIVERFACT kernel=7.2.6-arch2-1
DRIVERFACT kernel_source=image
DRIVERFACT lockdown_present=yes
DRIVERFACT lockdown=[none] integrity confidentiality
DRIVERFACT lockdown_bracketed=[none]
DRIVERFACT secureboot=absent
DRIVERFACT var_fstype=tmpfs
DRIVERFACT modulesdir=readonly
DRIVERFACT builddir=absent
DRIVERFACT pacman=/usr/bin/pacman
DRIVERFACT has_modprobe=/usr/bin/modprobe
DRIVERFACT has_insmod=/usr/bin/insmod
DRIVERFACT has_i2cdetect=/usr/bin/i2cdetect
DRIVERFACT has_v4l2-ctl=/usr/bin/v4l2-ctl
DRIVERFACT has_fusermount3=/usr/bin/fusermount3
DRIVERFACT i2c_node_count=1
DRIVERFACT i2c_node_sample=crw-rw----+ 1 root i2c 89, 0 Oct 10 06:32 /dev/i2c-0
DRIVERFACT dev_fuse=present
DRIVERFACT fuse_mounts=4
DRIVERFACT v4l2_rc=0
DRIVERFACT done=yes
EOF
out=$(bash "$VERIFY" "$T/real.facts" 2>&1)
echo "# --- the measured stream ---"
echo "$out" | grep -E '^RESULT' | sed 's/^/#   /'
check "the stream is complete"                    "$out" "fact-stream-complete" PASS
check "the boot was the image's own kernel"       "$out" "boot-is-the-images-kernel" PASS
check "the lockdown format is the bracketed one"  "$out" "lockdown-format" PASS
check "an unsigned module is not refused here"    "$out" "unsigned-modules-not-refused" PASS
check "the absent efivar is a SKIP, not a verdict" "$out" "secureboot-state" SKIP
check "/var is volatile"                          "$out" "var-is-volatile" PASS
check "the module directory is read-only"         "$out" "module-dir-readonly" PASS
check "there is no build toolchain"               "$out" "no-build-toolchain" PASS
check "the i2c node is not world-writable"        "$out" "i2c-nodes-not-world-writable" PASS
# And it must have reached the end rather than stopping at the first failure.
if grep -q '^== verification done' <<<"$out"; then ok "the verifier reached its end"
else no "the verifier reached its end"; fi

# **No check may report twice.** The verifier once carried a superseded `case`
# block beside the if/elif chain that replaced it, so `module-dir-readonly` was
# emitted twice on a live run - a PASS and a PASS, which reads as one strong
# result and is in fact one result and one leftover. Every other check here is
# about a verdict being right; this one is about there being exactly one of it.
dupes=$(grep -oE '^RESULT [^ ]+' <<<"$out" | awk '{print $2}' | sort | uniq -d)
if [ -z "$dupes" ]; then ok "every check reports exactly once"
else no "these checks reported more than once: $dupes"; fi
nres=$(grep -c '^RESULT ' <<<"$out")
if [ "$nres" = 9 ]; then ok "the verifier emits 9 verdicts (was 10 with the duplicate)"
else no "the verifier emits 9 verdicts, got $nres"; fi

# --- doctored streams that must FAIL -----------------------------------------
# Each is one documented claim going stale, which is what this file exists to
# notice. They are copies of the real stream with ONE line changed, so nothing
# else can be responsible for the verdict.

d() { sed "$2" "$T/real.facts" >"$T/$1"; bash "$VERIFY" "$T/$1" 2>&1; }

o=$(d sb-on.s 's|^DRIVERFACT secureboot=.*|DRIVERFACT secureboot=readable byte=01|')
echo "# --- Secure Boot turned on ---"
check "an enabled SecureBoot efivar FAILS" "$o" "secureboot-state" FAIL

o=$(d locked.s 's|^DRIVERFACT lockdown_bracketed=.*|DRIVERFACT lockdown_bracketed=[integrity]|')
check "an enforced lockdown mode FAILS" "$o" "unsigned-modules-not-refused" FAIL

o=$(d var-not-tmpfs.s 's|^DRIVERFACT var_fstype=.*|DRIVERFACT var_fstype=btrfs|')
check "a non-tmpfs /var FAILS the volatility claim" "$o" "var-is-volatile" FAIL

o=$(d modules-writable.s 's|^DRIVERFACT modulesdir=.*|DRIVERFACT modulesdir=writable|')
check "a writable module directory FAILS" "$o" "module-dir-readonly" FAIL

o=$(d with-gcc.s 's|^DRIVERFACT has_i2cdetect=.*|DRIVERFACT has_gcc=/usr/bin/gcc\nDRIVERFACT has_i2cdetect=/usr/bin/i2cdetect|')
check "a compiler on the image FAILS the toolchain claim" "$o" "no-build-toolchain" FAIL

o=$(d unbracketed.s 's|^DRIVERFACT lockdown_bracketed=.*|DRIVERFACT lockdown_bracketed=|')
check "a lockdown file with no bracketed mode FAILS" "$o" "lockdown-format" FAIL

o=$(d host-kernel.s 's|^DRIVERFACT kernel_source=.*|DRIVERFACT kernel_source=host|')
check "a host-kernel boot FAILS the attribution check" "$o" "boot-is-the-images-kernel" FAIL

o=$(d world-writable.s 's|^DRIVERFACT i2c_node_sample=.*|DRIVERFACT i2c_node_sample=crw-rw-rw- 1 root root 89, 0 /dev/i2c-0|')
check "a world-writable i2c node FAILS" "$o" "i2c-nodes-not-world-writable" FAIL

# --- the incomplete stream, which is the measurement's own failure -----------
# The measurement script's first run printed `linux_pkg=` and `headers_pkg=` as
# EMPTY strings for an unreadable package database, which reads as a measured
# absence. This stream is that shape: keys present, values absent.
grep -v '^DRIVERFACT var_fstype=' "$T/real.facts" >"$T/incomplete.facts"
o=$(bash "$VERIFY" "$T/incomplete.facts" 2>&1)
echo "# --- a stream with a key missing ---"
grep -E 'fact-stream-complete' <<<"$o" | sed 's/^/#   /'
check "a missing key FAILS the completeness check" "$o" "fact-stream-complete" FAIL
# Stopping is the point: after a completeness FAIL the verifier must not go on to
# offer verdicts about the image. Asserted as ABSENCE, and the first version of
# this asserted it as presence - which would have been satisfied only if the
# verifier carried on past its own failure.
absent "no verdict about signing is offered either" "$o" "unsigned-modules-not-refused" PASS
absent "no verdict about the image is offered" "$o" "var-is-volatile" PASS
# **The exit code is the contract, not the end marker.** The verifier prints its
# end marker in both paths - a run that stopped early still finished the thing a
# reader is waiting on - so the marker says nothing about whether it went on to
# judge the image, and the exit status does. The first version of this asserted
# on the marker and was checking the wrong signal.
if bash "$VERIFY" "$T/incomplete.facts" >/dev/null 2>&1; then
  no "an incomplete stream exits non-zero"
else
  ok "an incomplete stream exits non-zero"
fi

# The attribution key on its own: a stream with no `kernel_source` cannot say
# which machine its facts describe, so nothing below it may be believed. This is
# a separate case from the one above because a stream can lose a key by a bug in
# the measurement and by a truncation in a pipe, and only one of them is likely.
grep -v '^DRIVERFACT kernel_source=' "$T/real.facts" >"$T/no-attribution.facts"
o=$(bash "$VERIFY" "$T/no-attribution.facts" 2>&1)
check "a stream with no kernel_source FAILS completeness" "$o" "fact-stream-complete" FAIL
absent "and offers no verdict about the image" "$o" "boot-is-the-images-kernel" PASS

echo "1..$((pass + fail))"
printf '# pass %d, fail %d\n' "$pass" "$fail"
[[ "$fail" == 0 ]] || exit 1