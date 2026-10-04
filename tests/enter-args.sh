#!/bin/bash
# A check of the harness itself: cmd_enter's option parser (lib/boot.sh), with
# every slot-touching helper stubbed and systemd-nspawn replaced by a recorder on
# PATH. No root, no disks, no network, no slot.
#
# Why this exists: `enter`'s option loop is ALSO its command parser. Everything
# the loop does not recognise becomes the command to run, so a missing case does
# not report a bad flag - it reports the slot failing to exec it. That is
# exactly what happened with --local-pkg, which `app`, `probe`, `desktop` and
# `slot-test` all accepted and `enter` alone did not: the slot answered
# `exec: --`, which reads like a broken payload and sent the next person looking
# at the payload instead of at the flag. One missing case in one command is a
# five-minute mystery; the fix has to be the kind of thing that cannot come back.
#
# So the assertion is not "the flag is mentioned in lib/boot.sh" (a grep, which
# passes on a comment). It is what the loop LEAVES for the command, read back out
# of the real function: the pre-fix code leaves `--local-pkg=...` in that list,
# and this test goes red.
#
#   tests/enter-args.sh      (no root, no disks, no network)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL %s -- %s\n' "$1" "$2"; fail=$((fail + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$3], got [$2]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# systemd-nspawn is invoked with `exec`, which resolves an external command
# rather than a shell function, so the recorder is a real executable on PATH.
mkdir -p "$TMP/bin"
# It also reports the overlay env vars, because cmd_enter EXECs nspawn: anything
# after the call never runs in that shell, so the state can only be read from the
# process that was actually exec'd.
cat >"$TMP/bin/systemd-nspawn" <<'RECORDER'
#!/bin/bash
printf 'NSPAWN %s\n' "$*"
printf 'LOCAL_PKGS=%s\n' "${SHANIOS_TEST_LOCAL_PKGS:-unset}"
printf 'REPO_PKGS=%s\n' "${SHANIOS_TEST_REPO_PKGS:-unset}"
printf 'CHRONOA_SRC=%s\n' "${SHANIOS_TEST_CHRONOA_SRC:-unset}"
RECORDER
chmod 755 "$TMP/bin/systemd-nspawn"
export PATH="$TMP/bin:$PATH"

run_enter() {
  # Everything a slot-touching cmd_enter calls before it execs, stubbed.
  # _prepare_enter_args records what the option loop LEFT for the command, which
  # is the only thing this test needs to see.
  env -u SHANIOS_TEST_LOCAL_PKGS -u SHANIOS_TEST_REPO_PKGS -u SHANIOS_TEST_CHRONOA_SRC \
    bash -c '
      set -uo pipefail
      log()  { :; }
      warn() { echo "warn: $*" >&2; }
      die()  { echo "die: $*" >&2; exit 1; }
      _set_chronoa_src() { SHANIOS_TEST_CHRONOA_SRC="$1"; export SHANIOS_TEST_CHRONOA_SRC; }
      _ensure_host_machine_id() { :; }
      _ensure_dbus() { :; }
      _ensure_by_label_dir() { :; }
      _prepare_boot() { echo "BOOT $*"; }
      _prepare_enter_args() { echo "RESTCOUNT=$#"; echo "RESTARGS=${*:3}"; NSPAWN_ENTER_ARGS=(recorded); }
      NSPAWN_WORK=/tmp NSPAWN_ENTER_ARGS=() NSPAWN_FULL_BOOT_ARGS=()
      source "'"$ROOT"'/lib/boot.sh"
      cmd_enter "$@"
    ' enter-args "$@" 2>&1
}

# --- 1. the regression: every overlay flag is consumed, not exec'd ------------
OUT="$(run_enter blue --local-pkg=/tmp/a.pkg.tar.zst --repo-pkg=sox,soundtouch \
                  --local-src-chronoa=/opt/shani-chronoa /bin/true)"
check "the option loop leaves only the command" "$(grep '^RESTARGS=' <<<"$OUT")" "RESTARGS=/bin/true"
check "exactly one argument is left for the payload" "$(grep '^RESTCOUNT=' <<<"$OUT")" "RESTCOUNT=3"
check "--local-pkg becomes SHANIOS_TEST_LOCAL_PKGS" \
  "$(grep '^LOCAL_PKGS=' <<<"$OUT")" "LOCAL_PKGS=/tmp/a.pkg.tar.zst"
check "--repo-pkg becomes SHANIOS_TEST_REPO_PKGS" \
  "$(grep '^REPO_PKGS=' <<<"$OUT")" "REPO_PKGS=sox,soundtouch"
check "--local-src-chronoa becomes SHANIOS_TEST_CHRONOA_SRC" \
  "$(grep '^CHRONOA_SRC=' <<<"$OUT")" "CHRONOA_SRC=/opt/shani-chronoa"
if grep -q '^NSPAWN recorded$' <<<"$OUT"; then
  ok "the slot boot itself is reached (nspawn was exec'd, not the flag)"
else
  no "the slot boot itself is reached (nspawn was exec'd, not the flag)" "no NSPAWN line in: ${OUT//$'\n'/ | }"
fi

# --- 2. the same env vars _enter_prep reads, accumulated not overwritten ------
OUT="$(run_enter green --local-pkg=/tmp/a.pkg.tar.zst --local-pkg=/tmp/b.pkg.tar.zst \
                  --repo-pkg=sox --repo-pkg=rubberband /bin/true)"
check "two --local-pkg accumulate into one list" \
  "$(grep '^LOCAL_PKGS=' <<<"$OUT")" "LOCAL_PKGS=/tmp/a.pkg.tar.zst,/tmp/b.pkg.tar.zst"
check "two --repo-pkg accumulate into one list" \
  "$(grep '^REPO_PKGS=' <<<"$OUT")" "REPO_PKGS=sox,rubberband"

# --- 3. the flags still work with the other two, in any order ----------------
OUT="$(run_enter blue --repo-pkg=sox --local-src-chronoa=/opt/shani-chronoa --boot)"
# --boot takes the full-boot branch, so the loop's output is _prepare_boot's
# line: the flag was consumed, and the slot was prepared rather than exec'd.
check "--boot is still consumed, and takes the full-boot branch" \
  "$(grep '^BOOT ' <<<"$OUT" | sed 's/ *$//')" "BOOT blue"
check "--boot is not left for the payload as a command" \
  "$(grep -c '^NSPAWN recorded$' <<<"$OUT")" "0"
OUT="$(run_enter blue --local-src=/opt/shani-deploy/scripts --local-pkg=/tmp/a.pkg.tar.zst)"
# _prepare_enter_args supplies the default /bin/bash; the stub records what the
# loop left, which must be nothing at all.
check "with no command at all, the loop leaves the payload to the caller" \
  "$(grep '^RESTARGS=' <<<"$OUT")" "RESTARGS="

# --- 4. an UNRECOGNISED flag is the command, not silently swallowed -----------
# This is the behaviour the whole parser rests on, so it is asserted rather than
# assumed: a harness that quietly ignored an unknown flag would hide exactly the
# class of typo this test exists to catch.
OUT="$(run_enter blue --not-a-flag=1 /bin/true)"
check "an unknown option becomes the command (never swallowed)" \
  "$(grep '^RESTARGS=' <<<"$OUT")" "RESTARGS=--not-a-flag=1 /bin/true"

# --- 5. every slot-booting command parses the same overlay flags -------------
# The gap was never "enter is missing a feature", it was "enter disagrees with
# its four siblings". So the invariant is checked across the family, which fails
# the moment a flag is added to some of them.
missing=""
for pair in "cmd_enter:lib/boot.sh" "cmd_probe:lib/boot.sh" \
            "cmd_desktop:lib/boot.sh" "cmd_slot_test:lib/boot.sh" "cmd_app:lib/app.sh"; do
  fn="${pair%%:*}"; file="${pair#*:}"
  # Comment lines are dropped before the grep: this check exists precisely
  # because a flag named only in a prose comment (as --local-pkg was, while
  # explaining the bug it had just caused) must not count as support.
  body="$(awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\)" { inside=1 }
    inside && /^}/ { print buf; exit }
    inside && $0 !~ /^[[:space:]]*#/ { buf = buf $0 "\n" }
  ' "$ROOT/$file")"
  # A case PATTERN (`--local-pkg=*)`), not the flag's name: the usage string
  # lists every flag a command accepts, and one that only appears there is not
  # parsed at all.
  for flag in --local-src= --local-src-chronoa= --local-pkg= --repo-pkg=; do
    grep -qE -- "${flag}\*\)" <<<"$body" || missing+=" ${fn}${flag}"
  done
done
check "every slot-booting command parses all four overlay flags" "$missing" ""

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]