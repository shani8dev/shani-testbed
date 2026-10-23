"""tests/mcp-parity.sh must notice when the MCP server drops a testbed feature."""
TEST = "tests/mcp-parity.sh"
F = "mcp/shani_harness_mcp.py"
MUTATIONS = [
    {"file": F, "label": "the release gate is no longer an allowed command",
     "old": '"suite", "gate", "install",', "new": '"suite", "install",'},
    {"file": F, "label": "a host-only command (vmspawn) disappears",
     "old": 'HOST_COMMANDS = {"vmspawn", "qemu", "gui", "iso", "watch"}',
     "new": 'HOST_COMMANDS = {"qemu", "gui", "iso", "watch"}'},
    {"file": F, "label": "a11y-lint has no tool any more",
     "old": '"app_a11y_lint": lambda: "a11y-lint",', "new": '"app_a11y_lint": lambda: "status",'},
    {"file": F, "label": "app_start can no longer record",
     "old": 'extra.append("--record=" + SESSION.record)', "new": 'pass'},
]
