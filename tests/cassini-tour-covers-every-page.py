#!/usr/bin/env python3
"""The Cassini tour must cover every page the app has.

A tour that is 25 pages behind is worse than no tour: it reports PASS while
walking a third of the sidebar, and nothing in it notices that a page was added.
That is exactly what happened - the tour was a hand-maintained list of 32
`click-element` lines against a 57-page sidebar, and the rot was invisible until
the two were counted against each other.

So this compares the checked-in actions file with what
`app-scripts/generate-cassini-tour.py` produces from the app's own `SECTIONS`,
and fails when they differ. Adding a page now fails here until the tour is
regenerated.

Runs on the host in a second, with no slot, no display and no GTK: it is two
text files and an import.

    python3 tests/cassini-tour-covers-every-page.py [--repo=../shani-cassini]
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR = os.path.join(HERE, "app-scripts", "generate-cassini-tour.py")
TOUR = os.path.join(HERE, "app-scripts", "cassini-tour.actions")

RESULT_PREFIX = "RESULT "


def res(name: str, verdict: str) -> None:
    print(f"{RESULT_PREFIX}{name:<44} {verdict}")


def sidebar_titles(repo: str) -> list[tuple[str, str]]:
    src = os.path.join(repo, "src")
    if src not in sys.path:
        sys.path.insert(0, src)
    from shani_cassini.notebook import SECTIONS
    return [(e[1], e[2]) for _g, subs in SECTIONS for _s, pp in subs for e in pp]


def toured_patterns() -> dict[str, str]:
    """page id -> the regex the tour clicks for it.

    Read back out of the actions file by matching the comment the generator
    writes (`# --- Title (id)`) rather than by re-deriving the click line: the
    id in the comment is what the generator emitted, so a tour that lists a
    page id the sidebar does not have is caught rather than matched.
    """
    out: dict[str, str] = {}
    pending: str | None = None
    with open(TOUR, encoding="utf-8") as handle:
        for line in handle:
            comment = re.match(r"# --- .* \(([a-z0-9-]+)\)\s*$", line)
            if comment:
                pending = comment.group(1)
                continue
            click = re.match(r"click-element=(.+)$", line)
            if click and pending:
                out[pending] = click.group(1).strip()
                pending = None
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.path.join(HERE, "..", "shani-cassini"))
    args = ap.parse_args()
    repo = os.path.realpath(args.repo)

    failures = 0

    try:
        pages = sidebar_titles(repo)
    except Exception as exc:  # the app not importable is itself the finding
        res("sidebar-readable", f"FAIL ({exc})")
        return 1
    res("sidebar-readable", f"PASS ({len(pages)} pages)")

    toured = toured_patterns()
    missing = [f"{pid} ({title})" for pid, title in pages if pid not in toured]
    if missing:
        shown = ", ".join(missing[:6]) + (" ..." if len(missing) > 6 else "")
        res("every-page-is-toured",
            f"FAIL ({len(missing)} not toured: {shown})")
        failures += 1
    else:
        res("every-page-is-toured", f"PASS (all {len(pages)})")

    extra = sorted(set(toured) - {pid for pid, _t in pages})
    if extra:
        res("no-page-that-does-not-exist",
            f"FAIL ({', '.join(extra)} is not in the sidebar)")
        failures += 1
    else:
        res("no-page-that-does-not-exist", "PASS")

    # Each page's click must match its OWN title and nothing else, so one
    # page's row cannot stand in for another's.
    wrong = []
    for pid, title in pages:
        pattern = toured.get(pid)
        if pattern is None:
            continue
        if not re.search(pattern, title):
            wrong.append(f"{pid}: /{pattern}/ does not match {title!r}")
        for other_pid, other_title in pages:
            if other_pid != pid and re.search(pattern, other_title):
                wrong.append(f"{pid}: /{pattern}/ also matches "
                             f"{other_pid} ({other_title!r})")
    if wrong:
        res("each-click-is-that-page-only", f"FAIL ({wrong[0]}"
            + (f" +{len(wrong) - 1} more" if len(wrong) > 1 else "") + ")")
        failures += 1
    else:
        res("each-click-is-that-page-only", "PASS")

    # And the file must be exactly what the generator produces, so the format
    # itself cannot drift (a screenshot per page, the lint after each one).
    proc = subprocess.run([sys.executable, GENERATOR, f"--repo={repo}", "--check"],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip().splitlines()
        res("tour-matches-the-generator", f"FAIL ({detail[0] if detail else '?'})")
        failures += 1
    else:
        res("tour-matches-the-generator", "PASS")

    shots = sum(1 for line in open(TOUR, encoding="utf-8")
                if line.startswith("screenshot=@out/tour-"))
    lints = sum(1 for line in open(TOUR, encoding="utf-8")
                if line.startswith("a11y-lint"))
    if shots >= len(pages) and lints >= len(pages):
        res("a-screenshot-and-a-lint-per-page",
            f"PASS ({shots} screenshots, {lints} lints)")
    else:
        res("a-screenshot-and-a-lint-per-page",
            f"FAIL ({shots} screenshots / {lints} lints for {len(pages)} pages)")
        failures += 1

    total = 5
    print(f"{total - failures}/{total} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
