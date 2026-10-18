#!/bin/bash
# Assert that no script truncates a BOOT-CRITICAL file in place.
#
#   tests/critical-writes.sh [root...]      (defaults to the sibling checkouts)
#
# WHY THIS EXISTS. Two real power-cut defects, found 2026-10-18 by reading the
# deploy's boot-flip for an unrelated reason, not by any test:
#
#   shani-deploy.sh   grep -v "^default " "$loader_conf" > "${loader_conf}.tmp" || true
#                     mv "${loader_conf}.tmp" "$loader_conf"
#
#   configure.sh      printf ... > /boot/efi/loader/loader.conf
#
# The second truncates before it writes, so a power cut mid-write leaves a
# partial loader.conf - and on a first install there is no earlier one, no
# deploy, and no `default` line for systemd-boot to read, so it falls through to
# "the first suitable entry". The first is worse in kind: the `|| true` does not
# merely swallow a failure, the next line RENAMES that file over a working one,
# so a failed grep commits a truncated default.
#
# Both are invisible to every test in this harness. powercut-scenario.sh
# reproduces the END STATE a cut leaves and cannot represent a state that only
# exists mid-write, and no unit test executes a deploy's write path against a
# real ESP. The observable pass condition is therefore a property of the SOURCE:
#
#   every write to a boot-critical file goes to a .tmp in the same directory and
#   is renamed into place, and rename(2) within one directory is atomic.
#
# That is a real invariant with real violations behind it, not a style rule: a
# script that writes any of these directly has a window in which the machine
# cannot boot, caused by nothing more than losing power.
#
# WHAT IT DOES NOT COVER - and this bit twice, so read it before trusting a PASS.
#
# It matches a literal critical path after a `>` operator. That misses:
#
#   * a target built from shell variables - `> ${UKI_BOOT_ENTRY}/${entry_filename}`
#     contains no literal `loader/entries/...`, so it is invisible. THE BOOT
#     ENTRY WRITE IN configure.sh WAS EXACTLY THIS, and this check did not see
#     it; it was found by reading.
#   * a `cp`/`mv`/`tee` DESTINATION - no `>` operator at all. The rollback path
#     in shani-deploy.sh copies a UKI straight onto a live ESP path, which
#     truncates it before writing. Also invisible; also fixed.
#   * a redirect target assembled at runtime from anything but a literal.
#
# So: **`0 violations` from this script is not evidence that the ESP writes are
# atomic.** It is evidence that no write of that one literal shape exists. Both
# real violations above are recorded here because the check that was written to
# catch that class let two instances of it through, and a reader deserves to
# know which parts of the surface are unexamined rather than discovering them
# from a black screen.

set -uo pipefail

ROOTS=("$@")
if [[ ${#ROOTS[@]} -eq 0 ]]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    # $here is shani-testbed/tests, so the siblings are two levels up. Getting
    # this wrong scanned ZERO files and still reported PASS, which is the one
    # outcome this file exists to make suspicious.
    ROOTS=("$here/../../shani-deploy/scripts" "$here/../../os-installer-config/scripts")
fi

pass=0 fail=0

# Boot-critical: the loader config, a type-1 boot entry, and any EFI binary
# (UKI). Each is read by systemd-boot on the very next boot, so each must appear
# on the ESP whole or not at all.
CRIT_RE='loader\.conf|loader/entries/[^"[:space:]]*\.conf|/[^"[:space:]]*\.efi\b'

# The redirect operator and the single token that follows it. `[^0-9&]` skips
# 2> and &>; the character class stops at the shell metacharacters so a staged
# write followed by `&& mv` yields the staging path, not the whole line. Kept in a
# variable because bash's [[ =~ ]] cannot parse an escaped metacharacter inside
# a bracket expression - it dies on `\&` with "unexpected token `&'".
REDIR_RE='[^0-9&]>[[:space:]]*([^[:space:]"&|;]*)'

check() {
    local file="$1" line_no="$0" text="$1"
    :
}

total=0
violations=()
review=()

for root in "${ROOTS[@]}"; do
    [[ -d "$root" ]] || { echo "FAIL: no such directory: $root"; fail=$((fail+1)); continue; }
    while IFS= read -r f; do
        total=$((total + 1))
        # Only redirect forms that TRUNCATE. `>>` appends and cannot destroy the
        # existing content, and `> "$x.tmp"` is the correct staging write.
        while IFS=: read -r n rest; do
            [[ -n "$n" ]] || continue
            [[ "$rest" =~ ^[[:space:]]*# ]] && continue
            # The REDIRECT TARGET, and nothing else.
            #
            # Matching the whole line produced a false positive on
            #   cp "$ESP/loader/loader.conf" "$staging/loader.conf" 2>/dev/null
            # which redirects stderr to /dev/null and writes no boot-critical
            # file at all - the CRIT pattern was matching the `cp` SOURCE. A
            # check that cries wolf gets ignored, so the target is extracted:
            #   [^0-9&]   skip 2> and &>
            #   one bare word, stopping at shell metacharacters, so a staged
            #   write plus its trailing `mv` reads as the staging write rather
            #   than as the whole line.
            if [[ "$rest" =~ $REDIR_RE ]]; then
        target="${BASH_REMATCH[1]}"
    else
        continue
    fi
            [[ -z "$target" ]] && continue
            # staging write to a temp is the whole point
            [[ "$target" == *.tmp || "$target" == *.tmp.* ]] && continue
            # is the TARGET boot-critical?
            if [[ "$target" =~ $CRIT_RE ]]; then
                violations+=("${f#${here}/}:${n}: -> ${target}")
            fi
        done < <(grep -nE '[^>]>[[:space:]]*' "$f" 2>/dev/null | grep -v '^\s*#')

        # A redirect target built from a variable is a BLIND SPOT, not a pass.
        # `> ${UKI_BOOT_ENTRY}/${entry_filename}` contains no literal
        # loader/entries path, so pass 1 cannot see it - and that one was real.
        # Listing them turns an invisible gap into a visible one.
        while IFS=: read -r n rest; do
            [[ -n "$n" ]] || continue
            [[ "$rest" =~ ^[[:space:]]*# ]] && continue
            if [[ "$rest" =~ $REDIR_RE ]]; then
                vt="${BASH_REMATCH[1]}"
                [[ "$vt" == *.tmp || "$vt" == *.tmp.* || -z "$vt" ]] && continue
                [[ "$vt" == *'$'* ]] || continue
                # Gate on the TARGET's own shape, not on the file. A file-level
                # gate listed ${new}MB, $(format_bytes and $* as "ESP writes",
                # because shani-deploy.sh mentions the ESP somewhere - and a
                # review list that lists everything is a review list nobody reads.
                [[ "$vt" =~ (efi|EFI|\.conf|loader|entry|LOADER) ]] || continue
                review+=("${f#${here}/}:${n}: variable target -> ${vt}")
            fi
        done < <(grep -nE '[^>]>[[:space:]]*' "$f" 2>/dev/null | grep -v '^\s*#')

        # --- pass 2: cp / mv / install / tee DESTINATIONS ---
        # `cp a b` truncates b before writing and has NO redirect operator, so
        # pass 1 cannot see it at all. That is the shape that was missed in
        # shani-deploy.sh's rollback UKI copy.
        #
        # `mv "$x.tmp" "$loader_conf"` is the CORRECT staging rename and must not
        # be flagged, so an mv with any .tmp argument is exempt.
        while IFS=: read -r n rest; do
            [[ -n "$n" ]] || continue
            [[ "$rest" =~ ^[[:space:]]*# ]] && continue
            if [[ "$rest" =~ (^|[^[:alnum:]_])(cp|mv|install|tee)[[:space:]] ]]; then
                cmd="${BASH_REMATCH[2]}"
                case "$rest" in
                    *.tmp*|*.tmp.*) [[ "$cmd" == mv ]] && continue ;;
                esac
                dest="${rest##*[[:space:]]}"
                dest="${dest%[\;\)\]]*}"; dest="${dest%[\"\']}"
                [[ -z "$dest" || "$dest" == -* ]] && continue
                if [[ "$dest" =~ $CRIT_RE ]]; then
                    violations+=("${f#${here}/}:${n}: $cmd dest -> ${dest}")
                fi
            fi
        done < <(grep -nE '(^|[^[:alnum:]_])(cp|mv|install|tee)[[:space:]]' "$f" 2>/dev/null | grep -v '^\s*#')
    done < <(find "$root" -maxdepth 1 -name '*.sh' -type f | sort)
done

for v in "${violations[@]+"${violations[@]}"}"; do
    fail=$((fail + 1))
    echo "FAIL: in-place truncating write to a boot-critical file"
    echo "  $v"
done

echo
echo "critical-writes: $total script(s) scanned, $fail violation(s)"

# Blind spots, reported rather than hidden. These are not failures - they are
# writes this check cannot resolve, listed so a reader knows what was NOT
# examined instead of having to rediscover it from a black screen.
for r in "${review[@]+"${review[@]}"}"; do
    echo "REVIEW (unresolvable target): $r"
done
[[ ${#review[@]} -gt 0 ]] && echo "  ${#review[@]} write(s) to a variable-built path - not decidable by this check"

# A scanner that examined nothing has not passed. This is the difference between
# "no violations" and "no files", and only one of them is a result.
if [[ "$total" -eq 0 ]]; then
    echo "FAIL: examined 0 scripts - that is an absent measurement, not a clean one"
    fail=$((fail + 1))
fi

# --- negative control ---------------------------------------------------------
# A check that cannot fail is not a check. Build a script that truncates
# loader.conf directly - exactly what configure.sh did - and assert this scanner
# reports it. If the control passes silently the scanner is broken.
ctl="$(mktemp -d)"
trap 'rm -rf "$ctl"' EXIT
mkdir -p "$ctl/scripts"
cat > "$ctl/scripts/bad.sh" <<'EOF'
printf 'default shanios-blue.conf\n' > /boot/efi/loader/loader.conf
printf 'default shanios-blue.conf\n' > /boot/efi/loader/.loader.conf.tmp
mv -f /boot/efi/loader/.loader.conf.tmp /boot/efi/loader/loader.conf
EOF
ctl_hits=0
while IFS=: read -r n rest; do
    [[ -n "$n" ]] || continue
    if [[ "$rest" =~ $REDIR_RE ]] \
        && [[ ! "${BASH_REMATCH[1]}" == *.tmp ]] \
        && [[ "${BASH_REMATCH[1]}" =~ $CRIT_RE ]]; then
        ctl_hits=$((ctl_hits + 1))
    fi
done < <(grep -nE '[^>]>[[:space:]]*' "$ctl/scripts/bad.sh" | grep -v '^\s*#')

if [[ "$ctl_hits" -eq 1 ]]; then
    echo "PASS: control tripped exactly once (the direct write; the staged write is not counted)"
else
    echo "FAIL: control expected 1 violation in the fixture, got $ctl_hits - the scanner does not discriminate"
    fail=$((fail + 1))
fi

if [[ "$fail" -eq 0 ]]; then
    echo "RESULT critical-writes PASS"
    exit 0
fi
echo "RESULT critical-writes FAIL"
exit 1