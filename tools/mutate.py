#!/usr/bin/env python3
"""Run a mutation set: break the code, watch the test fail, put it back.

Ported from shani-chronoa/tools/mutate.py (pytest-based) to this repo's bash
tests. The rule both carry: **a negative control that cannot fail is not a
control.** This harness has shipped checks that passed while measuring
nothing - the power-cut efivar check that reported PASS for a write that never
happened (2026-10-18) - and the negative controls that would have caught it
lived in /tmp and were lost. They live here now, beside the tests they back.

Usage:
    tools/mutate.py                 # every set in tools/mutations/
    tools/mutate.py mcp_parity      # one set by name
    tools/mutate.py --list

A set is a Python module in tools/mutations/ exporting:
    TEST      = "tests/some-check.sh"        # run with bash from the repo root
    MUTATIONS = [{"file": "lib/x.sh",        # relative to this repo; ../ reaches
                  "old": "exact text",       #   sibling repos (shani-deploy, ...)
                  "new": "replacement",
                  "label": "what it breaks"}]

Rules the runner enforces (each from chronoa's measured failures):
1. Every anchor occurs exactly once, asserted before the write - a replace that
   matched nothing is a "survivor" that never ran.
2. The file is restored in a `finally`, and a journal records the original
   before the write, so a SIGKILLed run is put back by the next run.
3. One run at a time (O_EXCL lock holding the pid; a dead owner is reported and
   taken over) - two runs each restoring their own copy corrupt the tree.
4. The test runs in its own process group with a timeout; a timeout kills the
   whole group and is reported as TIMEOUT, never as caught.
5. A mutation is CAUGHT only when the test exits non-zero; the unmutated
   baseline must pass first, or the set is reported unmeasurable.
6. A set that errors does not stop the run, and the tally says how many sets it
   reached out of how many exist.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SETS_DIR = ROOT / "tools" / "mutations"
STATE = ROOT / "cache" / "mutate"
LOCK = STATE / "run.lock"
JOURNAL = STATE / "mutated.json"
TIMEOUT = 300


def sets() -> dict:
    return {p.stem: p for p in sorted(SETS_DIR.glob("*.py")) if not p.stem.startswith("_")}


def load(path: Path):
    spec = importlib.util.spec_from_file_location("mutset_" + path.stem, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Lock:
    def __enter__(self):
        STATE.mkdir(parents=True, exist_ok=True)
        while True:
            try:
                fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                try:
                    pid = int(LOCK.read_text().split()[0])
                    os.kill(pid, 0)
                except (OSError, ValueError, IndexError):
                    print(f"  NOTE: taking over a stale lock ({LOCK.read_text().strip()!r})", file=sys.stderr)
                    LOCK.unlink(missing_ok=True)
                    continue
                sys.exit(f"another mutation run holds the tree (pid {pid}); two runs overwrite each other's restore")
            with os.fdopen(fd, "w") as f:
                f.write(f"{os.getpid()}\n")
            return self

    def __exit__(self, *exc):
        LOCK.unlink(missing_ok=True)


def recover() -> list:
    """Put back anything a killed run left mutated."""
    if not JOURNAL.exists():
        return []
    done = []
    for name, text in json.loads(JOURNAL.read_text()).items():
        (ROOT / name).write_text(text)
        done.append(name)
    JOURNAL.unlink()
    return done


def run_test(test: str) -> tuple:
    """(rc or 'TIMEOUT', output tail)."""
    proc = subprocess.Popen(["bash", test], cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        out, _ = proc.communicate()
        return "TIMEOUT", out[-600:]
    return proc.returncode, out[-600:]


def apply(m: dict) -> tuple:
    path = ROOT / m["file"]
    original = path.read_text()
    count = original.count(m["old"])
    if count != 1:
        raise AssertionError(f"anchor occurs {count} times in {m['file']} (must be exactly 1): {m['old'][:60]!r}")
    JOURNAL.write_text(json.dumps({m["file"]: original}))
    path.write_text(original.replace(m["old"], m["new"]))
    return path, original


def run_set(name: str, path: Path, quiet: bool) -> dict:
    mod = load(path)
    rc, out = run_test(mod.TEST)
    if rc != 0:
        print(f"[{name}] UNMEASURABLE: baseline {mod.TEST} does not pass (rc={rc})\n{out}")
        return {"set": name, "error": "baseline fails", "caught": 0, "total": len(mod.MUTATIONS)}
    caught = 0
    rows = []
    for m in mod.MUTATIONS:
        target = None
        try:
            target, original = apply(m)
            rc, out = run_test(mod.TEST)
        except AssertionError as e:
            rows.append(("ERROR", m["label"], str(e)))
            continue
        finally:
            if target is not None:
                target.write_text(original)
                JOURNAL.unlink(missing_ok=True)
        if rc == "TIMEOUT":
            rows.append(("TIMEOUT", m["label"], ""))
        elif rc != 0:
            caught += 1
            rows.append(("CAUGHT", m["label"], ""))
        else:
            rows.append(("SURVIVED", m["label"], out.strip().splitlines()[-1] if out.strip() else ""))
    print(f"[{name}] {caught}/{len(mod.MUTATIONS)} caught by {mod.TEST}")
    for verdict, label, why in rows:
        if not quiet or verdict != "CAUGHT":
            print(f"  {verdict:<9} {label}" + (f"  ({why})" if why else ""))
    return {"set": name, "caught": caught, "total": len(mod.MUTATIONS),
            "survivors": [r[1] for r in rows if r[0] != "CAUGHT"]}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("names", nargs="*")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="only print non-caught mutations")
    args = ap.parse_args()
    available = sets()
    if args.list:
        for name, path in available.items():
            mod = load(path)
            print(f"{name:<24} {len(mod.MUTATIONS)} mutations  -> {mod.TEST}")
        return 0
    chosen = args.names or list(available)
    unknown = [n for n in chosen if n not in available]
    if unknown:
        sys.exit(f"unknown set(s): {', '.join(unknown)}; --list shows them")
    with Lock():
        for name in recover():
            print(f"  NOTE: restored {name}, left mutated by a killed run", file=sys.stderr)
        results = []
        for name in chosen:
            try:
                results.append(run_set(name, available[name], args.quiet))
            except Exception as e:  # one broken set does not stop the rest
                print(f"[{name}] ERROR: {type(e).__name__}: {e}")
                results.append({"set": name, "error": str(e), "caught": 0, "total": 0})
    total = sum(r["total"] for r in results)
    caught = sum(r["caught"] for r in results)
    errors = [r["set"] for r in results if r.get("error")]
    print(f"\n{caught}/{total} mutations caught across {len(results) - len(errors)}/{len(chosen)} sets measured"
          + (f"; NOT measured: {', '.join(errors)}" if errors else ""))
    return 0 if caught == total and not errors else 1


if __name__ == "__main__":
    sys.exit(main())
