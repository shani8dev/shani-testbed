# Agent instructions — shani-testbed

This file applies to any AI coding assistant working in this repository
(Claude Code, opencode, Kilo Code, Cursor, Aider, or similar). Read this
before editing, and follow the verification steps before calling any change
done.

## Start here (fast path)

This file holds both the rules you must follow and a dated record
of past defects. Read what your change touches; don't page through
the rest.

**Always read these first:**
- `What this repo is` — the nspawn slots, vmspawn, and MCP server
- `Empirical verification (mandatory)`
- `Fast checks (run first; they are the floor, not the proof)`
- `Never edit a harness file while a harness run is using it`
- `Boundaries`

**Read when your change touches them:**
- `Extend the harness — don't write one-off test scripts`
- `Slot tests cannot all be unit tests — the distro is part of the contract`
- `Rules that have bitten this harness before`

**Current known issues — read this before you start:**
- `Audit-verified known issues (confirmed present)` — ~238 lines

  This section mixes fixed history with issues that are **still open**,
  including Critical security ones. Grep it for `not fixed`,
  `still open`, and your subsystem name before you touch anything.

This repo has no `AUDIT-HISTORY.md` yet, so the detail lives here. **Grep it for the subsystem you are changing**, then read
the hits in full; skip the rest.

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
tests/run-app-actions.sh        # real Xvfb + GTK4/libadwaita test of lib/app.sh + lib/a11y_client.py, in docker
tests/run-web-client.sh         # real headless Chromium test of lib/web_client.py + web_serve.py, in docker
tests/chronoa-singing-results.sh  # proves slot-tests/chronoa-singing.sh's style checks can go red (host, no docker)
```

## Extend the harness — don't write one-off test scripts

When verifying something needs a capability the harness lacks, add it
here instead of a throwaway script (scratchpad, `.verify-bin/`, a heredoc
piped into `probe --exec`):

- **an in-slot check** → a file in `slot-tests/` with a
  `# slot-test-mode: boot` header, printing `RESULT <name> PASS|FAIL` lines,
  run by `slot-test <slot> <name|all>` (one boot for many checks);
- **a new way to drive or observe** a boot, an app, a VM or a web page → a
  command option, an `app` action, or a `web_client.py` check in `lib/`,
  documented in `usage` + README, with a negative control in its self-test
  (`tests/run-app-actions.sh`, `tests/run-web-client.sh`);
- **a repeatable walk through a real app** → an `app-scripts/<app>.actions`
  file (`cassini-tour.actions`), run with `app --script=`;
- **a check of the harness itself** → `tests/`.

A test that only exists in one session's scratchpad is lost the moment the
session ends, and the next agent re-derives it.

## Slot tests cannot all be unit tests — the distro is part of the contract

`slot-tests/chronoa-machine-state.sh` exists because of a specific, repeated
failure, and the reason generalises to anything in `shani-chronoa/senses/`.

**The senses were written and unit-tested on an Ubuntu 24.04 dev box. ShaniOS
is Arch-based.** Four of the eleven senses shell out to a binary and one asks
the package manager a distro-specific question, so the unit suite cannot speak
to them at all. Three were green while returning a confident wrong answer on Arch:

- `contention` reported every camera and microphone **free** when `fuser`
  (psmisc) was missing — the OSError was swallowed into "no holders";
- `privilege` used Debian's `dpkg-query`, so on Arch it found no owner for
  anything and reported **every process as unmanaged third-party software**;
- `bluetooth` reported "0 devices" when `bluetoothctl` was not installed.

584 passing unit tests caught none of it. A green suite on the wrong
distribution is not weak evidence about the right one — it is no evidence, and
the three failures were all *plausible* rather than loud.

**So a sense test that touches a distro-specific dependency belongs here, not
in `tests/`.** The test asserts the eleven senses register, that all eleven
consent keys are in the *running compiled* schema, that consent genuinely
refuses, and the two properties this class of bug violates: a sense must not
report UNKNOWN while its dependency **is** installed, and must never call a
device "free" while undetermined.

**The count is derived from a list for that reason, and it is still not
self-maintaining — so the failure mode is a sense with no slot coverage at
all.** `hwmon` and `modelfit` were added to the registry and were simply
absent from `SENSES=(...)` here, which is the same rot as the overlay banner's
hardcoded key count: a literal that adding a sense does not update. A sense
missing from that list is a sense that regresses to a plausible wrong answer
the first time it is touched on Arch, while this file reports a comfortable
pass. Check the list against the registry, not against this paragraph.

**A sense with no external dependency makes the generic step unanswerable, and
the honest result is SKIP.** `hwmon` and `modelfit` read `/sys` and
`/proc` directly, so no missing tool can account for an UNKNOWN from them —
and the loop has no way to know whether the UNKNOWN was legitimate. It
therefore reports SKIP rather than a verdict, and `modelfit` gets a dedicated
check below it, because its UNKNOWN has a nameable cause (Ollama not
answering). Two earlier versions of that branch were wrong and both looked
fine: one asserted a *reason* for the UNKNOWN that was not true, and one
required a 3+ digit number as proof the sense had read something, which fails
`senses` whose real readings are all one or two digits (`rfsense` legitimately
reports `link=70/70 level=-29dBm`). Neither a confident PASS nor a confident
FAIL is available here; say so instead of guessing.

**Status: run and green — 42 pass, 0 fail, rc=0** (2026-09-28) on a real
booted slot (`@blue`, testbed `9be7139`, Chronoa overlaid from `d6b0362` and
packaged as `shani-chronoa 0.1.0-6`), after a full `bootstrap -p gnome -d
latest`. The decisive lines:

```
RESULT privilege-uses-package-manager  PASS (18 further holder attributed to
  distribution packages, so the ownership lookup is actually working)
```

which is exactly the assertion that would have failed before the Arch fix,
and the modelfit pair that the dedicated check added:

```
RESULT modelfit-ollama-unknown-honest  PASS (Ollama did not answer and the
                                  sense said UNKNOWN rather than claiming a count)
RESULT modelfit-hardware-half-still-real PASS (31795 MB RAM total, 25656 MB
                                  available - the kernel half read fine even
                                  though Ollama did not answer)
```
Run it with the invocation already documented under "Running it for real"
below — that section carries the `--cgroupns=host` and extra-`-v` details, and
they apply unchanged to this test.

One harness fix came out of the same run: the overlay banner hardcoded "all
five *-sense-enabled consent keys" and had gone stale. It now counts the keys
it just read out of the compiled schema, and `slot-tests/chronoa-senses.sh`
derives its count from the list it checks, so neither can rot silently again.

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

- ✅ **Always**: pre-seed `cache/pacman_cache/pkg` from the workspace's
  existing caches before a first `vmspawn` run — it is created **empty**.
  `lib/vmspawn.sh` sets `pacman_cache="${REPO_ROOT}/cache/pacman_cache/pkg"`
  (`:60`), `mkdir -p`s it (`:65`), bind-mounts it at `/var/cache/pacman/pkg`
  (`:73`), and then installs `qemu-base edk2-ovmf swtpm openssh` (`:86`). As
  checked on 2026-09-26, that directory does not exist in this repo, so the
  mount is empty and the first run downloads all four — while every one of
  them is **already** in the sibling caches: `qemu-base` (4 files),
  `edk2-ovmf` (2), `swtpm` (1), `openssh` (1) in
  `shani-install-media/cache/pacman_cache/pkg` (6.0G) and
  `shani-pkgbuilds/cache/pacman_cache/pkg` (3.2G). Symlink those package
  files in rather than copying them. The same two caches cover the full KDE
  Plasma stack, so anything else that runs `pacman -S` in a container should
  mount one too — a from-scratch Plasma install dropped from ~2G of downloads
  to 681 MiB with them mounted. See the parent `AGENTS.md` for the full list.
- ✅ **Always**: verify by running the real command; keep every existing
  `build.sh test <cmd>` interface (commands, flags, env vars, paths) working,
  since other repos' AGENTS.md files and CI call them.
- ⚠️ **Ask first**: changing where state lives (`test-env/disk/`), adding a
  host-side privileged step, or anything that injects input into the HOST
  display (`app --display=host`).
- 🚫 **Never**: point `app`/`gui` input at a real user session by default;
  disable the graceful-shutdown path; commit anything from `test-env/disk/`.

## Audit-verified known issues (confirmed present)

- **`--crawl=N` reported PASS having crawled nothing, and the real docs site hit
  it (2026-10-01).** Found while verifying a `shani-docs` change: the run said
  `RESULT crawl PASS (0/0 same-origin pages clean)` and I read it as a pass.
  It is not one. `crawl()` collects `a[href]` from the start page, and
  **`shani-docs` and `shani-blog` navigate with `<button onclick="navigate(...)">`
  — the home page's cards and quick-links have no `href` at all**, so the crawl
  collected nothing, examined nothing, and reported the confidence of a green
  check. Same class as every other absence-shaped green in this workspace's
  history, and the reason CI's `--crawl=20` was doing nothing for the two sites
  most likely to need it.
  Two fixes, both needed. `crawl()` already had a `sitemap.xml` fallback for
  exactly this shape (untracked, added earlier the same day), so the docs site
  now reports `PASS (20/20 … from sitemap.xml: the start page has no
  same-origin <a href> page)`. That fallback cannot rescue a site with **no**
  sitemap, so **zero pages crawled is now a FAIL**, with the detail naming the
  cause rather than just going red — the message says a link that navigates via
  `onclick` rather than `href` is invisible to the crawler, so the failure is
  actionable instead of mysterious.
  The fixture is `tests/web-fixtures/anchors-but-not-links/`: real markup, no
  sitemap, destinations as buttons. **Both new assertions were run against the
  un-guarded client and both failed** (`88/90`; the run reported
  `PASS (0/0 same-origin pages clean)`) — so they are holding the guard and not
  merely the sitemap's presence. Suite **91/91** with it.
  The lesson generalises past this check: **`0/0` in a detail string is a
  result that examined nothing, so treat a zero as a failure unless the check
  has a stated reason to be vacuous.**

- **Plain nspawn boots do not reproduce `systemd.volatile=state` (2026-10-01).**
  Every real ShaniOS boot has an empty tmpfs `/var`; nspawn shows the image's
  whole `/var`. So every slot-test until then ran with package-shipped `/var`
  directories present that real machines never have - smb/nmb/winbind,
  rpc-statd, libvirtd and **AppArmor** (the snap-confine profile includes
  `/var/lib/snapd/apparmor/snap-confine`) failed on every fresh install and no
  slot-test could see it. `slot-test --volatile` boots with `/var` a tmpfs (`--tmpfs=/var`; nspawn's
  `--volatile=state` would also make `/etc` read-only, which ShaniOS's is not);
  slot-tests that need pacman read the db from the slot's subvolume
  (`slot-tests/_pacdb.sh`). The fix (shani-install-media
  `scripts/gen-var-tmpfiles.sh`) was verified on a real UEFI boot with
  `iso-install --boot-only --console-exec`. Default is still non-volatile:
  run `service-start`, `unit-verify` and anything `/var`-touching both ways.
- **GTK4 AT-SPI coordinates (fixed 2026-10-01).** GTK 4.22 reports `SCREEN`
  extents as `0,0` for every widget (it cannot know its window's position);
  only `WINDOW` extents are real, relative to the frame (itself at -5,-5, the
  CSD shadow margin). `click-element` and `monkey` clicked the window's
  top-left on every GTK4 app (Cassini, Chronoa). `a11y_client.extents()` maps
  WINDOW coordinates through the X window origin for GTK 4. The self-test
  drove a GTK3 yad dialog, whose SCREEN extents are right, so it never showed
  - it now drives `tests/fixtures/adw_fixture.py` (libadwaita, Cassini's
  widgets). Keep the fixture GTK4.
- **`iso-install --boot-only` firmware state (fixed 2026-10-01).** (1) It
  booted a disk `bootstrap` had re-created with the previous iso-install's
  NVRAM and TPM; now a changed disk (inode) gets fresh ones, and
  `--reset-firmware` forces it. (2) swtpm drops capabilities, so it could not
  read a 0640 `tpm2-00.permall` owned by another uid: every boot after the
  first failed `CMD_INIT: 0x101`. The state dir is chowned to the running uid
  before swtpm starts, and a TPM-side qemu failure now prints swtpm.log. (3) A
  leftover `swtpm.log` from another uid made swtpm exit at once.
- **`app` against GTK4 apps on the virtual display (fixed 2026-10-01).** No
  window manager runs there, so (1) a window larger than the display stays
  larger - Cassini opened 1280x1100 on 1280x800 and half its sidebar sat below
  the screen; `wait-window` now fits such windows to the display, as a WM
  would - and (2) GTK4 has no AT-SPI `scroll_to`, so `click-element` on an
  off-screen element now falls back to focusing it (GTK4 scrolls a focused
  child into view), then to the mouse wheel. `monkey` skips Close/Quit-named
  controls: ending the app is their job, not a crash.
  `tests/run-app-actions.sh` covers both (Item 40 in a scrolled list).
- **`web` measured overflow against `innerWidth` (fixed 2026-10-01).** On a
  mobile viewport innerWidth GROWS with the overflow (898 on a 390px phone),
  so a page twice the screen's width passed. It is `clientWidth` now, and the
  self-test's broken fixture has a page that only that catches.
- **`desktop --tour` on GNOME runs gnome-shell as root (open).** As root,
  GNOME 50 shows a "privileged user" banner (the tour clears it) and has no
  screen shield, so the lock-screen step is SKIP. A fresh-user session (as
  the Plasma path does) produced 0-byte screenshots from the Screenshot API
  - render-node access or the API's caller checks as a user, not yet
  resolved. Until it is, the GNOME desktop is checked as root.
- **`repo-pytest` (2026-10-01): give the Broadway daemon and every suite one
  `XDG_RUNTIME_DIR`.** The socket is looked up under it (else `~/.cache`);
  with a per-suite HOME and no shared runtime dir GTK had no display and the
  first widget segfaulted. A crashing suite is now reported with the test
  that was running.
- **Feature checks (`lib/web_features.py`) - pitfalls already paid for:**
  re-find an element by its `data-sf-pick` tag, never by a selector string
  (several share one); measure a theme at the top of the page (a reload
  restores the scroll position); judge each colour scheme on a FIRST visit
  (clear storage, set the media feature, reload - a saved choice wins, and
  sites read the preference once at load); disable transitions when comparing
  a focused look with an unfocused one; parse `color(srgb ...)` channels as
  0-1; clip text boxes to their clipping ancestors before calling it overlap.
- **Two harness runs on one disk corrupt shared state** - now refused:
  `disk/.testbed.lock` (flock) is taken by every disk-touching command.
- **TCG guests stall under host load.** With Chrome/Docker work on the same
  CPUs a firmware boot sat 30 min in `calibrate_delay_direct()` after `tsc:
  Unable to calibrate against PIT` and timed out. Keep the host idle during
  `iso-install`/`vmspawn` under TCG; a timeout there is not evidence about the
  image until rerun on an idle host.
- **`bootstrap -d latest` is the LOCAL build, not the published image.**
  Without `--from-r2` it installs `cache/output/<profile>/latest.txt` - on
  2026-10-01 a month-old 20260821 build (shani-deploy 62) while R2's
  latest was 20260925 (87). Overlaying current units onto it failed
  mark-boot-success (it calls a script that image predates). To test what
  users run: `bootstrap -p <p> -d latest --from-r2`; check with
  `enter <slot> cat /etc/shani-version`.
- **R2 sidecars are re-fetched every time (fixed 2026-10-01).** R2 downloads
  share `cache/output/<p>/<date>/` with local builds, and `_r2_get` skips
  files that exist: a local build's `.sha256` was trusted forever, so the
  real image failed its check and was deleted on every run.

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

- **Chronoa has no testbed coverage yet — ADDED (2026-09-27).** `lib/chronoa.sh`
  is a Chronoa **source** overlay (`--local-src-chronoa=<dir>`, also
  `SHANIOS_TEST_CHRONOA_SRC=<dir>`) accepted by `app`, `slot-test`, `enter`,
  `probe` and `desktop`; it overlays a checkout's `usr/bin` launchers, the
  Python package and the gsettings schema, recompiles the schema in place, and
  reverts on the next run like `--local-src`. `slot-tests/chronoa-senses.sh` is
  the acceptance test for the senses layer, and `tests/chronoa-overlay.sh` is
  the fast host self-test of the overlay itself. Verified live against a real
  booted slot: 15/15 checks pass, including real tesseract OCR over a real
  generated PNG. See README.md, "Testing an unpackaged app: `--local-src-chronoa`".

  Two harness bugs this work found and fixed, both real and both confirmed in
  the slot before fixing:

  - **`slot-test` accepted no `--local-pkg`.** Every other slot-booting
    command (`app`, `desktop`, `enter`) parses it; `cmd_slot_test`'s arg loop
    fell through to `--*) die`, so the tesseract stack could never be got into
    a booted slot. Wired onto `SHANIOS_TEST_LOCAL_PKGS` so `_enter_prep`
    applies it through the same path as everything else.
  - **A slot-test has no session D-Bus, so gsettings writes silently no-op.**
    `_ensure_dbus` starts only a SYSTEM bus for nspawn itself, and dconf is a
    session-bus service, so `shani-chronoa-sense enable <sense>` printed
    "ocr-sense-enabled = true (enabled)" and then failed to commit — the same
    `run` the test had just "enabled" was refused with exit 4, so the
    PASS/FAIL pair could not both be green in any environment. Fixed by
    running each slot-test inside `dbus-run-session`, the same mechanism
    `desktop` already uses for exactly this reason. Confirmed live: before the
    fix `enable ocr` → `gsettings get` → `false` → `run ocr` → exit 4; after,
    `true` → `ok: true`.

  Two findings about `shani-chronoa` itself, reported here rather than patched
  (this harness does not modify that repo):

  - **`shani-pkgbuilds/shani-chronoa/PKGBUILD` declares neither `tesseract`
    nor `tesseract-data-eng`**, so no published image ships tesseract and the
    ocr sense is unusable as packaged. `shani-install-media/image_profiles/*/
    Packages-Desktop` does pin `tesseract-data-eng`, so a freshly built image
    gets the data but not the binary — both halves are needed. Supply them for
    a test with `--local-pkg=...` (the recorded evidence used
    `tesseract-5.5.3-1`, `tesseract-data-eng-2:4.1.0-5`,
    `tesseract-data-osd-2:4.1.0-5` and `leptonica-1.87.0-2` from the pacman
    cache).
  - **`shani-chronoa-sense percepts` has no `--durable-file` flag** (only
    `--json`). It is a `run`/`forget` option, not a percepts one — the
    slot-test asserted it and reported a harness defect. `--durable-file` on a
    `run memory` is also a known no-op (the memory sense holds its own store),
    which chronoa's own `AGENTS.md` records; the slot-test deliberately does
    not assert that as expected behaviour.

  **`run_in_container.sh` DOES mount the chronoa checkout** — at `/opt/shani-chronoa:ro`.
  This line used to say the opposite, and the hand-rolled `docker run` block below
  existed only because of that false claim. `run_in_container.sh:316` loops over
  `shani-cassini shani-chronoa shani-backup shani-docs shani-blog shani-website
  shani-wiki` and bind-mounts each sibling that exists, so the plain invocation is
  all you need:

  ```bash
  cd ../shani-install-media
  SHANIOS_NO_PULL=1 ./run_in_container.sh build.sh test slot-test blue chronoa-speech \
    --local-src-chronoa=/opt/shani-chronoa --timeout=300 --settle=10
  ```

  Verified 2026-10-01: **11 pass, 0 fail** on `@blue`. If you do drive the container
  yourself, `SHANIOS_TEST_CHRONOA_SRC=<dir>` still works and is equivalent.

  ### `chronoa-singing`: the label has to be earned, and proved able to go red

  `slot-tests/chronoa-singing.sh` had a stage named *"a sung line in a soothing
  voice"* that sang a line, printed PASS, and never touched `voice_style` at
  all — the label described an effect the output did not have. The stage now
  applies the `soothing` preset (`equalizer 180 1.0q +2.16`,
  `equalizer 3500 1.0q -1.20`) to the sung WAV and **measures** it with a
  Goertzel filter at those two frequencies (no numpy on the image, and a
  two-band EQ needs no FFT). Two changes came with it, both found by running:

  - **The gate under-implemented its own comment.** The comment promised a skip
    unless kokoro, consent *and* a transposer were all present; the code checked
    only the first two, so the stage could report singing on an image where
    per-note pitch was impossible. All three are checked now, and the tone stage
    skips on a missing transposer rather than reporting *"per-syllable pitch did
    not move as the plan says"* — a confident wrong answer, since the plan was
    never attempted.
  - **An empty style is a regression, not a limitation.** If `soothing` resolves
    but asks for nothing, the stage says FAIL, not SKIP: a SKIP would be the
    absence-shaped green this repo keeps being bitten by, printing the same line
    for a slot with no style and for a slot whose style silently stopped
    applying.

  The stage carries its own negative control in-band: the same measurement is
  re-run with the **opposite** preset (`bright`, +2.56 dB at 3500 Hz) and has to
  move 3500 Hz the other way. Without it, "the bands moved" could just mean SoX
  ran.

  Verified live on `@blue` (`shanios-20260925-gnome`, Chronoa overlaid, kokoro +
  soundstretch + sox present): **4 pass, 0 fail**, with
  `low180=1.28x high3500=0.87x control3500=1.40x` — the same class of numbers the
  presets ask for.

  `tests/chronoa-singing-results.sh` proves those assertions can fail, against a
  stubbed slot with the *real* package on `PYTHONPATH` (24 pass, 0 fail). It is
  the second half of `chronoa-speech-results.sh`'s argument: a pass proves the
  check ran, not that it can say no. Scenarios: a pass-through sox and an
  exit-0-but-writes-nothing sox both go red; the control goes red with them; no
  kokoro, consent off and no transposer each SKIP naming their own cause and emit
  no FAIL (so `cmd_slot_test`'s `pass == 0` rule cannot fire on a stock image);
  and a doctored `voice_style` with a neutralised `soothing` FAILS. Consent is
  read through a **real compiled GSettings schema** (the checkout's own XML with
  one default flipped), not a gsettings stub.

  Two things about writing it, both worth not re-deriving:

  - **sox is stubbed, and the stub has to be faithful in a way that is easy to
    get wrong.** The `equalizer` stub is a forward FFT, a Gaussian band gain of
    width f0/Q, and an inverse FFT. It was a biquad first, written from the
    cookbook, and it produced **−39 dB at 30 Hz** for a "peaking" EQ at 180 Hz —
    a high-pass. The stage then reported the soothing style as ineffective at
    180 Hz: true of the stub, false of the product. It also has to preserve
    *duration* (resample **plus** overlap-add time-stretch), because the tone
    stage measures each note at the time it was asked for and a shortening stub
    reads the last note of a rising run as −19 semitones against a +6 plan.
  - **A missing tool in the harness reads exactly like a broken product.** The
    first version's `TOOLS` list omitted `tail`, which the slot-test pipes its
    stage output through, and every stage reported an empty verdict and four
    FAILs that had nothing to do with the stub under test. Same family as the
    `usage` heredoc that once ran `pacstrap` on the host.

  ### Two harness-rot failures found by the self-test on 2026-10-02 — FIXED

  `tests/chronoa-speech-results.sh` (the file whose whole job is proving
  `slot-tests/chronoa-speech.sh` can fail) went red at **76 pass, 4 fail**.
  Neither failure was a Chronoa defect; both were the harness asserting
  against literals that upstream had legitimately moved on from, which is the
  same rot as the hardcoded sense count in `chronoa-senses.sh`.

  - **`shani_chronoa/app.py` became the package `shani_chronoa/app/`**
    (`application.py` inside it). The slot-test still grepped
    `${CHRONOA_LIB}/shani_chronoa/app.py` for the STT warning string, so it
    reported the string **ABSENT on a checkout that still contained it** — a
    harness bug wearing a product bug's clothes, and the most expensive kind
    to debug because every layer above it reads as a Chronoa regression. It
    now resolves the module with `importlib.util.find_spec` and searches the
    package directory (`submodule_search_locations`, since a package's
    `origin` is only its `__init__.py` — searching that alone is the same bug
    one level down). `find_spec` rather than an import, because importing
    `shani_chronoa.app` needs PyGObject, which is why `app-imports-clean` is
    in `HOST_ONLY` in the first place. **The pacman `-Qql` stub was updated
    to the real layout too** — it was advertising a fictional `app.py`, which
    is what let the hardcoded path look right in the self-test and be wrong in
    a real slot.
  - **The espeak-ng stub assertion pinned the whole argv literal**
    (`espeak-ng --stdin -v en-us -w`). Upstream `tts.py` added the female
    voice variant and the rate flag, so the real call is
    `espeak-ng --stdin -v en-us+f3 -s 175 -w <out>` and the pinned literal
    reported "the stub was never invoked" about a stub that had just run.
    Asserted by **shape** now (`--stdin`, a `-v` voice, `-w` out), which is
    what the WAV assertions actually depend on and survives a voice or rate
    change.

  **Both fixes were run against their controls, not just observed passing.**
  Reintroducing the hardcoded path turns the new guard red *and names the
  line* (`426: app_src="${CHRONOA_LIB}/shani_chronoa/app.py"`) while the STT
  check itself goes red again; restoring the pinned espeak literal reproduces
  its failure with the true argv printed in the reason. Against a doctored
  copy of the package with the warning string genuinely removed, the resolved
  location correctly yields no match — so the assertion is not a rubber stamp.

  Three permanent checks were added to the self-test for the class itself, not
  just this instance: **no `CHRONOA_LIB}/shani_chronoa/<file>.py` literal may
  appear in the slot-test** (resolve it with `find_spec` or `pacq -Qql`);
  `find_spec` must resolve `shani_chronoa.app` to something real on the
  current checkout; and the warning string must actually be present where it
  says the module lives. The second and third are the control for the first —
  without them, a slot-test that resolved nothing at all would satisfy it.
  Suite **83/83** with them; the whole floor (`run-app-actions` 30/30,
  `run-web-client` 95/95, `run-chronoa-ui` 12/12, `gate-flow`,
  `iso-install-runner`, `serve-port-guard`, `suite-summary`, `chronoa-overlay`
  9/9, `update-check`) green.

  **The generalisable lesson, and it is the second time this repo has paid
  it:** a check that names a *file* inside a package its neighbours refactor
  will fail as a false product bug, and a check that pins a *whole command
  line* will fail when a flag is added. Resolve by import system or package
  manager, and assert on the shape of an interface rather than its exact text.
  Neither failure was loud in the way this repo's rules care about — both
  reported confident, specific, wrong verdicts.

  ### Running it for real (verified 2026-09-27: 15 pass, 0 fail)

  `run_in_container.sh` has no flag for the extra mount and no flag for
  tesseract, so the passing run drives the same container itself. This is
  the whole invocation; only the two `-v` lines and the `--local-pkg` set
  are specific to chronoa, the rest mirrors `run_in_container.sh` verbatim:

  ```bash
  cd ../shani-install-media
  PKG=/var/cache/pacman/pkg
  docker run --rm --privileged --network=host --cgroupns=host \
    --tmpfs /tmp --tmpfs /run/lock --tmpfs /run \
    --cap-add SYS_ADMIN --security-opt apparmor:unconfined \
    --security-opt seccomp:unconfined \
    -v /sys/fs/cgroup:/sys/fs/cgroup -v /lib/modules:/lib/modules:ro -v /dev:/dev \
    -v "$PWD:/home/builduser/build" \
    -v "$PWD/cache/pacman_cache:/var/cache/pacman" \
    -v ../shani-testbed:/opt/shani-testbed:ro \
    -v ../shani-pkgbuilds:/opt/shani-pkgbuilds:ro \
    -v ../shani-chronoa:/opt/shani-chronoa:ro \
    -e SHANIOS_TEST_CHRONOA_SRC=/opt/shani-chronoa -e SHANIOS_NO_PULL=1 \
    -w /home/builduser/build shrinivasvkumbhar/shani-builder:latest \
    bash -c '/opt/shani-testbed/testbed slot-test blue chronoa-senses \
      --local-src-chronoa=/opt/shani-chronoa \
      --local-pkg='"$PKG"'/tesseract-5.5.3-1-x86_64.pkg.tar.zst \
      --local-pkg='"$PKG"'/tesseract-data-eng-2:4.1.0-5-any.pkg.tar.zst \
      --local-pkg='"$PKG"'/leptonica-1.87.0-2-x86_64.pkg.tar.zst \
      --timeout=300 --settle=10'
  ```

  Three things this run proved that a passing assertion alone would not:

  - **Without `--local-pkg` the test fails 4 assertions, and the failure is
    the finding, not a broken test.** tesseract is genuinely absent from the
    image; the test names both causes rather than skipping. Supplying the
    three packages turns those 4 into passes. That is the difference between
    "the ocr sense has unit tests" and "the ocr sense reads a real PNG".
  - **The consent refusal is real, not simulated.** `run ocr` with the key
    off exits 4 and says `refusing to run sense 'ocr': the ocr sense is
    turned off` — the negative control runs *before* the positive one, which
    is what makes the positive result mean anything.
  - **The overlay's schema step is verified through the running system.**
    All five `*-sense-enabled` keys are read back out of
    `GSETTINGS_SCHEMA_DIR` in the booted slot, not out of the XML — the
    failure mode where `glib-compile-schemas` exits 0 having written nothing
    is invisible otherwise.

  Without tesseract the 4 failures are `tesseract-binary-present`,
  `tesseract-eng-data`, `ocr-text-recognized` and `ocr-word-boxes`. Note
  `ocr-negative-control` passes *vacuously* in that state — both images
  return the same "not installed" error, so the first string's tokens are
  trivially absent. Do not read that pass as evidence the control works; it
  only means something once tesseract is present.
