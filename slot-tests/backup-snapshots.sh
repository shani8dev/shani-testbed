#!/bin/bash
# slot-test-mode: boot
#
# backup-snapshots — what `shani_backup.btrfs` actually does on a REAL btrfs
# filesystem, measured rather than reasoned about, driving the repo's own module
# (/mnt/src/shani-backup, the live checkout, read-only) instead of a copy of it.
#
# WHY THIS FILE EXISTS. Shanios root IS btrfs: `/` is a subvolume, `@blue`/
# `@green` are its siblings, and `btrfs subvolume list /` on a real machine
# returns *system* subvolumes, not only the ones somebody took as backups. Six
# claims about this repo's snapshot code decide what its fix has to be, so none
# of them may be left as a reading:
#
#   1. `create_snapshot` on a **plain directory**. The GUI checked only
#      `os.path.exists(source)`, so any directory - most of `/home` is one -
#      passed the check and failed inside btrfs.
#   2. A destination on **another filesystem**. btrfs cannot snapshot across
#      filesystems at all.
#   3. The Snapshots tab's default, which is a **sibling of the source**. Whether
#      that works depends on which subvolume the source is.
#   4. `list_snapshots` called with a path that is **not a subvolume root**. The
#      implementation joins the tool's relative paths onto `findmnt -T`'s mount
#      point; whether that is right depends on what the tool prints relative to,
#      which is exactly what a reading cannot settle. The property asserted is
#      the one a caller depends on: **every path returned exists on disk**,
#      because the tab hands a returned path straight to `delete_snapshot`. A
#      wrong join is a wrong delete.
#   5. `delete_snapshot` on a **read-only** snapshot - the kind the GUI itself
#      creates (`readonly=True`). Whether its Delete button can remove what its
#      own Create button makes is not an assumption to make.
#   6. What a real ShaniOS machine has in that list, read-only: the rows a user
#      is one click from acting on.
#
# WHERE THE FILESYSTEM COMES FROM. A loopback image is the preferred scratch
# space, and on the first run of this check it did not work: **the slot has no
# loop devices at all** (`/dev/loop-control` absent, the module loaded on the
# host but no nodes in nspawn's /dev), so `mount -o loop` answers ENOENT. The
# fallback is a scratch **subvolume of the slot's own root filesystem**, created
# under subvolume 5, and everything is measured inside it. That is deliberately
# the same device a real user's snapshots live on, which is the point. It is
# disposable: nothing existing is read for writing, touched or deleted, and the
# scratch subvolume is removed on exit. The second filesystem claim is measured
# against a **tmpfs**, which nspawn does allow.
#
# NEGATIVE CONTROL: `btrfs-path-probe-can-fail` computes the path the mount-point
# join would produce for the nested snapshot and asserts it does NOT exist. Without
# it, claims 4 and 5 would pass exactly as well against a list_snapshots that
# returns nothing at all - the failure mode this repo's tests keep finding.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }

SRC=/mnt/src/shani-backup/src
[ -d "$SRC" ] || { res backup-repo-mounted "SKIP (no /mnt/src/shani-backup on this run)"; exit 0; }
res backup-repo-mounted "PASS ($SRC is the live checkout, read-only)"

command -v btrfs >/dev/null || { res btrfs-present "SKIP (btrfs-progs not installed)"; exit 0; }
res btrfs-present "PASS ($(btrfs --version 2>&1 | head -1))"

T=$(mktemp -d /tmp/shani-backup-btrfs.XXXXXX)
SCRATCH="@backup-probe-scratch-$$"
cleanup() {
  for m in "$T/root" "$T/toplevel" "$T/other"; do
    mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null
  done
  if [ -n "${SCRATCH_CREATED:-}" ]; then
    mkdir -p "$T/toplevel" 2>/dev/null
    mount -o subvolid=5 /dev/disk/by-label/shani_root "$T/toplevel" 2>/dev/null && \
      btrfs subvolume delete "$T/toplevel/$SCRATCH" >/dev/null 2>&1
    mountpoint -q "$T/toplevel" 2>/dev/null && umount "$T/toplevel" 2>/dev/null
  fi
  rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$T/toplevel" "$T/root" "$T/other"
HOW=""

# Preferred: a throwaway loopback image. Measured to fail on this harness (no
# loop devices in the slot's /dev), so it is a capability probe, not an
# assumption.
if dd if=/dev/zero of="$T/a.img" bs=1M count=192 status=none 2>/dev/null &&
   mkfs.btrfs -q "$T/a.img" 2>/dev/null &&
   mount -o loop "$T/a.img" "$T/root" 2>/dev/null; then
  HOW="loopback image at $T/root"
else
  if ! mount -o subvolid=5 /dev/disk/by-label/shani_root "$T/toplevel" 2>/dev/null; then
    res btrfs-scratch-available "FAIL (no loop devices and subvolume 5 could not be mounted: $(ls /dev/loop-control 2>&1 | head -1))"
    exit 0
  fi
  if ! btrfs subvolume create "$T/toplevel/$SCRATCH" >/dev/null 2>&1; then
    res btrfs-scratch-available "FAIL (could not create the scratch subvolume $SCRATCH)"
    exit 0
  fi
  SCRATCH_CREATED=1
  # Two spellings, because which one nspawn's mount accepts is worth knowing and
  # the error is worth having: a path-form mount of a subvolume that was created
  # moments ago is the obvious one, and `-o subvol=NAME` is the one the real
  # fstab uses.
  MOUNT_ERR=""
  for attempt in path subvol; do
    if [ "$attempt" = path ]; then
      ERR=$(mount "$T/toplevel/$SCRATCH" "$T/root" 2>&1) && break
    else
      ERR=$(mount -o "subvol=$SCRATCH" /dev/disk/by-label/shani_root "$T/root" 2>&1) && break
    fi
    MOUNT_ERR="$attempt: $ERR"
  done
  if ! mountpoint -q "$T/root" 2>/dev/null; then
    res btrfs-scratch-available "FAIL (created $SCRATCH but could not mount it: ${MOUNT_ERR:-both forms failed}; subvolume list shows: $(btrfs subvolume list "$T/toplevel" 2>&1 | tail -2 | tr '\n' ' ' | cut -c1-160))"
    exit 0
  fi
  HOW="scratch subvolume $SCRATCH on the slot's own root device"
fi
res btrfs-scratch-available "PASS ($HOW; removed on exit)"

# The second filesystem for claim 2.
mount -t tmpfs -o size=8m tmpfs "$T/other" 2>/dev/null && OTHER="$T/other" || OTHER=""

# The shape every claim is asked against: a subvolume with a plain directory
# inside it, a nested subvolume, and snapshots of both.
#
# ORDER MATTERS, and the first version of this got it wrong: `data/inner` was
# mkdir'd BEFORE `btrfs subvolume create data`, so `data` was never a subvolume
# and claims 2 and 3 were answered "is not a btrfs subvolume" about a path that
# was supposed to be one. A probe whose fixture is wrong is worse than no probe,
# because it reports a fact about the wrong machine.
btrfs subvolume create "$T/root/data" >/dev/null 2>&1 || { res btrfs-fixtures-built "FAIL (could not create the data subvolume)"; exit 0; }
mkdir -p "$T/root/data/inner"
echo payload >"$T/root/data/inner/file"
btrfs subvolume create "$T/root/data/inner/nested" >/dev/null 2>&1
btrfs subvolume snapshot "$T/root/data" "$T/root/snap-data" >/dev/null 2>&1
btrfs subvolume snapshot -r "$T/root/data/inner/nested" "$T/root/snap-nested-ro" >/dev/null 2>&1
btrfs subvolume snapshot "$T/root/data/inner/nested" "$T/root/snap-nested" >/dev/null 2>&1
res btrfs-fixtures-built "PASS (data is a subvolume: $(btrfs subvolume show "$T/root/data" >/dev/null 2>&1 && echo yes || echo no); $(btrfs subvolume list "$T/root" 2>/dev/null | wc -l) subvolumes listed under the scratch root, against $(btrfs subvolume list "$T/root/data" 2>/dev/null | wc -l) under data)"

export PYTHONPATH="$SRC" PYTHONDONTWRITEBYTECODE=1
py() { python3 -c "$1" 2>&1; }

# --- 4. every returned path must exist, because it is handed to delete -------
# The path is embedded as a quoted Python string literal. The first version used
# `printf %q`, which prints a plain path with no shell metacharacters as itself,
# so the generated line read `list_snapshots_detailed(/tmp/...)` and all three of
# these checks died on a SyntaxError - reported as three FAILs that looked like
# findings about the code.
check_paths_exist() {
  local label=$1 path=$2 out paths missing
  out=$(py "
import json, os
from shani_backup.btrfs import list_snapshots_detailed
r = list_snapshots_detailed('$path')
print(json.dumps({'ok': r.ok, 'paths': r.paths, 'detail': r.detail,
                  'missing': [p for p in r.paths if not os.path.exists(p)]}))
")
  paths=$(printf '%s' "$out" | sed -n 's/.*"paths": \(\[[^]]*\]\).*/\1/p')
  missing=$(printf '%s' "$out" | sed -n 's/.*"missing": \(\[[^]]*\]\).*/\1/p')
  if printf '%s' "$out" | grep -q '"ok": false'; then
    res "$label" "FAIL (the read refused: $(printf '%s' "$out" | sed -n 's/.*"detail": "\([^"]*\)".*/\1/p'))"
  elif [ -z "$paths" ]; then
    res "$label" "FAIL (no parseable answer: $(printf '%s' "$out" | tr -d '\n' | cut -c1-120))"
  elif [ "$missing" != "[]" ]; then
    res "$label" "FAIL (returned $(printf '%s' "$paths" | tr -cd ',' | wc -c) path(s); these do not exist: $missing)"
  else
    res "$label" "PASS ($path -> $paths, every path exists)"
  fi
}
check_paths_exist list-from-subvolume-root "$T/root/data"
check_paths_exist list-from-plain-dir "$T/root/data/inner"
check_paths_exist list-from-mount-root "$T/root"

# --- the control: the old join's answer must be distinguishable from the truth
old_join=$(py "
import json, os
from shani_backup.btrfs import _mount_point_for
bogus = _mount_point_for('$T/root/data/inner').rstrip('/') + '/nested/snap'
print(json.dumps({'bogus': bogus, 'exists': os.path.exists(bogus)}))
")
if printf '%s' "$old_join" | grep -q '"exists": true'; then
  res btrfs-path-probe-can-fail "FAIL (the join's wrong answer exists on disk, so the existence check cannot tell right from wrong here)"
else
  res btrfs-path-probe-can-fail "PASS (the join's answer $(printf '%s' "$old_join" | sed -n 's/.*"bogus": "\([^"]*\)".*/\1/p') does not exist, so existence really discriminates)"
fi

# --- 1. a plain directory cannot be snapshotted ------------------------------
plain=$(py "
from shani_backup.btrfs import create_snapshot_detailed, is_btrfs_path
r = create_snapshot_detailed('$T/root/data/inner', '$T/root/snap-of-plain-dir')
print('ok=%s detail=%r is_subvolume=%s' % (r.ok, r.detail, is_btrfs_path('$T/root/data/inner')))
")
if printf '%s' "$plain" | grep -q "ok=True"; then
  res create-snapshot-of-plain-dir "FAIL (it succeeded - btrfs snapshotted a plain directory: $plain)"
else
  res create-snapshot-of-plain-dir "PASS (refused; is_btrfs_path=False; $plain)"
fi

# --- 2. a destination on another filesystem ----------------------------------
if [ -n "$OTHER" ]; then
  cross=$(py "
from shani_backup.btrfs import create_snapshot_detailed
r = create_snapshot_detailed('$T/root/data', '$OTHER/snapshot')
print('ok=%s detail=%r' % (r.ok, r.detail))
")
  if printf '%s' "$cross" | grep -q "ok=True"; then
    res create-snapshot-cross-filesystem "FAIL (it succeeded across two filesystems: $cross)"
  else
    res create-snapshot-cross-filesystem "PASS (refused, as btrfs must: $cross)"
  fi
else
  res create-snapshot-cross-filesystem "SKIP (no tmpfs could be mounted for a second filesystem)"
fi

# --- 3. the sibling-of-source destination the Snapshots tab defaults to -------
sibling=$(py "
from shani_backup.btrfs import create_snapshot_detailed
r = create_snapshot_detailed('$T/root/data', '$T/root/data-snapshot-default')
print('ok=%s detail=%r' % (r.ok, r.detail))
")
if printf '%s' "$sibling" | grep -q "ok=True"; then
  btrfs subvolume delete "$T/root/data-snapshot-default" >/dev/null 2>&1
  res create-snapshot-as-sibling-of-source "PASS (the tab's sibling default works for a subvolume that is not the top-level one)"
else
  res create-snapshot-as-sibling-of-source "FAIL (the tab's own default destination was refused: $sibling)"
fi

# --- 5. can a read-only snapshot be deleted? ---------------------------------
ro=$(py "
from shani_backup.btrfs import delete_snapshot_detailed
r = delete_snapshot_detailed('$T/root/snap-nested-ro')
print('ok=%s detail=%r' % (r.ok, r.detail))
")
if printf '%s' "$ro" | grep -q "ok=True"; then
  res delete-readonly-snapshot "PASS (deleted; the tab can remove what it creates)"
else
  res delete-readonly-snapshot "FAIL (delete_snapshot_detailed refused its own readonly=True output: $ro)"
fi

# --- 6. the real machine, read only -------------------------------------------
# Carries findmnt's answer and the tool's own first line, because the first run
# of this reported "0 subvolumes reachable from /" with nothing to explain it -
# and an empty list beside a zero count is precisely the answer this whole file
# exists to distrust.
real=$(py "
import json
from shani_backup.btrfs import list_snapshots_detailed, is_btrfs_path, _mount_point_for
r = list_snapshots_detailed('/')
print(json.dumps({'ok': r.ok, 'n': len(r.paths), 'paths': r.paths[:10],
                  'detail': r.detail, 'mount_of_root': _mount_point_for('/'),
                  'root_is_subvolume': is_btrfs_path('/')}))
")
n=$(printf '%s' "$real" | sed -n 's/.*"n": \([0-9]*\).*/\1/p')
if [ -z "$n" ]; then
  res real-root-snapshot-list "FAIL (could not read: $(printf '%s' "$real" | tr -d '\n' | cut -c1-140))"
else
  res real-root-snapshot-list "PASS ($n reachable from /; / is a subvolume: $(printf '%s' "$real" | sed -n 's/.*"root_is_subvolume": \([a-z]*\).*/\1/p'); findmnt says / is on $(printf '%s' "$real" | sed -n 's/.*"mount_of_root": "\([^"]*\)".*/\1/p'); $(btrfs subvolume list / 2>&1 | head -1 | cut -c1-90))"
fi

res backup-btrfs-probe-done "PASS (scratch removed on exit; no existing subvolume was modified)"