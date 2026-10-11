#!/bin/bash
# chronoa-binary-hardening-results — proves slot-tests/chronoa-binary-hardening.sh
# can go red, on the host, with no slot and no boot.
#
# WHY THIS FILE EXISTS. Same argument as every other `*-results.sh` here: a
# slot-test that has only ever printed PASS proves the check ran, not that it can
# say no. This drives the same python the slot runs — extracted from the
# slot-test's OWN heredoc, not reimplemented, so the two cannot drift apart
# unnoticed — against deliberately broken builds of the skill.
#
# The defects reproduced are the ones this skill actually shipped, and every one
# is the shape of a confident wrong answer:
#
#   1. **PIE from the header word alone.** `DYN` is also what a shared object
#      reports, so a library would be called a PIE executable.
#   2. **A missing `GNU_STACK` treated as an executable stack.** Measured: a
#      `gcc -c` object has no such segment at all, which is not the same as NX
#      being off.
#   3. **A canary read as a defined symbol.** The real symbol is an UNDEFINED
#      import (`__stack_chk_fail@GLIBC_2.4`), because the check itself lives in
#      libc - so requiring a definition misses every dynamically linked binary.
#   4. **`BIND_NOW` only.** A toolchain that emits `FLAGS_1 ... NOW` instead
#      would then report Full RELRO as absent.
#   5. **A non-zero readelf ignored**, so a text file gets a verdict.
#
# **Every mutation asserts its anchor is unique** and the file is restored and
# byte-compared afterwards, so a mutation that never applied cannot be counted as
# a catch - the trap this harness has already hit twice.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SLOT_TEST="$ROOT/slot-tests/chronoa-binary-hardening.sh"
PKG=$ROOT/../shani-chronoa/usr/lib/shani-chronoa
SKILL="$PKG/shani_chronoa/skills/binary_hardening.py"

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

T=$(mktemp -d /var/tmp/bin-hardening-XXXXXX)
BAK="$T/binary_hardening.py.bak"
ORIG_SHA=$(sha256sum "$SKILL" | cut -d' ' -f1)
cp "$SKILL" "$BAK"
cleanup() { cp "$BAK" "$SKILL"; rm -rf "$T"; }
trap cleanup EXIT

# The python the slot runs, taken from its own heredoc.
sed -n "/<<'PY'/,/^PY$/p" "$SLOT_TEST" | sed '1d;$d' > "$T/probe.py"
if [[ ! -s "$T/probe.py" ]]; then
  printf 'Bail out! could not extract the probe from the slot-test\n'
  exit 0
fi

# The scenarios. Each is (label, assertion that must go red, python source, old, new).
run_scenario() {
  local label="$1" match="$2" old="$3" new="$4"

  python3 - "$SKILL" "$BAK" "$old" "$new" <<'PY'
import sys
skill, bak, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
src = open(bak, encoding="utf-8").read()
if src.count(old) != 1:
    sys.stderr.write(f"ANCHOR x{src.count(old)}\n")
    sys.exit(3)
open(skill, "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
  local rc=$?
  if [[ $rc -eq 3 ]]; then
    no "$label (the mutation never applied - its anchor is not unique)"
    return
  elif [[ $rc -ne 0 ]]; then
    no "$label (the mutation errored)"
    return
  fi

  # PYTHONDONTWRITEBYTECODE is not optional here: a stale .pyc served the
  # pristine module to a mutated file and two scenarios read as survivors - this
  # harness's recorded fourth instance of the bytecode trap.
  local out
  out=$(PYTHONDONTWRITEBYTECODE=1 SKILL_PATH="$SKILL" PROBE_T="$T" \
        PYTHONPATH="$PKG" python3 - "$T/probe.py" "$match" 2>&1 <<'PY'
import contextlib, importlib.util, io, os, re, sys

probe_src, match = open(sys.argv[1]).read(), sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "shani_chronoa.skills.binary_hardening", os.environ["SKILL_PATH"])
mod = importlib.util.module_from_spec(spec)
sys.modules["shani_chronoa.skills.binary_hardening"] = mod
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    spec.loader.exec_module(mod)

# The probe reads its scratch dir and the compiler flag off argv, as it does on
# the slot; absent, it fails for a reason that has nothing to do with the build
# under test.
# argv[2] is "does this machine have a C compiler", which decides whether the
# probe builds its controls at all. Passed as 1 whenever a compiler is really
# present, because the scenarios below are aimed at assertions that only run once
# the controls exist - and a scenario that SKIPs is not a catch.
sys.argv = ["probe", os.environ.get("PROBE_T", "/tmp"),
            "1" if __import__("shutil").which("cc") else "0"]
for v in ("HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME"):
    os.environ.setdefault(v, os.path.join(os.environ.get("PROBE_T", "/tmp"), v.lower()))
    os.makedirs(os.environ[v], exist_ok=True)
os.environ.setdefault("GSETTINGS_BACKEND", "keyfile")

buf = io.StringIO()
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
  local got
  got=$(grep -oE '(FAIL|PASS|SKIP)$| FAIL| PASS| SKIP' <<<"$out" | tail -1 || true)
  # **Restore FIRST, then judge.** A probe that raises used to leave the mutated
  # file in place, and the next scenario then mutated an already-broken build -
  # so a defect was reported against a source nobody had. That is exactly the
  # "a failed assertion corrupts the run instead of reporting itself" shape,
  # and it cost a real session: a leftover mutation produced a `TypeError` that
  # read like a defect in the shipped skill. The restore is unconditional and
  # comes before any decision about the verdict.
  cp "$BAK" "$SKILL"

  if grep -q "PROBE-ERROR" <<<"$out"; then
    no "$label (the probe itself failed: $(grep -o 'PROBE-ERROR.*' <<<"$out" | head -c 120))"
  elif [[ -z "$got" ]]; then
    no "$label (no verdict: $(tr '\n' ' ' <<<"$out" | head -c 160))"
  elif [[ "$got" == *"FAIL"* ]]; then
    ok "$label"
  else
    no "$label (expected FAIL, got $got - the check cannot see this defect)"
  fi
}

echo "# 1. PIE from the header word alone - a shared library would be called PIE"
# **Retargeted twice, and the reason is a property of the data rather than of
# the check.** It first aimed at `agrees-with-readelf`; on this host that
# comparison is against `/usr/bin/env`, which measures as fully hardened (PIE,
# RELRO, NOW, canary all present), so a build that decides PIE from the header
# word reaches the *same answer* and the check has nothing to disagree with. A
# check can only fail on a value the data actually takes, so the target is the
# control built specifically to be the other value: `-no-pie` measures
# `Type: EXEC`, and "not PIE" is the only answer that can be wrong there.
run_scenario "pie-from-header-word-alone" bin-hardening-control-non-pie \
  'out["pie"] = etype == "DYN"' 'out["pie"] = etype != "REL"'

echo "# 2. a missing GNU_STACK treated as an executable stack"
# Targeted at the relocatable control: a `.o` has no GNU_STACK segment at all,
# so a build that treats "no segment" as an executable stack either calls the
# file unhardened or raises while reaching for a line that is not there. Both
# are wrong answers about a file that has not been linked yet.
run_scenario "missing-gnu-stack-called-exec" bin-hardening-control-relocatable \
  'if stack_line is None:' 'if stack_line is not None:'

echo "# 3. the canary demanded as a DEFINED symbol"
run_scenario "canary-must-be-defined" bin-hardening-agrees-with-readelf \
  '_CANARY = re.compile(r"__stack_chk_fail")' '_CANARY = re.compile(r"__stack_chk_fail(?!@)")'

echo "# 4. the exec-stack flag read as a substring instead of a column"
# **This scenario was aimed at the wrong control for a real reason, and the
# measurement is the point.** `cc -Wl,-z,now` on this toolchain emits BOTH
# spellings together - measured: `(FLAGS) BIND_NOW` *and* `(FLAGS_1) Flags: NOW
# PIE` on the same binary - and `-Wl,-z,lazy` removes both. So there is no
# binary on this box where only the FLAGS spelling is present, which means a
# build that dropped the FLAGS check produces the *same answer* on every binary
# here. A check can only fail on a value the data actually takes: this needs a
# linker that emits one spelling without the other, which is a slot question,
# not a host one.
#
# So it is aimed at the exec-stack control instead, where the same class of
# mistake (reading a whole line instead of its flag column) is measurable: a
# `\bR` substring over the GNU_STACK line matches every ordinary R segment.
run_scenario "gnu-stack-flag-column-read-loosely" bin-hardening-control-plain-stack \
  '_EXECSTACK = re.compile(r"\bRWE\b")' '_EXECSTACK = re.compile(r"R")'

echo "# 5. a non-zero readelf ignored, so a text file gets a verdict"
run_scenario "nonzero-readelf-ignored" bin-hardening-refuses-a-non-elf-file \
  'if proc.returncode != 0:' 'if False:'

# The file must be byte-identical to how it started, whatever happened above.
if [[ "$(sha256sum "$SKILL" | cut -d' ' -f1)" == "$ORIG_SHA" ]]; then
  ok "the skill file is restored byte-for-byte after every mutation"
else
  no "the skill file was left mutated (a failed assertion would leak to the next run)"
fi

echo "1..$((pass+fail))"
exit $(( fail > 0 ? 1 : 0 ))