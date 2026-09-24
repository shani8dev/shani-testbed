# lib/gate.sh — `gate`: the release gate promote-stable runs before it
# repoints stable.txt and iso-stable.txt. Tests the PUBLISHED artifacts the
# way users get them (R2, SHA-256 + GPG checked, the self-updated
# shani-deploy — never --local-src), along both journeys to the candidate:
#
#   fresh    a new user: the candidate ISO (iso-latest) booted under UEFI
#            firmware, installed by its own os-installer scripts in its live
#            session, the installed disk booted through firmware
#            (iso-install) -> checks -> upgrade to the candidate -> checks
#            -> rollback
#   upgrade  an existing user: current stable image -> upgrade to the
#            candidate -> checks -> rollback
#
# checks = identity (/etc/shani-version of the slot /data/current-slot
# names), verify-boot, slot-tests and a desktop screenshot. Every upgrade is
# `upgrade --self-update`: shani-deploy first updates itself from GitHub
# main (as on a real machine), then follows the LIVE latest.txt - identity
# is what pins the test to one artifact, so a build published mid-gate
# fails the gate instead of being promoted untested.
#
# `launchers` runs only on the fresh path: an image installed from R2
# (upgrade phase) never gets a Flatpak layer, which only ships inside ISOs.
#
# Writes disk/gate-<profile>-<epoch>.json and, on success only,
# disk/gate-<profile>.passed: line 1 the image, line 2 the ISO folder -
# what promote-stable.sh --expect / --expect-iso compare against.

_gate_pointer() {  # <profile> <latest|stable>
  curl -fsS --max-time 30 --retry 5 --retry-delay 5 --retry-all-errors \
    "${R2_PUBLIC_BASE:-https://downloads.shani.dev}/$1/$2.txt" 2>/dev/null | tr -d '[:space:]'
}

# Wait (up to 5 min) until R2 answers the check shani-deploy makes before a
# deploy: one network blip on this host failed an hour-long gate at
# "No internet connection" although the next five checks all passed.
_gate_wait_net() {
  local i
  for (( i=0; i<30; i++ )); do
    timeout 10 curl -fsSL --max-time 8 --head "${R2_PUBLIC_BASE:-https://downloads.shani.dev}" >/dev/null 2>&1 && return 0
    (( i == 0 )) && warn "gate: ${R2_PUBLIC_BASE:-https://downloads.shani.dev} not reachable - waiting up to 5 min"
    sleep 10
  done
  warn "gate: still no network after 5 min"
}

# The deploy, once more if (and only if) shani-deploy stopped at its own
# connectivity check; any other failure stands.
_gate_deploy() {
  local out="${DATA_DIR}/gate-deploy-$$.log" rc=0
  _gate_wait_net
  cmd_upgrade --self-update 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}
  if (( rc != 0 )) && grep -aq 'No internet connection' "$out"; then
    warn "gate: shani-deploy found no network - retrying the deploy once"
    _gate_wait_net
    cmd_upgrade --self-update; rc=$?
  fi
  rm -f "$out"
  return "$rc"
}

_gate_identity() {  # <expected YYYYMMDD> — current slot must run that build
  local want="$1" slot have
  slot="$(_current_slot)"
  have=$(tr -cd '0-9' < "${MNT}/@${slot}/etc/shani-version" 2>/dev/null || true)
  log "identity: @${slot} runs ${have:-?} (want ${want})"
  [[ "$have" == "$want" ]] || { warn "identity: @${slot} is ${have:-unreadable}, not ${want}"; return 1; }
  GATE_SLOT="$slot"
}

cmd_gate() {
  local usage_gate="Usage: $(basename "$0") gate -p <profile> [--candidate=<file.zst>] [--skip=fresh,upgrade,desktop] [--keep] [--reuse-install]"
  local profile="" candidate="" skip="" keep=0 reuse=0 a
  local -a rest=()
  for a in "$@"; do
    case "$a" in
      --candidate=*) candidate="${a#--candidate=}" ;;
      --skip=*)      skip=",${a#--skip=}," ;;
      --keep)        keep=1 ;;
      --reuse-install) reuse=1 ;;  # local iteration only: see below
      *)             rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"
  local opt OPTARG OPTIND=1
  while getopts "p:" opt "$@"; do
    case "$opt" in
      p) profile="$OPTARG" ;;
      *) die "$usage_gate" ;;
    esac
  done
  [[ -n "$profile" ]] || die "$usage_gate"
  # the local-mirror mapping (run_in_container.sh) would send every fetch,
  # and shani-deploy inside the slots, to an empty loopback
  getent hosts downloads.shani.dev | grep -q '^127\.' \
    && die "gate: downloads.shani.dev resolves to loopback (local-mirror mapping) - gate tests the real R2; run it as 'build.sh test gate' or with SHANIOS_TEST_REAL_R2=1"

  local latest stable iso_date
  latest="$(_gate_pointer "$profile" latest)" || true
  stable="$(_gate_pointer "$profile" stable)" || true
  iso_date="$(_gate_pointer "$profile" iso-latest)" || true
  [[ -n "$latest" ]] || die "gate: no latest.txt for '${profile}' on R2"
  [[ -n "$candidate" ]] || candidate="$latest"
  [[ "$candidate" == "$latest" ]] \
    || die "gate: candidate ${candidate} is not what latest.txt names (${latest}) - shani-deploy would upgrade to ${latest}"
  local cand_date stable_date=""
  cand_date=$(grep -oE '[0-9]{8}' <<<"$candidate" | head -n1) || true
  [[ -n "$cand_date" ]] || die "gate: can't parse a build date out of ${candidate}"
  [[ -n "$stable" ]] && { stable_date=$(grep -oE '[0-9]{8}' <<<"$stable" | head -n1) || true; }
  if [[ -z "$stable_date" ]]; then
    warn "gate: no stable.txt for '${profile}' - skipping the upgrade phase (nothing to upgrade from)"
    skip+=",upgrade,"
  elif [[ "$stable_date" == "$cand_date" ]]; then
    warn "gate: stable already is ${candidate} - the upgrade phase re-deploys the same build"
  fi
  if [[ ! "$iso_date" =~ ^[0-9]{8}$ ]]; then
    warn "gate: no usable iso-latest.txt for '${profile}' ('${iso_date}') - skipping the fresh phase"
    skip+=",fresh,"; iso_date=""
  fi
  local want_desktop=1
  [[ "$skip" == *,desktop,* ]] && want_desktop=0

  local -a names=() rcs=() secs=()
  local failed=0
  GATE_SLOT=""
  _gate_step() {  # <label> <cmd...> — a failed step stops the phase
    local label="$1"; shift
    local t0 rc=0
    t0=$(date +%s)
    log "════ gate: ${label} ════"
    ( "$@" ) || rc=$?
    names+=("$label"); rcs+=("$rc"); secs+=("$(( $(date +%s) - t0 ))")
    (( rc == 0 )) || failed=1
    return "$rc"
  }
  # identity must run in THIS shell (it sets GATE_SLOT for the next steps)
  _gate_identity_step() {
    local label="$1" want="$2" rc=0
    log "════ gate: ${label} ════"
    _gate_identity "$want" || rc=$?
    names+=("$label"); rcs+=("$rc"); secs+=(0)
    (( rc == 0 )) || failed=1
    return "$rc"
  }
  _gate_checks() {  # <label> <slot-test...> — the checks on GATE_SLOT
    local ph="$1"; shift
    _gate_step "${ph}:verify-boot" cmd_verifyboot "$GATE_SLOT" 120 || return 1
    _gate_step "${ph}:slot-tests" cmd_slot_test "$GATE_SLOT" "$@" || return 1
    if (( want_desktop )); then
      mkdir -p "${SCRIPT_DIR}/shots"
      _gate_step "${ph}:desktop" cmd_desktop "$GATE_SLOT" \
        "--out=${SCRIPT_DIR}/shots/gate-${profile}-${cand_date}-${ph//:/-}.png" || return 1
    fi
  }

  _gate_step ca cmd_ca || true

  # --reuse-install: boot (through firmware) the disk the last iso-install
  # of this same ISO left, instead of a 25-min reinstall under TCG. For local
  # iteration only - that disk has been through earlier checks, so it is not
  # a fresh install, and such a run never writes the .passed marker.
  local -a iso_install=(cmd_iso_install -p "$profile" "--iso=${iso_date}")
  if (( reuse )) && [[ "$(cat "${DATA_DIR}/isovm/installed-date" 2>/dev/null)" == "$iso_date" ]]; then
    warn "gate: --reuse-install - reusing the ISO ${iso_date} install (booted via firmware, NOT reinstalled)"
    iso_install+=(--boot-only)
  fi
  if (( ! failed )) && [[ "$skip" != *,fresh,* ]]; then
    _gate_step fresh:clean cmd_clean \
      && _gate_step fresh:install-iso "${iso_install[@]}" \
      && _gate_identity_step fresh:identity-iso "$iso_date" \
      && _gate_checks fresh:iso boot-health fresh-user launchers \
      && _gate_step fresh:deploy _gate_deploy \
      && _gate_identity_step fresh:identity "$cand_date" \
      && _gate_checks fresh boot-health fresh-user launchers \
      && _gate_step fresh:rollback cmd_rollback \
      && _gate_identity_step fresh:identity-rolledback "$iso_date" \
      && _gate_step fresh:verify-boot-rolledback cmd_verifyboot "$GATE_SLOT" 120 || true
  fi

  if (( ! failed )) && [[ "$skip" != *,upgrade,* ]]; then
    _gate_step upgrade:clean cmd_clean \
      && _gate_step upgrade:install-stable cmd_bootstrap -p "$profile" -d "$stable_date" --from-r2 \
      && _gate_identity_step upgrade:identity-stable "$stable_date" \
      && _gate_step upgrade:deploy _gate_deploy \
      && _gate_identity_step upgrade:identity "$cand_date" \
      && _gate_checks upgrade boot-health fresh-user \
      && _gate_step upgrade:rollback cmd_rollback \
      && _gate_identity_step upgrade:identity-rolledback "$stable_date" \
      && _gate_step upgrade:verify-boot-rolledback cmd_verifyboot "$GATE_SLOT" 120 || true
  fi

  if (( keep )); then log "gate: --keep, leaving mounts/loops attached"
  else _gate_step clean cmd_clean || true; fi

  local stamp out passed i json
  stamp="$(date +%s)"
  out="${DATA_DIR}/gate-${profile}-${stamp}.json"
  passed="${DATA_DIR}/gate-${profile}.passed"
  rm -f "$passed"
  json="{\"profile\":\"${profile}\",\"candidate\":\"${candidate}\",\"iso\":\"${iso_date}\",\"baseline\":\"${stable:-}\",\"skip\":\"${skip//,/ }\",\"steps\":["
  log "════ gate summary (profile=${profile} candidate=${candidate} iso=${iso_date:-none} baseline=${stable:-none}) ════"
  for i in "${!names[@]}"; do
    log "$(printf '  %-32s %-8s %5ss' "${names[$i]}" "$([[ ${rcs[$i]} -eq 0 ]] && echo PASS || echo "FAIL(${rcs[$i]})")" "${secs[$i]}")"
    (( i == 0 )) || json+=","
    json+="{\"step\":\"${names[$i]}\",\"rc\":${rcs[$i]},\"seconds\":${secs[$i]}}"
  done
  echo "${json}],\"passed\":$(( failed == 0 ? 1 : 0 ))}" > "$out"
  log "  results: ${out}"
  (( failed == 0 )) || die "gate FAILED for ${candidate}"
  (( reuse )) && { log "gate PASSED (--reuse-install: not a release result, no .passed marker)"; return 0; }
  # line 2 only when the fresh phase really installed that ISO
  printf '%s\n%s\n' "$candidate" "$([[ "$skip" == *,fresh,* ]] || echo "$iso_date")" > "$passed"
  log "gate PASSED for ${candidate} (${passed})"
}
