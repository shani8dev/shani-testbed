#!/bin/bash
# slot-test-mode: boot
#
# chronoa-matrix — shani-chronoa's tools/cli_matrix.py run against a REAL
# installed image: every command on PATH, its man page and package, the OS
# surfaces (D-Bus, GSettings, Polkit, sysfs, portals) and Chronoa's own live
# registries (tools, senses, trigger event types).
#
# Its one hard assertion is the reason it is a test and not just a report:
# a Chronoa skill or sense that runs a command this image does not ship must
# CHECK for it first and say what is missing. One that merely catches OSError
# shows the user "[Errno 2] No such file or directory: 'xdotool'", and one that
# does neither can crash - and no host unit test can see either case, because
# the host has its own set of binaries (or mocks shutil.which).
#
# Needs --local-src-chronoa=<checkout>: tools/ is not packaged, and the overlay
# puts the tool at /usr/lib/shani-chronoa-tools/. Without it this SKIPs.
#
#   slot-test <slot> chronoa-matrix --local-src-chronoa=/opt/shani-chronoa
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
TOOL=/usr/lib/shani-chronoa-tools/cli_matrix.py
if [[ ! -f "$TOOL" ]]; then
    res chronoa-matrix "SKIP (no $TOOL: run with --local-src-chronoa=<checkout>)"
    exit 0
fi
T=$(mktemp -d /tmp/chronoa-matrix.XXXXXX)
trap 'rm -rf "$T"' EXIT

rc=0
PYTHONDONTWRITEBYTECODE=1 python3 "$TOOL" --out="$T/m" --check >"$T/out" 2>&1 || rc=$?
summary=$(grep -m1 '^{' "$T/out")
# keep the matrix when the caller bound an output dir (SHANIOS_TEST_EXTRA_BINDS=<host>:/mnt/out)
if [[ -d /mnt/out && -w /mnt/out && -s "$T/m.json" ]]; then
    # the matrix knows its own profile (gnome/plasma); os-release says only "arch" on both
    tag=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("profile") or "image")' "$T/m.json" 2>/dev/null)
    for ext in json md html; do [[ -s "$T/m.$ext" ]] && cp "$T/m.$ext" "/mnt/out/matrix-${tag:-image}.$ext"; done
fi
if [[ ! -s "$T/m.json" ]]; then
    res chronoa-matrix-runs "FAIL (no matrix written, rc=$rc)"
    tail -15 "$T/out" | sed 's/^/  | /'
    exit 0
fi
python3 - "$T/m.json" "$rc" "$T/out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); rc = int(sys.argv[2])
res = lambda name, verdict: print(f"RESULT {name:<40} {verdict}")
s, inv = d["summary"], d["chronoa"]
res("chronoa-matrix-runs", f"PASS ({s['commands']} commands, {s['packages']} packages, {s['with_man']} man pages)"
    if s["commands"] > 500 and s["with_man"] > 100 else
    f"FAIL (only {s['commands']} commands / {s['with_man']} man pages: is this a real image?)")
if "error" in inv:
    res("chronoa-matrix-registries", f"FAIL (Chronoa's registries did not load: {inv['error']})")
else:
    res("chronoa-matrix-registries", f"PASS ({len(inv['tools'])} tools, {len(inv['senses'])} senses, "
        f"{len(inv['events'])} trigger event types)" if inv["tools"] and inv["senses"] and inv["events"] else
        "FAIL (a registry came back empty)")
checks = [l[len("CHECK: "):] for l in open(sys.argv[3]) if l.startswith("CHECK: ")]
if rc not in (0, 1):
    res("chronoa-deps-explained", f"FAIL (the tool exited {rc})")
elif checks:
    res("chronoa-deps-explained", f"FAIL ({len(checks)}: " + "; ".join(checks[:6]) + ")")
else:
    missing = sum(bool(x.get("missing")) for x in inv.get("tools", []) + inv.get("senses", []))
    res("chronoa-deps-explained", f"PASS ({missing} tool(s)/sense(s) need a command this image lacks, "
        "and every one checks for it first)")
c = d.get("calibration") or {}
if c.get("safety_accuracy") is not None:
    print(f"  calibration: safety {c['safety_accuracy']:.0%} ({c['safety_agree']}/{c['safety_agree'] + c['safety_disagree']}; "
          f"reads {c['reads_accuracy']:.0%}, changes {c['changes_accuracy']:.0%}), sense recall {c['sense_recall']:.0%}")
PY
