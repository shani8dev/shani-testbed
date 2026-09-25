#!/usr/bin/env bash
# tests/gate-flow.sh — the real cmd_gate (lib/gate.sh) under `set -Eeuo
# pipefail`, with every step command, the R2 pointers and the slots
# stubbed (a slot's /etc/shani-version is what identity reads; upgrade
# follows its --channel like shani-deploy: newer remote = deploy, older =
# "no update needed" without --force). Checks the phase order, that the
# image and the ISO get separate markers, that one failing does not
# withhold the other, and that a wrong build or --reuse-install never
# writes a marker.
#
#   tests/gate-flow.sh      (no root, no disks, no network)
set -Eeuo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }

# <name> <env: FAIL_ISO / FAIL_UPGRADE / LATEST_VER / FAIL_STEP> [gate args]
run() {
  local name="$1" envs="$2"; shift 2
  local tmp; tmp="$(mktemp -d)"
  OUT="$(env $envs DATA_DIR="$tmp" SCRIPT_DIR="$tmp" bash -c '
      set -Eeuo pipefail
      log()  { echo "[INFO] $*"; }; warn() { echo "[WARN] $*"; }; die() { echo "[ERROR] $*"; exit 1; }
      MNT="$DATA_DIR/mnt"; mkdir -p "$MNT/@blue/etc" "$MNT/@green/etc" "$MNT/@data" "$DATA_DIR/isovm"
      # source FIRST: gate.sh defines _gate_pointer/_gate_wait_net, and a stub
      # defined before it was silently replaced - the test then read the
      # LIVE latest.txt from R2 and passed only while it said 20260922
      source "'"$here"'/lib/gate.sh"
      _gate_pointer() { case $2 in latest) echo shanios-20260922-gnome.zst ;; stable) echo shanios-20260807-gnome.zst ;;
                                   iso-latest) echo 20260921 ;; iso-stable) echo 20260518 ;; esac; }
      _gate_wait_net() { :; }
      _current_slot() { cat "$MNT/@data/current-slot"; }
      ver() { cat "$MNT/@$1/etc/shani-version" 2>/dev/null || echo 0; }
      other() { [[ $1 == blue ]] && echo green || echo blue; }
      for s in ca clean verifyboot desktop; do eval "cmd_$s() { echo CALL $s \"\$*\"; }"; done
      cmd_slot_test() { echo CALL slot_test "$*"; [[ "${FAIL_STEP:-}" != slot_test ]] || return 3; }
      install_as() { echo blue > "$MNT/@data/current-slot"; echo "$1" > "$MNT/@blue/etc/shani-version"; rm -f "$MNT/@green/etc/shani-version"; }
      cmd_iso_install() { echo CALL iso_install "$*"
        if [[ "$*" == *--boot-only* ]]; then   # firmware boot: boots what current-slot names
          local want; want=$(grep -oP "(?<=--expect-slot=)[a-z]+" <<<"$*"); [[ "$(cat "$MNT/@data/current-slot")" == "$want" ]] || return 6; return 0; fi
        [[ -n "${FAIL_ISO:-}" && "$*" == *20260921* ]] && return 4; install_as "$(grep -oP "(?<=--iso=)[0-9]{8}" <<<"$*")"; }
      cmd_bootstrap()   { echo CALL bootstrap "$*"; install_as "$(grep -oE "[0-9]{8}" <<<"$*")"; }
      cmd_upgrade() {
        echo CALL upgrade "$*"
        [[ -n "${FAIL_UPGRADE:-}" && $(ver "$(_current_slot)") == 20260807 ]] && return 5
        local ch=latest force=1 a; for a in "$@"; do case $a in --channel=*) ch=${a#*=} ;; --no-force) force=0 ;; esac; done
        local remote; [[ $ch == latest ]] && remote=${LATEST_VER:-20260922} || remote=20260807
        local cur; cur=$(_current_slot)
        (( remote > $(ver "$cur") || force )) || { echo "no update needed"; return 0; }
        local o; o=$(other "$cur"); echo "$remote" > "$MNT/@$o/etc/shani-version"; echo "$o" > "$MNT/@data/current-slot"
      }
      cmd_rollback() { echo CALL rollback; other "$(_current_slot)" > "$MNT/@data/current-slot"; }
      cmd_gate -p gnome '"$*"'
    ' 2>&1)" && RC=0 || RC=$?
  IMG="$(cat "$tmp/gate-gnome.image.passed" 2>/dev/null || true)"
  ISO="$(cat "$tmp/gate-gnome.iso.passed" 2>/dev/null || true)"
  echo "--- $name (rc=$RC, image=${IMG:-none}, iso=${ISO:-none})"
  rm -rf "$tmp"
}
has() { grep -qF -- "$1" <<<"$OUT"; }

run all-pass ""
check "all-pass: exit 0"                         "[[ $RC -eq 0 ]]"
check "all-pass: image marker = candidate"       "[[ \$IMG == shanios-20260922-gnome.zst ]]"
check "all-pass: iso marker = ISO folder"        "[[ \$ISO == 20260921 ]]"
check "iso: installs the candidate ISO"          "has 'CALL iso_install -p gnome --iso=20260921'"
check "iso: first update = stable, no --force"   "has 'CALL upgrade --self-update --channel=stable --no-force'"
check "iso: older stable is not a downgrade"     "has 'no update needed' && has 'not newer than ISO 20260921'"
check "iso: launchers checked on ISO install"    "has 'CALL slot_test blue boot-health fresh-user launchers disk-layout'"
check "fresh: candidate on the ISO machine"      "has 'CALL upgrade --self-update --channel=latest --no-force'"
check "fresh: firmware boot of the updated slot" "has 'CALL iso_install -p gnome --iso=installed --boot-only --expect-slot=green'"
check "fresh: firmware boot after rollback"      "has 'CALL iso_install -p gnome --iso=installed --boot-only --expect-slot=blue'"
check "no firmware boot on the R2 install"       "[[ \$(grep -c 'boot-only' <<<\"\$OUT\") -eq 2 ]]"
check "upgrade: existing user from stable"       "has 'CALL bootstrap -p gnome -d 20260807 --from-r2'"
check "upgrade: no launchers on R2 install"      "has 'CALL slot_test green boot-health fresh-user disk-layout apparmor deploy-status'"
check "fresh: candidate checks apparmor + status" "has 'CALL slot_test green boot-health fresh-user launchers disk-layout apparmor deploy-status'"
check "iso: no candidate-only checks on stable"   "has 'CALL slot_test blue boot-health fresh-user launchers disk-layout' && ! grep 'CALL slot_test blue' <<<\"\$OUT\" | grep -q apparmor"
check "no --force anywhere in the gate"          "! grep 'CALL upgrade' <<<\"\$OUT\" | grep -qv -- '--no-force'"

run iso-broken "FAIL_ISO=1"
check "iso-broken: exit non-zero"                "[[ $RC -ne 0 ]]"
check "iso-broken: no iso marker"                "[[ -z \$ISO ]]"
check "iso-broken: image still promotable"       "[[ \$IMG == shanios-20260922-gnome.zst ]]"
check "iso-broken: new user via iso-stable"      "has 'CALL iso_install -p gnome --iso=20260518'"

run upgrade-broken "FAIL_UPGRADE=1"
check "upgrade-broken: no image marker"          "[[ -z \$IMG ]]"
check "upgrade-broken: ISO still promotable"     "[[ \$ISO == 20260921 ]]"

run wrong-build "LATEST_VER=20260923"
check "wrong-build: no image marker"             "[[ -z \$IMG && $RC -ne 0 ]]"

run slot-test-fails "FAIL_STEP=slot_test"
check "slot-test-fails: no markers at all"       "[[ -z \$IMG && -z \$ISO && $RC -ne 0 ]]"

run skip-iso "" --skip=iso
check "skip-iso: no iso marker, image tested"    "[[ -z \$ISO && \$IMG == shanios-20260922-gnome.zst ]]"

run for-image "" --for=image
check "for=image: image marker only"             "[[ \$IMG == shanios-20260922-gnome.zst && -z \$ISO && $RC -eq 0 ]]"
check "for=image: new user from iso-stable"      "has 'CALL iso_install -p gnome --iso=20260518 --disk-size=32000000000' && ! has 'CALL iso_install -p gnome --iso=20260921'"

run for-iso "" --for=iso
check "for=iso: ISO marker only"                 "[[ \$ISO == 20260921 && -z \$IMG && $RC -eq 0 ]]"
check "for=iso: no image journeys"               "! has 'channel=latest' && ! has 'CALL bootstrap'"

run for-iso-broken "FAIL_ISO=1" --for=iso
check "for=iso broken: fails, no marker"         "[[ -z \$ISO && $RC -ne 0 ]]"

run encrypted "" --encrypted
check "encrypted: ISO installs use LUKS"         "has 'CALL iso_install -p gnome --iso=20260921 --encrypted' && [[ \$ISO == 20260921 ]]"

run reuse "" --reuse-install
check "reuse: never writes markers"              "[[ -z \$IMG && -z \$ISO ]]"

OUT="$(DATA_DIR=/nonexistent bash -c 'set -Eeuo pipefail; log(){ :; }; warn(){ :; }; die(){ echo "$*"; exit 1; }
  source "'"$here"'/lib/gate.sh"
  _gate_pointer() { [[ $2 == latest ]] && echo shanios-20260922-gnome.zst; }
  cmd_gate -p gnome --candidate=shanios-20260915-gnome.zst' 2>&1)" || true
check "stale --candidate refused" "has 'is not what latest.txt names'"
echo
(( fails == 0 )) && echo "gate-flow: all checks passed" || { echo "gate-flow: $fails check(s) failed"; exit 1; }
