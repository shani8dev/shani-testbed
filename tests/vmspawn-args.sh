#!/bin/bash
# A check of the harness itself: cmd_vmspawn's overlay handling and its --commit
# flag (lib/vmspawn.sh), with docker and losetup replaced by recorders on PATH.
# No root, no disks, no VM, no network.
#
# Why this exists. vmspawn boots a qcow2 OVERLAY backed by the image and throws it
# away on exit, so the guest's writes never reach install.img. That is the right
# default — a boot must not scribble on the image — but it makes every question of
# the form "did this boot CHANGE the disk?" unanswerable *by omission*: the test
# reads the pre-boot state, which is indistinguishable from the boot having done
# nothing. That is not theoretical. A dracut boot-failover hook was investigated
# for a long stretch on the conclusion that its write to loader.conf was being
# lost, from three independent guest writes all missing from disk. The hook was
# fine; this overlay was discarding the evidence. The give-away is a guest that
# DELETES a file, reboots, and finds the file still there.
#
# --commit is the opt-in that makes those tests possible. Three ways it can be
# wrong, each asserted below rather than assumed:
#   * never called when asked for            -> the flag parses and does nothing
#   * called without the flag                -> a boot silently mutates the image
#   * called on a failed commit, unnoticed   -> a test believes it persisted
#                                             writes that were thrown away
#
# The assertions are about what the real function DID (recorded argv), not about
# what the source says: "qemu-img commit" appears in the usage comment too.
#
#   tests/vmspawn-args.sh     (no root, no disks, no network, no VM)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL %s -- %s\n' "$1" "$2"; fail=$((fail + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$3], got [$2]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/disk"

# The image the guest is nominally booting. Never mounted, never written: the
# commit is asserted from the argv the function built, not from bytes on disk.
IMG="$TMP/disk/install.img"
: > "$IMG"

# --- recorders -------------------------------------------------------------
# `docker` is an external command, so the recorder is a real executable on PATH
# (the same reasoning tests/enter-args.sh uses for systemd-nspawn).
cat >"$TMP/bin/docker" <<'RECORDER'
#!/bin/bash
# Records every invocation, answers the ones cmd_vmspawn branches on.
printf 'DOCKER %s\n' "$*" >> "$REC"
case "${1:-}" in
  run) exit 0 ;;                       # -d --name ... (container up)
  rm)  exit 0 ;;                       # the EXIT trap
  exec)
    shift 2                            # drop `exec <container>`
    case "${1:-}" in
      systemctl)  echo running; exit 0 ;;            # the container-is-up probe
      pacman)     exit 0 ;;                           # qemu-base edk2-ovmf swtpm openssh
      pkill)      exit 0 ;;                           # tearing qemu down
      qemu-img)
        case "${2:-}" in
          # Last field is the overlay path in both create and commit.
          create) printf 'CREATE %s\n' "${*: -1}" >> "$REC"; exit 0 ;;
          commit) printf 'COMMIT %s\n' "${*: -1}"  >> "$REC"
                  exit "${SHANIOS_TEST_COMMIT_RC:-0}" ;;
        esac ;;
      systemd-vmspawn)
        # Matches cmd_vmspawn's default --until ('login:'), then lingers so the
        # poll loop greps the console log before the pipeline can be reaped.
        echo "Welcome to Shanios login:"; sleep 6; exit 0 ;;
    esac ;;
esac
exit 0
RECORDER
chmod 755 "$TMP/bin/docker"

# losetup -j must report "not loop-attached", or cmd_vmspawn refuses up front.
cat >"$TMP/bin/losetup" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod 755 "$TMP/bin/losetup"

export PATH="$TMP/bin:$PATH"

run_vmspawn() {
  # Everything cmd_vmspawn needs from the harness core, stubbed. Only log,
  # warn and _in_container are called by name; the rest is configuration.
  REC="$TMP/rec" bash -c '
    set -uo pipefail
    log()   { echo "LOG: $*"; }
    warn()  { echo "WARN: $*" >&2; }
    _in_container() { return 1; }        # host-only command
    _vmspawn_die() { printf "[vmspawn][ERROR] %s\n" "$*" >&2; exit 2; }
    INSTALL_IMG="'"$IMG"'"
    DATA_DIR="'"$TMP"'/disk"
    REPO_ROOT="'"$TMP"'"
    SHANIOS_TEST_BUILDER_IMAGE=builder:test
    source "'"$ROOT"'/lib/vmspawn.sh"
    cmd_vmspawn "$@"
  ' vmspawn "$@" 2>&1
  printf 'RC=%s\n' "$?"
}

# --- 1. the DEFAULT: the overlay is discarded, and never committed ----------
OUT="$(run_vmspawn --image="$IMG" --timeout=60)"
check "default run commits nothing" "$(grep -c '^COMMIT ' "$TMP/rec" 2>/dev/null || true)" "0"
check "default run created an overlay" "$(grep -c '^CREATE ' "$TMP/rec" 2>/dev/null || true)" "1"
if grep -q 'guest writes discarded' <<<"$OUT"; then
  ok "default run says the writes were discarded"
else
  no "default run says the writes were discarded" "not stated in: ${OUT//$'\n'/ | }"
fi

# --- 2. --commit: the overlay created is the overlay committed --------------
OUT="$(run_vmspawn --image="$IMG" --timeout=60 --commit)"
check "--commit commits exactly once" "$(grep -c '^COMMIT ' "$TMP/rec" 2>/dev/null || true)" "1"
CREATED="$(grep '^CREATE ' "$TMP/rec" 2>/dev/null | awk '{print $NF}' | tail -1)"
COMMITTED="$(grep '^COMMIT ' "$TMP/rec" 2>/dev/null | awk '{print $NF}' | tail -1)"
# The two paths being equal is the assertion that matters: committing some other
# file would still print a success line and still persist nothing.
check "--commit commits the overlay it created" "$COMMITTED" "$CREATED"
if grep -q 'committed the guest' <<<"$OUT"; then
  ok "--commit reports the commit"
else
  no "--commit reports the commit" "not stated in: ${OUT//$'\n'/ | }"
fi

# --- 3. NEGATIVE CONTROL: a commit that fails must not read as success -------
# If the `|| _vmspawn_die` were dropped, this would exit 0 and print a success
# line, and every write test relying on it would believe it had persisted writes
# that were thrown away. A test that cannot fail is not a check.
OUT="$(SHANIOS_TEST_COMMIT_RC=1 run_vmspawn --image="$IMG" --timeout=60 --commit)"
check "a failed commit exits non-zero" "$(grep -c '^RC=2$' <<<"$OUT")" "1"
if grep -q 'qemu-img commit failed' <<<"$OUT"; then
  ok "a failed commit says so"
else
  no "a failed commit says so" "not stated in: ${OUT//$'\n'/ | }"
fi
if grep -q 'committed the guest' <<<"$OUT"; then
  no "a failed commit must NOT report success" "it reported a commit"
else
  ok "a failed commit must NOT report success"
fi

# --- 4. --commit is a real flag, not a usage rejection ----------------------
# Both a usage error and a commit failure exit 2, so the message is the only
# thing that tells them apart. Asserting rc alone would pass either way.
OUT="$(run_vmspawn --image="$IMG" --timeout=60 --commit)"
check "--commit is accepted, not refused as usage" "$(grep -c '^RC=2$' <<<"$OUT")" "0"

# --- 5. the backing file must be writable when --commit is asked for --------
# qemu-img commit writes to the overlay's BACKING file, which is the bind-mounted
# source image. If that mount is :ro the commit cannot succeed - and the run
# reports it as "the image is unchanged", which is true and useless.
# Measured in the builder image against a real read-only bind: `commit` exits 1
# with the guest's write absent from the base image, and `-U` does not help (it
# bypasses image locks, not filesystem permissions).
# $rec accumulates across every run, so each of these starts from empty.
: > "$TMP/rec"
OUT="$(run_vmspawn --image="$IMG" --timeout=60 --commit)"
check "--commit bind-mounts the source writable" "$(grep -c '/src:ro' "$TMP/rec" 2>/dev/null || true)" "0"
check "--commit bind-mounts the source explicitly rw" "$(grep -c '/src:rw' "$TMP/rec" 2>/dev/null || true)" "1"

# `commit` needs NO flags to write into the backing file - that is what it is for.
# `-r` is --rate-limit, and it made the whole flag fail on its first real use
# ("Invalid rate limit specified: '-f'"), which an earlier version of this file
# asserted the presence of. Assert the absence, so it cannot come back.
check "--commit's commit carries no rate-limit/format flags" \
  "$(grep -cE 'qemu-img commit -|qemu-img commit .* -r|qemu-img commit -r' "$TMP/rec" 2>/dev/null || true)" "0"
check "--commit's commit is the plain commit form" \
  "$(grep -c 'COMMIT ' "$TMP/rec" 2>/dev/null || true)" "1"

# ...and the default keeps that mount read-only, so a boot that is NOT asked to
# persist cannot touch the image even if something else in the guest tries to.
: > "$TMP/rec"
OUT="$(run_vmspawn --image="$IMG" --timeout=60)"
check "without --commit the source stays mounted read-only" \
  "$(grep -c '/src:ro' "$TMP/rec" 2>/dev/null || true)" "1"

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]