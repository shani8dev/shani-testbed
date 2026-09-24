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

  _suite_step clean cmd_clean
  if (( ! failed )); then _suite_step ca cmd_ca || true; fi
  if (( ! failed )); then _suite_step bootstrap cmd_bootstrap "${boot_args[@]}" || true; fi
  if (( ! failed )); then _suite_step upgrade cmd_upgrade "${src_arg[@]}" || true; fi
  if (( ! failed )); then _suite_step rollback cmd_rollback "${src_arg[@]}" || true; fi
  if (( keep )); then log "suite: --keep, leaving mounts/loops attached"
  else _suite_step clean cmd_clean || true; fi

  local out="${DATA_DIR}/suite-$(date +%s).json" i json="["
  log "════ suite summary (profile=${profile} date=${date_sel} local-src=${local_src:-none}) ════"
  for i in "${!names[@]}"; do
    log "$(printf '  %-10s %-5s %5ss' "${names[$i]}" "$([[ ${rcs[$i]} -eq 0 ]] && echo PASS || echo "FAIL(${rcs[$i]})")" "${secs[$i]}")"
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
  local img loops f
  log "── images (${DATA_DIR}) ──"
  for img in "$INSTALL_IMG"; do
    if [[ -f "$img" ]]; then
      loops="$(_loops_for_image "$img" | tr '\n' ' ')"
      log "  $(basename "$img"): $(du -h --apparent-size "$img" | cut -f1) apparent, $(du -h "$img" | cut -f1) used${loops:+, attached: ${loops}}"
    else
      log "  $(basename "$img"): absent"
    fi
  done
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
