"""tests/boot-default-entry-id.sh must catch a boot default that is not an entry id."""
TEST = "tests/boot-default-entry-id.sh"
MUTATIONS = [
    {"file": "../shani-deploy/scripts/shani-deploy.sh",
     "label": "shani-deploy writes the slot stem instead of the .conf entry id",
     "old": 'local loader_default="${OS_NAME}-${active_slot}.conf"',
     "new": 'local loader_default="${OS_NAME}-${active_slot}"'},
]
