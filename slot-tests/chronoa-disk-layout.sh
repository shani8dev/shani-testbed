#!/bin/bash
# slot-test-mode: boot
#
# chronoa-disk-layout — the `disk_layout` skill, driven on the REAL image through
# the REAL dispatch path (`tools.execute_tool_outcome`, which runs the handler in
# the sandboxed child a model's tool call would use).
#
# WHY THIS FILE EXISTS. `disk_layout` was written and verified on an Ubuntu dev
# box, and this is the second time in this repo that a thing measured on the dev
# box is a fact about the wrong machine. The dev box has one disk with a
# three-level stack (nvme0n1 -> p3 -> dm_crypt-0 -> lvm -> /) and 32 snap `loop`
# devices. **ShaniOS's own layout is the one this skill exists to describe**:
# btrfs subvolumes on a blue/green partition table, which is a different shape
# from anything the dev box could produce - and the whole point of the skill is
# that layout. A parser written only against the dev box's LVM-on-LUKS tree has
# never seen `@blue`/`@green`/`@home`/`@data` subvolumes at all.
#
# The claims asserted here are the ones the skill makes on a real install:
#   - the skill registers, and `storage-sense-enabled` is in the RUNNING COMPILED
#     schema (not the XML - `glib-compile-schemas` exiting 0 having written
#     nothing is a documented failure mode in this repo);
#   - it refuses by the storage sense's own switch with that key OFF, and runs
#     when it is on (the grant must actually cross to the child - see the
#     GSETTINGS_BACKEND note below);
#   - it names the boot slots, because those are the partitions a person on this
#     machine actually wants to know about;
#   - a partition whose GPT type GUID disagrees with its filesystem reports both
#     rather than picking one - measured on the dev box, where a partition
#     carrying the Linux-filesystem GUID held crypto_LUKS;
#   - an unrecognised GPT GUID is printed as the GUID, never guessed at;
#   - loop devices are hidden and COUNTED, never silently dropped.
#
# TWO THINGS A REAL `vmspawn` BOOT IS STILL NEEDED FOR, both measured here rather
# than assumed:
#   - the **partition labels**. Under nspawn the slot's `/dev` is a loop-attached
#     image, so `nvme0n1` and its three partitions exist while every `fstype`,
#     `partlabel` and `parttype` reads `None` - the btrfs subvolumes are only
#     visible in a real boot. The check SKIPs with that as its reason.
#   - **vmspawn's TPM on this dev box does not come up**: `swtpm` answers
#     "Could not send response: Permission denied" and QEMU drops the QMP
#     connection during feature probing, so the VM exits in 3 seconds. That is the
#     same Ubuntu restriction the `vm` skill's TPM path documents. `--tpm=no`
#     boots a real UEFI firmware image without it, and this skill needs no TPM -
#     so the measurement to take here is `--tpm=no`, not "vmspawn is broken".
#
# Without `--local-src-chronoa` the skill is not in the image, so this SKIPs with
# that as its reason and emits no FAIL - `cmd_slot_test`'s `pass == 0` rule must
# not fire on a stock image.
set -u
res() { printf 'RESULT %-44s %s\n' "$1" "$2"; }
PKG=/usr/lib/shani-chronoa
if [[ ! -f "$PKG/shani_chronoa/skills/disk_layout.py" ]]; then
    res chronoa-disk-layout "SKIP (the skill is not in $PKG: run with --local-src-chronoa=<checkout>)"
    exit 0
fi

# --- the platform, measured directly ------------------------------------------
# `lsblk` is the reader, so its presence is the platform fact; and reading the
# partition table needs no root, which is the reason the skill uses it rather
# than sgdisk/gdisk (both need root, and on the dev box `sudo -n sgdisk -p`
# answers "interactive authentication is required" while STILL exiting 0 - an
# exit code of 0 with a refusal on stderr is exactly the contract this repo
# refuses to reason about).
if command -v lsblk >/dev/null 2>&1; then
    res disk-layout-lsblk-present "PASS ($(command -v lsblk))"
else
    res disk-layout-lsblk-present "SKIP (no lsblk: util-linux is absent from this image)"
    exit 0
fi
if lsblk --json -o NAME,TYPE >/dev/null 2>&1; then
    res disk-layout-lsblk-json-works "PASS (lsblk --json answers on this image)"
else
    res disk-layout-lsblk-json-works "FAIL (lsblk --json did not answer, so the skill's reader is unusable here)"
fi
# The raw reader's own view, so a later failure has a number to compare against.
RAW_DISKS=$(lsblk --json -o NAME,TYPE 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin)["blockdevices"]; print(sum(1 for b in d if b.get("type")!="loop"))' 2>/dev/null || echo "?")
res disk-layout-disks-present "INFO ($RAW_DISKS non-loop block device(s) on this slot)"

T=$(mktemp -d /var/tmp/chronoa-disk-layout.XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/config"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

# **The keyfile GSettings backend, and this is why it has to be here.**
# `cmd_slot_test` wraps every slot-test in `dbus-run-session`, which is necessary
# and not sufficient: measured on this image, both `ChronoaConfig.set()` and the
# `gsettings set` CLI return rc=0, read back `true` in the *writing* process, and
# leave nothing on disk - a child process reads `false`. That private bus has no
# activatable `ca.desrt.dconf`, and dconf's client queues the change in memory,
# so the writer sees its own value and the write is silently dropped.
#
# It matters for this skill more than most: every gated skill runs in a
# sandboxed child, so a consent grant that does not persist is indistinguishable
# from one that was never made - and the refusal path would be the thing under
# test. `GSETTINGS_BACKEND=keyfile` puts both writers in a real file, and
# `sandbox/executor.py` carries `GSETTINGS_BACKEND` and `XDG_CONFIG_HOME` to the
# child for exactly this reason.
export GSETTINGS_BACKEND=keyfile

# The schema is read out of the RUNNING compiled store, never the XML.
SCHEMA_KEYS=$(gsettings list-keys org.shani.chronoa 2>/dev/null || echo "(schema unreadable)")

# **No `| ` prefix.** lib/boot.sh counts with `grep -cE '^RESULT ...'`, so a
# prefix of my own makes every line uncountable.
_PROBE_OUT=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PKG" python3 - "$T" "$SCHEMA_KEYS" <<'PY'
import json, os, re, subprocess, sys
from pathlib import Path

T = Path(sys.argv[1])
schema_keys = sys.argv[2].split()

def res(name, verdict):
    print(f"RESULT {name:<44} {verdict}", flush=True)

from shani_chronoa import planmode, tools
from shani_chronoa.config import ChronoaConfig
from shani_chronoa.skills import disk_layout
planmode.set_enabled(False)

def run(args=None):
    try:
        o = tools.execute_tool_outcome("disk_layout", args or {})
        return o.text or ""
    except Exception as exc:            # a skill that cannot answer at all
        return f"(dispatch raised {type(exc).__name__}: {exc})"

def grant(value):
    """Write the consent key and confirm a SECOND process sees it.

    The confirmation is the point. A grant that the writing process reads back as
    `true` and a child does not is the failure this file exists to rule out, so
    the value is read back in a fresh process that shares nothing but the
    keyfile.

    **The environment is passed in WHOLE, not rebuilt.** A first version built a
    fresh dict from `os.environ` plus `XDG_CONFIG_HOME` and read back `False` -
    because `GSETTINGS_BACKEND` and `GSETTINGS_SCHEMA_DIR` were there, but the
    child re-derived its own settings backend from a schema it could not
    resolve, so `storage-sense-enabled` was unknown to it and every read came
    back False. A confirmation that does not reproduce the writer's environment
    is not a confirmation of the grant; it is a measurement of something else.
    The measured cost of getting this wrong is a FAIL that names a real
    problem which does not exist.
    """
    # **The value is the STRING "true", not the Python True.** `ChronoaConfig.set`
    # takes `value: str` and branches on `value == "true"` for a boolean key, so
    # passing `True` writes `True == "true"` -> **false**. Measured on this slot:
    # the keyfile came back holding `storage-sense-enabled=false` and the
    # in-process read said `False`, which read exactly like a grant that did not
    # persist - the very thing this check exists to distinguish. A consent gate
    # that silently stores the opposite of what was asked for is the shape of bug
    # this file is here to catch, so writing it wrong is how it would have been
    # missed.
    ChronoaConfig().set("storage-sense-enabled",
                        "true" if value else "false")
    got = subprocess.run(
        ["python3", "-c",
         "from shani_chronoa.config import ChronoaConfig;"
         "print(ChronoaConfig().sense_allowed('storage'))"],
        capture_output=True, text=True, env=dict(os.environ))
    return (got.stdout or got.stderr).strip()

# --- 1. registration ---------------------------------------------------------
registered = {t["function"]["name"] for t in tools.TOOLS}
res("disk-layout-registered",
    "PASS" if "disk_layout" in registered else
    f"FAIL (not in tools.TOOLS; {len(registered)} tools registered)")

handlers = getattr(disk_layout, "_run", None)
res("disk-layout-handler-importable",
    f"PASS ({handlers.__name__} is an identifier)" if handlers and
    handlers.__name__.isidentifier() else
    "FAIL (the handler is not importable by name, so the sandboxed child cannot call it)")

# --- 2. the consent key exists in the RUNNING compiled schema -----------------
res("disk-layout-storage-key-in-schema",
    "PASS" if "storage-sense-enabled" in schema_keys else
    "FAIL (storage-sense-enabled is not in the compiled schema, so the gate can never open)")

# --- 3. the gate refuses with consent OFF ------------------------------------
grant(False)
off = run()
if off.startswith("(dispatch raised"):
    res("disk-layout-refuses-with-consent-off", f"FAIL ({off})")
elif "Not shown" in off and "storage-sense-enabled" in off:
    res("disk-layout-refuses-with-consent-off", "PASS (names the storage sense's own switch)")
else:
    res("disk-layout-refuses-with-consent-off",
         f"FAIL (an ungranted call did not refuse by name: {off[:120]!r})")

# --- 4. the grant actually crosses to the sandboxed child --------------------
# This is the control for section 3: if the grant never reached the child, the
# refusal above would still have been printed - and the two results would be
# indistinguishable. So the child is asked directly, in its own process.
seen = grant(True)
res("disk-layout-consent-crosses-to-a-child",
    "PASS (a second process reads True)" if seen == "True" else
    f"FAIL (a second process reads {seen!r}; the refusal above proves nothing if a grant cannot land)")

on = run()
if on.startswith("(dispatch raised"):
    res("disk-layout-runs-with-consent-on", f"FAIL ({on})")
else:
    res("disk-layout-runs-with-consent-on",
        "PASS (a real layout came back)" if on.strip() else
        "FAIL (consent granted and nothing came back at all)")

# --- 5. it names this machine's real layout ----------------------------------
# The whole reason the skill exists: on a blue/green machine, which partition
# holds the boot slots is the answer somebody wants.
#
# **And a slot cannot show it, which is a property of the slot, not a defect.**
# Measured on `@blue`: `lsblk` reports `nvme0n1` with three partitions, every
# `fstype`/`partlabel`/`parttype` `None` - the slot's `/dev` is a loop-attached
# image and nothing is mounted from it. The btrfs subvolumes (`@blue`,
# `@green`, `@home`, `@data`) live in the *mounted* slots, so a partition-table
# reading of an nspawn slot cannot name them. So this SKIPs with that as its
# reason, and the population of the labels is left to a real
# `iso-install --boot-only` boot - the same distinction
# `chronoa-driver-tools.sh` makes about `uname -r` naming the host's kernel.
# Asserting the subvolume names here would fail the run on the only shape the
# harness can produce, which is the confident wrong answer in reverse.
slots = [s for s in ("blue", "green", "home", "data") if s in on.lower()]
if slots:
    res("disk-layout-names-the-real-layout", f"PASS ({', '.join(slots)})")
else:
    res("disk-layout-names-the-real-layout",
        "SKIP (an nspawn slot's block devices carry no filesystem or partition "
        "labels - the partitions exist and are reported, but the btrfs subvolumes "
        "are only visible in a real boot; nothing here is asserting they are absent)")

# --- 6. hidden loop devices are counted, not dropped --------------------------
m = re.search(r"(\d+) other block device\(s\) were not shown", on)
res("disk-layout-hidden-count-stated",
    f"PASS ({m.group(1)} hidden)" if m else
    "PASS (no hidden layers on this slot, so there was nothing to count)" if "not shown" not in on
    else "FAIL (hidden layers were dropped with nothing said)")

# --- 7. a GUID is never guessed, and a disagreement names both ----------------
node = {"name": "p3", "type": "part", "size": "473.9G",
        "fstype": "crypto_LUKS",
        "parttype": "0fc63daf-8483-4772-8e79-3d69d8477de4",
        "mountpoint": None}
line = disk_layout._describe(node)
res("disk-layout-guid-disagreement-named",
    "PASS" if "created as" in line and "crypto_LUKS" in line else
    f"FAIL ({line!r} does not report both)")

unknown = disk_layout._describe(
    {"name": "sdX9", "type": "part", "size": "8G", "fstype": "ntfs",
     "parttype": "deadbeef-0000-1111-2222-333344445555", "mountpoint": None})
res("disk-layout-unknown-guid-not-guessed",
    "PASS (printed as the GUID)" if "deadbeef-0000-1111-2222-333344445555" in unknown
    and not re.search(r"Linux|EFI|\bdata\b", unknown) else
    f"FAIL ({unknown!r} guesses a purpose)")

# --- 8. the real reader agrees with what the skill printed -------------------
# The control for sections 5-7: the numbers must come from THIS machine's lsblk,
# not from a fixture. If the skill ever stopped shelling out, the layout would
# keep looking plausible and this would be the only thing that noticed.
#
# **`-o NAME,TYPE`, not `-o NAME`.** A first version asked for NAME alone and
# counted every device as non-loop, because `lsblk` omits the `type` key
# entirely when it was not requested - so 34 devices looked like 34 real disks
# and the comparison read "1/34 appear" on a machine with one disk. A field the
# check reads must be the field it asks for; that is the same rule the skill's
# own `-o` list is held to.
#
# **A disk with unmounted partitions is a legitimate slot finding, not a
# failure.** Measured here: the slot's `/dev` is loop-attached, so `nvme0n1`
# and its three partitions exist while every `fstype`, `partlabel` and
# `partype` is `None`. An earlier version of this check demanded a *populated*
# layout and failed the run with "0/1 real devices appear" on a machine that
# did report its disk - the disk name was absent from the output only because
# the assertion was checking the wrong thing (the partitions' contents) rather
# than the thing the skill promises (it reads and names what lsblk reports). So
# the check is: the real disk name appears in what the skill printed. A real
# boot (`iso-install --boot-only`) is where the labels are populated, and that
# is stated rather than assumed here.
try:
    raw = json.loads(subprocess.run(
        ["lsblk", "--json", "-o", "NAME,TYPE"], capture_output=True, text=True,
        timeout=20).stdout)["blockdevices"]
except Exception as exc:               # noqa: BLE001
    res("disk-layout-matches-real-lsblk", f"FAIL (could not read lsblk: {exc})")
else:
    real = [b["name"] for b in raw if b.get("type") != "loop"]
    named = [n for n in real if n in on]
    if not real:
        res("disk-layout-matches-real-lsblk",
            "SKIP (this slot reports no non-loop block device, so there is nothing to compare against)")
    elif len(named) == len(real):
        res("disk-layout-matches-real-lsblk",
            f"PASS ({len(named)}/{len(real)} non-loop device(s) appear, so the layout came from this lsblk)")
    else:
        res("disk-layout-matches-real-lsblk",
            f"FAIL ({len(named)}/{len(real)} real devices appear in the output: {real})")
PY
)
printf '%s\n' "$_PROBE_OUT"

# Count from the heredoc's OWN captured output, not from whatever reached
# stdout. `cmd_slot_test` indents every line it forwards (`  | RESULT ...`), so
# a grep over the script's stdout finds nothing and this printed "0 pass 0 fail"
# on a run the harness itself summarised as "10 pass 2 fail" - the work ran, the
# count did not, and nothing complained. The same mistake as a `str.replace`
# that silently changes nothing: the failure is that the summary was empty, not
# that any step went red.
if [[ -n "${_PROBE_OUT:-}" ]]; then
  pass=$(grep -cE '^RESULT .* PASS' <<<"$_PROBE_OUT" || true)
  fail=$(grep -cE '^RESULT .* FAIL' <<<"$_PROBE_OUT" || true)
else
  pass=0; fail=0
fi
echo "== probe done ($pass pass, $fail fail)"
# The exit status is the part the harness reads, so it is derived from the
# count rather than from the python's own status - a probe that printed a FAIL
# and exited 0 would be read as a pass.
if [[ "$fail" -gt 0 ]]; then
    exit 1
fi