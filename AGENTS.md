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
  against the live servers' keys on 2026-09-24: all 6 match). **This repo
  itself is still not under git** (no `.git`): nothing here has history or a
  backup until someone runs `git init` and commits.
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
  non-booted slot mounted).
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

- **The GitHub remote does not exist yet.** This repo was created locally;
  a human needs to create `shani8dev/shani-testbed` and push. Until then,
  `shani-install-media`'s shim needs this checkout next to it (or
  `SHANI_TESTBED`).
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
