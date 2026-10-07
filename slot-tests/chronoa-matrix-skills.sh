#!/bin/bash
# slot-test-mode: boot
#
# chronoa-matrix-skills — the twenty skills shani-chronoa built from the
# cli_matrix shortlist (2026-10-07), run on a REAL booted ShaniOS slot through
# the REAL dispatch path (`tools.execute_tool_outcome`, which runs each handler
# in a sandboxed child), against the image's own binaries.
#
# Why this cannot be a host test: the host unit suite drives every skill with
# fake binaries on PATH, which proves the logic and nothing about the image.
# What only the image can answer:
#
#   * whether each binary a skill shells out to is actually ON the image
#     (systemd-analyze, fc-list, wpctl, xdg-mime, pdfunite, lpstat,
#     hostnamectl, localectl, boltctl, distrobox, virsh, shani-deploy) - a skill
#     that says "X is not installed" for a binary `command -v` finds is a FAIL;
#   * whether a binary that IS missing is named by the right ARCH package (the
#     tree has shipped `bluez` for `bluez-utils` before) - the negative control
#     hides fc-list from PATH and requires the reply to name 'fontconfig';
#   * shani-deploy's real `--status --json` document being read (the Shanios-only
#     half of snapshot_status), and poppler really merging two PDFs with the
#     post-condition returning VERIFIED.
#
# Consent: nothing is granted here. Gated "set" paths must refuse and name their
# key; that is asserted, so a gate that silently opened would FAIL.
#
#   slot-test <slot> chronoa-matrix-skills --local-src-chronoa=/opt/shani-chronoa
set -u
res() { printf 'RESULT %-44s %s\n' "$1" "$2"; }
PKG=/usr/lib/shani-chronoa
if [[ ! -f "$PKG/shani_chronoa/skills/snapshot_status.py" ]]; then
    res chronoa-matrix-skills "SKIP (the matrix skills are not in $PKG: run with --local-src-chronoa=<checkout>)"
    exit 0
fi
T=$(mktemp -d /var/tmp/chronoa-matrix-skills.XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/config"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PKG" python3 - "$T" <<'PY'
import os, shutil, sys
from pathlib import Path
T = Path(sys.argv[1])
from shani_chronoa import planmode, tools
from shani_chronoa.verification import Verdict
planmode.set_enabled(False)

def res(name, verdict):
    print(f"RESULT {name:<44} {verdict}", flush=True)

def run(name, args=None):
    o = tools.execute_tool_outcome(name, args or {})
    return o, o.text

# The binary each skill depends on, as the matrix says the image ships it.
NEEDS = {
    "boot_report": "systemd-analyze", "list_fonts": "fc-list", "audio_output": "wpctl",
    "default_apps": "xdg-mime", "print_queue": "lpstat", "set_hostname": "hostnamectl",
    "set_locale": "localectl", "usb_devices": "boltctl", "list_containers": "distrobox",
    "list_vms": "virsh", "snapshot_status": "shani-deploy", "disk_health": "lsblk",
}
ARGS = {"default_apps": {"target": "pdf"}, "pdf_pages": {"action": "info", "path": "/nonexistent.pdf"},
        "photo_metadata": {"path": "/etc/os-release"}}
ALL = ["snapshot_status", "security_status", "list_containers", "list_vms", "boot_report",
       "disk_health", "temperatures", "usb_devices", "driver_info", "list_fonts",
       "photo_metadata", "crash_report", "login_history", "audio_output", "default_apps",
       "pdf_pages", "print_queue", "set_hostname", "set_locale", "speed_test"]

registered = {t["function"]["name"] for t in tools.TOOLS}
missing = [n for n in ALL if n not in registered]
res("matrix-skills:registered", "PASS (20 of 20)" if not missing else f"FAIL (not registered: {missing})")

for name in ALL:
    try:
        o, text = run(name, ARGS.get(name))
    except Exception as exc:  # noqa: BLE001
        res(f"matrix-skills:{name}", f"FAIL (dispatch raised {type(exc).__name__}: {exc})")
        continue
    first = text.strip().splitlines()[0][:90] if text.strip() else ""
    if "Traceback" in text or not text.strip():
        res(f"matrix-skills:{name}", f"FAIL (no answer or a traceback: {first!r})")
        continue
    binary = NEEDS.get(name)
    if binary and shutil.which(binary) and "is not installed" in text and binary in text:
        res(f"matrix-skills:{name}", f"FAIL ({binary} IS on the image but the skill says it is not installed)")
        continue
    note = f"{binary} {'present' if shutil.which(binary) else 'absent, reported honestly'}" if binary else "no binary needed"
    res(f"matrix-skills:{name}", f"PASS (ran={o.ran}; {note}; {first!r})")

# shani-deploy's real status document, the Shanios-only half.
o, text = run("snapshot_status")
if shutil.which("shani-deploy"):
    ok = "Shanios version" in text and "next boot uses" in text
    res("matrix-skills:shani-deploy-status-read", "PASS (the --status --json document was read)" if ok
        else f"FAIL (shani-deploy present but its status was not read: {text.splitlines()[0]!r})")
else:
    res("matrix-skills:shani-deploy-status-read", "SKIP (no shani-deploy on this image)")

# poppler, for real: merge two PDFs and require a VERIFIED verdict.
def make_pdf(path, pages):
    objs = ["<< /Type /Catalog /Pages 2 0 R >>",
            f"<< /Type /Pages /Kids [{' '.join(f'{3 + i} 0 R' for i in range(pages))}] /Count {pages} >>"]
    objs += ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>"] * pages
    out, offs = b"%PDF-1.4\n", []
    for n, body in enumerate(objs, 1):
        offs.append(len(out)); out += f"{n} 0 obj\n{body}\nendobj\n".encode()
    x = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode() + b"".join(f"{o:010d} 00000 n \n".encode() for o in offs)
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n".encode()
    path.write_bytes(out)
if shutil.which("pdfunite"):
    a, b = T / "a.pdf", T / "b.pdf"; make_pdf(a, 1); make_pdf(b, 2)
    o, text = run("pdf_pages", {"action": "merge", "paths": [str(a), str(b)], "output": str(T / "all.pdf")})
    res("matrix-skills:pdf-merge-verified", "PASS (3 pages, post-condition VERIFIED)" if o.verdict is Verdict.VERIFIED
        else f"FAIL (verdict {o.verdict.value}: {text.splitlines()[0]!r})")
else:
    res("matrix-skills:pdf-merge-verified", "FAIL (pdfunite is not on the image; poppler was expected)")

# Gates: nothing is granted, so every "set" must refuse and name its key.
for name, args, key in [
    ("set_hostname", {"action": "set", "name": "slot-test"}, "hostname-control-enabled"),
    ("set_locale", {"action": "set", "locale": "C.UTF-8"}, "locale-control-enabled"),
    ("default_apps", {"action": "set", "target": "pdf", "app": "x"}, "default-apps-enabled"),
    ("print_queue", {"action": "cancel", "job": "x-1"}, "print-control-enabled"),
    ("speed_test", {}, None),  # privacy mode (default on) or its own key - either way, no traffic
]:
    _, text = run(name, args)
    refused = "Refusing" in text and (key is None or key in text)
    res(f"matrix-skills:gate:{name}", "PASS (refused, naming the switch)" if refused
        else f"FAIL (not refused: {text.splitlines()[0][:90]!r})")

# Negative control: hide fc-list and require the ARCH package name.
real_path = os.environ.get("PATH", "")
os.environ["PATH"] = "/nonexistent"
try:
    from shani_chronoa.skills import list_fonts
    text = list_fonts._run({})
finally:
    os.environ["PATH"] = real_path
res("matrix-skills:control-missing-binary-named",
    "PASS (hidden fc-list reported with the 'fontconfig' package)" if "'fontconfig' package" in text
    else f"FAIL (expected the fontconfig package to be named: {text[:100]!r})")
PY
