#!/bin/bash
# A check of the harness itself: the MCP server exposes every testbed command
# and every app-session action, so an agent can do whatever a human can.
#
# WHY: on 2026-10-23 the server allowed 16 of 30 commands and none of the
# app actions behind visual regression (expect-same/-changed), OCR, a11y-lint,
# monkey, voice or --record. Nothing failed - the gap was only visible to an
# agent that needed one of them. This fails as soon as testbed or lib/app.sh
# grows a command/action the server does not know about.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
srv="$here/mcp/shani_harness_mcp.py"
fail=0

# testbed commands: the dispatcher's `name) cmd_...` lines, minus app (app_* tools)
mapfile -t cmds < <(sed -nE 's/^  ([a-z][a-z0-9-]*)\)[[:space:]]+cmd_.*/\1/p' "$here/testbed" | grep -vx app)
allowed=$(python3 -I - "$srv" <<'EOF'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
names = set()
for node in tree.body:
    if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") in ("CONTAINER_COMMANDS", "HOST_COMMANDS"):
        names |= {e.value for e in node.value.elts}
print("\n".join(sorted(names)))
EOF
)
for c in "${cmds[@]}"; do
  grep -qx "$c" <<<"$allowed" || { echo "FAIL: testbed command '$c' is not exposed by the MCP server"; fail=1; }
done

# app actions: every case label in _app_do must appear as an action string the
# server can send ("name=" or bare "name"); app_action covers anything else,
# but a typed tool is what an agent discovers.
mapfile -t actions < <(awk '/^_app_do\(\)/,/^}/' "$here/lib/app.sh" | grep -oE '^    [a-z0-9|-]+\)' | tr -d ' )' | tr '|' '\n')
for act in "${actions[@]}"; do
  grep -qE "\"${act}(=|\"|\\b)" "$srv" || { echo "FAIL: app action '$act' has no MCP tool"; fail=1; }
done

# app options worth exposing on app_start
for opt in local-src local-src-chronoa local-pkg repo-pkg whisper-model llm display size strict keyring voice gsettings record idle-timeout; do
  grep -q -- "--${opt}" "$srv" || { echo "FAIL: app option --${opt} is not reachable from app_start"; fail=1; }
done

(( fail )) && exit 1
echo "PASS: MCP exposes ${#cmds[@]} commands, ${#actions[@]} app actions and all app_start options"
