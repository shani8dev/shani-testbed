#!/bin/bash
# slot-test-mode: boot
#
# disk-layout — the Btrfs top level holds only the installed layout: every
# entry is a subvolume named @... (or bees' .beeshome subvolume), nothing
# else (a deploy once created a stray top-level data/varlib/* tree on every
# run - it resolved /data/... against the top level instead of @data). And every bind source the slot's
# fstab names under /data exists in @data, so each bind mounts at boot.
# NEGATIVE control: a planted stray directory is reported.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
dev=/dev/disk/by-label/shani_root
m=$(mktemp -d)
mount -o ro,subvolid=5 "$dev" "$m" 2>/dev/null || { res toplevel-only-subvolumes "FAIL (cannot mount ${dev})"; exit 0; }

stray() {  # top-level entries that are not @-named subvolumes
  local e b
  for e in "$m"/* "$m"/.[!.]*; do
    [[ -e "$e" ]] || continue
    b=$(basename "$e")
    # .beeshome: bees' hash table, created as a subvolume at the filesystem
    # root by upstream beesd (ShaniOS sets no BEESHOME)
    [[ "$b" == @* || "$b" == .beeshome ]] && btrfs subvolume show "$e" >/dev/null 2>&1 && continue
    echo "$b"
  done
}
s=$(stray | tr '\n' ' ')
echo "== top level: $(ls -A "$m" | tr '\n' ' ')"
[[ -z "$s" ]] && res toplevel-only-subvolumes PASS || res toplevel-only-subvolumes "FAIL (not @-subvolumes: ${s})"

missing=()
while IFS= read -r src; do
  [[ -d "$m/@data/${src#/data/}" ]] || missing+=("$src")
done < <(awk '!/^[[:space:]]*#/ && $4 ~ /bind/ && $1 ~ /^\/data\// {print $1}' /etc/fstab | sort -u)
n=$(awk '!/^[[:space:]]*#/ && $4 ~ /bind/ && $1 ~ /^\/data\//' /etc/fstab | wc -l)
(( ${#missing[@]} == 0 )) && res fstab-bind-sources-in-data "PASS (${n} binds)" \
  || res fstab-bind-sources-in-data "FAIL (${#missing[@]}/${n} missing: ${missing[*]:0:5})"
umount "$m"

# NEGATIVE control: plant a stray directory, the same check must see it
mount -o subvolid=5 "$dev" "$m" && mkdir "$m/disk-layout-negctl" \
  && { [[ "$(stray)" == *disk-layout-negctl* ]] && res negative-control-detected PASS || res negative-control-detected FAIL; }
rmdir "$m/disk-layout-negctl" 2>/dev/null; umount "$m"; rmdir "$m"
echo "== probe done"
