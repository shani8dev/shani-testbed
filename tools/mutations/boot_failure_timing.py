"""tests/boot-failure-timing.sh must catch a producer/consumer timer reorder."""
TEST = "tests/boot-failure-timing.sh"
MUTATIONS = [
    {"file": "../shani-deploy/systemd/system/check-boot-failure.timer",
     "label": "boot-failure check fires after the rollback reads its marker (15m -> 17m)",
     "old": "OnBootSec=15m\n", "new": "OnBootSec=17m\n"},
    {"file": "../shani-deploy/systemd/system/shani-auto-rollback.timer",
     "label": "soft-failure rollback check fires before the marker exists (16m -> 14m)",
     "old": "\nOnBootSec=16m\n", "new": "\nOnBootSec=14m\n"},
]
