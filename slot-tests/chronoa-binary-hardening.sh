#!/bin/bash
# slot-test-mode: boot
#
# chronoa-binary-hardening — the `binary_hardening` skill, driven on the REAL
# image through the REAL dispatch path (`tools.execute_tool_outcome`, which runs
# the handler in the sandboxed child a model's tool call would use).
#
# WHY THIS FILE EXISTS. The five ELF protections were read out of real readelf
# output **on an Ubuntu dev box**, and this repo's own history is that "it passed
# here" is not "it is right there". Three of the five parse differently on a
# differently-linked distribution:
#
#   - `Type: EXEC` versus `DYN (Position-Independent Executable)`. PIE is decided
#     by the parenthesised text, not by the header word alone, because a shared
#     object is `DYN` too and is not a PIE executable;
#   - `BIND_NOW` versus a `FLAGS_1 ... NOW` line, and which of the two a given
#     toolchain emits;
#   - the stack canary, which is an **undefined import** (`__stack_chk_fail@...`)
#     in every dynamically linked binary - a parser that wanted a defined symbol
#     would find none and report "no canary" on every one of them.
#
# So the assertions are the claims the skill makes, on this image:
#   - it registers, and `readelf` is present (its absence is a named SKIP, not a
#     silent zero - this is `util-linux`/`binutils` and a real install has both);
#   - it answers for a real system binary, and reports the same five properties
#     the raw `readelf` output does;
#   - **every property it reports is cross-checked against readelf run here**, so
#     the skill cannot agree with itself while being wrong about the machine;
#   - a non-ELF file is refused with readelf's own reason, not called unhardened;
#   - a shared library says "not applicable" for PIE rather than claiming it.
#
# Without `--local-src-chronoa` the skill is not in the image, so this SKIPs with
# that as its reason and emits no FAIL - `cmd_slot_test`'s `pass == 0` rule must
# not fire on a stock image.
set -u
res() { printf 'RESULT %-44s %s\n' "$1" "$2"; }
PKG=/usr/lib/shani-chronoa
if [[ ! -f "$PKG/shani_chronoa/skills/binary_hardening.py" ]]; then
    res chronoa-binary-hardening "SKIP (the skill is not in $PKG: run with --local-src-chronoa=<checkout>)"
    exit 0
fi

# --- the platform ------------------------------------------------------------
if command -v readelf >/dev/null 2>&1; then
    res bin-hardening-readelf-present "PASS ($(command -v readelf))"
else
    res bin-hardening-readelf-present "SKIP (no readelf: binutils is absent from this image)"
    exit 0
fi
# The compiler, for building the controls. A missing one is a SKIP on those two
# checks only - every other check below still runs against the real binaries.
HAVE_CC=0
command -v cc >/dev/null 2>&1 && HAVE_CC=1

T=$(mktemp -d /var/tmp/chronoa-bin-hardening.XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/config"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

# The skill reads no consent key, so a plain environment is enough; the backend
# is set anyway so a gate reached through `ChronoaConfig` behaves as on a desktop.
export GSETTINGS_BACKEND=keyfile

# **No `| ` prefix.** lib/boot.sh counts with `grep -cE '^RESULT ...'`, so a
# prefix of my own makes every line uncountable.
_PROBE_OUT=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PKG" python3 - "$T" "$HAVE_CC" <<'PY'
import os, re, subprocess, sys
from pathlib import Path

T = Path(sys.argv[1])
HAVE_CC = sys.argv[2] == "1"

def res(name, verdict):
    print(f"RESULT {name:<44} {verdict}", flush=True)

from shani_chronoa import planmode, tools
from shani_chronoa.skills import binary_hardening as bh
planmode.set_enabled(False)

# **The controls are built HERE, not in the shell above.** The shell cannot
# build them: the harness runs this heredoc on its own, so anything the wrapper
# made would not exist - which is exactly what happened, and it made all three
# control assertions report SKIP ("the -no-pie build failed here") on a machine
# where `cc` builds all three perfectly well. A SKIP reads as coverage and is
# not, so the thing under test builds its own fixtures.
built = {}
if HAVE_CC:
    src = T / "t.c"
    src.write_text("int main(void){return 0;}\n")
    for name, flags in (("plain", []),
                        ("nopie", ["-no-pie", "-Wl,-z,lazy"]),
                        ("execstack", ["-Wl,-z,execstack"]),
                        ("obj.o", ["-c"])):
        target = T / name
        try:
            r = subprocess.run(["cc", *flags, "-o", str(target), str(src)],
                               capture_output=True, text=True, timeout=120)
            built[name] = target if (target.exists() and r.returncode == 0) else None
        except (OSError, subprocess.TimeoutExpired):
            built[name] = False

def run(path):
    try:
        return tools.execute_tool_outcome("binary_hardening", {"path": path}).text or ""
    except Exception as exc:                       # noqa: BLE001
        return f"(dispatch raised {type(exc).__name__}: {exc})"

def readelf(flags, path):
    p = subprocess.run(["readelf", "-W", *flags, path], capture_output=True,
                       text=True, timeout=60)
    return p.stdout if p.returncode == 0 else ""

# --- 1. registration ---------------------------------------------------------
registered = {t["function"]["name"] for t in tools.TOOLS}
res("bin-hardening-registered",
    "PASS" if "binary_hardening" in registered else
    f"FAIL (not in tools.TOOLS; {len(registered)} tools registered)")

handler = getattr(bh, "_run", None)
res("bin-hardening-handler-importable",
    f"PASS ({handler.__name__} is an identifier)" if handler and
    handler.__name__.isidentifier() else
    "FAIL (the handler is not importable by name, so the sandboxed child cannot call it)")

# --- 2. it answers for a real binary on this image ---------------------------
target = "/usr/bin/env"
if not os.path.exists(target):
    target = "/bin/env"
out = run(target)
if out.startswith("(dispatch raised"):
    res("bin-hardening-answers-for-a-real-binary", f"FAIL ({out})")
elif not os.path.exists(target):
    res("bin-hardening-answers-for-a-real-binary", f"SKIP (no {target} on this image)")
else:
    missing_rows = [name for _, name, _ in bh._LABELS if name not in out]
    res("bin-hardening-answers-for-a-real-binary",
        f"PASS (all five properties reported for {target})" if not missing_rows
        else f"FAIL (no line for: {missing_rows})")

# --- 3. THE CONTROL: each property matches readelf on this image -------------
# The skill and readelf must agree, property by property, on the file this image
# actually has. Without this the skill could be consistently wrong and every
# other check would pass - the "it agrees with itself" failure.
if not os.path.exists(target):
    res("bin-hardening-agrees-with-readelf", "SKIP (no system binary to compare against)")
else:
    header = readelf(["-h"], target)
    programs = readelf(["-lW"], target)
    dynamic = readelf(["-dW"], target)
    syms = readelf(["--dyn-syms"], target)
    truth = {
        "PIE": "EXEC" not in header and "REL" not in header
               and "Position-Independent" in header,
        "RELRO": "GNU_RELRO" in programs,
        "Full RELRO": bool(re.search(r"\bBIND_NOW\b", dynamic)
                           or re.search(r"Flags:[^\n]*\bNOW\b", dynamic)),
        "Stack canary": "stack_chk_fail" in syms,
        "No-execute stack": (
            not any("RWE" in ln for ln in programs.splitlines() if "GNU_STACK" in ln)
            if "GNU_STACK" in programs else None),
    }
    disagreements = []
    for label, actual in truth.items():
        line = next((l for l in out.splitlines() if l.strip().startswith(("yes", "NO", "--"))
                     and label in l), "")
        if not line:
            continue
        claimed = line.strip().split()[0] == "yes"
        if actual is not None and claimed != actual:
            disagreements.append(f"{label}: skill says {claimed}, readelf says {actual}")
    res("bin-hardening-agrees-with-readelf",
        "PASS (all five properties match this image's readelf)" if not disagreements
        else f"FAIL ({'; '.join(disagreements)})")

# --- 4. a non-ELF file is refused, not called unhardened --------------------
notelf = T / "plain.txt"
notelf.write_text("this is not an ELF file\n")
out = run(str(notelf))
res("bin-hardening-refuses-a-non-elf-file",
    "PASS (readelf's own reason, and no verdict)" if "NOT hardened" not in out and "not hardened" not in out.lower()
    else "FAIL (a text file was given a hardening verdict)")

# --- 5. the built controls: each must lose exactly one protection ------------
def expect_missing(path, label, present):
    """Is `label` reported as missing (or present) for `path`, per readelf?"""
    text = run(path)
    if text.startswith("(dispatch raised"):
        return None, f"dispatch raised: {text[:80]}"
    line = next((l for l in text.splitlines() if l.strip().startswith(("yes", "NO", "--"))
                 and label in l), "")
    if not line:
        return None, f"no line for {label}"
    return (line.strip().split()[0] == "yes"), ""

if not HAVE_CC or not built.get("plain"):
    for label in ("bin-hardening-control-non-pie", "bin-hardening-control-exec-stack",
                  "bin-hardening-control-relocatable"):
        res(label, "SKIP (no C compiler on this image, so the control could not be built)")
else:
    # -no-pie must be reported as NOT PIE.
    p = built.get("nopie")
    if not p.exists():
        res("bin-hardening-control-non-pie", "SKIP (the -no-pie build failed here)")
    else:
        got, why = expect_missing(str(p), "PIE", False)
        res("bin-hardening-control-non-pie",
            "PASS (a -no-pie build is reported as not PIE)" if got is False
            else f"FAIL ({'reported PIE' if got else why})")

    # **The plain build is the control for the exec-stack flag, and that is not
    # obvious.** A loose `R` substring over the GNU_STACK line matches the
    # exec-stack binary's `RWE` too - so the defect is invisible on it. It only
    # shows on a binary whose stack is `RW` but *not* `RWE`, which is what
    # `plain` is: there the loose test says "executable stack" about a stack
    # that is not. Both are asserted, because they are the two halves.
    p = built.get("plain")
    if not p.exists():
        res("bin-hardening-control-plain-stack",
            "SKIP (the plain build failed here)")
    else:
        got, why = expect_missing(str(p), "No-execute stack", True)
        res("bin-hardening-control-plain-stack",
            "PASS (an RW stack is reported as non-executable)" if got is True
            else f"FAIL ({why or 'an ordinary RW stack was called executable'})")

    # -z execstack must be reported as an executable stack (NX off).
    p = built.get("execstack")
    if not p.exists():
        res("bin-hardening-control-exec-stack", "SKIP (the -z execstack build failed here)")
    elif not any("RWE" in ln for ln in readelf(["-lW"], str(p)).splitlines()
                 if "GNU_STACK" in ln):
        # The toolchain refused the flag; that is a fact about this image, and
        # asserting the protection is off would be the confident wrong answer.
        res("bin-hardening-control-exec-stack",
            "SKIP (this toolchain did not honour -z execstack, so there is no exec-stack binary to test with)")
    else:
        got, why = expect_missing(str(p), "No-execute stack", True)
        res("bin-hardening-control-exec-stack",
            "PASS (an RWE GNU_STACK is reported as no-execute-stack OFF)" if got is False
            else f"FAIL ({why or 'an executable stack was called non-executable'})")

    # A relocatable object must not be given a verdict at all.
    p = built.get("obj.o")
    if not p.exists():
        res("bin-hardening-control-relocatable", "SKIP (the -c build failed here)")
    else:
        text = run(str(p))
        # **Both "an answer" and "the right answer" are asserted.** A build that
        # treats "no GNU_STACK segment" as an executable stack does not merely
        # misreport: it reaches for a line that is not there and raises, and
        # through the dispatch that arrives as an error rather than a sentence.
        # So a check that only looked for the absence of "NOT hardened" read
        # that crash as a pass - the absence-shaped green, third instance in this
        # harness's own history.
        # **A traceback is not an answer.** The check first looked only for the
        # words "NOT hardened" and for `(dispatch raised`; a crash inside the
        # sandboxed child arrives as the traceback text itself, carrying neither,
        # so a build that cannot answer a `.o` file at all scored as a PASS.
        # Measured here: `execute_tool_outcome(...).text` for the mutated build
        # begins "Traceback (most recent call last):" and ends in `TypeError`.
        if text.startswith("(dispatch raised") or "Traceback (most recent call last)" in text:
            first = next((l for l in text.splitlines() if l.strip()), "")
            res("bin-hardening-control-relocatable",
                f"FAIL (the skill could not answer at all for a .o file: {first[:100]})")
        elif "NOT hardened" in text:
            res("bin-hardening-control-relocatable",
                "FAIL (a relocatable object was reported as missing protections, "
                "which is a verdict about a file that has not been linked yet)")
        else:
            res("bin-hardening-control-relocatable",
                "PASS (a .o file is answered, and not called unhardened)")
PY
)
printf '%s\n' "$_PROBE_OUT"

pass=$(grep -cE '^RESULT .* PASS' <<<"$_PROBE_OUT" || true)
fail=$(grep -cE '^RESULT .* FAIL' <<<"$_PROBE_OUT" || true)
echo "== probe done ($pass pass, $fail fail)"
# The exit status is derived from the count, not from the python's own status: a
# probe that printed a FAIL and exited 0 would be read as a pass.
if [[ "$fail" -gt 0 ]]; then
    exit 1
fi