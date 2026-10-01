usage() {
  # QUOTED heredoc: the text is full of `backticked` command names, and an
  # unquoted heredoc runs every one of them as a command substitution — the
  # old usage() really executed pacstrap, ca and `gnome-shell --headless` on
  # every mistyped command. @PROG@ is substituted afterwards instead.
  sed "s|@PROG@|$(basename "$0")|g" <<'EOF'
Usage: @PROG@ <command> [options]

Commands:
  disk        Kept for compatibility: ensures /dev/disk/by-label exists and
              removes the legacy root.img/esp.img pair. The only disk is
              disk/install.img (a whole GPT disk: ESP + btrfs), which
              `bootstrap` creates with the real install.sh.
  ca          [extra-host ...]   Generate a throwaway CA + a leaf server cert
              for downloads.shani.dev, plus one more per extra hostname given
              (e.g. ca raw.githubusercontent.com) — see "The local mirror"
              in README.md for how to wire a hostname up end to end.
  pacstrap    -p <profile> [pkg ...]   Real signature-verification smoke test: runs an
              actual `pacstrap` against that profile's real pacman.conf into
              a throwaway target (removed on success), using the builder
              container's real, already-populated pacman keyring — proves a
              SigLevel/mirror/keyring change actually works in ~1-2 minutes
              instead of a full 30+ min image build. Extra package names are
              installed on top of base. On failure the partial target is
              removed and the pacman log kept (target-<id>.log).
  bootstrap   -p <profile> [-d latest|stable|<date>] [--encrypted] [--from-r2]   Runs the
              REAL install.sh+configure.sh (calls cmd_install/cmd_configure
              directly) to produce @blue/@green, plus one genuinely
              test-only step: trust-anchoring this session's throwaway CA
              into both slots. Requires `ca` to have been run first.
  serve       [port] [docroot] [cert-host]   Serve a docroot as an HTTPS
              stand-in for cert-host (default: cache/output as
              downloads.shani.dev). Binds 127.0.0.1 unless SHANIOS_TEST_SERVE_ALL=1.
              Run a second instance on a different port/docroot/cert-host to
              stand in for a second external hostname at the same time.
  enter       Enter a slot via systemd-nspawn (requires <blue|green> [--boot]
              [--local-src=<dir>] [cmd...]). The repo is available read-only
              inside at /mnt/repo — run repo scripts directly, e.g.:
              enter blue /mnt/repo/scripts/foo.sh
               --local-src=/opt/shani-deploy/scripts overlays the sibling
               shani-deploy checkout's CURRENT scripts (shani-deploy,
               gen-efi, check-boot-failure, shani-health,
               shani-reset, shani-user-setup, beesd-setup) and systemd units
               over the package-installed ones — see "Testing edited
               scripts" in README.md.
               --local-src-chronoa=<dir> overlays a shani-chronoa checkout's
               usr/bin launchers, the Python package, and the gsettings schema
               (rebuilt in place with glib-compile-schemas) over the image's
               own — so `app`/`slot-test`/`probe`/`desktop`/`enter` can drive
               the real /usr/bin/shani-chronoa-sense from a working tree
               instead of the package-installed copy. The overlay is reverted
               at the start of the next run (same as --local-src). The
               chronoa checkout IS mounted by run_in_container.sh at
               /opt/shani-chronoa:ro (run_in_container.sh:316 loops over the
               sibling app repos), so pass --local-src-chronoa=/opt/shani-chronoa
               directly; set SHANIOS_TEST_CHRONOA_SRC=<dir> (resolved inside the
               slot) only if you want a different tree.
  verify-boot [blue|green] [seconds]   Headless boot smoke test: full systemd
              --boot, console captured to disk/boot-<slot>-console.log, then
              reports reached target / failed units. No display or TTY needed.
  desktop     <blue|green> [--de=auto|gnome|plasma] [--display=virtual|host]
              [--size=WxH] [--hold=SECONDS] [--local-pkg=<name|file>]
              [--exec="cmd"] [--out=<file.png>] [--timeout=N] [--settle=N]
              [--local-src=<dir>]   Real desktop verification via nspawn -- no
              VM. Boots the slot for real (--boot, so systemd-logind exists)
              and screenshots a real session. The desktop is read from the
              slot's /etc/shani-profile.
              GNOME: a controlled `gnome-shell --headless` session,
              screenshotted over its own D-Bus Screenshot API.
              Plasma: a FRESH user from /etc/skel (what a new install's first
              login gets) with its global theme applied as startplasma would;
              kwin_wayland runs nested on an X11 display with plasmashell, and
              the X side is captured (KWin's own screenshot API never
              completes on a headless output). --display=host puts that
              desktop in a window on YOUR screen (run `xhost +local:` on the
              host first); --hold=N keeps it up N seconds after the shot.
              --local-pkg overlays locally built, unpublished packages first
              (see enter). Screenshots go to test-env/shots/ by default.
              --tour opens each real shell surface in turn and requires it to
              change the screen (> 0.5 % of pixels vs the desktop shot) -
              GNOME (gnome-shell --unsafe-mode, Shell.Eval): overview, app
              grid, calendar, quick settings, a notification, the lock screen;
              Plasma: launcher, KRunner, a notification, Dolphin, Konsole,
              System Settings, the real lock screen greeter (--testing).
              RESULT lines; shots in disk/desktop-<slot>/tour-<epoch>/.
  probe       <blue|green> --exec="cmd" [--timeout=N] [--settle=N]
               [--local-src=<dir>] [--local-src-chronoa=<dir>] [--timeout=N]
               [--settle=N] [--local-pkg=<name|file>]   Generic live-boot
               diagnostic: boots the slot for real (--boot), nsenter's in once a
               Multi-User/Graphical target is reached, runs any command (e.g.
               `systemctl status <unit> --no-pager -l`), prints its output.
               Built for when verify-boot's console-log capture isn't
               reliable enough — confirmed live that some units genuinely
               start/fail without either line appearing in the captured
               console output, so `probe` asking systemd directly is the
               only way to get a real answer for those.
               --local-src-chronoa=<dir> overlays a shani-chronoa checkout
               (see enter).
slot-test   <blue|green> <name...|all> [--local-src=<dir>] [--local-src-chronoa=<dir>] [--local-pkg=<name|file>] [--timeout=N]
                Boot the slot ONCE and run in-slot checks from slot-tests/
                (files with '# slot-test-mode: boot'); aggregates their
                RESULT PASS/FAIL lines. Add new in-slot checks there.
                --local-src-chronoa=<dir> overlays a shani-chronoa checkout
                (see enter) — used by the chronoa-senses slot-test.
                --local-pkg=<name|file> overlays a built package (e.g. the
                tesseract stack, which no published shani-chronoa image ships)
                before the slot boots.
                --volatile boots with /var an empty tmpfs (nspawn
                --tmpfs=/var), as systemd.volatile=state makes it on every
                real ShaniOS boot - plain nspawn boots see the image's /var.
                --from-r2 is NOT accepted here, though it is listed in this
                block by mistake until now. Only `bootstrap` and `install` parse
                it (via _take_from_r2, lib/install.sh:312 and :516); this
                command's argument loop dies on any unrecognised flag, so
                passing it fails immediately with a usage line rather than
                doing the thing you asked. To test a PUBLISHED release from
                Cloudflare R2 ($R2_PUBLIC_BASE, default https://downloads.shani.dev
                - the layout build-iso.sh --from-r2 uses; resumable, no
                credentials, after SHA-256 + GPG checks), produce the slot with
                it first:
                  bootstrap -p <profile> -d latest --from-r2
                and then run this command against that slot, which needs no flag.
  install     -p <profile> [-d latest|stable|<date>] [--encrypted]   Runs the
              REAL os-installer-config install.sh (partitioning, LUKS,
              subvolumes, image extraction) against a fresh whole-disk image
              — see "install / configure" in README.md.
  configure   -p <profile> [--encrypted]   Runs the REAL os-installer-config
              configure.sh (locale/hostname/user/Secure Boot/UKI) against
              install's result. Must follow install (same --encrypted).
  upgrade     [--local-src=<dir>] [extra shani-deploy args...]   Real deploy:
              calls shani-deploy directly (--force --channel latest
              --skip-self-update) — download, SHA256+GPG verify, extract,
              gen-efi UKI generation/signing, boot-entry write.
  update-check [--local-src=<dir>]   Compatibility smoke check for the
              replacement update path: enters the current slot and runs
              `shani-deploy --status --check --json`, the read-only status
              contract consumed by Shani Cassini and its update agent.
              It never installs, switches slots, runs the notification agent,
              or changes state; use `upgrade` or `rollback` for those.
  reboot      Simulate a reboot (re-enters whichever slot is now current)
  rollback    [--local-src=<dir>]   Real rollback: calls shani-deploy
              --rollback directly (as upgrade does)
  cycle       -p <profile> [--local-src=<dir>]   ca (if missing) → bootstrap →
              serve (background) → upgrade → reboot
  suite       [-p <profile>] [-d <sel>] [--local-src=<dir>] [--keep] [--encrypted]
              The mandatory verification sequence (clean → ca → bootstrap →
              upgrade → rollback → clean) as one command, with per-step
              timing and a PASS/FAIL summary (disk/suite-<epoch>.json).
              --local-src defaults to /opt/shani-deploy/scripts when mounted.
  iso-install -p <profile> --iso=<iso-latest|iso-stable|YYYYMMDD|file.iso>
              Installs from a real ISO the way a user does: the ISO boots
              under OVMF (UEFI + software TPM) with install.img as a blank
              disk; in the live session the ISO's own os-installer scripts
              run exactly as os-installer runs them (live user, pty, only
              OSI_* vars, prepare -> install -> configure); then the
              installed disk boots through the same firmware. KVM if
              present, else TCG (slow). install.img stays for enter/
              verify-boot/slot-test/upgrade.
              [--encrypted]            LUKS2 install; the passphrase is typed at
                                       each boot (one key at a time: plymouth)
              [--boot-only]            boot install.img again: with the last iso-install's
                                       NVRAM/TPM, or fresh ones if bootstrap/install has
                                       re-created the disk since
              [--reset-firmware]       with --boot-only: fresh NVRAM and TPM regardless
                                       (recovers a corrupted swtpm state)
              [--expect-slot=blue|green] fail unless firmware booted that slot
              [--expect-tpm-unlock]    fail if the passphrase is asked (TPM2 unlock)
              [--console-exec=CMD]     run CMD as root on the booted system, in
                                       systemd's debug shell on a virtio console
                                       (only on such boots); prints its output
              [--console-put=LOCAL:REMOTE] copy a file in first (repeatable)
  gate        -p <profile> [--candidate=<file.zst>] [--skip=iso,fresh,upgrade,desktop] [--keep] [--reuse-install]
              Release gate for promote-stable, the image and the ISO
              separately: iso = the candidate ISO via iso-install, first
              update on the stable channel; fresh = a new user updated to
              the candidate; upgrade = stable updated to the candidate.
              Writes disk/gate-<profile>.iso.passed / .image.passed for
              promote-stable.sh --only=iso|image --expect(-iso).
  status      Read-only view: images, loop attachments, by-label links,
              slots, overlays (incl. --local-src files pending revert).
  app         <blue|green> --run="cmd" [--local-src=<dir>] [--local-pkg=<name|file>] [--display=virtual|host]
              [--size=WxH] [ACTIONS...|--script=F|--interactive|--control=DIR]
              Run a GUI app inside the slot on a private virtual display and
              drive it: wait-window, windows, click/doubleclick/rightclick/
              move (X,Y or @WINDOW-REGEX:X,Y), drag, scroll, type, key,
              focus, screenshot, tree / find / click-element (accessibility
              tree — role, name, value, states, box), expect-window,
              expect-gone, wait-exit, status, and assertions: a11y-lint,
              expect-same/expect-changed=REF.png[:PCT] (with mask=X,Y,WxH),
              expect-text=REGEX (OCR), monkey=N[:SEED], expect-clean-log[=IGNORE].
              --strict: G_DEBUG=fatal-criticals. Captures the app's stdout/rc.
              See lib/app.sh; an MCP server for AI agents is in test-env/mcp/.
  web         <--url=URL | --site=DIR [--path=/sub/]> [--expect=SEL] [--allow-host=H]...
              [--offline] [--spa=/path] [--crawl=N] [--devices=desktop,tablet,mobile]
              [--schemes=light,dark] [--budget-lcp=MS] [--budget-cls=N] [--ignore=RE]
              [--resolve=RULES]   Real headless Chromium over the DevTools
              protocol (lib/web_client.py, stdlib Python): exceptions, console
              errors, failed loads, Chrome issues, CSP violations, egress
              allowlist, title/lang, accessible names, LCP/CLS, and on EVERY
              device (desktop 1280x800, tablet 820x1180 touch, mobile 390x844
              touch - built in, default all three): its own load + errors,
              horizontal overflow, tap targets >= 24x24 px, full-page shots in
              light and dark - and the page's FEATURES used for real on each
              device (lib/web_features.py): hamburger menu, search + its
              shortcut, theme toggle + persistence + OS colour scheme,
              disclosures, dialogs, breadcrumbs, contents links, copy-code,
              back-to-top, reading progress, skip link, focus visibility /
              obscuring / traps, print, contrast in light and dark, reflow at
              320 px, text spacing, reduced motion, landmarks, headings, ids,
              labels, head metadata, robots/sitemap/404 (--no-features: off).
Also offline via the service worker, SPA fallback,
               no-js (with scripts off the page still shows text, not a
               full-screen loader only script removes), same-origin crawl (zero pages crawled is a FAIL, not a
               pass). --site serves DIR as GitHub Pages does
              (404.html, status 404). Sibling site checkouts: /opt/<repo>.
              Shots + JSON report: disk/web-<epoch>/. No disk lock.
  slot-diff   [--from=blue|green] [--to=blue|green] [--json=FILE]   What moving
              between the slots changes, from the two roots on disk: packages
              (+/-/~), sonames that disappear, units and their enablement,
              changed /etc defaults, kernel. Default: current -> other slot.
  qemu        Genuine UEFI boot via OVMF — HOST-ONLY, see below
              [--vnc[=port]]   Serve the real framebuffer over VNC-over-
              websocket (default port 5700) instead of a local GTK window —
              open it in `watch`'s Desktop panel, or any VNC client at
              localhost:5900.
  gui         Headless real-desktop check via OVMF+QMP+guest-agent — HOST-ONLY,
              see below (requires python3 on the host; no distrobox/socat).
              Actions run in the order given on the command line, e.g.
              --click=100,200 --type="hello" --key=ret --screenshot=out.ppm
              is: click, then type, then press Enter, then screenshot.
              [--exec="shell command"]        run a command in the guest
              [--click=X,Y[:button]]          click at pixel X,Y (button:
                                               left/right/middle, default left)
              [--doubleclick=X,Y]             two quick clicks at X,Y
              [--move=X,Y]                    move pointer without clicking
              [--type="text"]                 type literal text (US layout)
              [--key=COMBO]                   e.g. ret, tab, ctrl+alt+t, alt+F4
              [--sleep=SECS]                  pause between actions
              [--screenshot=<file.ppm>]       screendump at this point (repeatable)
              [--out=<file.ppm>]              final screenshot if none given above
              [--timeout=N]                   guest-agent boot-wait timeout
              All coordinates are real framebuffer pixels — resolved against
              the CURRENT resolution automatically (a fresh screendump) on
              every click/move, so it stays correct even if the desktop
              resizes between actions. Input goes through the guest's
              emulated USB keyboard/tablet (real HID events, like a real
              keyboard/mouse), so it works identically for an X11 or a
              Wayland session — no xdotool/ydotool dependency, nothing to
              install in the (deliberately minimal) shanios image.
  watch       [--port=N] [--vnc-port=N]   HOST-ONLY local page (default
              http://127.0.0.1:8090/) with a noVNC viewer for `qemu --vnc`.
              Nothing leaves 127.0.0.1.
  vmspawn     [--image=PATH|--iso=PATH] [--timeout=S] [--until=RE] [--fail=RE]
              [--tpm=yes|no] [--secure-boot=no|yes] [--force]   HOST-ONLY real
              UEFI boot (OVMF + systemd-boot + swtpm TPM) under
              systemd-vmspawn; works WITHOUT /dev/kvm. Boots a qcow2 overlay
              in a throwaway container (image never written, no new files in
              disk/ except the console log). Default image: install.img.
  iso         Boot a real installer ISO via OVMF — HOST-ONLY, see below (requires -p <profile> [-d latest|stable|<date>])
  clean       Unmount everything and detach install.img's loop device

Loop-device attachment does NOT survive across separate
run_in_container.sh invocations (each is a fresh --rm'd container) — every
every bootstrap/install/enter call re-attaches (or reuses) install.img's
loop device on the HOST, but nothing ever detaches them again on its own.
Run clean when you're done testing, or loop devices accumulate on the
host indefinitely across a session (only a reboot or manual losetup -d
otherwise releases them). install.img itself is left alone - clean only
tears down mounts and loop attachments, not the disk image.

Options:
  -p <profile>    Profile name (e.g. gnome, plasma) — for bootstrap/cycle/iso
  -d <sel>        Image selector: 'latest' (default), 'stable', or a date — for bootstrap/cycle/iso

Environment:
  SHANIOS_TEST_EXTRA_BINDS   Extra nspawn binds "host:ctr[,host:ctr...]"
                             (read-write, applied to enter and verify-boot)
  SHANIOS_TEST_SERVE_ALL=1   Let serve bind 0.0.0.0 instead of 127.0.0.1
  SHANIOS_TEST_DATA          Override the data dir (default test-env/disk)
  SHANIOS_TEST_OSI_HOST_DIR  Path to the os-installer-config checkout on the
                             HOST (default: ../os-installer-config next to
                             this repo) — set on the run_in_container.sh
                             invocation, not test.sh itself
  INSTALL_DISK_SIZE          Whole-disk image size for install (default 24G;
                             iso-install: the ISO installer's min_size)
  SHANIOS_TEST_LUKS_PIN      LUKS passphrase for install --encrypted /
                             configure --encrypted (default: shanios-test-passphrase)
  SHANIOS_TEST_OSI_*         Override individual configure.sh OSI_* values
                             (OSI_LOCALE, OSI_TIMEZONE, OSI_KEYBOARD, OSI_USERNAME,
                             OSI_USER_NAME, OSI_USER_PASSWORD, OSI_ROOT_PASSWORD,
                             OSI_FORMATS, OSI_AUTOLOGIN) — see configure's
                             defaults below

Run from the repo root, via build.sh (like every other command in this repo):
  ./run_in_container.sh build.sh test disk
  ./run_in_container.sh build.sh test ca
  ./run_in_container.sh build.sh test bootstrap -p plasma
  ./run_in_container.sh build.sh test serve &
  ./run_in_container.sh build.sh test enter blue
  ./run_in_container.sh build.sh test upgrade
  ./run_in_container.sh build.sh test reboot
  ./run_in_container.sh build.sh test rollback
  ./run_in_container.sh build.sh test cycle -p plasma
  ./run_in_container.sh build.sh test install -p plasma
  ./run_in_container.sh build.sh test configure -p plasma
  ./run_in_container.sh build.sh test clean

qemu/gui/iso need your GPU/display (gui needs it indirectly, via QEMU's own
graphics device — see below), so run this file directly on the HOST instead
of through build.sh/run_in_container.sh (which would put it in a container):
  test-env/test.sh qemu
  test-env/test.sh gui --exec="gsettings get org.gnome.desktop.interface gtk-theme"
  test-env/test.sh iso -p plasma
  test-env/test.sh vmspawn --timeout=900

Every command that boots or enters a slot accepts --local-src=<dir>; its
overlay is automatically reverted at the start of the next run, so a run
without --local-src always sees the image's own scripts/units.
EOF
  exit 1
}
