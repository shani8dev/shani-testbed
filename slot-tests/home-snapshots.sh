#!/bin/bash
# slot-test-mode: boot
#
# home-snapshots — `shani_backup.home` (daily snapshots of people's homes in
# /home/.snapshots, the idea of NAZY-OS/btrfs-home-user-snapshots) on a real
# btrfs, in the real image, driving the live checkout (/mnt/src/shani-backup).
#
# FIRST, THE MACHINE AS IT IS (read-only): /home is the @home subvolume (fstab),
# a home made by `useradd -m` is a plain folder inside it, setfacl is in the
# image, and - measured, by running the installed updatedb - that locate
# indexes / and the homes but not a `.snapshots` folder (else every file
# shows up in the launcher's file search once per snapshot).
#
# THEN THE CLAIMS, against a scratch copy of that layout - a subvolume standing
# in for @home, two plain-folder homes and one subvolume home
# (`useradd --btrfs-subvolume-home`), owned by throwaway accounts that are
# removed on exit - so the slot's real /home is never written:
#
#   1. `home daily` covers every home: one snapshot of the whole "home" for the
#      plain folders, and the subvolume home its own (a snapshot stops at a
#      nested subvolume, so the whole one has that home empty).
#   2. both are read-only; a second run the same day takes nothing.
#   3. nobody reads anybody else's files in them; each owner reads their own;
#      a subvolume home's snapshot folder is closed to everyone but its owner.
#   4. `list_for` gives each person paths that hold their own files.
#   5. retention keeps the newest N daily snapshots, and only daily ones.
#   6. a symlink planted at .snapshots is refused (negative control: the same
#      run with a real folder succeeds, so the refusal is about the link).
#   7. the CLI answers `home list --json` for a non-root person.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }

SRC=/mnt/src/shani-backup/src
[ -d "$SRC/shani_backup" ] && [ -f "$SRC/shani_backup/home.py" ] || { res home-repo-mounted "SKIP (no /mnt/src/shani-backup with home.py on this run)"; exit 0; }
res home-repo-mounted "PASS ($SRC)"
command -v btrfs >/dev/null || { res home-btrfs-present "SKIP (btrfs-progs not installed)"; exit 0; }

# ---- the machine as it is -------------------------------------------------------
btrfs subvolume show /home >/dev/null 2>&1 && res home-is-subvolume "PASS (/home is $(findmnt -no OPTIONS /home | grep -o 'subvol=[^,]*'))" \
    || res home-is-subvolume "FAIL (/home is not a btrfs subvolume: $(findmnt -no SOURCE,FSTYPE /home))"
plain=""; sub=""
for d in /home/*/; do d=${d%/}; [ -d "$d" ] || continue
  btrfs subvolume show "$d" >/dev/null 2>&1 && sub="$sub ${d##*/}" || plain="$plain ${d##*/}"; done
res home-real-homes "PASS (plain folders:${plain:- none}; subvolumes:${sub:- none})"
command -v setfacl >/dev/null && res home-setfacl-present PASS || res home-setfacl-present "FAIL (no setfacl: acl is not in the image)"

# ---- locate: the real mounts indexed, snapshot folders not -----------------------------
# updatedb exactly as the installed plocate-updatedb.service runs it (with any
# drop-in, e.g. shani-settings' --add-prunenames .snapshots), into a scratch db:
# a file under / and one in a home must be found (every ShaniOS mount is a
# subvol= mount, which updatedb can take for a bind mount), and a file in a
# .snapshots folder must not be - each snapshot would list every file again.
if command -v updatedb >/dev/null; then
  cmd=$(systemctl cat plocate-updatedb.service 2>/dev/null | sed -n 's/^ExecStart=\(.\+\)/\1/p' | tail -1)
  P=/root/home-snapshots-probe-$$; mkdir -p "$P/.snapshots/daily-x"; touch "$P/.snapshots/daily-x/needle-in-snapshot-$$"
  # a file of its own in /home (a fresh install has no homes yet), removed after
  PH=/home/home-snapshots-probe-$$; mkdir -p "$PH"; touch "$PH/needle-in-home-$$"
  db=/tmp/home-snapshots-$$.db
  eval "${cmd:-updatedb} -o $db" 2>/dev/null
  found="root:$(locate -d "$db" -c -r '^/usr/bin/bash$') home:$(locate -d "$db" -c "needle-in-home-$$") snapshot:$(locate -d "$db" -c "needle-in-snapshot-$$")"
  rm -rf "$P" "$PH" "$db"
  case "$found" in "root:1 home:1 snapshot:0") res locate-index "PASS ($found; ran: ${cmd:-updatedb})";;
    *) case "$cmd" in *prunenames*snapshots*) why="";; *) why="; this image predates shani-settings' plocate drop-in (51b3757) - rebuild to pick it up";; esac
       res locate-index "FAIL ($found; ran: ${cmd:-updatedb}$why)";; esac
else
  res locate-index "SKIP (no plocate in this image)"
fi

# ---- the scratch layout ------------------------------------------------------------
T=$(mktemp -d /tmp/home-snapshots.XXXXXX)
# mktemp makes it 0700 root: the throwaway accounts could not even reach
# their own homes inside it (the first run's privacy and CLI failures were
# this, not the code); /home itself is 0755
chmod 755 "$T"
SCRATCH="@home-snapshots-probe-$$"
U1=hsnapalice U2=hsnapbob U3=hsnapcarol
cleanup() {
  for u in $U1 $U2 $U3; do userdel "$u" >/dev/null 2>&1; done
  mountpoint -q "$T/root" 2>/dev/null && umount "$T/root"
  if [ -n "${SCRATCH_CREATED:-}" ]; then
    # everything made under the scratch subvolume (snapshots, the subvolume
    # home), deepest first, then the scratch itself - read-only ones delete too
    btrfs subvolume list "$T/toplevel" 2>/dev/null | awk '{print $NF}' | grep "^$SCRATCH/" | sort -r | while read -r p; do
      btrfs subvolume delete "$T/toplevel/$p" >/dev/null 2>&1; done
    btrfs subvolume delete "$T/toplevel/$SCRATCH" >/dev/null 2>&1
  fi
  mountpoint -q "$T/toplevel" 2>/dev/null && umount "$T/toplevel"
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/toplevel" "$T/root"
mount -o subvolid=5 /dev/disk/by-label/shani_root "$T/toplevel" 2>/dev/null || { res home-scratch "FAIL (subvolume 5 could not be mounted)"; exit 0; }
btrfs subvolume create "$T/toplevel/$SCRATCH" >/dev/null 2>&1 || { res home-scratch "FAIL (could not create $SCRATCH)"; exit 0; }
SCRATCH_CREATED=1
mount -o "subvol=$SCRATCH" /dev/disk/by-label/shani_root "$T/root" 2>/dev/null || { res home-scratch "FAIL (could not mount $SCRATCH)"; exit 0; }
H="$T/root"
chmod 755 "$H"
# the accounts own folders under the scratch "home"; their passwd home is the
# same path, so the module's /home/<name> is $H/<name>
# accounts a run before this one left (a slot boot's /etc persists): gone first
for u in $U1 $U2 $U3; do userdel "$u" >/dev/null 2>&1; groupdel "$u" >/dev/null 2>&1; done
err=$( { useradd -M -d "$H/$U1" -s /bin/sh $U1 && useradd -M -d "$H/$U3" -s /bin/sh $U3 && useradd -M -d "$H/$U2" -s /bin/sh $U2; } 2>&1 ) \
  || { res home-scratch "FAIL (useradd: $err)"; exit 0; }
mkdir -m 700 "$H/$U1" "$H/$U3"; btrfs subvolume create "$H/$U2" >/dev/null; chmod 700 "$H/$U2"
echo "alice-secret" > "$H/$U1/note.txt"; echo "bob-secret" > "$H/$U2/note.txt"; echo "carol" > "$H/$U3/note.txt"
for u in $U1 $U2 $U3; do chown -R "$u:$u" "$H/$u"; done
res home-scratch "PASS (scratch subvolume $SCRATCH: $U1, $U3 plain folders; $U2 a subvolume)"

export PYTHONPATH="$SRC" PYTHONDONTWRITEBYTECODE=1 SHANI_BACKUP_HOME="$H"
py() { python3 -c "$1" 2>&1; }
daily() { py "
import datetime as dt, json
from shani_backup import home
r = home.daily(keep=$1, now=dt.datetime($2, 10, 0))
print(json.dumps([[w, x.ok, x.detail] for w, x in r]))"; }

# ---- 1. daily covers every home -------------------------------------------------------
out=$(daily 14 "2026,10,29")
whole="$H/.snapshots/@home/daily-2026-10-29"; own="$H/.snapshots/$U2/daily-2026-10-29"
if [ -f "$whole/$U1/note.txt" ] && [ -f "$whole/$U3/note.txt" ] && [ -f "$own/note.txt" ] && [ -z "$(ls -A "$whole/$U2" 2>/dev/null)" ]; then
  res home-daily-covers-every-home "PASS (whole: $U1 $U3; own: $U2; $U2 empty in the whole one, as a nested subvolume is)"
else
  res home-daily-covers-every-home "FAIL ($out; whole has: $(ls "$whole" 2>&1 | tr '\n' ' '))"
fi

# ---- 2. read-only, once a day ----------------------------------------------------------
ro1=$(btrfs property get -ts "$whole" ro 2>&1); ro2=$(btrfs property get -ts "$own" ro 2>&1)
[ "$ro1" = ro=true ] && [ "$ro2" = ro=true ] && res home-snapshots-read-only PASS || res home-snapshots-read-only "FAIL (whole $ro1, own $ro2)"
n1=$(btrfs subvolume list "$H" | wc -l); out2=$(daily 14 "2026,10,29"); n2=$(btrfs subvolume list "$H" | wc -l)
[ "$n1" = "$n2" ] && printf '%s' "$out2" | grep -q 'already exists' && ! printf '%s' "$out2" | grep -q 'false' \
  && res home-daily-once-a-day "PASS ($n1 subvolumes before and after)" || res home-daily-once-a-day "FAIL ($n1 -> $n2: $out2)"

# ---- 3. privacy -------------------------------------------------------------------------
as() { su "$1" -s /bin/sh -c "$2" 2>&1; }
other=$(as $U3 "cat '$whole/$U1/note.txt'"); mine=$(as $U1 "cat '$whole/$U1/note.txt'")
bobdir=$(as $U3 "ls '$H/.snapshots/$U2'"); bobown=$(as $U2 "cat '$own/note.txt'")
if [ "$mine" = alice-secret ] && [ "$bobown" = bob-secret ] && ! printf '%s' "$other" | grep -q secret && ! printf '%s' "$bobdir" | grep -q daily; then
  res home-snapshots-private "PASS (owner reads own; $U3 on $U1's: ${other##*: }; on $U2's folder: ${bobdir##*: })"
else
  res home-snapshots-private "FAIL (mine=$mine bob=$bobown other=$other bobdir=$bobdir)"
fi

# ---- 4. list_for -----------------------------------------------------------------------
lst=$(py "
from shani_backup import home
import os
for u in ('$U1', '$U2'):
    s = home.list_for(u)
    print(u, len(s), all(os.path.isfile(os.path.join(x.path, 'note.txt')) for x in s))")
printf '%s' "$lst" | grep -q "$U1 1 True" && printf '%s' "$lst" | grep -q "$U2 1 True" \
  && res home-list-for-person "PASS ($(printf '%s' "$lst" | tr '\n' ';'))" || res home-list-for-person "FAIL ($lst)"

# ---- 5. retention -------------------------------------------------------------------------
py "
import datetime as dt
from shani_backup import home
home.snapshot_whole('manual', dt.datetime(2026, 10, 20, 9, 0))" >/dev/null
for d in 30 31; do daily 3 "2026,10,$d" >/dev/null; done
daily 3 "2026,11,1" >/dev/null
left=$(ls "$H/.snapshots/@home" | tr '\n' ' '); leftb=$(ls "$H/.snapshots/$U2" | tr '\n' ' ')
[ "$left" = "daily-2026-10-30 daily-2026-10-31 daily-2026-11-01 manual-2026-10-20_09-00-00 " ] && [ "$leftb" = "daily-2026-10-30 daily-2026-10-31 daily-2026-11-01 " ] \
  && res home-retention-keeps-newest "PASS (whole: $left| own: $leftb)" || res home-retention-keeps-newest "FAIL (whole: $left| own: $leftb)"

# ---- 6. a planted symlink is refused (and the control) ---------------------------------------
mv "$H/.snapshots" "$H/.snapshots-real"; mkdir "$T/elsewhere"; ln -s "$T/elsewhere" "$H/.snapshots"
bad=$(daily 3 "2026,11,2"); ls "$T/elsewhere" | grep -q . && planted=yes || planted=no
rm "$H/.snapshots"; mv "$H/.snapshots-real" "$H/.snapshots"
good=$(daily 3 "2026,11,2")
printf '%s' "$bad" | grep -q 'symbolic link' && [ $planted = no ] && ! printf '%s' "$good" | grep -q false \
  && res home-refuses-symlinked-root "PASS (refused through a link; the same run on the real folder succeeds)" \
  || res home-refuses-symlinked-root "FAIL (link: $bad; wrote through it: $planted; real: $good)"

# ---- 7. the CLI, as a person -----------------------------------------------------------------
cli=$(su $U1 -s /bin/sh -c "PYTHONPATH='$SRC' SHANI_BACKUP_HOME='$H' python3 -m shani_backup.cli home list --json" 2>&1)
printf '%s' "$cli" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['ok'] and d['user']=='$U1' and d['snapshots'] else 1)" 2>/dev/null \
  && res home-cli-list-as-person "PASS ($(printf '%s' "$cli" | cut -c1-120))" || res home-cli-list-as-person "FAIL ($cli)"
exit 0
