#!/bin/bash
# chronoa-driver-skills-results — proves slot-tests/chronoa-driver-skills.sh can
# go red, on the host, with no slot and no boot.
#
# WHY THIS FILE EXISTS. Same argument as every other `*-results.sh` here: a
# slot-test that has only ever printed PASS proves the check ran, not that it can
# say no. This drives the same python the slot runs — extracted from the
# slot-test's own heredoc, not reimplemented — against environments built to
# break each assertion, including the four defects this work shipped and caught:
#
#   1. the Kbuild line, wrong twice (`obj-m := NAME` is the form most tutorials
#      show, and it does not build);
#   2. the EEPROM register denylist, keyed (address, register) against register
#      ranges, so it could not fire on any input at all;
#   3. the consent keys, which must be read from the RUNNING COMPILED schema —
#      `glib-compile-schemas` exits 0 having written nothing, which is how
#      `calendar_write` and `fm_radio` became switches nobody could reach;
#   4. the scaffold clobbering a file the user had already edited.
#
# **Two of the first version's assertions passed for the wrong reason**, which is
# the failure this repo keeps meeting, so both are fixed structurally rather than
# by loosening them:
#   - it asserted a gate that defaults ON fails, but the schema it compiled had
#     no keys in it at all — so the FAIL came from "key absent", not from the
#     default. The scenario now verifies the compiled schema CONTAINS the key
#     before flipping it, and fails loudly if it does not;
#   - it mutated an anchor that appears twice, so the mutation never applied and
#     the check "caught" a failure that was already there for another reason.
#     Every mutation now asserts its anchor is unique, and the file is restored
#     and byte-compared afterwards so a failure cannot leak to the next run.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SLOT_TEST="$ROOT/slot-tests/chronoa-driver-skills.sh"
PKG=$ROOT/../shani-chronoa/usr/lib/shani-chronoa
SCHEMA_XML=$ROOT/../shani-chronoa/usr/share/glib-2.0/schemas

pass=0; fail=0
ok() { printf 'ok %d - %s\n' "$((++pass))" "$1"; }
no() { printf 'not ok %d - %s\n' "$((++fail))" "$1"; }
verdict() { grep -qE "RESULT ${2} +${3}\b" <<<"$1"; }
check() {
  if verdict "$2" "$3" "$4"; then ok "$1"; else
    no "$1"; printf '#   %s expected %s, got: %s\n' "$3" "$4" \
      "$(grep -oE "RESULT ${3} +\S+" <<<"$2" | head -1)"
  fi
}

if [[ ! -d "$PKG" ]]; then
  printf 'Bail out! the chronoa checkout is not beside this harness (%s)\n' "$PKG"
  exit 0
fi

T=$(mktemp -d /var/tmp/drv-skills-XXXXXX)
cleanup() {
  # The mutations below edit the checkout; restore before anything can exit.
  for f in driver_dev.py user_driver.py; do
    [[ -f "$T/$f.bak" ]] && cp "$T/$f.bak" "$PKG/shani_chronoa/skills/$f"
  done
  rm -rf "$T"
}
trap cleanup EXIT
for f in driver_dev.py user_driver.py; do cp "$PKG/shani_chronoa/skills/$f" "$T/$f.bak"; done

# schema <name> — compile the checkout's REAL xml, and refuse to go on if it
# did not produce a compiled store. Without that check a scenario can assert
# "the key defaults on" about a schema that does not contain the key at all, and
# pass for the wrong reason — which is exactly what the first version did.
schema() {
  local d="$T/schema-$1"; mkdir -p "$d"
  cp "$SCHEMA_XML"/*.xml "$d/"
  glib-compile-schemas "$d" >/dev/null 2>&1 || true
  if [[ ! -f "$d/gschemas.compiled" ]]; then
    echo "Bail out! glib-compile-schemas produced nothing in $d"
    exit 0
  fi
  printf '%s' "$d"
}

# flip_default <schema-dir> <key> — set that key's <default> to true, in the XML,
# then recompile. Done in python so a key that is not there is an error rather
# than a silent no-op.
flip_default() {
  python3 - "$1" "$2" <<'PY'
import pathlib, re, sys
d, key = pathlib.Path(sys.argv[1]), sys.argv[2]
p = d / "org.shani.chronoa.gschema.xml"
s = p.read_text()
pat = re.compile(r'(<key name="%s"[^>]*>\s*<default>)([^<]*)(</default>)' % re.escape(key))
if not pat.search(s):
    print(f"ANCHOR-MISSING: no <default> for {key} - refusing to pretend")
    sys.exit(3)
p.write_text(pat.sub(r"\g<1>true\g<3>", s))
PY
  [[ $? == 0 ]] || { echo "Bail out! could not flip a default in $1"; exit 0; }
  glib-compile-schemas "$1" >/dev/null 2>&1
  # The flip must be REAL: read it back through gsettings, which is what the
  # skill will do. A scenario that does not verify its own premise is the
  # "negative control that cannot fail" in its purest form.
  local got
  got=$(GSETTINGS_SCHEMA_DIR="$1" gsettings get org.shani.chronoa "$2" 2>/dev/null || echo "(unreadable)")
  [[ "$got" == "true" ]] || { echo "Bail out! flipping $2 did not take (gsettings says '$got')"; exit 0; }
}

# run_case <name> <schema-dir> — run the slot-test's own python body.
#
# **The argv[1] the body expects is the DIRECTORY THAT HOLDS `home/`,** because
# it builds paths as `T/"home"/"drivers"/...` while HOME is `T/home`. The first
# version passed the home directory itself, so the scaffold wrote to
# `$HOME/drivers/probe` and the checker looked in `$HOME/home/drivers/probe`,
# and six assertions failed with a missing directory — which reads like a broken
# product and was a broken fixture.
run_case() {
  local name=$1 sch=$2 base="$T/run-$1"
  mkdir -p "$base/home"
  local keys
  keys=$(GSETTINGS_SCHEMA_DIR="$sch" gsettings list-keys org.shani.chronoa 2>/dev/null \
         || echo "(schema unreadable)")
  sed -n '/^PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="\$PKG" python3 - "\$T" "\$SCHEMA_KEYS" <<.PY.$/,/^PY$/p' \
    "$SLOT_TEST" | sed '1d;$d' > "$T/$name.py"
  grep -q '^import ' "$T/$name.py" || { echo "Bail out! could not extract the python body"; exit 0; }
  HOME="$base/home" XDG_CONFIG_HOME="$base/home/config" \
  XDG_DATA_HOME="$base/home/data" XDG_STATE_HOME="$base/home/state" \
  GSETTINGS_SCHEMA_DIR="$sch" GSETTINGS_BACKEND=keyfile PYTHONDONTWRITEBYTECODE=1 \
  PYTHONPATH="$PKG" python3 "$T/$name.py" "$base" "$keys" 2>&1
}

mutate() { # mutate <file> <unique-from> <to>
  python3 - "$PKG/shani_chronoa/skills/$1" "$2" "$3" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
n = s.count(sys.argv[2])
if n != 1:
    print(f"ANCHOR-BAD ({n}x) - mutation NOT applied"); sys.exit(9)
p.write_text(s.replace(sys.argv[2], sys.argv[3]))
PY
  return $?
}

# --- the control: an unmodified checkout -------------------------------------
good=$(schema good)
out=$(run_case control "$good")
echo "# --- unmodified checkout, real compiled schema ---"
echo "$out" | grep -E '^RESULT' | sed 's/^/#   /'
check "all five skills are registered"       "$out" "driver-skills-registered" PASS
check "the build gate defaults off"          "$out" "consent-key-driver-build-enabled" PASS
check "the write gate defaults off"          "$out" "consent-key-i2c-write-enabled" PASS
check "driver_status answers"                 "$out" "driver-status-runs" PASS
check "driver_scaffold writes all five"       "$out" "driver-scaffold-writes" PASS
check "the Kbuild line is the one that builds" "$out" "driver-scaffold-kbuild-line" PASS
check "the scaffold does not clobber"         "$out" "driver-scaffold-never-clobbers" PASS
check "scaffolding is not verified as a build" "$out" "driver-scaffold-is-not-verified-as-a-build" PASS
check "the device write is refused"           "$out" "device-i2c-write-gated" PASS
check "the consent grant crosses processes"   "$out" "i2c-write-grant-reaches-a-second-process" PASS
check "the denylist speaks for itself"        "$out" "device-i2c-denylist-is-its-own-refusal" PASS
check "the EEPROM denylist fires"             "$out" "device-i2c-denylist-fires" PASS
check "every probe route is reported"         "$out" "device-probe-reports-every-route" PASS
check "every empty probe route is explained"  "$out" "device-probe-absent-routes-are-explained" PASS

# **The control can answer FAIL, and must.** On this dev box a compiler exists,
# so `driver-status-refuses-here` is EXPECTED to fail here — which is the point:
# it proves the check reads the machine rather than asserting a fixed answer. A
# check that passed on a box with gcc would be a rubber stamp.
if verdict "$out" "driver-status-refuses-here" FAIL; then
  ok "driver_status's refusal tracks the machine (this box HAS a compiler, so it does not refuse)"
else
  no "driver_status's refusal did not track the machine - the check may be a rubber stamp"
fi

# **Same machine-awareness, and it is why this one has no plain PASS here.**
# `driver-build-with-consent-names-the-packages` asserts the ShaniOS answer: gate
# open, no toolchain, so `_run_build` falls through to the missing-package
# refusal. On a host WITH gcc, make and a kernel build tree there is nothing
# missing, so the check FAILS - correctly, because the toolchain branch is not the
# branch this box takes. Demanding PASS on both machines would make the assertion
# a rubber stamp on whichever one ignored it, so it is asserted as
# machine-tracking instead: red here, and green on the slot where the packages are
# genuinely absent. **A check that passes everywhere is not evidence of the thing
# it names** - it is evidence the check has no opinion.
if verdict "$out" "driver-build-with-consent-names-the-packages" FAIL; then
  ok "the toolchain refusal tracks the machine (this box can build, so it does not refuse)"
else
  no "the toolchain refusal passed on a box that has a compiler - it may be a rubber stamp"
fi

# --- a gate that DEFAULTS ON -------------------------------------------------
opened=$(schema opened)
flip_default "$opened" driver-build-enabled
flip_default "$opened" i2c-write-enabled
out=$(run_case opened "$opened")
echo "# --- both gates flipped to default-on ---"
grep -E 'consent-key' <<<"$out" | sed 's/^/#   /'
check "a gate defaulting to true FAILS" "$out" "consent-key-driver-build-enabled" FAIL
check "and so does the second gate"     "$out" "consent-key-i2c-write-enabled" FAIL

# --- the four defects, mutated in the product -------------------------------
# (a) the Kbuild line back to the form that does not build. The anchor is the
#     ACTIVE line, identified by its newline, because the same text appears in
#     the comment listing the measured sweep - mutating both at once is how the
#     first version's anchor matched twice and changed nothing.
if mutate driver_dev.py 'obj-m := @NAME@.o
' 'obj-m := @NAME@
'; then
  out=$(run_case kbuild "$good")
  check "a Makefile that cannot build FAILS the Kbuild check" "$out" "driver-scaffold-kbuild-line" FAIL
fi
cp "$T/driver_dev.py.bak" "$PKG/shani_chronoa/skills/driver_dev.py"

# (b) the EEPROM denylist emptied
if mutate user_driver.py 'for low, high, reason in _FORBIDDEN_REG_RANGES:' 'for low, high, reason in ():'; then
  out=$(run_case denylist "$good")
  check "a denylist that refuses nothing FAILS" "$out" "device-i2c-denylist-fires" FAIL
fi
cp "$T/user_driver.py.bak" "$PKG/shani_chronoa/skills/user_driver.py"

# (c) the scaffold clobbers instead of preserving
# **The guard that has to go is the one in the WRITE loop, not the validate
# loop's.** `_run_scaffold` checks twice - once to refuse to overwrite and once
# to skip writing - so the first version of this mutation disabled the first and
# the scaffold still did the right thing. **A mutation that leaves the behaviour
# intact and a check that cannot see it are the same defect as a test that cannot
# fail**, and the first version of this file had both.
if mutate driver_dev.py '        target = directory / filename
        if target.exists():
            continue
        try:' '        target = directory / filename
        if False:
            continue
        try:'; then
  out=$(run_case clobber "$good")
  check "a scaffold that overwrites an edited file FAILS" "$out" "driver-scaffold-never-clobbers" FAIL
fi
cp "$T/driver_dev.py.bak" "$PKG/shani_chronoa/skills/driver_dev.py"

# (c2) the post-condition is shared by all three skills again - the scaffold
# would then be verified against a `.ko` only `driver_build` produces. This is
# the real defect found by running `driver_scaffold` on this machine.
if mutate driver_dev.py '    if tool == "driver_scaffold":' '    if tool == "driver_scaffold-MUTATED":'; then
  out=$(run_case postcond "$good")
  check "a scaffold verified as a build FAILS" "$out" "driver-scaffold-is-not-verified-as-a-build" FAIL
fi
cp "$T/driver_dev.py.bak" "$PKG/shani_chronoa/skills/driver_dev.py"

# (e) the gate INVERTED - it refuses when the key is on. This is the control for
# `device-i2c-denylist-is-its-own-refusal`, and (d) cannot cover it: (d) opens the
# gate unconditionally, so with the grant made the denylist is still reached and
# that check still passes. **A mutation that leaves a check green is not a control
# for it.** Inverting instead means the skill blames the switch on a machine where
# the switch reads true, which is the exact wrong answer that check names - it
# sends someone to flip a setting that is already set.
if mutate user_driver.py '    if not ChronoaConfig().get_bool(_WRITE_KEY, False):' '    if ChronoaConfig().get_bool(_WRITE_KEY, False):'; then
  out=$(run_case inverted "$good")
  check "a gate that refuses when granted FAILS the denylist check" "$out" "device-i2c-denylist-is-its-own-refusal" FAIL
fi
cp "$T/user_driver.py.bak" "$PKG/shani_chronoa/skills/user_driver.py"

# (f) the BUILD gate stuck shut, which is the control for
# `driver-build-with-consent-names-the-packages`. With the grant made the toolchain
# branch must be what answers, so a gate that refuses anyway is the one failure the
# check names - and it is the failure mode that matters most, because it is the
# switch silently doing nothing. (d) and (e) above are both about the I2C gate and
# cannot reach this one: **a mutation aimed at a different gate leaves a check
# green, which is the same as having no control for it.**
if mutate driver_dev.py '    if not ChronoaConfig().get_bool(_BUILD_KEY, False):' '    if True:'; then
  out=$(run_case buildgate "$good")
  check "a build gate stuck shut FAILS the toolchain refusal" "$out" "driver-build-with-consent-names-the-packages" FAIL
fi
cp "$T/driver_dev.py.bak" "$PKG/shani_chronoa/skills/driver_dev.py"

# **No control is offered for `i2c-write-grant-reaches-a-second-process`, and that
# is stated rather than papered over.** Its failure mode is environmental - the
# private session bus `dbus-run-session` creates has no activatable dconf-service,
# so both writers report success while a child reads the old value - and the
# `mutate` helper here can only edit files under `skills/`, not the config layer
# that would have to be broken. A mutation invented to fill the slot would be the
# negative control that cannot fail, which this file exists to avoid. What it has
# instead is the observed red: that check was run for real against the slot with
# the dconf backend and reported
#     FAIL (parent true, child 'false', on disk False)
# before the keyfile backend was set. The red was measured, not simulated.

# The checkout must be exactly as found, or the failures above leak into whoever
# runs the suite next — which is what a `git stash` round-trip once hid.
for f in driver_dev.py user_driver.py; do
  if cmp -s "$T/$f.bak" "$PKG/shani_chronoa/skills/$f"; then
    ok "$f is byte-identical after the mutations"
  else
    no "$f was left mutated"
  fi
done

echo "1..$((pass + fail))"
printf '# pass %d, fail %d\n' "$pass" "$fail"
[[ "$fail" == 0 ]] || exit 1