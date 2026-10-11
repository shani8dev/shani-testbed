#!/bin/bash
# chronoa-disk-layout-results — proves slot-tests/chronoa-disk-layout.sh can go
# red, on the host, with no slot and no boot.
#
# WHY THIS FILE EXISTS. Same argument as every other `*-results.sh` here: a
# slot-test that has only ever printed PASS proves the check ran, not that it can
# say no. This drives the same python the slot runs — extracted from the
# slot-test's OWN heredoc, not reimplemented, so a change to one cannot silently
# leave the other testing something else — against an environment built to break
# each assertion.
#
# The defects it reproduces are the ones this skill actually shipped:
#
#   1. **the gate read `sense_allowed()` as a `(bool, why)` pair.** The real
#      method returns a bare `bool`, so every call raised `TypeError` — and no
#      in-process test noticed, because the tests called `_measure()` directly.
#      It was found by driving the REAL dispatch path in a sandboxed child. This
#      file drives the real `_run`, so the same fault is reproducible here.
#   2. **loop devices buried the answer.** 32 snap squashfs loops against one
#      real disk; a layout that lists all of them answers a different question.
#   3. **an unknown GPT GUID could be guessed** into a purpose nobody measured.
#   4. **a hidden count that is silently dropped** is the absence-shaped green:
#      "1 disk" and "1 disk plus 32 loops I did not print" are different claims.
#
# **Every mutation asserts its anchor is unique** and the file is restored and
# byte-compared afterwards, so a mutation that never applied cannot be counted as
# a catch — the trap this harness records twice already.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SLOT_TEST="$ROOT/slot-tests/chronoa-disk-layout.sh"
PKG=$ROOT/../shani-chronoa/usr/lib/shani-chronoa
SKILL="$PKG/shani_chronoa/skills/disk_layout.py"
SCHEMA_XML=$ROOT/../shani-chronoa/usr/share/glib-2.0/schemas

pass=0; fail=0
ok() { printf 'ok %d - %s\n' "$((++pass))" "$1"; }
no() { printf 'not ok %d - %s\n' "$((++fail))" "$1"; }

if [[ ! -f "$SKILL" ]]; then
  printf 'Bail out! the chronoa checkout is not beside this harness (%s)\n' "$PKG"
  exit 0
fi
if [[ ! -f "$SLOT_TEST" ]]; then
  printf 'Bail out! the slot-test is missing (%s)\n' "$SLOT_TEST"
  exit 0
fi

T=$(mktemp -d /var/tmp/disk-layout-XXXXXX)
BAK="$T/disk_layout.py.bak"
ORIG_SHA=$(sha256sum "$SKILL" | cut -d' ' -f1)
cp "$SKILL" "$BAK"
cleanup() { cp "$BAK" "$SKILL"; rm -rf "$T"; }
trap cleanup EXIT

# The python the slot runs, extracted from its own heredoc.
sed -n "/<<'PY'/,/^PY$/p" "$SLOT_TEST" | sed '1d;$d' > "$T/probe.py"

# The scenario: a python that reads the probe's own source for the assertions it
# makes, and evaluates them against a deliberately broken skill. That is what
# makes this a test OF the slot-test rather than a second implementation of it.
run_scenario() {
  local label="$1"          # what is broken
  local expect="$2"         # FAIL|PASS expected of the matching assertion
  local match="$3"          # the RESULT name that must change verdict
  shift 3

  # Apply the mutation. $@ is old|new pairs, applied in order.
  python3 - "$SKILL" "$BAK" "$@" <<'PY'
import sys
skill, bak = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
src = open(bak, encoding="utf-8").read()
for i in range(0, len(pairs), 2):
    old, new = pairs[i], pairs[i+1]
    if src.count(old) != 1:
        sys.stderr.write(f"ANCHOR x{src.count(old)}: {old[:60]!r}\n")
        sys.exit(3)
    src = src.replace(old, new, 1)
open(skill, "w", encoding="utf-8").write(src)
PY
  local rc=$?
  if [[ $rc -eq 3 ]]; then
    no "$label (mutation never applied)"
    return
  elif [[ $rc -ne 0 ]]; then
    no "$label (mutation errored)"
    return
  fi

  # Drive the probe's assertions against the mutated skill, in a subprocess that
  # shares only the file: the module is re-imported fresh every time.
  local out
  out=$(SKILL_PATH="$SKILL" PROBE_T="$T" GSETTINGS_SCHEMA_DIR="$GSETTINGS_SCHEMA_DIR" PYTHONPATH="$PKG" python3 - "$T/probe.py" "$match" 2>&1 <<'PY'
import contextlib
import importlib.util
import io
import os
import re
import sys

probe_src, match = open(sys.argv[1]).read(), sys.argv[2]
skill_path = os.environ["SKILL_PATH"]

# Load the MUTATED skill under its real module name, so the probe's own
# `from shani_chronoa.skills import disk_layout` resolves to the mutated file
# rather than the pristine one on disk. Executing it under a DIFFERENT name
# would leave the probe importing the unmutated copy - a control that cannot
# fail, which is the whole reason this file exists.
spec = importlib.util.spec_from_file_location(
    "shani_chronoa.skills.disk_layout", skill_path)
mod = importlib.util.module_from_spec(spec)
sys.modules["shani_chronoa.skills.disk_layout"] = mod
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    spec.loader.exec_module(mod)

buf = io.StringIO()
# The probe reads its scratch dir and the schema keys off argv, exactly as it
# does on the slot; give it the same shape or it fails for a reason that has
# nothing to do with the mutation under test.
sys.argv = ["probe", os.environ.get("PROBE_T", "/tmp"), ""]
# ...and the XDG roots the scratch dir is built out of. Absent, the probe dies on
# a KeyError that has nothing to do with the mutation - which is how a scenario
# "catches" a failure that was already there for another reason.
for var in ("HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME"):
    os.environ.setdefault(var, os.path.join(os.environ.get("PROBE_T", "/tmp"), var.lower()))
    os.makedirs(os.environ[var], exist_ok=True)
os.environ.setdefault("GSETTINGS_BACKEND", "keyfile")
try:
    with contextlib.redirect_stdout(buf):
        exec(compile(probe_src, "probe", "exec"), {"__name__": "__main__"})
except SystemExit:
    pass
except Exception as exc:
    print(f"PROBE-ERROR {type(exc).__name__}: {exc}")
    raise SystemExit(0)
text = buf.getvalue()
line = next((l for l in text.splitlines()
             if re.search(rf"RESULT {re.escape(match)} ", l)), "")
print("MATCH:", line.strip() or "(no such RESULT line)")
PY
)
  cp "$BAK" "$SKILL"

  local got
  got=$(grep -o 'MATCH: RESULT [^ ]* *[A-Z]*' <<<"$out" | grep -oE '[A-Z]+$' || true)
  if [[ -z "$got" ]]; then
    no "$label (probe produced no verdict: $(tr '\n' ' ' <<<"$out" | head -c 160))"
    return
  fi
  if [[ "$got" == "$expect" ]]; then
    ok "$label"
  else
    no "$label (expected the assertion to report $expect, got $got)"
  fi
}

# The probe needs a READABLE consent key or its output assertions are all
# unreachable. Compile the checkout's real schema and refuse to go on if
# glib-compile-schemas produced nothing - a clean exit code alone proves nothing
# here, and the first version of this file ran without a schema at all and got
# four green scenarios that could not have gone red.
SCHEMA_DIR="$T/schemas"; mkdir -p "$SCHEMA_DIR"
cp "$SCHEMA_XML"/*.xml "$SCHEMA_DIR/" 2>/dev/null || true
glib-compile-schemas "$SCHEMA_DIR" >/dev/null 2>&1 || true
if [[ ! -f "$SCHEMA_DIR/gschemas.compiled" ]]; then
  printf 'Bail out! glib-compile-schemas produced nothing in %s\n' "$SCHEMA_DIR"
  exit 0
fi
export GSETTINGS_SCHEMA_DIR="$SCHEMA_DIR"
export PROBE_T="$T"

echo "# scenario 1: the gate unpacking a bare bool as a pair (the shipped bug)"
# The original defect, verbatim: `allowed, why = config.sense_allowed(...)`
# where the real method returns a bare bool. One line, so the file still parses
# - an earlier multi-line replacement produced an IndentationError and the
# scenario reported a load failure rather than the behaviour it was written for.: `allowed, why = config.sense_allowed(...)`
#
# **Targeted at the refusal, not at "it ran".** The first target here was
# `disk-layout-runs-with-consent-on`, which asserts only that *something*
# non-empty came back - and a refusal sentence is also non-empty, so that
# assertion cannot tell a working gate from a broken one. On a machine where
# consent cannot be granted the two are indistinguishable, which is precisely
# the absence-shaped green this harness keeps refusing. The refusal assertion
# names the switch, so it discriminates on its own.
#
# **And why the schema is compiled below.** Without `GSETTINGS_SCHEMA_DIR` the
# config cannot read `storage-sense-enabled` at all, the gate is permanently
# shut, and every assertion about what the skill PRINTS is unreachable - which
# is how scenarios 2-4 first reported PASS for the wrong reason. A grant that
# cannot be made is indistinguishable from one that was never asked for, and
# that is the same absence the probe's own section 4 exists to rule out on a
# real slot.
run_scenario "gate-unpacks-a-bool" FAIL disk-layout-refuses-with-consent-off \
  '    if config.sense_allowed("storage"):' \
  '    allowed, why = config.sense_allowed("storage")
    if allowed:'

echo "# scenario 2: loop devices no longer hidden"
# Targeted at the count assertion, not at "it ran": the count is the fact the
# skill claims about what it withheld, so a build that withholds nothing has to
# fail the claim.
# The hidden-count assertion itself PASSes when there is "nothing to count",
# and it is reached only after the gate - so on a machine where consent cannot be
# granted it cannot discriminate. This scenario therefore targets
# `disk-layout-matches-real-lsblk`, the control that compares the skill's output
# against the REAL lsblk: if every loop device is printed, the 32 snap loops
# appear in the output that is supposed to name the disks, and that comparison is
# exactly what breaks.
run_scenario "loops-not-hidden" FAIL disk-layout-matches-real-lsblk \
  'if not show_hidden and (dev.get("type") or "").lower() in _HIDDEN_LAYERS:' 'if False:'

echo "# scenario 3: an unknown GPT GUID guessed"
run_scenario "unknown-guid-guessed" FAIL disk-layout-unknown-guid-not-guessed \
  'bits.append(known if known else f"GPT type {parttype.strip()}")' \
  'bits.append(known if known else "Linux data partition")'

echo "# scenario 4: a disagreeing GUID/filesystem pair reported as agreeing"
run_scenario "guid-disagreement-hidden" FAIL disk-layout-guid-disagreement-named \
  'if known and fstype_l in _CONTAINER_FSTYPES and fstype_l not in known.lower():' 'if False:'

# The file must be byte-identical to how it started, whatever happened above.
NOW_SHA=$(sha256sum "$SKILL" | cut -d' ' -f1)
if [[ "$NOW_SHA" == "$ORIG_SHA" ]]; then
  ok "the skill file is restored byte-for-byte after every mutation"
else
  no "the skill file was left mutated (a failed assertion would leak to the next run)"
fi

echo "1..$((pass+fail))"
exit $(( fail > 0 ? 1 : 0 ))