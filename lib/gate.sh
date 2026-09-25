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
_gate_deploy() {  # [upgrade args...]
  local out="${DATA_DIR}/gate-deploy-$$.log" rc=0
  _gate_wait_net
  cmd_upgrade --self-update "$@" 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}
  if (( rc != 0 )) && grep -aq 'No internet connection' "$out"; then
    warn "gate: shani-deploy found no network - retrying the deploy once"
    _gate_wait_net
    cmd_upgrade --self-update "$@"; rc=$?
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
  local usage_gate="Usage: $(basename "$0") gate -p <profile> [--candidate=<file.zst>] [--for=image|iso] [--skip=iso,fresh,upgrade,desktop] [--encrypted] [--keep] [--reuse-install]"
  local profile="" candidate="" skip="" keep=0 reuse=0 for="" encrypted=0 a
  local -a rest=()
  for a in "$@"; do
    case "$a" in
      --candidate=*) candidate="${a#--candidate=}" ;;
      --skip=*)      skip+=",${a#--skip=}," ;;
      # separate gates for the two artifacts (built and promoted separately):
      # image = the new-user (from iso-stable) and existing-user journeys to
      # the candidate image; iso = the candidate ISO's install + first update
      --for=image)   for=image; skip+=",iso," ;;
      --for=iso)     for=iso; skip+=",fresh,upgrade," ;;
      --for=*)       die "gate: --for must be image or iso" ;;
      --keep)        keep=1 ;;
      --reuse-install) reuse=1 ;;  # local iteration only: see below
      --encrypted)   encrypted=1 ;;
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
  if [[ -z "$stable_date" && "$skip" != *,upgrade,* ]]; then
    warn "gate: no stable.txt for '${profile}' - the existing-user path can't be tested"
    skip+=",upgrade,"
  elif [[ "$stable_date" == "$cand_date" ]]; then
    warn "gate: stable already is ${candidate} - the upgrade phase re-deploys the same build"
  fi
  if [[ ! "$iso_date" =~ ^[0-9]{8}$ ]]; then
    warn "gate: no usable iso-latest.txt for '${profile}' ('${iso_date}') - skipping the ISO phase"
    skip+=",iso,"; iso_date=""
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
  # apparmor / deploy-status run on the CANDIDATE (fresh, upgrade): the ISO
  # phase runs stable, which may predate a fix they check for.
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
  # a fresh install, and such a run never writes a .passed marker.
  # --encrypted: the ISO installs use LUKS (the passphrase is typed at each
  # firmware boot, as a user would; TPM2 auto-unlock is enrolled only later)
  local -a enc=(); (( encrypted )) && enc=(--encrypted)
  local -a iso_install=(cmd_iso_install -p "$profile" "--iso=${iso_date}" "${enc[@]}")
  # The updated / rolled-back disk through firmware: systemd-boot, the UKI
  # shani-deploy generated and the boot entry it wrote - nspawn skips all
  # three. Asserts which slot really booted. ISO-installed machines only
  # (iso-install keeps their NVRAM + TPM).
  _gate_fw_boot() { cmd_iso_install -p "$profile" --iso=installed --boot-only "--expect-slot=$1"; }
  if (( reuse )) && [[ "$(cat "${DATA_DIR}/isovm/installed-date" 2>/dev/null)" == "$iso_date" ]]; then
    warn "gate: --reuse-install - reusing the ISO ${iso_date} install (booted via firmware, NOT reinstalled)"
    iso_install+=(--boot-only)
  fi
  # each phase starts from failed=0 and reports its own result
  _gate_phase_ok() { (( failed == 0 )); }
  local iso_ok=0 fresh_ok=0 up_ok=0 installed_from=""

  # ---- iso: the candidate ISO, for iso-stable.txt. Its first update is what
  # the update timer does on a new install: the default (stable) channel, no
  # --force - an older stable is "no update needed", never a downgrade.
  if [[ "$skip" != *,iso,* ]]; then
    failed=0
    local after_first="$iso_date"
    [[ -n "$stable_date" && "$stable_date" > "$iso_date" ]] && after_first="$stable_date"
    _gate_step iso:clean cmd_clean \
      && _gate_step iso:install "${iso_install[@]}" \
      && installed_from="$iso_date" \
      && _gate_identity_step iso:identity "$iso_date" \
      && _gate_checks iso boot-health fresh-user launchers disk-layout \
      && _gate_step iso:first-update _gate_deploy --channel=stable --no-force \
      && _gate_identity_step iso:identity-after-update "$after_first" || true
    if _gate_phase_ok && [[ "$after_first" != "$iso_date" ]]; then
      _gate_checks iso:updated boot-health fresh-user launchers disk-layout \
        && _gate_step iso:firmware-boot-updated _gate_fw_boot "$GATE_SLOT" \
        && _gate_step iso:rollback cmd_rollback \
        && _gate_identity_step iso:identity-rolledback "$iso_date" \
        && _gate_step iso:verify-boot-rolledback cmd_verifyboot "$GATE_SLOT" 120 \
        && _gate_step iso:firmware-boot-rolledback _gate_fw_boot "$GATE_SLOT" || true
    elif _gate_phase_ok; then
      log "gate: stable (${stable_date:-none}) is not newer than ISO ${iso_date}: no first update, as on a real install"
    fi
    _gate_phase_ok && iso_ok=1
  fi

  # ---- fresh: a new user reaching the candidate image. On the ISO phase's
  # machine when it installed; otherwise installed from iso-stable on a disk
  # of the documented minimum (32 GB). Not that ISO's own accepted floor:
  # whether an ISO's install leaves room for updates on its smallest disk is
  # the ISO gate's question (iso phase), and an image can't change it.
  if [[ "$skip" != *,fresh,* ]]; then
    failed=0
    if [[ -z "$installed_from" ]]; then
      local iso_stable; iso_stable="$(_gate_pointer "$profile" iso-stable)" || true
      if [[ "$iso_stable" =~ ^[0-9]{8}$ ]]; then
        _gate_step fresh:clean cmd_clean \
          && _gate_step fresh:install cmd_iso_install -p "$profile" "--iso=${iso_stable}" \
               "--disk-size=${SHANIOS_TEST_NEW_USER_DISK:-32000000000}" "${enc[@]}" \
          && installed_from="$iso_stable" || true
      else
        warn "gate: no ISO installed and no iso-stable.txt - the new-user path to ${candidate} is untested"
        names+=(fresh:install); rcs+=(1); secs+=(0); failed=1
      fi
    fi
    if _gate_phase_ok; then
      local before; before=$(tr -cd '0-9' < "${MNT}/@$(_current_slot)/etc/shani-version" 2>/dev/null || true)
      if [[ "$cand_date" > "$before" ]]; then
        _gate_step fresh:deploy _gate_deploy --channel=latest --no-force \
          && _gate_identity_step fresh:identity "$cand_date" \
          && _gate_checks fresh boot-health fresh-user launchers disk-layout apparmor deploy-status \
          && _gate_step fresh:firmware-boot-updated _gate_fw_boot "$GATE_SLOT" \
          && _gate_step fresh:rollback cmd_rollback \
          && _gate_identity_step fresh:identity-rolledback "$before" \
          && _gate_step fresh:verify-boot-rolledback cmd_verifyboot "$GATE_SLOT" 120 \
          && _gate_step fresh:firmware-boot-rolledback _gate_fw_boot "$GATE_SLOT" || true
      else
        log "gate: this install already runs ${before} (not older than ${cand_date}): the new-user path is the install itself"
      fi
    fi
    _gate_phase_ok && fresh_ok=1
  fi

  # ---- upgrade: an existing user on the current stable image
  if [[ "$skip" != *,upgrade,* ]]; then
    failed=0
    _gate_step upgrade:clean cmd_clean \
      && _gate_step upgrade:install-stable cmd_bootstrap -p "$profile" -d "$stable_date" --from-r2 \
      && _gate_identity_step upgrade:identity-stable "$stable_date" \
      && _gate_step upgrade:deploy _gate_deploy --channel=latest --no-force \
      && _gate_identity_step upgrade:identity "$cand_date" \
      && _gate_checks upgrade boot-health fresh-user disk-layout apparmor deploy-status \
      && _gate_step upgrade:rollback cmd_rollback \
      && _gate_identity_step upgrade:identity-rolledback "$stable_date" \
      && _gate_step upgrade:verify-boot-rolledback cmd_verifyboot "$GATE_SLOT" 120 || true
    _gate_phase_ok && up_ok=1
  fi

  failed=0
  if (( keep )); then log "gate: --keep, leaving mounts/loops attached"
  else _gate_step clean cmd_clean || true; fi

  # image promotable: both user journeys to it passed (a phase skipped with
  # --skip counts as not tested, so no marker)
  local image_ok=0
  (( fresh_ok && up_ok )) && image_ok=1
  local stamp out i json iso_m img_m
  stamp="$(date +%s)"
  out="${DATA_DIR}/gate-${profile}-${stamp}.json"
  img_m="${DATA_DIR}/gate-${profile}.image.passed"; iso_m="${DATA_DIR}/gate-${profile}.iso.passed"
  rm -f "$img_m" "$iso_m" "${DATA_DIR}/gate-${profile}.passed"
  json="{\"profile\":\"${profile}\",\"candidate\":\"${candidate}\",\"iso\":\"${iso_date}\",\"baseline\":\"${stable:-}\",\"skip\":\"${skip//,/ }\",\"steps\":["
  log "════ gate summary (profile=${profile} candidate=${candidate} iso=${iso_date:-none} baseline=${stable:-none}) ════"
  for i in "${!names[@]}"; do
    log "$(printf '  %-32s %-8s %5ss' "${names[$i]}" "$([[ ${rcs[$i]} -eq 0 ]] && echo PASS || echo "FAIL(${rcs[$i]})")" "${secs[$i]}")"
    (( i == 0 )) || json+=","
    json+="{\"step\":\"${names[$i]}\",\"rc\":${rcs[$i]},\"seconds\":${secs[$i]}}"
  done
  echo "${json}],\"iso_passed\":${iso_ok},\"image_passed\":${image_ok}}" > "$out"
  log "  results: ${out}"
  log "  ISO ${iso_date:-none}:  $( ((iso_ok)) && echo PASSED || echo 'not passed')"
  log "  image ${candidate}: $( ((image_ok)) && echo PASSED || echo "not passed (new user: $( ((fresh_ok)) && echo ok || echo no), existing user: $( ((up_ok)) && echo ok || echo no))")"
  if (( reuse )); then
    warn "gate: --reuse-install run - not a release result, no .passed markers"
  else
    (( iso_ok )) && printf '%s\n' "$iso_date" > "$iso_m" && log "  -> ${iso_m}"
    (( image_ok )) && printf '%s\n' "$candidate" > "$img_m" && log "  -> ${img_m}"
  fi
  case "$for" in
    image) (( image_ok )) || die "gate: image ${candidate} not passed"; log "gate PASSED: image ${candidate}" ;;
    iso)   (( iso_ok ))   || die "gate: ISO ${iso_date} not passed";   log "gate PASSED: ISO ${iso_date}" ;;
    *)     (( iso_ok && image_ok )) || die "gate: not everything passed (see above)"
           log "gate PASSED for ${candidate} and ISO ${iso_date}" ;;
  esac
}
