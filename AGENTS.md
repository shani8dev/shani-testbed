# Agent instructions — shani-testbed

This file applies to any AI coding assistant working in this repository
(Claude Code, opencode, Kilo Code, Cursor, Aider, or similar). Read this
before editing, and follow the verification steps before calling any change
done.

## What this repo is

The ShaniOS test harness: installs a real ShaniOS image onto loop-backed
disks with the real `install.sh`/`configure.sh`, enters or boots its
`@blue`/`@green` slots with `systemd-nspawn`, runs real `shani-deploy`
upgrades/rollbacks, drives GUI apps inside a slot (`app`), and boots real
UEFI firmware (`vmspawn`, `qemu`, `iso`, `gui`). `mcp/` exposes the GUI and
harness commands to AI agents over MCP.

It was split out of `shani-install-media/test-env/` on 2026-09-23. That repo
is still what it tests and how it runs: it provides `config/config.sh`,
`image_profiles/`, `cache/output/`, the builder-container runner
(`run_in_container.sh`, which mounts this repo at `/opt/shani-testbed`), and
the state dir `test-env/disk/`. `shani-install-media/test-env/test.sh` is a
shim that execs `testbed`, so every existing `build.sh test <cmd>`
invocation keeps working.

## Empirical verification (mandatory)

**Reading code is analysis; running code is verification.** A change here is
verified by running the changed command for real against a bootstrapped
slot, not by `bash -n`. For a change to anything on the boot/deploy path,
run the mandatory sequence from `shani-install-media`:

```bash
cd ../shani-install-media
./run_in_container.sh build.sh test suite -p gnome     # clean → ca → bootstrap → upgrade → rollback → clean
# (or the six steps one by one — see shani-install-media/AGENTS.md)
```

Plus the command you changed (`probe`, `verify-boot`, `desktop`, `app`, ...)
with a positive case **and** a negative control.

## Fast checks (run first; they are the floor, not the proof)

```bash
for f in testbed lib/*.sh slot-tests/*.sh tests/*.sh; do bash -n "$f"; done
python3 -m py_compile lib/*.py mcp/*.py
tests/run-app-actions.sh        # real Xvfb + GTK (yad) test of lib/app.sh + lib/a11y_client.py, in docker
```

## Extend the harness — don't write one-off test scripts

When verifying something needs a capability the harness lacks, add it
here instead of a throwaway script (scratchpad, `.verify-bin/`, a heredoc
piped into `probe --exec`):

- **an in-slot check** → a file in `slot-tests/` with a
  `# slot-test-mode: boot` header, printing `RESULT <name> PASS|FAIL` lines,
  run by `slot-test <slot> <name|all>` (one boot for many checks);
- **a new way to drive or observe** a boot, an app or a VM → a command
  option or an `app` action in `lib/`, documented in `usage` + README;
- **a check of the harness itself** → `tests/`.

A test that only exists in one session's scratchpad is lost the moment the
session ends, and the next agent re-derives it.

## Never edit a harness file while a harness run is using it

bash reads a script as it executes. Editing `testbed`, a `lib/*.sh` module,
or `shani-install-media/run_in_container.sh` while a `build.sh test ...` run
is in progress can corrupt that run mid-way. Check `status` / running
containers first.

## Rules that have bitten this harness before

- **Never hard-kill a live `--boot` container.** Use `_boot_bg_stop`
  (graceful poweroff, 30 s, then SIGKILL with a warning). A hard kill
  mid-write once left both `@blue` and `@green` missing. Any caller's outer
  timeout must exceed the command's own timeout plus 30 s.
- **`--local-src` overlays are reverted at the start of the next run**
  (`_revert_local_src_overlay`). Don't bypass `_overlay_one` when adding a
  new overlay path, or that file will leak into later runs again.
- **`set -e` + command substitution:** `x=$(pgrep ... | head -1)` kills the
  script when nothing matches (pipefail). Keep the `|| true` on such
  assignments, and don't write bare `cmd && break` in loops.
- **A line-buffered filter in a console pipe hides partial lines.** getty
  prints `login: ` with no newline; `vmspawn` keeps only an unbuffered `tr`
  in the live pipe for that reason.
- **The virtual display has no window manager.** `app` focuses the app's
  window before `type`/`key`; don't remove `_app_ensure_focus`.
- **at-spi2-core role names changed** (`button`, not `push button`). Take
  role names from a real `tree`, not from memory.
- **`gate` must stay a test of what users get.** No `--local-src`, no
  `--local-pkg`, no loosened checks to make a candidate pass: it is what
  `promote-stable.yml` trusts. A check for a feature newer than an image's
  packages reports `SKIP` via `since` (fresh-user.sh), never a silent PASS.
  Verifying downloads uses a public-only keyring (`_release_keyring`);
  `gpg_prepare_keyring` needs the secret key and would fail on CI.
- **`iso-install` replays os-installer, it doesn't reinvent it.** The
  in-guest runner (`_isovm_runner`) mirrors installation_scripting.py /
  envvar_creator.py from the ISO: live user, pty, cwd `/`, ONLY the step's
  `OSI_*` vars (prepare gets none - `printf '%q '` with no args yields `''`,
  which once made every prepare exit 127), and `finished` only after all
  three steps succeed (it was once written unconditionally: a failed install
  would have passed). `tests/iso-install-runner.sh` guards both. qemu-base
  has no virtio-gpu (use `-vga std`); a comma inside a `-smbios` value must
  be written `,,`.
- Never read or enumerate `shani-install-media/test-env/disk/` or `cache/`
  contents by hand: loop-mounted images and build artifacts.

## Boundaries

- ✅ **Always**: verify by running the real command; keep every existing
  `build.sh test <cmd>` interface (commands, flags, env vars, paths) working,
  since other repos' AGENTS.md files and CI call them.
- ⚠️ **Ask first**: changing where state lives (`test-env/disk/`), adding a
  host-side privileged step, or anything that injects input into the HOST
  display (`app --display=host`).
- 🚫 **Never**: point `app`/`gui` input at a real user session by default;
  disable the graceful-shutdown path; commit anything from `test-env/disk/`.

## Audit-verified known issues (confirmed present)

- **A container's `swapon` is the host's.** install.sh / shani-deploy swap
  on a test disk's swapfile inside the container, i.e. on the host kernel;
  deleted images then stayed allocated (3 found, 31 GB). `_release_test_swap`
  (disk.sh) turns them off before loops are detached and after every
  command — keep it when touching teardown. Check: `cat /proc/swaps` lists
  only the host's own swap. (2026-09-25)
- **Console on a firmware-booted install:** `iso-install --boot-only
  --console-exec=CMD [--console-put=LOCAL:REMOTE]` runs as root in systemd's
  debug shell on a virtio console (hvc0). Not a second serial port (OVMF
  stopped at the boot menu); not a login (the ISO installer creates no
  user, `skip_user`). `--expect-tpm-unlock` fails a boot that asks for the
  passphrase. Used to verify TPM2 enroll → prompt-free boot → remove.
- **LUKS on the serial console is plymouth's prompt:** type one key at a
  time (a burst lost all but 2 characters). The kernel prints
  "Kernel **c**ommand line:" (lower-case c) — the slot check matches it
  case-insensitively.

- **The shim was never applied until 2026-09-24 — FIXED.** After the split,
  `shani-install-media/test-env/test.sh` was still the old 3544-line harness
  and `run_in_container.sh` never mounted this repo, so every `build.sh test`
  ran the pre-split code: `status`/`suite`/`slot-test`/`app` didn't exist
  there (`status` printed usage), and this session's harness fixes that only
  live here (pacstrap extra packages, no `rm -rf` across live mounts) weren't
  running. The staged shim, runner and README are now applied; verified by
  `build.sh test status` running from `/opt/shani-testbed` in the builder
  container, and `slot-test blue fresh-user` booting a real slot. The same
  staged runner restores the pinned GitHub/SourceForge SSH host keys (checked
  against the live servers' keys on 2026-09-24: all 6 match). This repo got
  its git history and GitHub remote the same day.
- **Slot overlays were corrupted by the runner and never reset; one disk
  instead of three — FIXED (2026-09-24).** `test-env/disk` was 144 GB:
  `nspawn-overlay-blue/upper` held 121 GB, of which 107 GB was one
  `var/log/cups/error_log`. Cause: `run_in_container.sh`'s post-run `chown -R
  <host user> test-env/disk` also recursed into the overlay upper layers, so
  all 331,467 copied-up slot files were owned by the host user, with setuid
  stripped (`sudo`, `dbus-daemon-launch-helper`; `/etc/shadow` user-owned);
  cupsd rejected its "insecure" dbus notifier in an endless retry loop.
  Every slot test since that chown ran on a broken permission model. And
  nothing reset the overlays on re-bootstrap, so `/usr` copies from 09-17
  (13 GB) shadowed newer slots. Fixed: the chown skips `nspawn-overlay-*`;
  `install` resets both overlays (`_reset_slot_overlays`). Verified: suite
  PASSED, both upper layers root-only, disk/ 14 GB. The never-bootable
  `root.img`/`esp.img` pair is removed; `_mount_root` attaches install.img
  (it called `_ensure_disk_attached`, which only worked because the
  install path's by-label links made it return early).
- **`desktop` supports Plasma; `bootstrap --from-r2`; `--local-pkg` (2026-09-24).**
  Only gnome had ever been built locally, so no other profile could be
  bootstrapped; `--from-r2` installs a published, SHA-256+GPG-verified
  release from R2 (first Plasma slot bootstrapped this way). rclone is used
  only for the pointer fallback: a multi-thread object download can't
  resume, and one stalled stream crawled at ~13 KB/s for the last 55 MB of
  3.1 GB (default 5-min idle timeout; its stats print below the default log
  level, so it looked hung). Plasma `desktop` findings, confirmed live, so
  nobody re-derives them:
  - **KWin's `org.kde.KWin.ScreenShot2` does not work on a headless output.**
    `spectacle -b` blocked for 13+ min; a direct Gio call got `NoAuthorized`
    (only executables whose .desktop declares the interface may call it;
    `KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1` lifts that), then `Cancelled`
    for every capture under QPainter, and never returned under OpenGL even
    with forced damage. Hence: kwin nested on an X11 display, X-side
    `import`. Never call an unbounded screenshot command.
  - **The fresh user needs the render node's group** (in the slot the host's
    `render` gid maps to `input`); without it kwin dies silently. kwin is
    silent on success, so an empty log proves nothing.
  - **Plasma's first-login theme comes from `startplasma`**, not plasmashell:
    without `plasma-apply-lookandfeel` + kdedefaults first in
    XDG_CONFIG_DIRS the session is stock Breeze.
  - kded's bluedevil module re-activates `org.bluez.obex` in a loop without
    bluetoothd (14k activations in ~2 min) - disabled for the test user.
  - Image findings, not harness bugs: published plasma 20260922
    (shani-desktop-plasma 1.0-35) shows the stock wallpaper (`[Wallpaper]
    Image=file://...png` instead of a package name) and a light panel;
    1.0-36 via `--local-pkg` shows the full Saturn desktop. R2 has no
    `flatpakfs.zst` for plasma, so its flatpak dock launchers are blank.
    `xdg-desktop-portal-gtk` aborts with "Settings schema
    'org.appmenu.gtk-module' is not installed" in the session - not yet
    investigated.
- **`suite` always exited 1 and truncated its summary — FIXED
  (2026-09-24).** `json+="$([[ $i -gt 0 ]] && echo ,)..."` in the summary
  loop returns 1 on the first row and `set -Eeuo pipefail` killed the
  harness there: one summary line, no JSON, no `suite PASSED/FAILED`, exit 1
  even when every step passed. Regression test: `tests/suite-summary.sh`
  (the real `cmd_suite` with stubbed steps; the old line fails 4/9 checks,
  the fix passes 9/9); confirmed live by a full passing suite.
- **A slot overlay left mounted pinned that slot during the next command —
  FIXED (2026-09-24).** `_enter_prep` only unmounted a stale overlay of the
  slot being entered, so the suite's `upgrade` (in @blue) left @blue's
  overlay mounted and `rollback` (in @green) deleted the old @blue while
  the harness still held it as lowerdir: shani-deploy's `subvolume sync`
  sat out its full 900 s timeout (rollback 925 s). Now both slots' overlays
  are unmounted before entering either (a real machine never has the
  non-booted slot mounted). That alone did not cure it: the real pin was
  `/mnt` in the builder namespace, where install.sh/configure.sh mount the
  top level and then @blue and the harness never released them (a real
  install reboots). `cmd_configure` now detaches `/mnt` after configure.sh;
  the suite's rollback went from 915 s (sync timeout) to 19 s.
- **`fresh-user` fails on images built before 2026-09-24 — expected.** It
  reports the tools, `/etc/tmux.conf`, the Nerd Font and the greeting that
  the new `shani-settings`/`shani-tools-extra`/`shani-fonts` add, and the
  dead keys (gnome-terminal/gedit/file-roller, wrong-case file chooser) that
  the new `shani-desktop-gnome` removes. It should pass once those packages
  are built and an image is rebuilt; if it doesn't, that's a real regression.

- **`usage` executed commands — FIXED (2026-09-23).** The usage text was an
  unquoted heredoc full of `backticked` names, so bash ran them as command
  substitutions: every mistyped command (and `help`) ran `pacstrap`, `ca`
  and **`gnome-shell --headless`** on the host. Found by running the shim on
  the host (libmutter output appeared in the help text). Now a quoted
  heredoc with `@PROG@` substituted by sed; re-run shows 0 executed commands.
  Keep every heredoc that contains backticks quoted.

- **`shani-install-media`'s shim needs this checkout next to it** (or
  `SHANI_TESTBED`): it is `github.com/shani8dev/shani-testbed` (created and
  first pushed 2026-09-24), cloned beside shani-install-media.
- **Native-Wayland input injection is not supported** by `app` (no
  virtual-pointer compositor in the image); apps run on X11 backends. Real
  Wayland-only apps can only be screenshotted via `desktop`.
- **`gui`'s full desktop click/type flow is still unverified end to end**
  (see shani-install-media AGENTS.md, "Fully-automated GUI test harness").
  The shared QMP client (`lib/qmp_client.py`) is verified against a real
  QEMU 8.2 QMP socket (screendump, click scaling `(400,300) → abs(10240,12288)`
  on 1280×800, key, type, move, error paths).
- **`root.img`/`esp.img`** (the `disk` command) only feed `qemu`/`gui`'s
  PXE-bound fallback and `iso`'s optional blank target. Proposal (not done):
  make `install.img` the single disk and boot ISOs via `vmspawn`.
