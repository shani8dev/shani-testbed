# lib/isoinstall.sh — `iso-install`: install from a real ISO the way a user
# does, then boot the result through firmware.
#
#   iso-install -p <profile> --iso=<iso-latest|iso-stable|YYYYMMDD|file.iso>
#               [--encrypted] [--live-timeout=S] [--install-timeout=S]
#               [--boot-timeout=S] [--boot-only] [--disk-size=BYTES]
#
# --boot-only: skip 1-2 and boot the disk the last iso-install installed,
# with its NVRAM and TPM state (debugging the firmware boot without a
# 20+ min reinstall under TCG).
#
# 1. The ISO boots under OVMF (UEFI) with a software TPM and disk/install.img
#    as a blank virtio disk: firmware, the ISO's bootloader, its kernel and
#    initramfs, the archiso live root - nothing faked.
# 2. In the live session, through the ISO's own qemu-guest-agent, the
#    installer runs exactly as os-installer runs it (read from its source,
#    installation_scripting.py / envvar_creator.py): `/bin/bash
#    /etc/os-installer/scripts/<step>.sh` for prepare, install, configure;
#    as the live user (`shani`, wheel); in a pty; cwd /; an environment of
#    ONLY that step's OSI_* variables. So the ISO's own scripts, tools and
#    kernel do the install - not the builder container's.
# 3. The installed disk boots under the same firmware NVRAM and TPM (the
#    boot entries configure.sh wrote are what OVMF finds): systemd-boot ->
#    the signed UKI -> userspace. Its serial console goes to disk/ via
#    systemd-stub's SMBIOS kernel-cmdline-extra (console=ttyS0 only).
#
# What is NOT clicked: the os-installer GUI pages themselves (they only
# collect the OSI_* values). Secure Boot stays off: shim/MOK enrollment
# needs MokManager at the console.
#
# install.img is left in place, so enter/verify-boot/slot-test/upgrade/
# rollback continue on the firmware-installed disk (`gate` does).

ISOVM_DIR_NAME="isovm"

_isovm_tools() {
  local missing=()
  command -v qemu-system-x86_64 >/dev/null || missing+=(qemu-base)
  command -v swtpm >/dev/null || missing+=(swtpm)
  [[ -f /usr/share/edk2/x64/OVMF_CODE.4m.fd || -f /usr/share/edk2/x64/OVMF_CODE.fd ]] || missing+=(edk2-ovmf)
  command -v python3 >/dev/null || missing+=(python)
  (( ${#missing[@]} )) || return 0
  log "iso-install: installing ${missing[*]} into the builder container (pacman cache is persistent)"
  local try
  for try in 1 2 3; do
    pacman -Sy --needed --noconfirm "${missing[@]}" && return 0
    warn "pacman failed (try ${try}/3)"; sleep 20
  done
  die "iso-install: could not install ${missing[*]}"
}

_isovm_ovmf() {
  local d=/usr/share/edk2/x64
  if [[ -f $d/OVMF_CODE.4m.fd ]]; then ISOVM_CODE=$d/OVMF_CODE.4m.fd; ISOVM_VARS_TEMPLATE=$d/OVMF_VARS.4m.fd
  else ISOVM_CODE=$d/OVMF_CODE.fd; ISOVM_VARS_TEMPLATE=$d/OVMF_VARS.fd; fi
}

_isovm_qga() {  # <cmd> [timeout] — run as root in the guest, print output, return its rc
  python3 "${LIB_DIR}/qmp_client.py" qga-exec "${ISOVM}/qga.sock" "$1" "${2:-60}"
}

_isovm_qmp() {  # <qmp-command> — fire and forget
  python3 - "${ISOVM}/qmp.sock" "$1" <<'PY' 2>/dev/null || true
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
f = s.makefile("rw")
f.readline()
for cmd in ("qmp_capabilities", sys.argv[2]):
    f.write(json.dumps({"execute": cmd}) + "\n"); f.flush(); f.readline()
PY
}

# <label> <console-log> <boot-from: iso|disk> — starts swtpm + qemu in the
# background; sets ISOVM_PID / ISOVM_TPM_PID.
_isovm_start() {
  local label="$1" console="$2" from="$3"
  rm -f "${ISOVM}"/{qga,qmp,swtpm,serial}.sock
  swtpm socket --tpm2 --tpmstate "dir=${ISOVM}/tpm" \
    --ctrl "type=unixio,path=${ISOVM}/swtpm.sock" --log "file=${ISOVM}/swtpm.log" &
  ISOVM_TPM_PID=$!
  local i; for (( i=0; i<50; i++ )); do [[ -S "${ISOVM}/swtpm.sock" ]] && break; sleep 0.2; done
  local -a accel=(-accel tcg) media=() dbg=()
  [[ -w /dev/kvm ]] && accel=(-accel kvm -cpu host)
  if [[ "$from" == iso ]]; then
    media=(-drive "file=${ISO_FILE},if=none,id=cd,media=cdrom,readonly=on" -device ide-cd,drive=cd,bus=ide.0,bootindex=1)
  else
    # systemd-stub appends this SMBIOS string to the UKI's command line
    # (Secure Boot is off): the only change to the booted system - console
    # output only. loglevel=6 undoes `quiet` for notices, so the kernel's
    # "Command line:" (which slot booted) reaches the console.
    # (",," is qemu's escape for a literal comma inside an option value)
    local extra="console=ttyS0,,115200 loglevel=6"
    # --console-exec: a root shell (systemd's own debug shell) on a virtio
    # console, /dev/hvc0 - no login, nothing changed on the installed
    # system; only on such boots, so a normal boot stays what a user boots.
    # Not a second serial port: OVMF takes that as another console and the
    # boot menu stopped counting down (the machine never booted).
    if [[ -n "${ISOVM_CONSOLE_EXEC:-}" ]]; then
      extra+=" systemd.debug_shell=/dev/hvc0"
      : > "${ISOVM}/debug-console.log"
      dbg=(-chardev "socket,id=dbg0,path=${ISOVM}/debug.sock,server=on,wait=off,logfile=${ISOVM}/debug-console.log"
           -device virtconsole,chardev=dbg0)  # after -device virtio-serial below
    fi
    media+=(-smbios "type=11,value=io.systemd.stub.kernel-cmdline-extra=${extra}")
  fi
  : > "$console"
  log "iso-install: ${label} ($([[ ${accel[1]} == kvm ]] && echo KVM || echo 'TCG, slow'); console ${console})"
  qemu-system-x86_64 -name "shanios-${label}" -machine q35 -smp 4 -m "${QEMU_MEM:-4096}" "${accel[@]}" \
    -drive "if=pflash,format=raw,readonly=on,file=${ISOVM_CODE}" \
    -drive "if=pflash,format=raw,file=${ISOVM}/OVMF_VARS.fd" \
    -chardev "socket,id=chrtpm,path=${ISOVM}/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
    -drive "file=${INSTALL_IMG},if=none,id=target,format=raw" -device "virtio-blk-pci,drive=target,serial=shanitarget,bootindex=2" \
    "${media[@]}" \
    -chardev "socket,path=${ISOVM}/qga.sock,server=on,wait=off,id=qga0" \
    -device virtio-serial -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    "${dbg[@]}" \
    -qmp "unix:${ISOVM}/qmp.sock,server=on,wait=off" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -chardev "socket,id=ser0,path=${ISOVM}/serial.sock,server=on,wait=off,logfile=${console}" -serial chardev:ser0 \
    -vga std -display none -monitor none \
    >"${ISOVM}/qemu-${label}.log" 2>&1 &
  ISOVM_PID=$!
}

# Graceful: ACPI power button, then up to 180s, then quit.
_isovm_stop() {
  local i
  if kill -0 "$ISOVM_PID" 2>/dev/null; then
    _isovm_qmp system_powerdown
    for (( i=0; i<180; i++ )); do kill -0 "$ISOVM_PID" 2>/dev/null || break; sleep 1; done
    if kill -0 "$ISOVM_PID" 2>/dev/null; then
      warn "iso-install: guest did not power off in 180s - quitting qemu"
      _isovm_qmp quit; sleep 3; kill "$ISOVM_PID" 2>/dev/null || true
    fi
  fi
  wait "$ISOVM_PID" 2>/dev/null || true
  kill "$ISOVM_TPM_PID" 2>/dev/null || true; wait "$ISOVM_TPM_PID" 2>/dev/null || true
}

# The script run inside the live session: os-installer's invocation of
# prepare/install/configure (see the header). <profile> <encrypted 0|1>
_isovm_runner() {
  local profile="$1" encrypted="$2"
  local pin="${SHANIOS_TEST_LUKS_PIN:-shanios-test-passphrase}"
  local -a inst_env=(
    "OSI_DESKTOP=${profile}" "OSI_LOCALE=${SHANIOS_TEST_OSI_LOCALE:-en_US.UTF-8}"
    "OSI_KEYBOARD_LAYOUT=${SHANIOS_TEST_OSI_KEYBOARD:-us}" "OSI_DEVICE_PATH=@DEV@"
    "OSI_DEVICE_IS_PARTITION=0" "OSI_DEVICE_EFI_PARTITION=" "OSI_USE_ENCRYPTION=${encrypted}"
    "OSI_ENCRYPTION_PIN=$( (( encrypted )) && echo "$pin")"
  )
  local -a conf_env=(
    "OSI_USER_NAME=${SHANIOS_TEST_OSI_USER_NAME:-Test User}" "OSI_USER_USERNAME=${SHANIOS_TEST_OSI_USERNAME:-testuser}"
    "OSI_USER_AUTOLOGIN=${SHANIOS_TEST_OSI_AUTOLOGIN:-0}" "OSI_USER_PASSWORD=${SHANIOS_TEST_OSI_USER_PASSWORD:-testpass123}"
    "OSI_ROOT_PASSWORD=${SHANIOS_TEST_OSI_ROOT_PASSWORD:-}" "OSI_FORMATS=${SHANIOS_TEST_OSI_FORMATS:-en_US.UTF-8}"
    "OSI_TIMEZONE=${SHANIOS_TEST_OSI_TIMEZONE:-UTC}" "OSI_ADDITIONAL_SOFTWARE=" "OSI_ADDITIONAL_FEATURES="
  )
  local q_inst q_conf
  q_inst=$(printf '%q ' "${inst_env[@]}"); q_conf=$(printf '%q ' "${conf_env[@]}")
  q_inst=${q_inst//@DEV@/'$dev'}   # expanded in the guest
  # Runs detached in the guest (a guest-exec must not outlive its timeout).
  # Progress also goes to the serial console, so the host log shows it live.
  cat <<EOF
set -u
dev=\$(readlink -f /dev/disk/by-id/virtio-shanitarget) || { echo "no target disk" > /tmp/osi/fatal; exit 1; }
user=\$(getent group wheel | cut -d: -f4 | cut -d, -f1); user=\${user:-shani}
cd /
step() {  # <name> <env...>
  local n=\$1; shift
  echo "OSI-STEP \$n start (dev=\$dev user=\$user)" | tee /dev/ttyS0
  local q=""; (( \$# )) && q=\$(printf '%q ' "\$@")   # prepare gets none
  script -qefc "runuser -u \$user -- env -i \$q /bin/bash /etc/os-installer/scripts/\$n.sh" /tmp/osi/\$n.log >/dev/null 2>&1
  local rc=\$?
  echo \$rc > /tmp/osi/\$n.rc
  echo "OSI-STEP \$n rc=\$rc" | tee /dev/ttyS0
  return \$rc
}
# "finished" only after all three succeeded: the host treats it as success
step prepare && step install ${q_inst} && step configure ${q_inst} ${q_conf} \\
  && echo done > /tmp/osi/finished
EOF
}

# Boot disk/install.img under the firmware NVRAM + TPM iso-install left
# (the boot entries configure.sh wrote are what OVMF finds). <timeout>
# Types into the serial console (a user at the keyboard): <text>
_isovm_type() {  # <text> [socket]
  python3 - "${2:-${ISOVM}/serial.sock}" "$1" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
# one key at a time: plymouth's serial prompt took 2 of a burst-written
# passphrase ("*", "**") and dropped the rest, then waited forever
for ch in sys.argv[2].encode() + b"\r":
    s.sendall(bytes([ch])); time.sleep(0.15)
s.close()
PY
}

# Types a file's lines into a logged-in shell (a shell reads bursts fine -
# only plymouth's prompt needed one key at a time). <file>
_isovm_type_lines() {  # <file> [socket]
  python3 - "${2:-${ISOVM}/serial.sock}" "$1" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sys.argv[1])
for line in open(sys.argv[2], "rb"):
    s.sendall(line.rstrip(b"\n") + b"\r"); time.sleep(0.02)
s.close()
PY
}

# What the console showed since <offset> (the last 20 lines): why a step stalled
_isovm_console_tail() {  # <log> <offset>
  log "iso-install: console since the last step:"
  tail -c +"$(( $2 + 1 ))" "$1" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r//g' | grep -av -e '^\s*$' -e '\$\$\$' -e '[.:`]\s*[,.:;\$()]\{4\}' | tail -25 | cut -c1-160 | sed 's/^/  > /' || true
}

# Wait until <regex> appears in <log> after byte <offset>; <timeout> s.
_isovm_wait_log() {  # <log> <offset> <regex> <timeout>
  local t0; t0=$(date +%s)
  until tail -c +"$(( $2 + 1 ))" "$1" 2>/dev/null | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -aqE "$3"; do
    (( $(date +%s) - t0 < $4 )) || return 1
    kill -0 "$ISOVM_PID" 2>/dev/null || return 1
    sleep 2
  done
}

# --console-exec: run <cmd> as root in systemd's debug shell on hvc0 (see
# _isovm_start) - the real firmware-booted system, TPM and all, without a
# login (the ISO installer creates no user: skip_user). Prints the output;
# returns the command's exit status.
_isovm_console_exec() {  # <boot log (unused)> <cmd> <timeout>
  local log="${ISOVM}/debug-console.log" sock="${ISOVM}/debug.sock" cmd="$2" to="$3" off b64 rc
  off=0
  # the debug shell starts with the boot; wait until it really runs commands
  local i
  for (( i=0; i<30; i++ )); do
    _isovm_type 'echo CE_SHELL_$((6*7))' "$sock" 2>/dev/null || true
    _isovm_wait_log "$log" "$off" 'CE_SHELL_42' 10 && break
  done
  (( i < 30 )) || { _isovm_console_tail "$log" 0; warn "console-exec: no debug shell on hvc0"; return 92; }
  # --console-put LOCAL:REMOTE: base64 lines through a heredoc (each line
  # far below the tty's 4096-byte canonical limit)
  local put src dst tmpb
  for put in ${ISOVM_CONSOLE_PUT:-}; do
    src=${put%%:*}; dst=${put#*:}
    [[ -f "$src" ]] || { warn "console-put: no ${src}"; return 95; }
    tmpb=$(mktemp); { echo "base64 -d > '${dst}' <<'__CE_B64__'"; base64 -w76 "$src"; echo "__CE_B64__"; } > "$tmpb"
    off=$(stat -c %s "$log")
    _isovm_type_lines "$tmpb" "$sock"; rm -f "$tmpb"
    _isovm_type "sha256sum '${dst}' | cut -c1-16; echo CE_PUT_DONE" "$sock"
    _isovm_wait_log "$log" "$off" '^CE_PUT_DONE' 300 || { _isovm_console_tail "$log" "$off"; warn "console-put: ${dst} did not arrive"; return 96; }
    log "iso-install: console-put ${src##*/} -> ${dst} (sha256 here $(sha256sum "$src" | cut -c1-16))"
  done
  # base64: no quoting of <cmd> on a typed command line; the marker is only
  # produced by the shell expanding $? - the echoed typed line shows it raw
  b64=$(printf '%s' "$cmd" | base64 -w0)
  off=$(stat -c %s "$log")
  _isovm_type "echo $b64 | base64 -d > /tmp/ce.sh; bash /tmp/ce.sh 2>&1; echo CE_RC=\$?_END" "$sock"
  _isovm_wait_log "$log" "$off" 'CE_RC=[0-9]+_END' "$to" || { _isovm_console_tail "$log" "$off"; warn "console-exec: no result in ${to}s"; return 93; }
  rc=$(tail -c +"$(( off + 1 ))" "$log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -aoE 'CE_RC=[0-9]+_END' | tail -1 | tr -cd '0-9')
  log "iso-install: console-exec output (rc=${rc}):"
  tail -c +"$(( off + 1 ))" "$log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r//g' \
    | grep -av -e 'base64 -d > /tmp/ce.sh' -e 'CE_RC=' | sed 's/^/  $ /' || true
  return "${rc:-94}"
}

_isovm_boot_installed() {  # <timeout> [expected slot]
  local boot_to="$1" expect="${2:-}" boot_log="${DATA_DIR}/iso-install-boot-console.log"
  local until_re='login:|Reached target .*(Graphical Interface|Multi-User System)'
  local fail_re='Kernel panic|emergency mode|Failed to mount /sysroot|dracut-initqueue.*timeout|You are in rescue mode'
  local pin="" typed=0
  [[ -f "${ISOVM}/luks-pin" ]] && pin=$(cat "${ISOVM}/luks-pin")
  _isovm_start installed "$boot_log" disk
  t0=$(date +%s)
  local result=""
  while :; do
    # an encrypted install asks for the LUKS passphrase on the console
    # (TPM2 auto-unlock is only enrolled later, gen-efi enroll-tpm2)
    if [[ -n "$pin" ]] && (( typed < 3 )) \
       && (( $(grep -acE 'Please enter passphrase|Enter passphrase for' "$boot_log") > typed )); then
      typed=$((typed + 1)); log "iso-install: LUKS passphrase prompt - typing the test passphrase (${typed})"
      _isovm_type "$pin" || warn "iso-install: could not type into the serial console"
    fi
    grep -aqE "$fail_re" "$boot_log" && { result="FAIL: $(grep -aoE "$fail_re" "$boot_log" | head -1)"; break; }
    grep -aqE "$until_re" "$boot_log" && { result="OK: $(grep -aoE "$until_re" "$boot_log" | head -1)"; break; }
    kill -0 "$ISOVM_PID" 2>/dev/null || { result="FAIL: qemu exited: $(tail -3 "${ISOVM}/qemu-installed.log" | tr '\n' ' ')"; break; }
    (( $(date +%s) - t0 < boot_to )) || { result="FAIL: no login/target after ${boot_to}s"; break; }
    sleep 5
  done
  # which slot really booted: systemd-boot picked a UKI whose command line
  # names it (rootflags=subvol=@<slot>), echoed by the kernel on the console
  # as "Kernel command line:" (lower-case c)
  # (|| true: no match must not end the run under pipefail before the
  # result is logged - it did, silently, on every failed boot)
  ISOVM_BOOTED_SLOT=$(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$boot_log" | grep -aoiE 'command line:.*' | grep -oE 'subvol=@(blue|green)' | head -1 | sed 's/.*@//' || true)
  if [[ -z "$ISOVM_BOOTED_SLOT" ]]; then
    log "iso-install: no subvol=@blue|@green in the kernel command line: $(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$boot_log" | grep -aoiE 'command line:.*' | head -1 | cut -c1-400 || true)"
  fi
  if [[ "$result" == OK:* && -n "${ISOVM_EXPECT_TPM_UNLOCK:-}" ]] && (( typed > 0 )); then
    result="FAIL: asked for the LUKS passphrase - TPM2 automatic unlock did not happen"
  fi
  if [[ "$result" == OK:* && -n "$expect" && "$ISOVM_BOOTED_SLOT" != "$expect" ]]; then
    result="FAIL: firmware booted @${ISOVM_BOOTED_SLOT:-?}, expected @${expect}"
  fi
  log "iso-install: installed-disk boot ${result} ($(( $(date +%s) - t0 ))s, @${ISOVM_BOOTED_SLOT:-?})"
  ISOVM_CONSOLE_RC=0
  if [[ "$result" == OK:* && -n "${ISOVM_CONSOLE_EXEC:-}" ]]; then
    _isovm_console_exec "$boot_log" "$ISOVM_CONSOLE_EXEC" "${ISOVM_CONSOLE_TIMEOUT:-600}" || ISOVM_CONSOLE_RC=$?
  fi
  sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$boot_log" | grep -aE 'Linux version|systemd-boot|shanios|tpm|TPM|Reached target|login:|FAILED|emergency' \
    | cut -c1-140 | tail -10 | sed 's/^/  | /' || true
  if [[ "$result" != OK:* ]]; then  # the filter above misses a hang: show where it stopped
    log "iso-install: last console lines:"
    sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r//g' "$boot_log" | grep -av '^\s*$' | tail -25 | cut -c1-160 | sed 's/^/  > /' || true
  fi
  _isovm_stop
  trap - EXIT
  [[ "$result" == OK:* ]] || die "iso-install: the installed disk did not boot (${boot_log})"
  (( ISOVM_CONSOLE_RC == 0 )) || die "iso-install: --console-exec command failed (rc=${ISOVM_CONSOLE_RC})"
}

cmd_iso_install() {
  local usage="Usage: $(basename "$0") iso-install -p <profile> --iso=<iso-latest|iso-stable|YYYYMMDD|file.iso> [--encrypted] [--live-timeout=S] [--install-timeout=S] [--boot-timeout=S] [--boot-only] [--disk-size=BYTES] [--expect-slot=blue|green] [--console-exec=CMD] [--console-put=LOCAL:REMOTE] [--console-timeout=S] [--expect-tpm-unlock]"
  local profile="" sel="" encrypted=0 live_to=1800 inst_to=10800 boot_to=1800 boot_only=0 disk_size="" expect_slot=""
  while (( $# )); do
    case "$1" in
      -p) profile="${2:-}"; shift ;;
      --iso=*) sel="${1#--iso=}" ;;
      --encrypted) encrypted=1 ;;
      --live-timeout=*) live_to="${1#*=}" ;;
      --install-timeout=*) inst_to="${1#*=}" ;;
      --boot-timeout=*) boot_to="${1#*=}" ;;
      --boot-only) boot_only=1 ;;
      --disk-size=*) disk_size="${1#*=}" ;;
      --expect-slot=*) expect_slot="${1#*=}" ;;
      --console-exec=*) ISOVM_CONSOLE_EXEC="${1#*=}" ;;
      --console-timeout=*) ISOVM_CONSOLE_TIMEOUT="${1#*=}" ;;
      --console-put=*) ISOVM_CONSOLE_PUT="${ISOVM_CONSOLE_PUT:+${ISOVM_CONSOLE_PUT} }${1#*=}" ;;
      --expect-tpm-unlock) ISOVM_EXPECT_TPM_UNLOCK=1 ;;
      *) die "$usage" ;;
    esac
    shift
  done
  [[ -n "$profile" && -n "$sel" ]] || die "$usage"

  _isovm_tools
  _isovm_ovmf
  ISOVM="${DATA_DIR}/${ISOVM_DIR_NAME}"
  if (( boot_only )); then
    [[ -f "$INSTALL_IMG" && -f "$ISOVM/OVMF_VARS.fd" && -f "$ISOVM/installed-date" ]] \
      || die "iso-install --boot-only: no previous iso-install to boot (disk, NVRAM or TPM state missing)"
    _detach_all_loops "$INSTALL_IMG"
    ISO_DATE=$(cat "$ISOVM/installed-date"); ISO_FILE=""
    trap '_isovm_stop' EXIT
    _isovm_boot_installed "$boot_to" "$expect_slot"
    return
  fi
  _fetch_published_iso "$profile" "$sel"

  # a fresh machine: blank disk, fresh NVRAM and TPM. The disk is the
  # smallest one this ISO's installer accepts (its config.yaml min_size, in
  # decimal GB - os-installer's GIGABYTE_FACTOR is 1000^3): the worst case a
  # user can really have, and the size the first update must still fit in.
  local size="${disk_size:-${INSTALL_DISK_SIZE:-}}" min_gb
  if [[ -z "$size" ]]; then
    _mount_iso "$ISO_FILE"
    min_gb=$(awk '/^[[:space:]]*min_size:/ {print $2; exit}' "${OSI_ROOT}/config.yaml" 2>/dev/null)
    _umount_iso; unset OSI_ROOT
    [[ "$min_gb" =~ ^[0-9]+$ ]] || { warn "iso-install: no disk min_size in the ISO's config.yaml - using 32 GB"; min_gb=32; }
    size=$(( min_gb * 1000 * 1000 * 1000 ))
    log "iso-install: target disk ${min_gb} GB (the ISO installer's minimum)"
  else
    log "iso-install: target disk ${size} bytes (--disk-size / INSTALL_DISK_SIZE)"
  fi
  _detach_all_loops "$INSTALL_IMG"
  _reset_slot_overlays
  rm -f "$INSTALL_IMG"
  truncate -s "$size" "$INSTALL_IMG"
  rm -rf "$ISOVM"; mkdir -p "$ISOVM/tpm"
  cp "$ISOVM_VARS_TEMPLATE" "$ISOVM/OVMF_VARS.fd"
  # the throwaway test passphrase, typed at every later boot of this disk
  (( encrypted )) && printf '%s' "${SHANIOS_TEST_LUKS_PIN:-shanios-test-passphrase}" > "$ISOVM/luks-pin"
  trap '_isovm_stop' EXIT

  # ---- 1. live ISO
  local live_log="${DATA_DIR}/iso-install-live-console.log" t0 i
  _isovm_start live "$live_log" iso
  t0=$(date +%s)
  log "iso-install: waiting up to ${live_to}s for the live session's guest agent"
  until python3 "${LIB_DIR}/qmp_client.py" qga-ping "${ISOVM}/qga.sock" >/dev/null 2>&1; do
    kill -0 "$ISOVM_PID" 2>/dev/null || { tail -5 "${ISOVM}/qemu-live.log"; die "iso-install: qemu exited during the live boot"; }
    (( $(date +%s) - t0 < live_to )) || die "iso-install: no guest agent after ${live_to}s (console: ${live_log})"
    sleep 10
  done
  log "iso-install: live session up after $(( $(date +%s) - t0 ))s: $(_isovm_qga 'uname -r; cat /etc/os-release | grep ^PRETTY' | tr '\n' ' ')"

  # ---- 2. os-installer's own invocation of its scripts
  local runner
  runner=$(_isovm_runner "$profile" "$encrypted")
  _isovm_qga "mkdir -p /tmp/osi && cat > /tmp/osi/run.sh <<'RUN'
${runner}
RUN
setsid bash /tmp/osi/run.sh >/tmp/osi/runner.log 2>&1 < /dev/null & echo started" 30 >/dev/null \
    || die "iso-install: could not start the installer in the guest"
  t0=$(date +%s)
  local st="" last=""
  while :; do
    st=$(_isovm_qga 'for s in prepare install configure; do [ -f /tmp/osi/$s.rc ] && echo "$s=$(cat /tmp/osi/$s.rc)"; done; [ -f /tmp/osi/finished ] && echo finished; [ -f /tmp/osi/fatal ] && cat /tmp/osi/fatal; true' 30 2>/dev/null | tr '\n' ' ') || true
    [[ "$st" != "$last" ]] && log "iso-install: [$(( $(date +%s) - t0 ))s] ${st:-prepare running}" && last="$st"
    [[ "$st" == *finished* || "$st" =~ =[1-9] || "$st" == *"no target"* ]] && break
    kill -0 "$ISOVM_PID" 2>/dev/null || die "iso-install: qemu exited during the install"
    (( $(date +%s) - t0 < inst_to )) || { st+=" TIMEOUT"; break; }
    sleep 30
  done
  local s
  for s in prepare install configure; do
    _isovm_qga "cat /tmp/osi/$s.log 2>/dev/null" 120 > "${DATA_DIR}/iso-install-${s}.log" 2>/dev/null || true
  done
  if [[ "$st" != *finished* ]]; then
    for s in prepare install configure; do
      [[ -s "${DATA_DIR}/iso-install-${s}.log" ]] && { log "── ${s}.sh (last lines) ──"; tail -15 "${DATA_DIR}/iso-install-${s}.log" | sed 's/^/  | /'; }
    done
    die "iso-install: the ISO's installer failed (${st}) - logs: ${DATA_DIR}/iso-install-{prepare,install,configure}.log"
  fi
  log "iso-install: os-installer scripts done in $(( $(date +%s) - t0 ))s (${st})"
  echo "$ISO_DATE" > "$ISOVM/installed-date"
  _isovm_stop

  # ---- 3. the installed disk, through firmware
  _isovm_boot_installed "$boot_to" "${expect_slot:-blue}"
  ISO_INSTALLED_DATE="$ISO_DATE"
  log "iso-install: PASSED - ${ISO_FILE##*/} installed by its own live installer and booted via UEFI"
}
