#!/bin/bash
# slot-diff [--from=blue|green] [--to=blue|green] [--json=FILE]
#
# What changes for a machine when it moves from one slot to the other: the two
# read-only roots on disk compared directly (nothing is booted). By default
# --from is the current slot and --to the other one, i.e. after `upgrade`
# this is exactly what the next reboot will change.
#
# Adapted from shani-builder's pkg/checkpkg.sh, which compares one built
# package's file list and sonames against the previous version before it is
# published. The same two questions matter for a whole image, plus the ones
# only an image has:
#   packages   added / removed / version changes (each slot's own pacman db)
#   sonames    shared libraries that disappear (a removed .so breaks whatever
#              a user built or installed against it - Nix, AppImages, /opt)
#   units      systemd units added / removed, and units whose enablement in
#              the image (/usr/lib/systemd + /etc/systemd *.wants) changed
#   etc        default config files in the image's /etc that changed (on a
#              real machine /etc is an overlay, so a changed default can be
#              shadowed by an old user copy - these are the ones to look at)
#   kernel     kernel version(s)
# It is a report, not a gate: it always exits 0 unless the slots are missing.
cmd_slot_diff() {
  local from="" to="" json=""
  while (( $# )); do
    case "$1" in
      --from=*) from="${1#*=}" ;;
      --to=*)   to="${1#*=}" ;;
      --json=*) json="${1#*=}" ;;
      *) die "Usage: $(basename "$0") slot-diff [--from=blue|green] [--to=blue|green] [--json=FILE]" ;;
    esac
    shift
  done
  _mount_root
  [[ -n "$from" ]] || from=$(_current_slot)
  [[ -n "$to" ]] || { [[ "$from" == blue ]] && to=green || to=blue; }
  local A="$MNT/@${from}" B="$MNT/@${to}"
  [[ -d "$A/usr" && -d "$B/usr" ]] || die "slot-diff: @${from} or @${to} has no root filesystem"
  local T; T=$(mktemp -d)
  log "slot-diff: @${from} ($(cat "$A/etc/shani-version" 2>/dev/null || echo ?)) -> @${to} ($(cat "$B/etc/shani-version" 2>/dev/null || echo ?))"

  # packages: name version, from each slot's own db
  pacman --root "$A" --dbpath "$A/var/lib/pacman" -Q 2>/dev/null | sort > "$T/pa"
  pacman --root "$B" --dbpath "$B/var/lib/pacman" -Q 2>/dev/null | sort > "$T/pb"
  local added removed changed
  added=$(join -v2 "$T/pa" "$T/pb" | awk '{print $1" "$2}')
  removed=$(join -v1 "$T/pa" "$T/pb" | awk '{print $1" "$2}')
  changed=$(join "$T/pa" "$T/pb" | awk '$2 != $3 {print $1" "$2" -> "$3}')
  log "── packages: $(wc -l < "$T/pa") -> $(wc -l < "$T/pb"); +$(grep -c . <<<"$added") -$(grep -c . <<<"$removed") ~$(grep -c . <<<"$changed")"
  [[ -n "$added" ]]   && sed 's/^/  + /' <<<"$added"
  [[ -n "$removed" ]] && sed 's/^/  - /' <<<"$removed"
  [[ -n "$changed" ]] && sed 's/^/  ~ /' <<<"$changed" | head -200

  # sonames that disappear
  _sonames() { find "$1/usr/lib" -maxdepth 2 -name '*.so.*' \( -type f -o -type l \) -printf '%f\n' 2>/dev/null | sed -E 's/(\.so\.[0-9]+).*/\1/' | sort -u; }
  _sonames "$A" > "$T/sa"; _sonames "$B" > "$T/sb"
  local gone; gone=$(comm -23 "$T/sa" "$T/sb")
  log "── sonames: $(grep -c . <<<"$gone") disappear"
  [[ -n "$gone" ]] && sed 's/^/  - /' <<<"$gone"

  # units, and their enablement in the image
  _units() { find "$1/usr/lib/systemd/system" "$1/usr/lib/systemd/user" -maxdepth 1 \( -type f -o -type l \) -printf '%f\n' 2>/dev/null | sort -u; }
  _enabled() { find "$1/usr/lib/systemd" "$1/etc/systemd" -path '*.wants/*' -printf '%h %f\n' 2>/dev/null | sed -E 's|.*/([^/]+\.wants) | \1 |' | awk '{print $2" ("$1")"}' | sort -u; }
  _units "$A" > "$T/ua"; _units "$B" > "$T/ub"
  _enabled "$A" > "$T/ea"; _enabled "$B" > "$T/eb"
  log "── units: +$(comm -13 "$T/ua" "$T/ub" | grep -c .) -$(comm -23 "$T/ua" "$T/ub" | grep -c .); enablement +$(comm -13 "$T/ea" "$T/eb" | grep -c .) -$(comm -23 "$T/ea" "$T/eb" | grep -c .)"
  comm -13 "$T/ua" "$T/ub" | sed 's/^/  + unit /'
  comm -23 "$T/ua" "$T/ub" | sed 's/^/  - unit /'
  comm -13 "$T/ea" "$T/eb" | sed 's/^/  + enabled /'
  comm -23 "$T/ea" "$T/eb" | sed 's/^/  - enabled /'

  # default /etc files whose content changed
  local etc; etc=$( (cd "$A/etc" && find . -type f -print0 2>/dev/null) | while IFS= read -r -d '' f; do
      # if/fi, not a && chain: under set -e + pipefail a false last test made
      # the pipeline fail and this assignment exit slot-diff silently
      if [[ -f "$B/etc/$f" ]] && ! cmp -s "$A/etc/$f" "$B/etc/$f"; then echo "/etc/${f#./}"; fi; done | sort || true)
  log "── /etc defaults changed: $(grep -c . <<<"$etc")"
  [[ -n "$etc" ]] && sed 's/^/  ~ /' <<<"$etc" | head -100

  local ka kb
  ka=$(ls "$A/usr/lib/modules" 2>/dev/null | tr '\n' ' ' || true); kb=$(ls "$B/usr/lib/modules" 2>/dev/null | tr '\n' ' ' || true)
  log "── kernel: ${ka:-?}-> ${kb:-?}"

  if [[ -n "$json" ]]; then
    python3 - "$json" "$from" "$to" "$T" <<'PY'
import json, sys, os
out, a, b, t = sys.argv[1:]
r = lambda f: [l.rstrip("\n") for l in open(os.path.join(t, f)) if l.strip()]
pa = dict(l.split(" ", 1) for l in r("pa")); pb = dict(l.split(" ", 1) for l in r("pb"))
json.dump({"from": a, "to": b,
           "added": {k: pb[k] for k in pb.keys() - pa.keys()},
           "removed": {k: pa[k] for k in pa.keys() - pb.keys()},
           "changed": {k: [pa[k], pb[k]] for k in pa.keys() & pb.keys() if pa[k] != pb[k]},
           "sonames_gone": sorted(set(r("sa")) - set(r("sb"))),
           "units_added": sorted(set(r("ub")) - set(r("ua"))),
           "units_removed": sorted(set(r("ua")) - set(r("ub"))),
           "enabled_added": sorted(set(r("eb")) - set(r("ea"))),
           "enabled_removed": sorted(set(r("ea")) - set(r("eb")))},
          open(out, "w"), indent=2, sort_keys=True)
PY
    log "slot-diff: JSON report ${json}"
  fi
  rm -rf "$T"
}
