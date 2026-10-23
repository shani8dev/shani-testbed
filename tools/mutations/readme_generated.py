"""tests/readme-generated.sh must notice when the code changes under the README."""
TEST = "tests/readme-generated.sh"
MUTATIONS = [
    {"file": "lib/usage.sh", "label": "a command's usage line changes without regenerating",
     "old": "  reboot      ", "new": "  reboot      Renamed: "},
    {"file": "mcp/shani_harness_mcp.py", "label": "an MCP tool's description changes without regenerating",
     "old": '"Pause inside the session', "new": '"Wait inside the session'},
]
