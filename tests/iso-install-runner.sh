#!/usr/bin/env bash
# tests/iso-install-runner.sh — the script iso-install runs inside the live
# ISO (_isovm_runner, lib/isoinstall.sh), executed for real in a throwaway
# Arch container with fake os-installer scripts that record what they got.
# Checks os-installer's contract (installation_scripting.py /
# envvar_creator.py): prepare -> install -> configure in order, as the wheel
# user, cwd /, in a pty, with ONLY that step's OSI_* variables (a value with
# a space intact), the target disk resolved from its virtio serial, and a
# failing step stopping the run.
#
#   tests/iso-install-runner.sh      (needs docker; no root, no disks)
set -Eeuo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log() { :; }; warn() { :; }; die() { echo "$*"; exit 1; }
# shellcheck source=../lib/isoinstall.sh
source "$here/lib/isoinstall.sh"
_isovm_runner plasma 0 > "$tmp/run.sh"
bash -n "$tmp/run.sh"

cat > "$tmp/fake.sh" <<'EOF'
#!/bin/bash
n=$(basename "$0" .sh)
{ echo "user=$(id -un)"; echo "cwd=$PWD"; echo "tty=$([ -t 0 ] && echo yes || echo no)"
  env | grep -vE '^(PWD|SHLVL|_|OLDPWD)=' | sort | sed 's/^/env:/'; } > "/tmp/rec/$n"
echo "$n" >> /tmp/rec/order
[ "$n" = install ] && [ -n "${FAIL_INSTALL:-}" ] && exit 7
exit 0
EOF

run_case() {  # <name> <extra-docker-env>
  docker run --rm -e "$2" -v "$tmp:/t:ro" archlinux:latest bash -c '
    set -e
    useradd -m -G wheel shani
    mkdir -p /etc/os-installer/scripts /tmp/osi /tmp/rec /dev/disk/by-id
    for s in prepare install configure; do cp /t/fake.sh /etc/os-installer/scripts/$s.sh; done
    chmod -R a+rx /etc/os-installer; chmod 1777 /tmp/rec
    ln -s /dev/null /dev/disk/by-id/virtio-shanitarget
    # env -i strips the variable, so the failing case is baked into the file
    if [ -n "${FAIL_INSTALL:-}" ]; then sed -i "1a FAIL_INSTALL=1" /etc/os-installer/scripts/install.sh; fi
    bash /t/run.sh >/dev/null 2>&1 || true
    cd /tmp/rec; for f in *; do [ -e "$f" ] || continue; echo "## $f"; cat "$f"; done
    echo "## rc"; cat /tmp/osi/*.rc 2>/dev/null | tr "\n" " "; echo
    echo "## finished"; [ -f /tmp/osi/finished ] && echo yes || echo no
  ' 2>&1
}

fails=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }
section() { awk -v s="## $2" '$0==s{f=1;next} /^## /{f=0} f' <<<"$1"; }

out=$(run_case ok X=1)
check "steps run in order"              "[[ \$(section \"\$out\" order | tr '\n' ' ') == 'prepare install configure ' ]]"
check "run as the wheel user"           "[[ \$(section \"\$out\" install | grep ^user=) == user=shani ]]"
check "cwd is /"                        "[[ \$(section \"\$out\" install | grep ^cwd=) == cwd=/ ]]"
check "a pty, like os-installer's Vte"  "[[ \$(section \"\$out\" configure | grep ^tty=) == tty=yes ]]"
check "prepare gets no OSI_ vars"       "! section \"\$out\" prepare | grep -q '^env:OSI_'"
check "install gets install vars only"  "section \"\$out\" install | grep -q '^env:OSI_DEVICE_PATH=/dev/null' && ! section \"\$out\" install | grep -q '^env:OSI_USER_'"
check "configure gets both sets"        "section \"\$out\" configure | grep -q '^env:OSI_USER_USERNAME=testuser' && section \"\$out\" configure | grep -q '^env:OSI_DEVICE_PATH=/dev/null'"
check "value with a space intact"       "section \"\$out\" configure | grep -qx 'env:OSI_USER_NAME=Test User'"
check "no other environment leaks in"   "! section \"\$out\" install | grep -vE '^env:(OSI_|PATH=)' | grep -q '^env:'"
check "all rc 0, finished"              "[[ \$(section \"\$out\" rc) == '0 0 0 ' && \$(section \"\$out\" finished) == yes ]]"

out=$(run_case fail FAIL_INSTALL=1)
check "failing install stops the run"   "[[ \$(section \"\$out\" order | tr '\n' ' ') == 'prepare install ' && \$(section \"\$out\" finished) == no ]]"
check "its rc is recorded"              "section \"\$out\" rc | grep -q 7"
echo
(( fails == 0 )) && echo "iso-install-runner: all checks passed" || { echo "iso-install-runner: $fails check(s) failed"; echo "$out" | head -40; exit 1; }
