#!/bin/bash
# slot-test-mode: boot
#
# chronoa-driver-skills — the five driver-development skills, driven on the REAL
# image through the REAL dispatch path (`tools.execute_tool_outcome`, which runs
# each handler in the sandboxed child a model's tool call would use).
#
# WHY THIS FILE EXISTS. Those skills had been verified in two halves that never
# touched: `chronoa-driver-tools.sh` and `tests/driver-boot-facts.sh` measure the
# **platform**, and shani-chronoa's own suite exercises the **logic** on an Ubuntu
# dev box. Nobody had run the skills on the distribution they ship to — and that
# matters more than it sounds, because **on the dev box `driver_status` reports
# "everything needed to build a module is present"**. So the branch every target
# machine takes — the refusal — had never executed against a machine that really
# lacks gcc, make and the kernel build tree. A refusal sentence is assembled from
# `files.tool_missing()` per missing piece, so it is exactly the code that only
# runs on ShaniOS and had only ever been unit-tested with the pieces stubbed.
#
# So the assertions are the claims the skills make, on this image:
#   - all five register, and both consent keys are in the RUNNING COMPILED schema
#     (not the XML — `glib-compile-schemas` exiting 0 having written nothing is a
#     documented failure mode here);
#   - `driver_status` says a module cannot be built here, names base-devel and
#     linux-headers, and does NOT claim it can;
#   - `driver_build` refuses with the consent key off, BEFORE naming any
#     toolchain fact, so a refusal cannot confirm what it should not;
#   - `driver_scaffold` writes a real project and refuses to overwrite one;
#   - `device_i2c` refuses every write with consent off, and refuses the EEPROM
#     register ranges even when it is on.
#
# Without `--local-src-chronoa` the skills are not in the image, so this SKIPs
# with that as its reason and emits no FAIL — `cmd_slot_test`'s `pass == 0` rule
# must not fire on a stock image.
set -u
res() { printf 'RESULT %-44s %s\n' "$1" "$2"; }
PKG=/usr/lib/shani-chronoa
if [[ ! -f "$PKG/shani_chronoa/skills/driver_dev.py" ]]; then
    res chronoa-driver-skills "SKIP (the driver skills are not in $PKG: run with --local-src-chronoa=<checkout>)"
    exit 0
fi

T=$(mktemp -d /var/tmp/chronoa-driver-skills.XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/config"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

# The schema is read out of the RUNNING compiled store, never out of the XML.
# A gsettings read is what the app itself does, so a key that exists in the file
# but was discarded at compile time shows up here as missing - which is the whole
# class of bug the `calendar_write` / `fm_radio` dead-switch entries record.
SCHEMA_KEYS=$(gsettings list-keys org.shani.chronoa 2>/dev/null || echo "(schema unreadable)")

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PKG" python3 - "$T" "$SCHEMA_KEYS" <<'PY' 2>&1 | sed 's/^/  | /'
import os, sys
from pathlib import Path

T = Path(sys.argv[1])
schema_keys = sys.argv[2].split()

def res(name, verdict):
    print(f"RESULT {name:<44} {verdict}", flush=True)

from shani_chronoa import planmode, tools
from shani_chronoa.skills import driver_dev, user_driver
from shani_chronoa.config import ChronoaConfig
planmode.set_enabled(False)

def run(name, args=None):
    try:
        o = tools.execute_tool_outcome(name, args or {})
        return o.text or ""
    except Exception as exc:                       # a skill that cannot answer at all
        return f"(dispatch raised {type(exc).__name__}: {exc})"

# --- 1. registration ---------------------------------------------------------
ALL = ["driver_status", "driver_scaffold", "driver_build", "device_probe", "device_i2c"]
registered = {t["function"]["name"] for t in tools.TOOLS}
missing = [n for n in ALL if n not in registered]
res("driver-skills-registered",
    "PASS (5 of 5 in tools.TOOLS)" if not missing else f"FAIL (not registered: {missing})")

# --- 2. the consent keys, read from the running compiled schema --------------
cfg = ChronoaConfig()
for key, expect_default in (("driver-build-enabled", False), ("i2c-write-enabled", False)):
    if key not in schema_keys:
        res(f"consent-key-{key}", "FAIL (not in the RUNNING compiled schema, so the gate can never be opened by a user and every call refuses forever - the calendar_write / fm_radio dead-switch class)")
        continue
    got = cfg.get_bool(key, True)
    res(f"consent-key-{key}",
        f"PASS (in the compiled schema; default is {got}, expected {expect_default})"
        if got is expect_default else
        f"FAIL (default is {got}, expected {expect_default} - a gate that opens by default is worse than one that never opens)")

# --- 3. driver_status: the refusal branch, on the machine that takes it -------
text = run("driver_status")
if text.startswith("(dispatch raised"):
    res("driver-status-runs", f"FAIL ({text})")
else:
    res("driver-status-runs", "PASS (answered through the real dispatch path)")

cannot = "cannot be built here" in text
claims_can = "Everything needed to build a module is present" in text
if cannot and not claims_can:
    res("driver-status-refuses-here",
        "PASS (reports that a kernel module cannot be built on this image)")
elif claims_can:
    res("driver-status-refuses-here",
        f"FAIL (says everything needed is present, so the refusal is wrong on this image: {text.splitlines()[-2:]})")
else:
    res("driver-status-refuses-here", f"FAIL (neither refusal nor presence is stated: {text[:160]})")

named = [p for p in ("base-devel", "linux-headers") if p in text]
res("driver-status-names-the-packages",
    f"PASS (names {', '.join(named)})" if named else
    "FAIL (the refusal names no package, so the person reading it has nothing to act on - the whole reason it is a refusal rather than compiler stderr)")

# The signing half, corrected 2026-10-10 after a firmware boot measured lockdown
# enforcing `none`. On an image WITH a signing wall this line must change, which
# is what the boot-time verifier's staleness check is for; here it records which
# way this image goes.
locked = "locked down" in text
res("driver-status-signing-claim",
    "PASS (does not claim modules are refused for their signature on this image)"
    if not locked else
    "FAIL (claims a module is locked down; the boot measured lockdown enforcing 'none', so that sentence is STALE)")

# --- 4. driver_build: the gate, before any fact ------------------------------
built = run("driver_build", {"name": "probe", "path": str(T / "home" / "drivers" / "probe")})
if "Refusing to build" in built:
    res("driver-build-gated", f"PASS (consent off: {built.split('.')[0]})")
else:
    res("driver-build-gated", f"FAIL (did not refuse with the key off: {built[:150]})")

# --- 5. driver_scaffold: creates, and never clobbers -------------------------
made = run("driver_scaffold", {"name": "probe"})
d = T / "home" / "drivers" / "probe"
want = {"probe.c", "Makefile", "dkms.conf", "99-probe.rules", "README.md"}
have = {p.name for p in d.iterdir()} if d.is_dir() else set()
res("driver-scaffold-writes",
    f"PASS ({len(have & want)}/5 files under {d})" if want <= have else
    f"FAIL (wrote {sorted(have)}, expected {sorted(want)} - a scaffold that does not produce a loadable skeleton is text, not a driver)")

# The Kbuild line is the part that was wrong twice: `obj-m := NAME` is the form
# most tutorials show and it does not build. Asserted on the generated file.
mk = (d / "Makefile").read_text() if (d / "Makefile").exists() else ""
active = [ln.strip() for ln in mk.splitlines() if ln.startswith("obj-m")]
res("driver-scaffold-kbuild-line",
    f"PASS ({active[0]!r})" if active and active[0] == "obj-m := probe.o" else
    f"FAIL (the active Kbuild line is {active!r}; 'obj-m := probe.o' is the form that actually builds, measured against real headers)")

(d / "probe.c").write_text("/* edited by the person */\n")
again = run("driver_scaffold", {"name": "probe"})
kept = (d / "probe.c").read_text()
res("driver-scaffold-never-clobbers",
    "PASS (left the edited file alone)" if kept == "/* edited by the person */\n" else
    f"FAIL (overwrote an edited file: {kept[:60]!r})")

# --- 6. device_i2c: the destructive half -------------------------------------
w = run("device_i2c", {"action": "write", "bus": 1, "address": "0x50", "register": "0x00", "value": "0x01"})
res("device-i2c-write-gated",
    "PASS (refused the write with consent off)" if "Refusing to write" in w else
    f"FAIL (did not refuse: {w[:150]})")

# The denylist must fire with consent ON, which is the case the first version got
# wrong - it was keyed (address, register) against register ranges, so it could
# not fire on any input at all.
fired = driver_dev.__name__ and user_driver._forbidden_register(0x00, "0x01") != ""
res("device-i2c-denylist-fires",
    "PASS (an EEPROM block-select register is refused)" if fired else
    "FAIL (_forbidden_register says 0x00 is writable, so the destructive guard does not exist)")

# --- 7. device_probe: answers, with a reason for every route ------------------
p = run("device_probe")
routes = [r for r in ("I2C:", "Video:", "FUSE mounts:") if r in p]
res("device-probe-reports-every-route",
    f"PASS ({len(routes)}/3 routes)" if len(routes) == 3 else
    f"FAIL (only {routes} present; a route with no line cannot be told from one that was not checked)")
if p.startswith("(dispatch raised"):
    res("device-probe-runs", f"FAIL ({p})")
else:
    # An absent route must carry its reason: "no I2C buses" and "I could not ask"
    # are opposite claims.
    bare = [ln for ln in p.splitlines()
            if ln.strip().endswith("none") and len(ln.split()) <= 4]
    res("device-probe-absent-routes-are-explained",
        "PASS (every empty route names why)" if not bare else
        f"FAIL (a route is reported empty with nothing said about it: {bare}")
PY

pass=$(grep -c 'RESULT .* PASS' || true)
fail=$(grep -c 'RESULT .* FAIL' || true)
if [[ "$fail" -gt 0 ]]; then
    echo "== probe done ($pass pass, $fail fail)"
    exit 1
fi
echo "== probe done ($pass pass, $fail fail)"