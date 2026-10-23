#!/usr/bin/env python3
"""Generate README.md's reference tables from the code, so they cannot drift.

Ported from shani-chronoa/tools/gen_capabilities.py. A hand-kept README table
goes stale in silence: it still reads fine after the command it describes was
renamed, gained an option, or moved host-only. These tables are rebuilt from
the things that actually decide behaviour:

  commands   the dispatcher in ./testbed  + the one-liners in lib/usage.sh
             + which commands are host-only + how the MCP server reaches each
  mcp-tools  the TOOLS list in mcp/shani_harness_mcp.py
  slot-tests slot-tests/*.sh: the `slot-test-mode:` header and first sentence

Usage:
    tools/gen_readme.py           # rewrite the generated blocks in README.md
    tools/gen_readme.py --check   # exit 1 if README.md is out of date (CI)

Each block lives between `<!-- BEGIN GENERATED: name -->` and
`<!-- END GENERATED: name -->`; everything outside the markers is untouched.
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
README = ROOT / "README.md"


def dispatcher() -> list:
    """(command, lib file defining its cmd_ function), in dispatcher order."""
    rows = []
    libs = {p: p.read_text() for p in sorted((ROOT / "lib").glob("*.sh"))}
    for m in re.finditer(r"^  ([a-z][a-z0-9-]*)\)\s+(cmd_[a-z_]+) ", (ROOT / "testbed").read_text(), re.M):
        cmd, fn = m.groups()
        where = next((f"lib/{p.name}" for p, t in libs.items() if re.search(rf"^{fn}\(\)", t, re.M)), "?")
        rows.append((cmd, where))
    return rows


ARG_RUN = re.compile(r"^((?:\s*(?:\[[^\]]*\]|<[^>]*>|--?[\w=.,|<>\x22/-]+|\.\.\.|\|))+)\s+(?=[A-Z(])")
ABBREV = ("e.g.", "i.e.", "incl.", "etc.", "vs.")


def first_sentence(text: str) -> str:
    for m in re.finditer(r"[.!?](?=\s)|\s[—]\s", text):
        end = m.end()
        if any(text[:end].endswith(a) for a in ABBREV):
            continue
        return text[:m.start()].strip() if text[m.start()] in " —" else text[:end].strip().rstrip(".")
    return text.strip().rstrip(".")


def usage_summaries() -> dict:
    """command -> (args, first sentence) from the Commands: block of usage()."""
    out, cur, buf = {}, None, []

    def flush():
        if not cur:
            return
        joined = " ".join(" ".join(buf).split())
        args = ""
        m = ARG_RUN.match(joined)
        if m:
            args, joined = " ".join(m.group(1).split()), joined[m.end():]
        out[cur] = (args, first_sentence(joined))

    for line in (ROOT / "lib" / "usage.sh").read_text().splitlines():
        m = re.match(r"^  ([a-z][a-z0-9-]*)\s{2,}(.*)$", line)
        if m:
            flush()
            cur, buf = m.group(1), [m.group(2)]
        elif cur and re.match(r"^\s{6,}\S", line):
            buf.append(line.strip())
        elif cur and not line.strip():
            continue
        elif cur:
            flush()
            cur, buf = None, []
    flush()
    return out


def server_sets() -> dict:
    tree = ast.parse((ROOT / "mcp" / "shani_harness_mcp.py").read_text())
    found = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            if name in ("CONTAINER_COMMANDS", "HOST_COMMANDS", "BACKGROUND_HINT"):
                found[name] = {e.value for e in node.value.elts}
            if name == "TOOLS":
                found["TOOLS"] = [(ast.literal_eval(t.elts[0]), ast.literal_eval(t.elts[1])) for t in node.value.elts]
    return found


def esc(s: str) -> str:
    return s.replace("|", "\\|")


def table_commands() -> str:
    use, srv = usage_summaries(), server_sets()
    lines = ["| command | arguments | what it does (lib/usage.sh) | runs | via MCP |", "|---|---|---|---|---|"]
    for cmd, where in dispatcher():
        args, what = use.get(cmd, ("", "**no line in lib/usage.sh** - `testbed --help` does not list it"))
        runs = "host" if cmd in srv.get("HOST_COMMANDS", set()) else "container"
        if cmd == "app":
            mcp = "`app_*` tools"
        elif cmd in srv.get("BACKGROUND_HINT", set()):
            mcp = "`harness_start`"
        elif cmd in srv.get("HOST_COMMANDS", set()) | srv.get("CONTAINER_COMMANDS", set()):
            mcp = "`harness_run`"
        else:
            mcp = "**not exposed**"
        lines.append(f"| `{cmd}` | {esc('`' + args + '`' if args else '')} | {esc(what)} | {runs} ({where}) | {mcp} |")
    return "\n".join(lines)


def table_mcp_tools() -> str:
    lines = ["| tool | what it does |", "|---|---|"]
    for name, desc in server_sets().get("TOOLS", []):
        lines.append(f"| `{name}` | {esc(desc)} |")
    return "\n".join(lines)


def table_slot_tests() -> str:
    lines = ["| slot-test | mode | what it checks |", "|---|---|---|"]
    for p in sorted((ROOT / "slot-tests").glob("*.sh")):
        text = p.read_text().splitlines()
        mode = next((l.split(":", 1)[1].strip() for l in text[:5] if "slot-test-mode:" in l), None)
        if mode is None:
            continue  # helpers sourced by others, never run on their own
        comment = []
        for l in text[1:40]:
            if not l.startswith("#"):
                break
            body = l.lstrip("#").strip()
            if body.startswith("slot-test-"):
                continue
            if not body and comment:
                break
            if body:
                comment.append(body)
        joined = " ".join(comment)
        joined = re.sub(rf"^{re.escape(p.stem)}\s*[—-]\s*", "", joined)
        what = re.split(r"(?<=[.:])\s", joined, maxsplit=1)[0].rstrip(".:")
        lines.append(f"| `{p.stem}` | {mode} | {esc(what)} |")
    return "\n".join(lines)


BLOCKS = {"commands": table_commands, "mcp-tools": table_mcp_tools, "slot-tests": table_slot_tests}


def render(readme: str) -> str:
    for name, fn in BLOCKS.items():
        pat = re.compile(rf"(<!-- BEGIN GENERATED: {name} -->\n).*?(<!-- END GENERATED: {name} -->)", re.S)
        if not pat.search(readme):
            raise SystemExit(f"README.md has no markers for block {name!r}")
        body = fn()
        readme = pat.sub(lambda m: m.group(1) + body + "\n" + m.group(2), readme)
    return readme


def main() -> int:
    current = README.read_text()
    fresh = render(current)
    if "--check" in sys.argv:
        if fresh != current:
            print("README.md generated tables are stale - run tools/gen_readme.py and commit the result")
            return 1
        print("README.md generated tables are up to date")
        return 0
    if fresh != current:
        README.write_text(fresh)
        print("README.md updated")
    else:
        print("README.md already up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
