#!/bin/bash
# Sourced by slot-tests that ask pacman which package owns what (no
# slot-test-mode header: the runner never runs this file on its own).
#
# On a real ShaniOS boot /var is an empty tmpfs (systemd.volatile=state), so
# /var/lib/pacman/local does not exist at runtime - and neither does it under
# `slot-test --volatile`, which reproduces that. The database is still in the
# slot's own read-only subvolume, underneath the tmpfs: mount that subvolume
# read-only elsewhere and point pacman at it. Without --volatile the live path
# is used as before.
#
#   source /mnt/testbed/slot-tests/_pacdb.sh   then:   pacq -Qql shani-deploy
PACDB=/var/lib/pacman
_PACDB_MNT=""
if [ ! -d /var/lib/pacman/local ] || [ -z "$(ls -A /var/lib/pacman/local 2>/dev/null)" ]; then
    # the btrfs device: by label (also present in the harness's nspawn boots,
    # whose / is an overlay), else whatever / is mounted from
    _dev=/dev/disk/by-label/shani_root
    if [ ! -e "$_dev" ]; then _src=$(findmnt -no SOURCE / 2>/dev/null); _dev=${_src%%[*}; fi
    _sub=$(sed -n 's/.*rootflags=[^ ]*subvol=@\{0,1\}\([a-z]*\).*/\1/p' /proc/cmdline)
    [ -n "$_sub" ] || _sub=$(tr -d '[:space:]' < /data/current-slot 2>/dev/null)
    _PACDB_MNT=$(mktemp -d /run/shani-pacdb.XXXXXX)
    if [ -n "$_dev" ] && [ -n "$_sub" ] && mount -o ro,subvol="@${_sub}" "$_dev" "$_PACDB_MNT" 2>/dev/null; then
        PACDB="$_PACDB_MNT/var/lib/pacman"
    else
        rmdir "$_PACDB_MNT"; _PACDB_MNT=""
    fi
fi
pacq() { pacman --dbpath "$PACDB" "$@"; }
_pacdb_cleanup() { [ -n "$_PACDB_MNT" ] && { umount "$_PACDB_MNT" 2>/dev/null; rmdir "$_PACDB_MNT" 2>/dev/null; }; }
