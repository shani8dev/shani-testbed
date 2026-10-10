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

# **The keyfile GSettings backend, and this is why it has to be here.**
# `cmd_slot_test` wraps every slot-test in `dbus-run-session` so a `gsettings`
# WRITE has a session bus to reach dconf-service on. That is necessary and it is
# not sufficient: measured on this image, both `ChronoaConfig.set()` and the
# `gsettings set` CLI return rc=0, read back `true` **in the writing process**, and
# leave nothing on disk - a child process reads `false`. The private bus
# `dbus-run-session` creates has no activatable `ca.desrt.dconf`, and dconf's
# client library is deliberately resilient about an unreachable service: it queues
# the change in memory, the writer still sees its own value, and the write is
# silently dropped. That is the harness's own "gsettings writes silently no-op"
# failure reached from the opposite direction - the parent sees it and the child
# cannot.
#
# It matters here more than anywhere else in the suite, because **every gated
# skill runs in a sandboxed child**: with consent off by default, a consent grant
# that does not persist is indistinguishable from one that was never made, and the
# denylist - the guard that stops an EEPROM's calibration being erased - stays
# unreachable through the skill on the one platform that matters. It reported
# SKIP for three runs as a result, with a cause I had invented rather than
# measured.
#
# `GSETTINGS_BACKEND=keyfile` makes both writers put the value in
# `$XDG_CONFIG_HOME/glib-2.0/settings/keyfile`, a real file. It travels to the
# child too (`sandbox/executor.py:741` reads `GSETTINGS_BACKEND` and `:743`
# `XDG_CONFIG_HOME` for exactly this reason), so the child reads the same store.
export GSETTINGS_BACKEND=keyfile

# The schema is read out of the RUNNING compiled store, never out of the XML.
# A gsettings read is what the app itself does, so a key that exists in the file
# but was discarded at compile time shows up here as missing - which is the whole
# class of bug the `calendar_write` / `fm_radio` dead-switch entries record.
SCHEMA_KEYS=$(gsettings list-keys org.shani.chronoa 2>/dev/null || echo "(schema unreadable)")

# **No `| ` prefix here.** lib/boot.sh counts with `grep -cE '^RESULT ...'`, so a
# prefix of my own makes every line uncountable: the first run of this printed 15
# RESULT lines and the harness summarised "0 pass 0 fail", then failed on its
# own `pass == 0` rule. It adds its own indentation. The same mistake as a
# `str.replace` that silently changes nothing - the work ran, and nothing counted
# it.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PKG" python3 - "$T" "$SCHEMA_KEYS" <<'PY'
import os, re, subprocess, sys, time
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
d = T / "home" / "drivers" / "probe"
built = run("driver_build", {"name": "probe", "path": str(d)})
if "Refusing to build" in built:
    res("driver-build-gated", f"PASS (consent off: {built.split('.')[0]})")
else:
    res("driver-build-gated", f"FAIL (did not refuse with the key off: {built[:150]})")

# --- 5. driver_scaffold: creates, and never clobbers -------------------------
# `made` carries the explicit `path`, which matters for the post-condition check
# below: a post-condition that cannot resolve the directory answers `None` =>
# UNVERIFIED, so a check driven by a pathless call could never fail. This is the
# same shape as the negative control that cannot fail.
made = run("driver_scaffold", {"name": "probe", "path": str(d)})
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

# --- 5c. the gate OPEN: the refusal every enabling user actually gets ---------
# **`driver-build-gated` in section 4 only proves the key-off path, and it runs
# BEFORE the scaffold exists.** The branch a person who flips the switch in
# Settings takes has never run here at all: with the gate open, `_run_build` falls
# through to the toolchain check and refuses NAMING the packages. That sentence is
# the entire output of this feature on ShaniOS - a refusal naming base-devel and
# linux-headers tells somebody what to install, and one that does not is a dead
# end. It is also the ONLY place the missing-toolchain branch of `_run_build` is
# exercised, which is exactly the code that runs on no other distribution.
#
# Placed after the scaffold on purpose: `_run_build` answers "the .c does not
# exist" before it ever reaches the toolchain, so a check driven before section 5
# asserts that sentence instead of the one it is about.
try:
    cfg.set("driver-build-enabled", "true")
    build_granted = cfg.get_bool("driver-build-enabled", False) is True
    build_grant_why = "" if build_granted else "the key read back False straight after being set"
except Exception as exc:
    build_granted, build_grant_why = False, f"{type(exc).__name__}: {exc}"
if not build_granted:
    if cfg._settings is None:
        build_grant_why += " | ChronoaConfig found no GSettings schema, so every gate reads its Python default"
    res("driver-build-with-consent-names-the-packages",
        f"SKIP (driver-build-enabled could not be granted: {build_grant_why})")
else:
    opened = run("driver_build", {"name": "probe", "path": str(d)})
    if "Refusing to build" in opened:
        res("driver-build-with-consent-names-the-packages",
            f"FAIL (still refused BY CONSENT although the key reads true, so the switch does nothing: {opened[:150]})")
    elif "base-devel" in opened and "linux-headers" in opened:
        res("driver-build-with-consent-names-the-packages",
            f"PASS (gate open: refuses naming both packages - {opened.split('.')[0]})")
    else:
        res("driver-build-with-consent-names-the-packages",
            f"FAIL (refused without naming base-devel and linux-headers, so a person has nothing to install: {opened[:150]})")
    # Restored, not left open: a run that leaves the machine's gate on after itself
    # is a worse failure than a red check. Same API as the grant above.
    cfg.set("driver-build-enabled", "false")

# --- 5b. scaffolding must not be verified as a build --------------------------
# **Found by running the skill on a real machine (this one):** the module-level
# POST_CONDITION was the build's own `.ko` check, and
# `verification.post_condition_for` reads one POST_CONDITION per MODULE - so
# `driver_scaffold` and `driver_status` were both being checked for a `.ko` that
# only `driver_build` produces. The reply came back
#     "reported success but verification failed: no .ko file is in ..."
# about a call whose own last paragraph reads "This is source, not a built
# module". A post-condition describing another tool's output calls a correct
# action a failure, which is the confident-wrong-answer shape this suite exists
# to catch. `verification._call` already passes the tool name to a check that
# takes two arguments, so the fix belongs in the check.
#
# Asserted through the real dispatch path, because the post-condition runs after
# dispatch and this is the only place the marker is observable end to end.
res("driver-scaffold-is-not-verified-as-a-build",
    "PASS (scaffolding is not reported as a failed build)" if "VERIFICATION FAILED" not in made else
    f"FAIL (scaffolding was verified against a .ko it never produces: {made[-160:]})")

# --- 6. device_i2c: the destructive half -------------------------------------
# **This check could not tell the two refusals apart, which the self-test's
# ungating mutation exposed.** It used register 0x00 - an EEPROM block-select
# byte, which the DENYLIST refuses - and then asserted only that the reply
# contained "Refusing to write". Both refusals begin that way, so the check
# passed with the consent gate removed entirely: it was proving that *something*
# refused, not that consent was consulted.
#
# So it now does three things: it writes a register the denylist does NOT
# touch, it asserts the refusal names the SWITCH (only the consent refusal does),
# and it asserts the denylist's refusal does not. That is what makes the gate's
# presence observable.
w = run("device_i2c", {"action": "write", "bus": 1, "address": "0x48", "register": "0x0c", "value": "0x01"})
if "i2c-write-enabled" in w:
    res("device-i2c-write-gated",
        f"PASS (refused by consent, and the refusal names the switch: {w.split('.')[0]})")
elif "Refusing to write" in w:
    res("device-i2c-write-gated",
        f"FAIL (refused, but not by consent - the denylist or the tool spoke instead: {w[:150]})")
else:
    res("device-i2c-write-gated", f"FAIL (did not refuse at all: {w[:150]})")

# The other half, and it needs the gate OPEN — which is the first thing this
# check got wrong. With consent off the gate always answers first, so the
# denylist is **unreachable through the skill** and a check that expected the
# denylist's words there was asserting something the product deliberately never
# does: permission is the first question, and a refusal about destroying a device
# must not be mistaken for a permission prompt. So the gate is opened, **and the
# grant is read back** — a check that trusts its own setup is how the senses
# slot-test's consent assertions were satisfied by a stub.
# The grant is done in PYTHON, not through gsettings on the host, because this
# body runs inside the slot-test's own python process and the gsettings call
# belongs to the slot's session bus. The first version wrote it in bash and left
# it inside the heredoc, so the extracted body did not parse and the slot-test
# could not run at all.
#
# **The setter is `set(key, "true")`, not `set_bool`.** The first version called a
# method ChronoaConfig does not have, the bare `except Exception` turned the
# resulting AttributeError into "could not grant", and the SKIP therefore read as
# an environment limitation. It was a bug in this test naming a method that does
# not exist - and a SKIP whose cause is invented is worse than one that fails,
# because nothing sends you to look. `set` writes booleans as "true"/"false"
# strings (`config.py:516`).
try:
    cfg.set("i2c-write-enabled", "true")
    granted = cfg.get_bool("i2c-write-enabled", False) is True
    grant_why = "" if granted else "the key read back False straight after being set"
except Exception as exc:
    granted, grant_why = False, f"{type(exc).__name__}: {exc}"
# `ChronoaConfig` degrades to Python defaults with only a log line when it cannot
# find the schema, so a silent `False` here is a *silent no-op* - the dead-switch
# class this suite exists to catch. The reason is therefore named rather than
# reported as a bare "could not grant": "no mounts" and "I could not ask" have to
# be tellable apart, exactly as for `device_probe`'s empty routes.
if not granted:
    if cfg._settings is None:
        grant_why += " | ChronoaConfig found no GSettings schema, so every gate reads its Python default"
    res("device-i2c-denylist-is-its-own-refusal",
        f"SKIP (i2c-write-enabled could not be granted: {grant_why} - the denylist is unreachable through the skill while consent is off, because permission is deliberately the first question)")
else:
    # **Write it, then check a SECOND process reads it.** A gsettings/dconf write
    # is queued to the session-bus service, so the writing process's own read can
    # answer true from its in-memory tree while the file the child reads is still
    # the old one. That is the harness's own documented "gsettings writes silently
    # no-op" failure reached from the opposite direction: the parent sees it, the
    # child cannot. A check that does not test the crossing proves nothing about
    # the skill, which runs in a child.
    #
    # Measured on the real image: parent `true`, child `false`. So the diagnosis
    # below separates the two possible causes, because they are opposite bugs -
    # a timing flush (add a settle) against a write that never persists at all
    # (every gated skill on the machine is reading the wrong value).
    disk = Path(os.environ.get("XDG_CONFIG_HOME", "")) / "glib-2.0" / "settings" / "keyfile"
    on_disk = disk.exists() and b"i2c-write-enabled" in disk.read_bytes()
    # The second process has to read through the backend the SKILL uses, which is
    # `ChronoaConfig`, not the `gsettings` CLI. That is not a detail: **the two
    # backends write different group names into the same keyfile** —
    # `ChronoaConfig`'s explicit backend (`config.py:416`) writes
    # `[org.shani.chronoa]`, the default backend the CLI uses writes
    # `[org/shani/chronoa]` — so `gsettings get` reads back a value the app wrote
    # as `false`. The first version of this check used the CLI, measured
    # "parent true, child false", and spent two runs on a defect that is actually
    # a trap for whoever debugs with `gsettings`: the switch says on, the skill
    # refuses, and the CLI insists it is off. The group `[org.shani.chronoa]` is
    # the one the skills read (shani-chronoa's own AGENTS.md records the opposite
    # spelling as "silently ignored"), so the child that matters is this one.
    probe = (
        f"import sys; sys.path.insert(0, {os.environ['PYTHONPATH']!r})\n"
        "from shani_chronoa.config import ChronoaConfig\n"
        "print(ChronoaConfig().get_bool('i2c-write-enabled', False))"
    )
    deadline = time.time() + 10
    child_val = ""
    while time.time() < deadline:
        seen = subprocess.run([sys.executable, "-c", probe],
                              capture_output=True, text=True, timeout=30, check=False)
        child_val = seen.stdout.strip()
        if child_val == "True":
            break
        time.sleep(0.5)
    res("i2c-write-grant-reaches-a-second-process",
        f"PASS (a separate ChronoaConfig process reads True; the value is on disk: "
        f"{disk})"
        if child_val == "True" else
        f"FAIL (the parent reads True but a separate ChronoaConfig reads {child_val!r}, "
        f"and the key is {'' if on_disk else 'NOT '}in {disk}) - a gated skill runs in "
        "a child, so a grant that does not cross is indistinguishable from one never made")

    d = run("device_i2c", {"action": "write", "bus": 1, "address": "0x50", "register": "0x00", "value": "0x01"})
    if "i2c-write-enabled" in d:
        res("device-i2c-denylist-is-its-own-refusal",
            f"FAIL (with the gate open, the denied register blamed the switch instead of itself: {d[:140]})")
    elif "Refusing to write register 0x00" in d:
        res("device-i2c-denylist-is-its-own-refusal",
            "PASS (with consent granted, the forbidden register is still refused - in its own words, without blaming a switch that is already on)")
    else:
        res("device-i2c-denylist-is-its-own-refusal",
            f"FAIL (the denied register was not refused its own way: {d[:140]})")
    # And the control: with the gate open, an ordinary register must actually be
    # allowed to reach the tool. Without this the check above would also pass on a
    # skill that refused EVERY write for any reason.
    ok_reg = run("device_i2c", {"action": "write", "bus": 1, "address": "0x48", "register": "0x0c", "value": "0x01"})
    if "Refusing" in ok_reg and "i2c-write-enabled" in ok_reg:
        res("device-i2c-consent-gate-opens",
            f"FAIL (still refusing by consent although the key reads true: {ok_reg[:140]})")
    else:
        res("device-i2c-consent-gate-opens",
            f"PASS (an ordinary register got past the gate and reached the tool: {ok_reg[:90]})")
    # The same `set(key, "true"/"false")` API as the grant above: `set_bool` does
    # not exist on `ChronoaConfig`, and this line is the reason the self-test
    # reported two blank verdicts after `device-i2c-consent-gate-opens`. Restored
    # rather than dropped, because a run that leaves a machine's gate open after
    # itself is a worse failure than a red check.
    cfg.set("i2c-write-enabled", "false")

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
    # A route counts as EXPLAINED when its own line carries the reason in
    # parentheses, or when the line immediately under it adds one -
    # `device_probe` writes some notes as a second line, and a checker that read
    # one line called that unexplained. The window is one line on purpose: a
    # reason three lines later belongs to something else.
    lines_out = p.splitlines()
    bare = []
    for i, ln in enumerate(lines_out):
        st = ln.strip()
        if not st.startswith(("I2C:", "Video:", "FUSE mounts:")):
            continue
        if "none" not in st:
            continue
        if re.search(r"\([^)]*\)", st):
            continue                      # the reason is already on this line
        nxt = lines_out[i + 1].strip() if i + 1 < len(lines_out) else ""
        if nxt and nxt != st:
            continue                      # ...or on the line directly beneath
        bare.append(st)
    res("device-probe-absent-routes-are-explained",
        "PASS (every empty route names why)" if not bare else
        f"FAIL (a route is reported empty with nothing said about it: {bare})")
PY

pass=$(grep -c 'RESULT .* PASS' || true)
fail=$(grep -c 'RESULT .* FAIL' || true)
if [[ "$fail" -gt 0 ]]; then
    echo "== probe done ($pass pass, $fail fail)"
    exit 1
fi
echo "== probe done ($pass pass, $fail fail)"