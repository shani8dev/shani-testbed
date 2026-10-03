# lib/chronoa.sh — a Chronoa SOURCE overlay for testing an unpackaged app.
#
#   --local-src-chronoa=<dir>       (or SHANIOS_TEST_CHRONOA_SRC=<dir>)
#
# Why this exists, and why it is not just --local-pkg / --local-src:
#
#   * `--local-src=<dir>` overlays `<dir>/*.sh` onto /usr/local/bin scripts the
#     image already ships. shani-chronoa is not a shell-script app.
#   * `--local-pkg=<name|file>` overlays a BUILT .pkg.tar.zst. That works, but
#     it can only ever test what a PKGBUILD packages — and the senses layer is
#     exactly the part of shani-chronoa that no published package has yet:
#     `shani-chronoa-sense` and `senses/` are new, and a source overlay is what
#     lets the harness drive them in a REAL slot today, before any republish.
#
# So this overlays the checkout's own `usr/` tree (the same layout the Arch
# PKGBUILD copies out of it) into the slot's overlay upper layer, exactly like
# --local-src and --local-pkg do, and records every path it writes so
# _revert_local_src_overlay undoes it at the start of the next run.
#
# The GSettings schema is the load-bearing part. The image's
# /usr/share/glib-2.0/schemas/gschemas.compiled is a binary blob baked at
# package-install time; dropping a new .xml next to it changes NOTHING, because
# nothing recompiles it. Chronoa's consent keys (`ocr-sense-enabled` and
# friends) live in that XML, and the CLI refuses a sense whose key the RUNNING
# schema does not declare. So this overlay recompiles the schema directory
# itself, and records gschemas.compiled for revert too (deleting it from upper/
# makes the image's own compiled blob visible again — see
# _revert_local_src_overlay).
#
# glib-compile-schemas is all-or-nothing: one invalid XML discards the whole
# directory and still exits 0, which is how chronoa's own AGENTS.md records
# losing every setting silently once. So the compile here is checked, not
# assumed: a non-zero exit dies with the compiler's own stderr, and the
# acceptance check in slot-tests/chronoa-senses.sh independently re-reads the
# compiled schema's keys rather than the XML's.
#
# Usage from a caller (each of these also accepts the flag directly):
#   app blue --local-src-chronoa=/opt/shani-chronoa --run="shani-chronoa-sense list"
#   slot-test blue chronoa-senses --local-src-chronoa=/opt/shani-chronoa
#
# run_in_container.sh mounts the sibling checkouts read-only at fixed paths
# (/opt/shani-testbed, /opt/shani-pkgbuilds, /opt/shani-deploy,
# /opt/os-installer-config). It does NOT mount shani-chronoa, so in the builder
# container you must either pass a path that exists in there, or bind the
# checkout in yourself. See AGENTS.md, "Chronoa has no testbed coverage yet".

CHRONOA_SCHEMA_ID="org.shani.chronoa"
# Where the checkout's usr/ tree lands in the slot, and the one path inside it
# that proves this really is a chronoa checkout rather than any random usr/.
CHRONOA_PKG_REL="usr/lib/shani-chronoa/shani_chronoa"

# What every --local-src-chronoa= option ultimately does. A shared helper
# rather than five copies of the same string concatenation: the option has to
# mean the same thing in five commands, and last-wins is the sane rule (a
# caller who passes it twice is pointing at one checkout, not two).
# Usage: _set_chronoa_src <dir>
_set_chronoa_src() {
  SHANIOS_TEST_CHRONOA_SRC="$1"
  export SHANIOS_TEST_CHRONOA_SRC
}

# Resolves the source checkout, in the order the operator would expect:
#   1. an explicit --local-src-chronoa=<dir>
#   2. $SHANIOS_TEST_CHRONOA_SRC (what run_in_container.sh forwards, and what
#      CI can set)
#   3. /opt/shani-chronoa — the builder-container convention, matching
#      /opt/shani-testbed and /opt/shani-pkgbuilds
#   4. ../shani-chronoa next to this repo — the host-side sibling, for running
#      the harness directly instead of through run_in_container.sh
#
# An EXPLICIT path is authoritative and is never allowed to fall through to a
# different checkout. Caught by tests/chronoa-overlay.sh: with a deliberately
# wrong --local-src-chronoa= pointing at a directory that is not a Chronoa
# checkout, the search happily continued and returned the real sibling one
# instead — the exact "a typo'd path silently no-ops and looks like it worked"
# failure this harness has been bitten by before. When the caller named a
# directory, that directory is the only candidate.
# Echoes the directory, or returns 1 (with the list it tried) if none is one.
_chronoa_src_dir() {
  local explicit="${1:-}" c
  if [[ -n "$explicit" ]]; then
    if [[ -f "${explicit}/${CHRONOA_PKG_REL}/__init__.py" ]]; then
      (cd "$explicit" && pwd)
      return 0
    fi
    echo "--local-src-chronoa=${explicit}: no ${CHRONOA_PKG_REL}/__init__.py in it" >&2
    return 1
  fi
  for c in "${SHANIOS_TEST_CHRONOA_SRC:-}" /opt/shani-chronoa "${TESTBED_ROOT}/../shani-chronoa"; do
    [[ -n "$c" ]] || continue
    if [[ -f "${c}/${CHRONOA_PKG_REL}/__init__.py" ]]; then
      (cd "$c" && pwd)
      return 0
    fi
  done
  echo "no Chronoa checkout found (looked at \$SHANIOS_TEST_CHRONOA_SRC, /opt/shani-chronoa and ${TESTBED_ROOT}/../shani-chronoa)" >&2
  return 1
}

# Copies one file into the merged slot view and records it for
# _revert_local_src_overlay, the same way _overlay_one does.
#
# Deliberately WITHOUT _overlay_one's "only replace a file the image already
# ships" gate. That gate is right for --local-src: there, a name that is not in
# the image is indistinguishable from a typo, and a typo that silently no-ops
# looks exactly like a fix that worked. It is wrong here, because introducing
# the app IS the point — the image may ship no Chronoa at all, and requiring
# SHANIOS_TEST_ALLOW_NEW_LOCAL_SRC=1 for the normal case would make the
# documented invocation fail. The typo protection that actually matters is kept
# instead: the checkout is validated as a real Chronoa tree up front
# (_chronoa_src_dir), and every path written is recorded, so the whole overlay
# reverts cleanly and a wrong directory is loud, not silent.
# Usage: _chronoa_overlay_file <src> <dest-in-merged> [mode]
_chronoa_overlay_file() {
  local src="$1" dest="$2" mode="${3:-}" rel
  mkdir -p "$(dirname "$dest")"
  cp -f "$src" "$dest"
  [[ -n "$mode" ]] && chmod "$mode" "$dest"
  rel="${dest#"${NSPAWN_WORK}/merged/"}"
  echo "$rel" >> "$(_local_src_record)"
  log "  ${src} -> /${rel}"
}

# Copies a directory tree, skipping bytecode.
_chronoa_overlay_tree() {
  local src="$1" dest="$2" n=0 f base rel
  [[ -d "$src" ]] || return 0
  # find on the absolute path, NOT `cd "$src" && find .`: the cd happens in the
  # process substitution's own subshell, so the parent never moved and every
  # `cp "$f"` failed with "cannot stat './shani_chronoa/...'". Found by
  # tests/chronoa-overlay.sh, which copies nothing and passes otherwise.
  while IFS= read -r -d '' f; do
    rel="${f#"${src}/"}"
    # Bytecode from the developer's machine must never reach the slot: a .pyc
    # built by a different Python would either be ignored or, worse, be the
    # stale copy that wins over the .py just overlaid. Chronoa's own AGENTS.md
    # records 14 committed .pyc files as a shipped bug once already.
    case "$rel" in __pycache__/*|*/__pycache__/*|*.pyc) continue ;; esac
    base="$(basename "$f")"
    mkdir -p "${dest}/$(dirname "$rel")"
    cp -f "$f" "${dest}/${rel}"
    chmod 644 "${dest}/${rel}"
    echo "${dest#"${NSPAWN_WORK}/merged/"}/${rel}" >> "$(_local_src_record)"
    n=$(( n + 1 ))
  done < <(find "$src" -mindepth 1 \( -type f -o -type l \) -print0)
  log "  ${src} -> ${n} file(s) under ${dest#"${NSPAWN_WORK}/merged/"} (bytecode skipped)"
  return 0
}

# Removes any bytecode already sitting in the target library directory and
# records it, so a stale .pyc in the image cannot shadow the overlaid source.
# Deleting through the merged overlay creates a whiteout in upper/, and
# _revert_local_src_overlay's `rm -f upper/<path>` removes the whiteout — the
# image's own file becomes visible again. Same mechanism, opposite direction.
# Hides the image's modules the checkout no longer has, the same way: an old
# skills/scan_archive.py from the installed package stayed importable over a
# checkout without it ("Skipping 'builtin:scan_archive': SKILLS must be a
# list"), so the slot ran a mix of two versions.
_chronoa_strip_stale() {
  local src="$1" lib="$2" n=0 f rel
  [[ -d "$lib" && -d "$src" ]] || return 0
  while IFS= read -r -d '' f; do
    rel="${f#"${lib}/"}"
    [[ -e "${src}/${rel}" ]] && continue
    rm -f "$f"
    echo "${f#"${NSPAWN_WORK}/merged/"}" >> "$(_local_src_record)"
    n=$(( n + 1 ))
  done < <(find "$lib" -type f -name '*.py' -print0 2>/dev/null)
  (( n == 0 )) || log "  hid ${n} module(s) the image has and the checkout does not (reverted next run)"
  return 0
}

_chronoa_strip_bytecode() {
  local lib="$1" n=0 f rel
  [[ -d "$lib" ]] || return 0
  while IFS= read -r -d '' f; do
    rel="${f#"${NSPAWN_WORK}/merged/"}"
    rm -f "$f"
    echo "$rel" >> "$(_local_src_record)"
    n=$(( n + 1 ))
  done < <(find "$lib" \( -type f -name '*.pyc' -o -path '*/__pycache__/*' \) -print0 2>/dev/null)
  (( n == 0 )) || log "  removed ${n} stale bytecode file(s) from the slot's ${lib#"${NSPAWN_WORK}/merged/"} (reverted next run)"
  return 0
}

# _overlay_chronoa_src <slot> <dir>
# The real work. Called from _enter_prep (so every command that mounts the
# merged slot gets it, exactly like SHANIOS_TEST_LOCAL_PKGS) whenever
# SHANIOS_TEST_CHRONOA_SRC is set.
_overlay_chronoa_src() {
  local slot="$1" src_dir="$2"
  local merged="${NSPAWN_WORK}/merged"
  src_dir="$(_chronoa_src_dir "$src_dir")" \
    || die "--local-src-chronoa: ${src_dir} is not a Chronoa checkout (need ${CHRONOA_PKG_REL}/__init__.py in it)"

  command -v glib-compile-schemas >/dev/null 2>&1 \
    || die "--local-src-chronoa needs glib-compile-schemas in the builder container (package glib2) to rebuild gschemas.compiled — the overlay's consent keys would be dead XML otherwise"

  log "Overlaying Chronoa sources from ${src_dir} onto @${slot}:"

  # 1. the launchers, exactly the three the Arch PKGBUILD installs. They are
  #    the real entry points: usr/bin/shani-chronoa-sense is what
  #    slot-tests/chronoa-senses.sh drives, and its sys.path fix
  #    (usr/lib/shani-chronoa, NOT dirname(dirname(__file__))) is a bug that
  #    only ever shows up when the launcher is invoked AS INSTALLED.
  local b
  for b in shani-chronoa shani-chronoa-mcp shani-chronoa-sense shani-chronoa-search shani-chronoa-daemon; do
    [[ -f "${src_dir}/usr/bin/${b}" ]] && _chronoa_overlay_file "${src_dir}/usr/bin/${b}" "${merged}/usr/bin/${b}" 755
  done

  # 2. the Python package
  _chronoa_overlay_tree "${src_dir}/usr/lib/shani-chronoa" "${merged}/usr/lib/shani-chronoa"
  _chronoa_strip_bytecode "${merged}/usr/lib/shani-chronoa"
  _chronoa_strip_stale "${src_dir}/usr/lib/shani-chronoa" "${merged}/usr/lib/shani-chronoa"

  # 3. the desktop entry and icons (present so launchers.sh's dock check sees
  #    a real .desktop for a Chronoa that the image never packaged)
  [[ -f "${src_dir}/usr/share/applications/shani-chronoa.desktop" ]] \
    && _chronoa_overlay_file "${src_dir}/usr/share/applications/shani-chronoa.desktop" \
        "${merged}/usr/share/applications/shani-chronoa.desktop" 644
  [[ -f "${src_dir}/usr/share/pixmaps/shani-chronoa.svg" ]] \
    && _chronoa_overlay_file "${src_dir}/usr/share/pixmaps/shani-chronoa.svg" \
        "${merged}/usr/share/pixmaps/shani-chronoa.svg" 644

  # 3b. the capability-matrix tool. tools/ is not packaged, so it goes beside the
  #     package rather than inside it (where _chronoa_strip_stale would treat it
  #     as stale); it reads the installed package when run from there.
  #     slot-tests/chronoa-matrix.sh runs it.
  [[ -f "${src_dir}/tools/cli_matrix.py" ]] \
    && _chronoa_overlay_file "${src_dir}/tools/cli_matrix.py" \
        "${merged}/usr/lib/shani-chronoa-tools/cli_matrix.py" 644

  # 3c. desktop search integration (GNOME Shell search provider + KRunner plugin)
  local f
  for f in dbus-1/services/dev.shani.chronoa.SearchProvider.service gnome-shell/search-providers/shani-chronoa.ini \
           krunner/dbusplugins/shani-chronoa.desktop; do
    [[ -f "${src_dir}/usr/share/${f}" ]] && _chronoa_overlay_file "${src_dir}/usr/share/${f}" "${merged}/usr/share/${f}" 644
  done

  [[ -f "${src_dir}/usr/lib/systemd/user/shani-chronoa-daemon.service" ]] \
    && _chronoa_overlay_file "${src_dir}/usr/lib/systemd/user/shani-chronoa-daemon.service" \
        "${merged}/usr/lib/systemd/user/shani-chronoa-daemon.service" 644
  [[ -f "${src_dir}/usr/lib/systemd/user/shani-chronoa-llm.service" ]] \
    && _chronoa_overlay_file "${src_dir}/usr/lib/systemd/user/shani-chronoa-llm.service" \
        "${merged}/usr/lib/systemd/user/shani-chronoa-llm.service" 644
  [[ -f "${src_dir}/usr/lib/systemd/user/shani-chronoa-model@.service" ]] \
    && _chronoa_overlay_file "${src_dir}/usr/lib/systemd/user/shani-chronoa-model@.service" \
        "${merged}/usr/lib/systemd/user/shani-chronoa-model@.service" 644

  # 4. the schema, then RECOMPILE it. Without this step every consent key in
  #    the new XML is inert: the CLI asks Gio.SettingsSchemaSource, which reads
  #    gschemas.compiled, and reports the sense as having no key at all.
  local schema_dir="${merged}/usr/share/glib-2.0/schemas"
  local compiled="${schema_dir}/gschemas.compiled"
  _chronoa_overlay_file "${src_dir}/usr/share/glib-2.0/schemas/${CHRONOA_SCHEMA_ID}.gschema.xml" \
      "${schema_dir}/${CHRONOA_SCHEMA_ID}.gschema.xml" 644
  local out rc=0
  # No --strict: that turns a deprecation warning anywhere in the IMAGE's
  # schemas into a failed overlay, which is this harness's problem, not
  # Chronoa's. The two checks below are the ones that actually catch the
  # silent case.
  out="$(glib-compile-schemas "$schema_dir" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    die "--local-src-chronoa: glib-compile-schemas failed (rc=${rc}) — a bad schema in ${schema_dir} would leave the WHOLE directory uncompiled and every consent key inert:
${out}"
  fi
  [[ -f "$compiled" ]] || die "--local-src-chronoa: glib-compile-schemas exited 0 but produced no gschemas.compiled — chronoa's own AGENTS.md records exactly that (a clean exit code proves nothing here)"
  # Recorded so the next run without the flag restores the image's own blob.
  echo "usr/share/glib-2.0/schemas/gschemas.compiled" >> "$(_local_src_record)"

  # Read the consent keys back out of the COMPILED schema (GSETTINGS_SCHEMA_DIR
  # points glib at the merged tree, not the builder's own /usr/share) — the
  # exact question the CLI asks. A warning, not a die: a checkout that has not
  # added a sense's key yet is a finding for the acceptance test to report.
  if command -v gsettings >/dev/null 2>&1; then
    local keys missing="" k
    keys="$(GSETTINGS_SCHEMA_DIR="$schema_dir" gsettings list-keys "$CHRONOA_SCHEMA_ID" 2>/dev/null || true)"
    for k in filesystem ocr web memory vision; do
      grep -qx "${k}-sense-enabled" <<<"$keys" || missing+=" ${k}-sense-enabled"
    done
    if [[ -n "$missing" ]]; then
      warn "--local-src-chronoa: the COMPILED schema declares no consent key for:${missing} (those senses will be reported as having no key at all, which is what the CLI sees)"
    else
      # Counted from the `keys` read above, never written out: a hardcoded
      # "five" went stale the moment the senses layer grew, and a banner that
      # misstates its own scope is worse than no banner.
      _ck=$(grep -c -- '-sense-enabled$' <<<"$keys" || true)
      log "  compiled schema declares ${_ck} *-sense-enabled consent keys (read back through GSETTINGS_SCHEMA_DIR, not from the XML)"
    fi
  fi

  log "Chronoa source overlay complete (this session's overlay only; reverted on the next run without --local-src-chronoa)"
}
