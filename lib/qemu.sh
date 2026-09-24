# Locate OVMF firmware. Sets globals OVMF_CODE_PATH / OVMF_VARS_TEMPLATE_PATH
# (shared by cmd_qemu and cmd_iso — both boot via the same firmware).
# The QEMU command-line prefix every OVMF boot here shares: machine, CPUs,
# memory, KVM-or-TCG, OVMF code + a per-purpose writable NVRAM copy.
# Each purpose keeps its OWN vars file on purpose (an installer boot, an
# interactive post-install boot and an unattended gui run are different
# machines to UEFI; sharing NVRAM would let a MOK enrollment or boot-order
# change in one contaminate the others). Sets QEMU_BASE_ARGS.
# Usage: _qemu_base_args <vars-file-basename>
_qemu_base_args() {
  _locate_ovmf
  local vars_copy="${DATA_DIR}/$1"
  [[ -f "$vars_copy" ]] || cp "$OVMF_VARS_TEMPLATE_PATH" "$vars_copy"
  local -a kvm=()
  if [[ -e /dev/kvm && -w /dev/kvm ]]; then
    kvm=(-enable-kvm -cpu host)
  else
    echo "no /dev/kvm access — falling back to (slow) TCG emulation" >&2
  fi
  QEMU_BASE_ARGS=(
    -machine q35 -smp 4 -m "${QEMU_MEM:-4096}" "${kvm[@]}"
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE_PATH"
    -drive if=pflash,format=raw,file="$vars_copy"
  )
}
# Devices every OVMF boot here attaches (GPU, user-mode net, USB kbd+tablet).
QEMU_COMMON_DEVICES=(
  -device virtio-gpu-pci
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0
  -device qemu-xhci -device usb-kbd -device usb-tablet
)

_locate_ovmf() {
  OVMF_CODE_PATH="${OVMF_CODE:-}"
  OVMF_VARS_TEMPLATE_PATH="${OVMF_VARS_TEMPLATE:-}"
  local candidate
  for candidate in \
      /usr/share/OVMF/OVMF_CODE_4M.fd \
      /usr/share/OVMF/OVMF_CODE.fd \
      /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
      /usr/share/edk2/x64/OVMF_CODE.fd; do
      [[ -z "$OVMF_CODE_PATH" && -f "$candidate" ]] && OVMF_CODE_PATH="$candidate"
  done
  for candidate in \
      /usr/share/OVMF/OVMF_VARS_4M.fd \
      /usr/share/OVMF/OVMF_VARS.fd \
      /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
      /usr/share/edk2/x64/OVMF_VARS.fd; do
      [[ -z "$OVMF_VARS_TEMPLATE_PATH" && -f "$candidate" ]] && OVMF_VARS_TEMPLATE_PATH="$candidate"
  done
  [[ -n "$OVMF_CODE_PATH" && -n "$OVMF_VARS_TEMPLATE_PATH" ]] || {
      echo "Couldn't find OVMF firmware. Install it:" >&2
      echo "  apt install qemu-system-x86 ovmf   (Debian/Ubuntu)" >&2
      echo "  pacman -S qemu-full edk2-ovmf      (Arch)" >&2
      echo "or set \$OVMF_CODE / \$OVMF_VARS_TEMPLATE explicitly." >&2
      exit 1
  }
}

# ------------------------------------------------------------------
# iso   — HOST-ONLY: boot a real, unmodified installer ISO via OVMF
#
# This is the one thing cmd_qemu deliberately does NOT cover: the real
# install flow (os-installer-config/scripts/install.sh's partitioning,
# configure.sh's locale/hostname/user setup, the os-installer GUI itself)
# has no automated test anywhere in this repo. cmd_iso doesn't automate the
# GUI either (it's an interactive installer — a human has to click through
# it), but it DOES give a genuine, automated confirmation that the signed
# ISO you built actually boots: firmware -> shim -> systemd-boot -> the
# live UKI -> kernel -> systemd -> the installer GUI, all unmodified.
#
# With SHANIOS_TEST_ISO_INSTALL_TARGET=1, disk/install.img is attached as a
# second virtio drive so a human can run the installer's partitioning/install
# step onto it for a full end-to-end test (it overwrites the current slots);
# entirely optional, the ISO boots fine without it.
# ------------------------------------------------------------------
cmd_iso() {
  if _in_container; then
    echo "qemu needs your GPU/display — it can't run inside the build container." >&2
    echo "Run this file directly on the HOST instead, from the repo root:" >&2
    echo "  test-env/test.sh iso -p <profile> [-d latest|stable|<date>]" >&2
    exit 1
  fi

  local usage_iso
  usage_iso() {
    echo "Usage: $(basename "$0") iso -p <profile> [-d <date>|latest|stable]" >&2
    exit 1
  }

  local profile="" date_sel="latest" opt OPTARG OPTIND=1
  while getopts "p:d:" opt "$@"; do
    case "$opt" in
      p) profile="$OPTARG" ;;
      d) date_sel="$OPTARG" ;;
      *) usage_iso ;;
    esac
  done
  [[ -n "$profile" ]] || usage_iso

  local date_dir
  if [[ "$date_sel" == "latest" || "$date_sel" == "stable" ]]; then
    local pointer="${OUTPUT_DIR}/${profile}/iso-${date_sel}.txt"
    [[ -f "$pointer" ]] || die "No iso-${date_sel}.txt for profile '${profile}' — build/release an ISO first (./build.sh iso -p ${profile} or iso-only)."
    date_dir=$(tr -d '[:space:]' < "$pointer")
  else
    date_dir="$date_sel"
  fi

  local iso_dir="${OUTPUT_DIR}/${profile}/${date_dir}"
  [[ -d "$iso_dir" ]] || die "No such directory: ${iso_dir}"

  # Prefer the Secure-Boot-repacked, signed ISO (what actually ships) —
  # fall back to the unsigned one if repack was never run in this dev setup.
  local iso
  iso=$(find "$iso_dir" -maxdepth 1 -name "signed_*.iso" | head -n1)
  [[ -n "$iso" ]] || iso=$(find "$iso_dir" -maxdepth 1 -name "*.iso" ! -name "*signed*" | head -n1)
  [[ -n "$iso" ]] || die "No .iso found under ${iso_dir}"

  _qemu_base_args OVMF_VARS_ISO.fd

  # Optional install target: install.img, only when asked for, since the live
  # installer will repartition it (the old root.img+esp.img pair is gone).
  local target_disk_args=()
  if [[ "${SHANIOS_TEST_ISO_INSTALL_TARGET:-0}" == 1 ]]; then
    [[ -f "$INSTALL_IMG" ]] || truncate -s "${INSTALL_SIZE:-24G}" "$INSTALL_IMG"
    warn "Attaching disk/install.img as the install target - installing from the ISO will OVERWRITE the current slots"
    target_disk_args=(-drive if=virtio,format=raw,file="$INSTALL_IMG")
  fi

  echo "==> Booting ${iso} via OVMF (close the window / send SIGTERM to stop)"
  echo "==> This lands in the live installer GUI — it does not automate clicking through it."
  exec qemu-system-x86_64 \
      "${QEMU_BASE_ARGS[@]}" \
      -drive if=none,id=isocd,format=raw,readonly=on,file="$iso" \
      -device virtio-scsi-pci,id=scsi0 \
      -device scsi-cd,drive=isocd,bootindex=0 \
      "${target_disk_args[@]}" \
      "${QEMU_COMMON_DEVICES[@]}" \
      -display "${QEMU_DISPLAY:-gtk}" \
      -serial mon:stdio
}

# ------------------------------------------------------------------
# _resolve_qemu_boot_drives — pick which backing image(s) cmd_qemu/cmd_gui boot
#
# There is one disk: install.img, a whole GPT disk written by `install` (the
# real os-installer-config install.sh partitions it: p1 = ESP shani_boot,
# p2 = btrfs shani_root) and populated by `configure` (real configure.sh:
# gen-efi.sh puts shim/systemd-boot/the signed UKI on its ESP). OVMF boots it
# like real firmware boots a laptop disk - no separate ESP image. (A
# root.img+esp.img pair used to exist; nothing ever populated it, so it only
# ever booted to firmware PXE. Removed 2026-09-24.)
#
# SHANIOS_TEST_QEMU_DISK is kept for existing callers: auto (default) and
# install both mean install.img; `root` dies with an explanation.
# Sets globals:
#   QEMU_BOOT_DRIVES — bash array of complete `-drive ...` args for QEMU
#   QEMU_BOOT_DESC   — short human string naming the booted image set
_resolve_qemu_boot_drives() {
  # One disk: install.img, the whole-disk image the real install.sh +
  # configure.sh produce (bootstrap/install). The old root.img+esp.img pair
  # was never populated by anything and only ever booted to OVMF's PXE
  # fallback, so it is gone; SHANIOS_TEST_QEMU_DISK is kept for callers but
  # only `auto`/`install` remain valid.
  local mode="${SHANIOS_TEST_QEMU_DISK:-auto}"
  case "$mode" in
    auto|install) ;;
    root) die "SHANIOS_TEST_QEMU_DISK=root: the root.img+esp.img pair was removed (it was never bootable) - run 'bootstrap -p <profile>' and boot install.img" ;;
    *) die "Invalid SHANIOS_TEST_QEMU_DISK value '$mode' - expected auto or install." ;;
  esac
  [[ -f "$INSTALL_IMG" ]] || die "No $INSTALL_IMG - run 'bootstrap -p <profile>' (or install + configure) first."
  QEMU_BOOT_DRIVES=(-drive if=virtio,format=raw,file="$INSTALL_IMG")
  QEMU_BOOT_DESC="disk/install.img (whole-disk image from install+configure)"
}

# ------------------------------------------------------------------
# qemu   (was 07-boot-qemu.sh) — HOST-ONLY
#
# Boots the real bootable disk image via OVMF, exactly like real hardware
# would. Which image is booted is resolved by _resolve_qemu_boot_drives
# (env SHANIOS_TEST_QEMU_DISK, default auto):
#   install.img - the whole-disk image a real `install`+`configure` flow
#     produces: install.sh partitions it itself and configure.sh runs
#     gen-efi.sh/finalize_boot_entries to lay down the ESP + signed UKI inside
#     it. The only disk this harness has.
  #
  # The chain that makes install.img bootable:
  #   - its ESP partition (p1, shani_boot) contains
  #     /EFI/BOOT/BOOTX64.EFI (shim) -> grubx64.efi (systemd-boot, renamed —
  #     see update_bootloader() in gen-efi.sh) -> the UKI for whichever slot
  #     loader.conf points at. OVMF's firmware boot manager finds this via the
  #     standard "removable media" fallback path, same as booting an installer
  #     USB stick — no NVRAM boot-entry setup needed for this to work.
  #   - its root filesystem (p2, the Btrfs volume, LABEL=shani_root) is where the
  #     kernel cmdline baked into the UKI points root= / rootflags=subvol=@<slot>.
#
# This is a genuine UEFI boot of the real bootloader/kernel/UKI shani-deploy
# produced — not a simulation. If it doesn't boot, that's signal about the
# image/deploy, not about this harness.
#
# Requirements on the HOST (not the container):
#   apt install qemu-system-x86 ovmf   (Debian/Ubuntu)
#   pacman -S qemu-full edk2-ovmf      (Arch)
# ------------------------------------------------------------------
cmd_qemu() {
  # --vnc[=port]: serve the real framebuffer over VNC-over-websocket (QEMU's
  # own built-in `websocket=` vnc suboption — confirmed live, no separate
  # websockify proxy needed) instead of opening a local GTK window, so a
  # browser-based noVNC client (see `watch`, below) can show the actual
  # live boot/desktop remotely. Raw VNC (TCP 5900+N) is always also listening
  # alongside the websocket port, for a native VNC client if you'd rather use one.
  local vnc_ws_port="" arg
  for arg in "$@"; do
    case "$arg" in
      --vnc)        vnc_ws_port=5700 ;;
      --vnc=*)      vnc_ws_port="${arg#--vnc=}" ;;
    esac
  done

  # The GTK-window path genuinely needs the HOST's GPU/display. `--vnc` needs
  # neither — just a network socket, which `run_in_container.sh`'s
  # `--network=host` already shares straight through to the host's own
  # 127.0.0.1 — so let `--vnc` run through the container instead, where it's
  # already root and doesn't hit install.img's host-side permissions
  # (those land root:root from the privileged container that created them;
  # confirmed live: running plain `qemu`/`--vnc` as the unprivileged host
  # user hits "Could not open install.img: Permission denied" otherwise).
  if [[ -z "$vnc_ws_port" ]] && _in_container; then
    echo "qemu needs your GPU/display — it can't run inside the build container." >&2
    echo "Run this file directly on the HOST instead, from the repo root:" >&2
    echo "  test-env/test.sh qemu" >&2
    exit 1
  fi

  _resolve_qemu_boot_drives

  # Locate OVMF firmware + a per-VM copy of the vars file (writable NVRAM store
  # — bootctl's `set-default` EFI-var write and any MOK enrollment land here;
  # copied once so re-running this doesn't reset it).
  _qemu_base_args OVMF_VARS.fd

  # Every profile this harness boots (gnome/plasma/cosmic) ships
  # shani-video-guest -> qemu-guest-agent, enabled by default. A real
  # libvirt-managed VM always wires up this exact virtio-serial channel for
  # it; without it here, the guest blocks at boot on "Timed out waiting for
  # device /dev/virtio-ports/org.qemu.guest_agent.0" — a harness gap, not a
  # ShaniOS one, so provide the channel like a real hypervisor would.
  local qga_sock="${DATA_DIR}/qga.sock"
  rm -f "$qga_sock"

  local -a display_args=(-display "${QEMU_DISPLAY:-gtk}")
  if [[ -n "$vnc_ws_port" ]]; then
    display_args=(-vnc ":0,websocket=${vnc_ws_port}")
    echo "==> Booting $QEMU_BOOT_DESC via OVMF — VNC on :5900, websocket on ${vnc_ws_port} (open the 'watch' UI, or point any VNC client at localhost:5900)"
  else
    echo "==> Booting $QEMU_BOOT_DESC via OVMF (close the window / send SIGTERM to stop)"
  fi

  exec qemu-system-x86_64 \
      "${QEMU_BASE_ARGS[@]}" \
      "${QEMU_BOOT_DRIVES[@]}" \
      "${QEMU_COMMON_DEVICES[@]}" \
      "${display_args[@]}" \
      -chardev socket,path="$qga_sock",server=on,wait=off,id=qga0 \
      -device virtio-serial \
      -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
      -serial mon:stdio
}

# ------------------------------------------------------------------
# watch   [--port=N] — HOST-ONLY local dashboard: "see the boot"
#
# One local page, two panels:
#   - Console: live-tails whichever *-console.log is most recently written
#     (desktop-<slot>-console.log from `desktop`, boot-<slot>-console.log
#     from `verify-boot`, or any future *-console.log) — a plain polling
#     fetch loop, no dependency beyond python3's stdlib http.server.
#   - Desktop (VNC): a noVNC viewer (loaded from a CDN, since this is a
#     plain local page you open yourself — not a claude.ai artifact, so
#     none of that sandbox's CDN allowlist applies here) pointed at a
#     ws://127.0.0.1:<port> you type in, matching `qemu --vnc[=port]`'s
#     websocket port. Confirmed live: `qemu-system-x86_64 -vnc
#     :0,websocket=5700` really does open both raw VNC (5900) and a
#     websocket bridge (5700) on this host's QEMU (8.2.2) — no separate
#     websockify proxy needed.
# Entirely local: nothing here is uploaded or exposed beyond 127.0.0.1.
# ------------------------------------------------------------------
cmd_watch() {
  if _in_container; then
    echo "watch opens a local port for your browser — run it on the HOST instead:" >&2
    echo "  test-env/test.sh watch [--port=N] [--vnc-port=N]" >&2
    exit 1
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 is required for watch (should already be present)."

  local port=8090 vnc_port=5700 arg
  for arg in "$@"; do
    case "$arg" in
      --port=*)     port="${arg#--port=}" ;;
      --vnc-port=*) vnc_port="${arg#--vnc-port=}" ;;
      *) echo "Usage: $(basename "$0") watch [--port=N] [--vnc-port=N]" >&2; exit 1 ;;
    esac
  done

  log "Boot-watch UI: http://127.0.0.1:${port}/  (Ctrl+C to stop — local only, nothing leaves this machine)"
  python3 - "$port" "$vnc_port" <<'PYEOF'
import http.server, socketserver, sys

PORT, VNC_PORT = int(sys.argv[1]), int(sys.argv[2])

# Desktop-only, full-bleed view — no split-screen scaling, which is also
# what was making the remote cursor render tiny/misaligned before. noVNC
# expects its target container to be a plain block/relative box (no
# flex-centering) so it can size and scale its own canvas correctly.
PAGE = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>ShaniOS test-env — watch</title>
<style>
  html,body{{background:#000;margin:0;height:100%;overflow:hidden}}
  #bar{{position:fixed;top:0;left:0;right:0;z-index:2;display:flex;gap:8px;align-items:center;
       padding:6px 10px;background:#181818;font:12px ui-monospace,Menlo,Consolas,monospace;color:#ddd}}
  #bar input,#bar button{{background:#222;color:#ddd;border:1px solid #444;padding:3px 6px;font:inherit}}
  #status{{color:#777}}
  #screen{{position:absolute;top:28px;left:0;right:0;bottom:0;background:#000;outline:none}}
</style></head>
<body>
  <div id="bar">
    <input id="wsUrl" size="24" value="ws://127.0.0.1:{VNC_PORT}">
    <button onclick="connectVnc()">Connect</button>
    <span id="status">not connected — run `qemu --vnc[=port]` on the host first</span>
  </div>
  <div id="screen"></div>
<script type="module">
window.connectVnc = async () => {{
  const status = document.getElementById('status');
  const screen = document.getElementById('screen');
  try {{
    const {{ default: RFB }} = await import('https://cdn.jsdelivr.net/npm/@novnc/novnc@1.4.0/core/rfb.js');
    screen.innerHTML = '';
    const url = document.getElementById('wsUrl').value;
    const rfb = new RFB(screen, url);
    rfb.viewOnly = false;
    rfb.scaleViewport = true;
    rfb.resizeSession = false;
    rfb.showDotCursor = true;
    rfb.addEventListener('connect', () => status.textContent = 'connected');
    rfb.addEventListener('disconnect', () => status.textContent = 'disconnected');
    status.textContent = 'connecting...';
    screen.tabIndex = 0;
    screen.addEventListener('click', () => screen.focus());
    screen.focus();
  }} catch (e) {{
    status.textContent = 'noVNC failed to load: ' + e;
  }}
}};
window.addEventListener('load', () => setTimeout(connectVnc, 300));
</script>
</body></html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    print(f"serving on http://127.0.0.1:{PORT}/", file=sys.stderr)
    httpd.serve_forever()
PYEOF
}
