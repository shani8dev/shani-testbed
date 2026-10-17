# lib/suite.sh — `suite` (the mandatory verification sequence as one
# command) and `status` (read-only view of the harness state).

# ------------------------------------------------------------------
# suite [-p <profile>] [-d <sel>] [--local-src=<dir>] [--keep] [--encrypted]
# ------------------------------------------------------------------
# Runs exactly the sequence shani-deploy/shani-install-media AGENTS.md make
# mandatory — clean -> ca -> bootstrap -> upgrade -> rollback -> clean — in
# one invocation, with per-step timing and a summary. Each step runs in a
# subshell so a failing step's `die` can't skip the final clean; a failed
# step stops the sequence (later steps depend on it) but clean still runs.
# --local-src defaults to /opt/shani-deploy/scripts (the sibling checkout
# run_in_container.sh mounts) when that exists. --keep skips the final
# clean (e.g. to probe/enter the result afterwards). Writes
# disk/suite-<epoch>.json.
cmd_suite() {
  _take_local_src "$@"
  set -- "${REST_ARGS[@]}"
  local local_src="$LOCAL_SRC" keep=0 profile="gnome" date_sel="latest" encrypted=0 from_r2=0 a
  local -a rest=()
  for a in "$@"; do
    case "$a" in
      --keep) keep=1 ;;
      --encrypted) encrypted=1 ;;
      --from-r2) from_r2=1 ;;
      *) rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"
  local opt OPTARG OPTIND=1
  while getopts "p:d:" opt "$@"; do
    case "$opt" in
      p) profile="$OPTARG" ;;
      d) date_sel="$OPTARG" ;;
      *) die "Usage: $(basename "$0") suite [-p <profile>] [-d <sel>] [--local-src=<dir>] [--keep] [--encrypted] [--from-r2]" ;;
    esac
  done
  if [[ -z "$local_src" && -d /opt/shani-deploy/scripts ]]; then
    local_src=/opt/shani-deploy/scripts
  fi
  local -a src_arg=()
  [[ -n "$local_src" ]] && src_arg=("--local-src=${local_src}")
  local -a boot_args=(-p "$profile" -d "$date_sel")
  (( encrypted )) && boot_args+=(--encrypted)
  (( from_r2 )) && boot_args+=(--from-r2)

  local -a names=() rcs=() secs=()
  local failed=0
  _suite_step() {
    local label="$1"; shift
    local t0 rc=0
    t0=$(date +%s)
    log "════ suite: ${label} ════"
    ( "$@" ) || rc=$?
    names+=("$label"); rcs+=("$rc"); secs+=("$(( $(date +%s) - t0 ))")
    (( rc == 0 )) || failed=1
    return "$rc"
  }

  # What upgrade/rollback promise, not just their exit codes: a rollback that
  # overwrote the previous system with a copy of the new one exited 0 and
  # passed this suite for weeks. Versions from each slot's /etc/shani-version.
  _suite_ver() { tr -cd '0-9' < "${MNT}/@$1/etc/shani-version" 2>/dev/null; }
  _suite_other() { [[ $1 == blue ]] && echo green || echo blue; }
  local cur0="" ver0="" cur1="" ver1=""
  _suite_check() {  # <label> <expr> <detail>
    local t0; t0=$(date +%s)
    log "════ suite: $1 ════"
    local rc=0; eval "$2" || rc=1
    (( rc == 0 )) && log "  $1: $3" || warn "  $1 FAILED: $3"
    names+=("$1"); rcs+=("$rc"); secs+=("$(( $(date +%s) - t0 ))")
    (( rc == 0 )) || failed=1
  }

  _suite_step clean cmd_clean
  if (( ! failed )); then _suite_step ca cmd_ca || true; fi
  if (( ! failed )); then _suite_step bootstrap cmd_bootstrap "${boot_args[@]}" || true; fi
  if (( ! failed )); then cur0=$(_current_slot); ver0=$(_suite_ver "$cur0"); fi
  if (( ! failed )); then _suite_step upgrade cmd_upgrade "${src_arg[@]}" || true; fi
  if (( ! failed )); then
    cur1=$(_current_slot); ver1=$(_suite_ver "$cur1")
    _suite_check upgrade:switched \
      '[[ $cur1 != "$cur0" && -n $ver1 && $ver1 -ge ${ver0:-0} && $(_suite_ver "$cur0") == "$ver0" ]]' \
      "@${cur0} v${ver0} -> @${cur1} v${ver1}; @${cur0} now v$(_suite_ver "$cur0")"
  fi
  if (( ! failed )); then _suite_step rollback cmd_rollback "${src_arg[@]}" || true; fi
  if (( ! failed )); then
    _suite_check rollback:restored \
      '[[ $(_current_slot) == "$cur0" && $(_suite_ver "$cur0") == "$ver0" && $(_suite_ver "$cur1") == "$ver1" ]]' \
      "current @$(_current_slot); @${cur0} v$(_suite_ver "$cur0") (was v${ver0}); @${cur1} v$(_suite_ver "$cur1") (was v${ver1})"
  fi

  # ...and that the BOOT CONFIGURATION names the slot it just rolled back to.
  #
  # Verified green on a real run (2026-10-17, suite 10/10): "loader.conf default
  # is [shanios-blue.conf], expected shanios-blue.conf" after a real upgrade
  # (144s, "Deployment successful!") and a real rollback. Four defects were
  # found by running this rather than reading it - an ID compared without its
  # `shanios-` prefix, an unclosed `if`, an unquoted glob in the comparison, and
  # a mount that raced the harness's own ESP mountpoint. None of them was
  # visible to `bash -n`, and the first two would each have made the check fail
  # on a CORRECT rollback or pass on a broken one.
  #
  # `rollback:restored` above reads @data/current-slot and both slots' versions.
  # None of that is what the firmware boots: systemd-boot reads loader.conf's
  # `default` and, ahead of it, four EFI variables. So a rollback that restored
  # every subvolume correctly and left the ESP pointing at the failed candidate
  # passed this suite - and the machine then booted the slot the user had just
  # rolled away from, having been told it succeeded.
  #
  # Not hypothetical: finalize_boot_entries set only LoaderEntryDefault (FIFTH
  # in systemd-boot's order) and never cleared LoaderEntrySysFail. See
  # shani-deploy's AGENTS.md and tests/finalize-boot-efivars.sh.
  #
  # Reads the ESP rather than trusting the command's exit status or its log,
  # because both said the right thing while the configuration was wrong.
  #
  # The ID is `shanios-<slot>.conf` - finalize_boot_entries builds
  # `loader_default="${OS_NAME}-${active_slot}.conf"` - so comparing against
  # `<slot>.conf` would fail on a CORRECT rollback, which is worse than not
  # checking at all.
  if (( ! failed )); then
    # The harness already owns an ESP mountpoint ($ESP_MNT, /opt/shanios-esp),
    # and a second mount of the same partition is REFUSED while the first is
    # still attached - "Can't mount, would change RO state" - so mounting my
    # own copy cannot work. Reuse the harness's, mounting it only if nothing
    # has it yet.
    local _esp_mnt="${ESP_MNT:-/opt/shaniios-esp}"
    local _esp_def="" _esp_own=0
    if ! mountpoint -q "$_esp_mnt" 2>/dev/null; then
      mkdir -p "$_esp_mnt" 2>/dev/null
      if mount -o ro /dev/disk/by-label/shani_boot "$_esp_mnt" 2>/dev/null; then
        _esp_own=1
      fi
    fi
    if mountpoint -q "$_esp_mnt" 2>/dev/null; then
      _esp_def=$(sed -n 's/^default[[:space:]]*//p' "$_esp_mnt/loader/loader.conf" 2>/dev/null | head -1)
      _suite_check rollback:esp-default-names-the-target \
        "[[ -n \"\$_esp_def\" && \"\$_esp_def\" == \"shanios-${cur0}.conf\" ]]" \
        "loader.conf default is [${_esp_def:-<none>}], expected shanios-${cur0}.conf (the slot rolled back to)"
      # A default naming an entry that is not on the ESP is the same failure in
      # a different costume: systemd-boot matches no entry and boots "the first
      # suitable entry" instead, which on a post-flip disk is the wrong one.
      if [[ -n "$_esp_def" && ! -f "$_esp_mnt/loader/entries/${_esp_def}" ]]; then
        _suite_check rollback:esp-entry-exists \
          'false' "loader.conf defaults to [${_esp_def}], which is not a file on the ESP"
      else
        _suite_check rollback:esp-entry-exists \
          '[[ -n "$_esp_def" ]]' "[${_esp_def:-<none>}] is present on the ESP"
      fi
      (( _esp_own )) && umount "$_esp_mnt" 2>/dev/null
    else
      # A mount gap is NOT a pass. Its own step, so the summary cannot be read
      # as all-green when one thing was never attempted.
      _suite_check rollback:esp-readable \
        'false' "could not mount /dev/disk/by-label/shani_boot read-only, so the boot configuration after rollback was NOT verified"
    fi
    (( _esp_own )) && rmdir "$_esp_mnt" 2>/dev/null
    true
  fi

  if (( keep )); then log "suite: --keep, leaving mounts/loops attached"
  else _suite_step clean cmd_clean || true; fi

  local out="${DATA_DIR}/suite-$(date +%s).json" i json="["
  log "════ suite summary (profile=${profile} date=${date_sel} local-src=${local_src:-none}) ════"
  for i in "${!names[@]}"; do
    log "$(printf '  %-18s %-5s %5ss' "${names[$i]}" "$([[ ${rcs[$i]} -eq 0 ]] && echo PASS || echo "FAIL(${rcs[$i]})")" "${secs[$i]}")"
    # (not `json+="$([[ $i -gt 0 ]] && echo ,)..."`: under set -e that
    # assignment takes the substitution's status 1 on the first row and
    # killed the harness mid-summary - no JSON, no PASSED/FAILED, exit 1
    # even when every step passed)
    (( i == 0 )) || json+=","
    json+="{\"step\":\"${names[$i]}\",\"rc\":${rcs[$i]},\"seconds\":${secs[$i]}}"
  done
  echo "${json}]" > "$out"
  log "  results: ${out}"
  (( failed == 0 )) || die "suite FAILED"
  log "suite PASSED"
}

# ------------------------------------------------------------------
# status — read-only: never attaches, mounts or writes anything.
# ------------------------------------------------------------------
cmd_status() {
  local img="$INSTALL_IMG" loops f
  log "── images (${DATA_DIR}) ──"
  if [[ -f "$img" ]]; then
    loops="$(_loops_for_image "$img" | tr '\n' ' ')"
    log "  $(basename "$img"): $(du -h --apparent-size "$img" | cut -f1) apparent, $(du -h "$img" | cut -f1) used${loops:+, attached: ${loops}}"
  else
    log "  $(basename "$img"): absent"
  fi
  log "── by-label ──"
  for f in shani_root shani_boot; do
    if [[ -L "/dev/disk/by-label/$f" ]]; then
      log "  $f -> $(readlink "/dev/disk/by-label/$f")$([[ -e "/dev/disk/by-label/$f" ]] || echo ' (dangling)')"
    else
      log "  $f: none"
    fi
  done
  log "── slots ──"
  if mountpoint -q "$MNT" 2>/dev/null; then
    log "  top-level mounted at ${MNT}; current-slot: $(tr -d '[:space:]' < "$MNT/@data/current-slot" 2>/dev/null || echo '?')"
    local s
    for s in blue green; do log "  @${s}: $([[ -d "$MNT/@${s}" ]] && echo present || echo MISSING)"; done
  else
    log "  top-level not mounted (any command that needs it mounts it; nothing read here)"
  fi
  log "── overlays ──"
  for f in "${DATA_DIR}"/nspawn-overlay-*; do
    [[ -d "$f" ]] || continue
    local n=0
    [[ -f "$f/.local-src-overlaid" ]] && n=$(sort -u "$f/.local-src-overlaid" | wc -l)
    log "  $(basename "$f"): $(mountpoint -q "$f/merged" 2>/dev/null && echo mounted || echo 'not mounted'), ${n} --local-src file(s) pending revert"
  done
  log "── other ──"
  log "  test CA: $([[ -f "${CA_DIR}/ca.crt" ]] && echo present || echo absent)"
  log "  background boot: $([[ -f "${DATA_DIR}/${BOOT_BG_PIDFILE_NAME}" ]] && echo "pid $(cat "${DATA_DIR}/${BOOT_BG_PIDFILE_NAME}")" || echo none)"
  for f in "${DATA_DIR}"/mcp-session/session.json; do
    [[ -f "$f" ]] && log "  app control session: $(cat "$f")"
  done
  return 0
}
