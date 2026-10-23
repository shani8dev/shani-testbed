"""tests/lock-release.sh must catch a child that keeps the disk lock open."""
TEST = "tests/lock-release.sh"
MUTATIONS = [
    {"file": "lib/common.sh", "label": "the system D-Bus inherits the lock descriptor again",
     "old": "dbus-daemon --system --fork 9>&- \\", "new": "dbus-daemon --system --fork \\"},
]
