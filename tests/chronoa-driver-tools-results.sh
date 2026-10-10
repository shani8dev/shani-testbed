#!/bin/bash
# chronoa-driver-tools-results — proves slot-tests/chronoa-driver-tools.sh can go
# red, on the host, with no slot and no docker.
#
# WHY THIS FILE EXISTS. chronoa-singing-results.sh established the argument and
# chronoa-cli-formats-results.sh repeated it: a slot-test that has only ever
# printed PASS proves the check ran, not that it can say no. This one drives the
# same assertions through the seam the slot-test reads captures from
# ($DRIVER_TOOLS_CAPTURE_DIR), feeding them both honest and doctored captures.
#
# **The doctored captures are the measurements that were wrong, not invented
# ones.** All four are the real defect or the real environment this work hit:
#
#   - lockdown read whole instead of by its bracketed active mode, so an
#     unlocked machine was called "locked down" (the exact bug found by
#     running on a dev box);
#   - a kernel build tree appearing, i.e. an image that DOES have a toolchain -
#     which is the case where driver_status's refusal becomes the stale claim,
#     so the test has to notice it;
#   - kmod's insmod missing, so nothing could load a module even where it
#     could be built;
#   - a world-readable /dev/i2c node, which would mean any user can write any
#     device and the skill's permission refusal says nothing about that.
#
# Anything the assertions read outside the capture directory is skipped here
# rather than faked, and a scenario that produces no RESULT line at all is a
# failure of this file rather than a pass for the slot-test.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SLOT_TEST="$ROOT/slot-tests/chronoa-driver-tools.sh"

pass=0; fail=0
ok()   { printf 'ok %d - %s\n' "$((++pass))" "$1"; }
no()   { printf 'not ok %d - %s\n' "$((++fail))" "$1"; }
# Matched by NAME and VERDICT, never by the RESULT line's exact spacing: the
# name field is `%-46s`, so an assertion written against a counted run of
# spaces breaks when a name gets longer. Recorded in this repo's AGENTS.md for
# the espeak argv; the same lesson, different place.
verdict() { grep -qE "RESULT ${2} +${3}\b" <<<"$1"; }
check() { # check <desc> <haystack> <name> <verdict>
  if verdict "$2" "$3" "$4"; then ok "$1"; else
    no "$1"; printf '#   %s expected %s, got: %s\n' "$3" "$4" \
      "$(grep -oE "RESULT ${3} +\S+" <<<"$2" | head -1)"
  fi
}
absent() { # absent <desc> <haystack> <name> <verdict>
  if verdict "$2" "$3" "$4"; then no "$1 - ${3} reported ${4} when it should not have"; else ok "$1"; fi
}

SCEN=$(mktemp -d /var/tmp/drivetools-XXXXXX)
trap 'rm -rf "$SCEN"' EXIT

# scenario <name>; sets $W to a fresh capture dir to fill
scenario() {
  W="$SCEN/$1"; mkdir -p "$W"
  printf '%s\n' "$W"
}

# The desktop profile as measured: no toolchain, kmod present, no build tree.
desktop_capture() { # desktop_capture <dir>
  local d=$1
  : >"$d/have-gcc.absent"; : >"$d/have-make.absent"; : >"$d/have-dkms.absent"
  printf '/usr/bin/modprobe\n' >"$d/have-modprobe"
  printf '/usr/bin/insmod\n'   >"$d/have-insmod"
  printf '/usr/bin/modinfo\n'  >"$d/have-modinfo"
  printf '7.2.6-arch2-1\n'     >"$d/uname"
  : >"$d/builddir.absent"
  # The real lockdown line from the dev box, verbatim.
  printf '[none] integrity confidentiality\n' >"$d/lockdown"
  printf 'enabled\n' >"$d/secureboot"
  printf 'readonly\n' >"$d/modulesdir"
  printf 'tmpfs\n' >"$d/varfstype"
  cat >"$d/i2c-nodes" <<'EOF'
crw-rw---- 1 root i2c 254, 0 Sep 30 09:12 /dev/i2c-0
crw-rw---- 1 root i2c 254, 1 Sep 30 09:12 /dev/i2c-1
EOF
  printf '0\n' >"$d/i2cdetect-l.rc"
  printf 'i2c-0  i2c  SM501/SM502\ni2c-1  i2c  SM501/SM502\n' >"$d/i2cdetect-l.out"
  printf '0\n' >"$d/v4l2-devices.rc"
  printf 'Integrated_Webcam_HD (usb-0000:00:14.0-1):\n\t/dev/video0\n' >"$d/v4l2-devices.out"
  printf 'fusermount3\n' >"$d/fusehelper"
  printf 'present\n' >"$d/devfuse"
  : >"$d/mountinfo-fuse"
}

# --- scenario 1: the desktop profile, as measured ------------------------------
d1=$(scenario desktop); desktop_capture "$d1"
out1=$(DRIVER_TOOLS_CAPTURE_DIR="$d1" bash "$SLOT_TEST" 2>&1)
echo "# --- desktop profile ---"
echo "$out1" | grep -E '^RESULT|^== ' | sed 's/^/#   /'

check "the missing build tree is reported as a measurement" "$out1" "kernel-build-tree" PASS
check "a missing compiler is recorded, not a failure"        "$out1" "toolchain-gcc" PASS
check "a missing dkms is recorded too"                       "$out1" "toolchain-dkms" PASS
check "kmod's modprobe is present"                           "$out1" "kmod-modprobe" PASS
check "the bracketed lockdown mode is read"                  "$out1" "lockdown-format" PASS
check "the efivar reading is recorded with why it matters"    "$out1" "secureboot-efivar" PASS
check "the read-only module location is recorded"            "$out1" "module-install-location" PASS
check "i2c nodes are counted"                                "$out1" "i2c-nodes" PASS
check "i2cdetect's bus-list shape is accepted"               "$out1" "i2cdetect-shape" PASS
check "v4l2 shape is accepted"                               "$out1" "v4l2-shape" PASS
check "the fuse helper is present"                           "$out1" "fuse-helper" PASS
# **Every one of those lines must name something.** A RESULT line whose detail
# is empty is a check that examined nothing and is indistinguishable from one
# that worked - the `0/0` rule from this repo's AGENTS.md, in new clothes.
if grep -E '^RESULT ' <<<"$out1" | grep -qE 'PASS \(\)|PASS$'; then
  no "no RESULT line has an empty detail"
else
  ok "no RESULT line has an empty detail"
fi

# --- scenario 2: lockdown with no bracketed mode -------------------------------
# The shape the parser reports as UNKNOWN. A test that accepted any content
# here would pass on the very file that caused the bug.
d2=$(scenario lockdown-unbracketed); desktop_capture "$d2"
printf 'none\n' >"$d2/lockdown"
out2=$(DRIVER_TOOLS_CAPTURE_DIR="$d2" bash "$SLOT_TEST" 2>&1)
echo "# --- lockdown with no [active] token ---"
grep -E 'lockdown-format' <<<"$out2" | sed 's/^/#   /'
check "an unbracketed lockdown file FAILS the format check" "$out2" "lockdown-format" FAIL

# --- scenario 3: lockdown absent ------------------------------------------------
d3=$(scenario lockdown-absent); desktop_capture "$d3"
: >"$d3/lockdown.absent"
out3=$(DRIVER_TOOLS_CAPTURE_DIR="$d3" bash "$SLOT_TEST" 2>&1)
echo "# --- no lockdown file ---"
grep -E 'lockdown-format' <<<"$out3" | sed 's/^/#   /'
check "an absent lockdown file SKIPs naming the reason" "$out3" "lockdown-format" SKIP
absent "an absent lockdown file does not also FAIL" "$out3" "lockdown-format" FAIL

# --- scenario 4: an image that HAS a toolchain ---------------------------------
# The case where driver_status's refusal is the stale claim. The test has to be
# able to see this, so this scenario must go green on the presence lines and
# the build-tree line must report present rather than absent.
d4=$(scenario with-toolchain); desktop_capture "$d4"
# The marker has to be REMOVED, not rewritten: the first version of this
# scenario re-created `have-gcc.absent` right after writing the presence file,
# so the slot-test correctly kept reporting "not on this image" and this
# file's own assertion failed for the fixture's reason.
printf '/usr/bin/gcc\n' >"$d4/have-gcc";  rm -f "$d4/have-gcc.absent"
printf '/usr/bin/make\n' >"$d4/have-make"; rm -f "$d4/have-make.absent"
printf '/usr/bin/dkms\n' >"$d4/have-dkms"; rm -f "$d4/have-dkms.absent"
printf '/usr/lib/modules/7.2.6-arch2-1/build\n' >"$d4/builddir"; rm -f "$d4/builddir.absent"
printf '[none] integrity confidentiality\n' >"$d4/lockdown"
out4=$(DRIVER_TOOLS_CAPTURE_DIR="$d4" bash "$SLOT_TEST" 2>&1)
echo "# --- an image with a full toolchain ---"
grep -E 'kernel-build-tree|toolchain-' <<<"$out4" | sed 's/^/#   /'
check "a present compiler is reported as present"  "$out4" "toolchain-gcc" PASS
if grep -E 'RESULT kernel-build-tree' <<<"$out4" | grep -q 'ABSENT'; then
  no "a present build tree is not reported as absent"
else
  ok "a present build tree is not reported as absent"
fi
# The sentence the slot-test prints in that case must say the refusal does not
# apply, because that is the documentation this scenario exists to keep honest.
if grep -E 'RESULT toolchain-gcc' <<<"$out4" | grep -q 'must NOT claim otherwise'; then
  ok "a toolchain-present line tells the reader the refusal no longer applies"
else
  no "a toolchain-present line tells the reader the refusal no longer applies"
fi

# --- scenario 5: kmod missing, so a module could not be loaded ------------------
d5=$(scenario no-kmod); desktop_capture "$d5"
: >"$d5/have-insmod.absent"; rm -f "$d5/have-insmod"
out5=$(DRIVER_TOOLS_CAPTURE_DIR="$d5" bash "$SLOT_TEST" 2>&1)
echo "# --- kmod's insmod absent ---"
grep -E 'kmod-insmod' <<<"$out5" | sed 's/^/#   /'
check "a missing insmod FAILS" "$out5" "kmod-insmod" FAIL

# --- scenario 6: a world-readable i2c node -------------------------------------
# If any user can write any device, the skill's permission refusal is not the
# whole story and the node listing is where that would be visible.
d6=$(scenario i2c-world-writable); desktop_capture "$d6"
cat >"$d6/i2c-nodes" <<'EOF'
crw-rw-rw- 1 root root 254, 0 Sep 30 09:12 /dev/i2c-0
EOF
out6=$(DRIVER_TOOLS_CAPTURE_DIR="$d6" bash "$SLOT_TEST" 2>&1)
grep -E 'i2c-nodes' <<<"$out6" | sed 's/^/#   /'
check "a world-writable i2c node is still counted as a node" "$out6" "i2c-nodes" PASS

# --- scenario 7: no fuse helper at all -----------------------------------------
d7=$(scenario no-fuse); desktop_capture "$d7"; rm -f "$d7/fusehelper"
out7=$(DRIVER_TOOLS_CAPTURE_DIR="$d7" bash "$SLOT_TEST" 2>&1)
echo "# --- no fusermount helper ---"
grep -E 'fuse-helper' <<<"$out7" | sed 's/^/#   /'
check "an absent fuse helper FAILS" "$out7" "fuse-helper" FAIL

# --- scenario 8: nothing at all ------------------------------------------------
# A capture directory with no measurements must produce **no verdict at all**.
#
# The first version of this assertion demanded zero RESULT lines, and it was
# wrong: with nothing measured the honest answer is one SKIP per assertion, each
# naming what it did not measure. What must never appear is a PASS or a FAIL -
# a PASS for an unmeasured thing is the `0/0` rule (a result that examined
# nothing), and a FAIL for it is the same confident wrong verdict the other
# direction. This scenario is what found the file printing 11 PASSes on an
# empty capture, then 2 FAILs, before the three-state branches existed.
d8=$(scenario empty)
out8=$(DRIVER_TOOLS_CAPTURE_DIR="$d8" bash "$SLOT_TEST" 2>&1)
verdicts=$(grep -oE '^RESULT [^ ]+ +(PASS|FAIL|SKIP)' <<<"$out8" | awk '{print $NF}' | sort | uniq -c | tr '\n' ' ')
n=$(grep -cE '^RESULT ' <<<"$out8" || true)
echo "# --- empty capture directory ---"
printf '#   %s line(s): %s\n' "$n" "${verdicts:-none}"
if grep -qE '^RESULT [^ ]+ +(PASS|FAIL)\b' <<<"$out8"; then
  no "an unmeasured capture produced a verdict"
  grep -E '^RESULT .* (PASS|FAIL)' <<<"$out8" | sed 's/^/#   /'
else
  ok "an unmeasured capture produced no PASS and no FAIL ($n SKIP(s), each naming what it did not measure)"
fi

echo "1..$((pass + fail))"
printf '# pass %d, fail %d\n' "$pass" "$fail"
[[ "$fail" == 0 ]] || exit 1