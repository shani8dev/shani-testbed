#!/bin/bash
# A check of the harness itself: README.md's generated reference tables match
# the code (tools/gen_readme.py --check).
#
# WHY: the hand-written README described commands, options and MCP tools that
# had drifted from the code - 2026-10-23 found 4 commands (verify-boot,
# slot-test, update-check, iso-install) with no line in lib/usage.sh at all, and
# an MCP section listing a fraction of the tools. Generated tables cannot drift
# silently: this fails until the generator is rerun and the result committed.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I tools/gen_readme.py --check
