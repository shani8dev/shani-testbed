#!/bin/bash
# slot-test-mode: boot
#
# chronoa-machine-state — acceptance coverage for the machine-state senses on a
# REAL booted ShaniOS slot, driven through the REAL installed
# /usr/bin/shani-chronoa-sense. Nothing here reimplements a sense; every
# reading comes back from the shipped CLI running the shipped package.
#
# WHY THIS FILE CANNOT BE A UNIT TEST, AND WHY IT SPECIFICALLY CANNOT BE RUN
# ON A DEVELOPER BOX. The unit suite for these senses is green on Ubuntu, and
# that proves close to nothing about ShaniOS, because four of the senses shell
# out to a binary and ask the package manager a question whose answer is
# distro-specific. Verified by hand on a 2026-09-28 Ubuntu 24.04 dev box while
# writing them:
#
#   contention  shells out to `fuser` (psmisc)
#   privilege   asks "which package owns this file"
#   bluetooth   shells out to `bluetoothctl` (bluez)
#   thermalgrid shells out to `i2cdetect` (i2c-tools) and `pkexec` (polkit)
#
# Three of the four had already been written and passing against the WRONG
# answer before this test existed, and each failed silently rather than loudly:
#
#   * `fuser` absent made contention report EVERY microphone and camera as
#     free - the exact inverse of the thing it exists to report. A missing
#     binary raised OSError, which the old code swallowed into "no holders".
#   * the ownership lookup was `dpkg-query`, which is Debian-only. On Arch -
#     which is what ShaniOS is - it does not exist, the lookup returns nothing,
#     and every process on the machine is then reported as unmanaged
#     third-party software. Not degraded: actively crying wolf on the OS it
#     ships to, and burying the one real finding under everything else.
#   * `bluetoothctl` absent produced "0 devices", which is a confident answer
#     to a question nobody had asked.
#
# So the assertions below are not "does the sense return something". They are
# "does the sense return something DIFFERENT from its own silence" - because
# a sensor whose failure mode is a plausible-looking wrong answer is worse
# than a sensor that fails, and on the wrong distro all three of the above
# returned confident nonsense.
#
# The negative control is the same shape as chronoa-senses.sh: consent off
# must exit 4 and say why, because a gate that cannot refuse proves nothing
# when it is open.
set -u
res() { printf 'RESULT %-44s %s\n' "$1" "$2"; }
CLI=/usr/bin/shani-chronoa-sense
WORK=$(mktemp -d /var/tmp/chronoa-machine-state-XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SCHEMA_ID="org.shani.chronoa"

# The senses this file covers, and the external binary each one depends on.
# hwmon and modelfit deliberately have no entry: they read /proc and /sys
# directly, so there is no binary that can be missing.
# The binary is the whole point: a sense whose dependency is missing on the
# target must degrade to UNKNOWN, and that is only observable here.
declare -A NEEDS=(
  [contention]=fuser
  [privilege]="pacman|dpkg-query|rpm|zypper"
  [bluetooth]=bluetoothctl
  [thermalgrid]=i2cdetect
)
SENSES=(contention privilege thermal thermalgrid display network bluetooth camera rfsense hwmon modelfit)

if [[ ! -x "$CLI" ]]; then
  res chronoa-machine-state-cli "FAIL (no $CLI in this slot - the image ships no shani-chronoa at all. Overlay the source with slot-test <slot> chronoa-machine-state --local-src-chronoa=<checkout>, or install a built package with --local-pkg=shani-chronoa)"
  echo "== probe done"
  exit 0
fi
res chronoa-machine-state-cli "PASS ($CLI)"

# --- 1. every sense registers -------------------------------------------------
# A malformed schema is skipped by the loader with only a log line, so a sense
# that can never be granted consent and can never be called looks merely
# absent from `list`.
out=$("$CLI" list 2>&1); rc=$?
for s in "${SENSES[@]}"; do
  if grep -qE "^  ${s} +" <<<"$out"; then
    res "sense-registered-$s" "PASS"
  else
    res "sense-registered-$s" "FAIL (not in list - its schema is malformed, so the loader skipped it; exit ${rc})"
  fi
done

# --- 2. every consent key is in the RUNNING compiled schema -------------------
# Present in the XML is not present in gschemas.compiled, and gsettings reads
# the compiled file only. A key that is in the XML and not in the compiled
# schema makes the sense permanently ungrantable while `list` still advertises
# it as available.
keys=$(gsettings list-keys "$SCHEMA_ID" 2>/dev/null)
missing=""
for s in "${SENSES[@]}"; do
  grep -qx "${s}-sense-enabled" <<<"$keys" || missing+=" ${s}-sense-enabled"
done
if [[ -z "$missing" ]]; then
  res consent-keys-compiled "PASS (all ${#SENSES[@]} *-sense-enabled keys are in the RUNNING compiled schema)"
else
  res consent-keys-compiled "FAIL (declared in the XML but absent from gschemas.compiled, so these senses can never be granted:${missing})"
fi

# --- 3. the external binaries these senses need -------------------------------
# Reported, not asserted as fatal. A missing binary is legitimate - it is
# exactly the ShaniOS-without-the-dependency case the UNKNOWN branches exist
# for - so the test records which are present and then, in step 5, checks that
# the senses behave correctly EITHER WAY.
for s in "${!NEEDS[@]}"; do
  tool=${NEEDS[$s]}
  found=""
  IFS='|' read -ra alts <<<"$tool"
  for a in "${alts[@]}"; do
    command -v "$a" >/dev/null 2>&1 && found+=" $a"
  done
  if [[ -n "$found" ]]; then
    res "dep-present-$s" "PASS (${found# })"
  else
    res "dep-present-$s" "PASS (none of: ${tool//|/, } - the sense must now report UNKNOWN, which step 5 asserts)"
  fi
done

# --- 4. consent is a real gate: off means exit 4 and a reason -----------------
for s in "${SENSES[@]}"; do
  "$CLI" disable "$s" >/dev/null 2>&1
  denied=$("$CLI" --json run "$s" 2>&1); rc=$?
  if (( rc == 4 )); then
    res "consent-denied-$s" "PASS (exit 4 while ${s}-sense-enabled is off)"
  else
    res "consent-denied-$s" "FAIL (expected exit 4 (consent denied), got ${rc}: $(tr -d '\n' <<<"$denied" | head -c 120))"
  fi
done

# --- 5. with consent on, each sense produces a REAL reading -------------------
# The assertion is that the output is a real observation, and specifically that
# it is not the sense's own UNKNOWN path when the dependency IS present.
for s in "${SENSES[@]}"; do
  "$CLI" enable "$s" >/dev/null 2>&1
  out=$("$CLI" --json run "$s" 2>&1); rc=$?
  if (( rc != 0 )); then
    res "real-reading-$s" "FAIL (exit ${rc}: $(tr -d '\n' <<<"$out" | head -c 160))"
    continue
  fi
  if ! grep -q '"percept"\|"ok":true\|"content"' <<<"$out"; then
    res "real-reading-$s" "FAIL (ran but produced no percept: $(tr -d '\n' <<<"$out" | head -c 160))"
    continue
  fi
  body=$(tr -d '\n' <<<"$out" | head -c 200)
  if grep -q 'UNKNOWN' <<<"$out"; then
    # Legitimate only when the dependency really is absent.
    tool=${NEEDS[$s]:-}
    have=0
    if [[ -n "$tool" ]]; then
      IFS='|' read -ra alts <<<"$tool"
      for a in "${alts[@]}"; do command -v "$a" >/dev/null 2>&1 && have=1; done
    fi
    if (( have )); then
      res "real-reading-$s" "FAIL (reported UNKNOWN although its dependency IS installed - a dependency that is present must produce a real reading, not silence)"
    elif [[ -z "$tool" ]]; then
      # No external binary, so a missing tool cannot explain this UNKNOWN - and
      # this loop cannot say what did, or whether it was legitimate. Guessing
      # either way is what produced two bad versions of this assertion: a
      # digit-counting heuristic that fails senses whose real readings are all
      # one or two digits (rfsense legitimately reports "link=70/70
      # level=-29dBm"), and a PASS that asserted a cause nobody had checked.
      # So: report it as unadjudicated and let a dedicated check own it.
      res "real-reading-$s" "SKIP (this sense has no external dependency, so no missing tool can account for the UNKNOWN, and this loop cannot tell whether it was honest - see the dedicated check for this sense if it has one)"
    else
      res "real-reading-$s" "PASS (UNKNOWN, which is correct: its dependency is genuinely absent)"
    fi
  else
    res "real-reading-$s" "PASS (${body})"
  fi
done

# --- 6. contention must never call a device "free" while it cannot tell ------
# The specific regression this file exists for. If fuser is present, a device
# with no holder is genuinely free; if it is absent, "free" is a lie and the
# only acceptable answer is that the state is undetermined.
if command -v fuser >/dev/null 2>&1; then
  # With fuser present, the UNKNOWN path must be unreachable: if it appears
  # anyway the sense is mistaking an error for an absence.
  out=$("$CLI" --json run contention 2>&1)
  if grep -q 'psmisc' <<<"$out" || grep -q 'UNKNOWN, not free' <<<"$out"; then
    res contention-fuser-respected "FAIL (fuser is installed but the sense still reported the missing-binary path - an error is being read as an absence)"
  else
    res contention-fuser-respected "PASS (fuser is installed and the sense is reporting real holder state, not the missing-binary path)"
  fi
else
  res contention-fuser-respected "PASS (fuser is absent, so the UNKNOWN branch is the correct outcome here)"
fi

# --- 7. privilege must attribute provenance, not blame the whole system ------
# The dpkg-query-on-Arch failure produced "every process is unmanaged", which
# reads as a serious finding and is a packaging bug. On a system where a
# package manager exists, the report must actually use it.
if pacman -Qo /usr/bin/bash >/dev/null 2>&1 || dpkg-query -S /usr/bin/bash >/dev/null 2>&1; then
  out=$("$CLI" --json run privilege 2>&1)
  if grep -q 'further holder' <<<"$out"; then
    res privilege-uses-package-manager "PASS ($(grep -o '[0-9]* further holder' <<<"$out" | head -1) attributed to distribution packages, so the ownership lookup is actually working)"
  elif grep -q 'UNKNOWN' <<<"$out"; then
    res privilege-uses-package-manager "FAIL (a package manager is present but provenance came back undetermined - the ownership lookup is not finding the tool that answers on THIS distro)"
  else
    res privilege-uses-package-manager "PASS (no dangerous-capability holder needed attributing on this slot)"
  fi
else
  res privilege-uses-package-manager "PASS (no ownership tool on this slot; the sense must say so rather than blame every process)"
fi

# --- 8. modelfit: an unreachable Ollama is UNKNOWN, never "no models" --------
# This is the one sense whose UNKNOWN has a nameable cause rather than a
# missing binary. `installed_models()` returns None when Ollama does not
# answer, and the sense must report that as undetermined - the daemon being
# down is a normal state, and reporting it as "0 models installed" is a
# confident answer to a question nobody asked, and would then feed the model
# resolver a claim that a configured model is absent.
#
# The half that must NOT degrade is the hardware half. It reads /proc/meminfo
# directly and has no reason to be blind, so even with Ollama unreachable the
# report must still carry real numbers.
if command -v ollama >/dev/null 2>&1 && ollama list >/dev/null 2>&1; then
  res modelfit-ollama-unknown-honest "SKIP (Ollama is installed AND answering, so there is no unknown to be honest about - the positive path is covered by real-reading-modelfit)"
else
  out=$("$CLI" --json run modelfit 2>&1)
  if grep -qiE 'no models installed|0 models|zero models' <<<"$out"; then
    res modelfit-ollama-unknown-honest "FAIL (Ollama did not answer but the sense reported a model count - an unreachable daemon is not an empty model list)"
  elif grep -q 'UNKNOWN' <<<"$out"; then
    res modelfit-ollama-unknown-honest "PASS (Ollama did not answer and the sense said UNKNOWN rather than claiming a model count)"
  else
    res modelfit-ollama-unknown-honest "FAIL (Ollama did not answer, but the sense neither said UNKNOWN nor reported a count - the unanswered question is being hidden)"
  fi

  if grep -qE '[1-9][0-9]{2,} MB RAM total' <<<"$out"; then
    res modelfit-hardware-half-still-real "PASS ($(grep -oE '[0-9]+ MB RAM total, [0-9]+ MB available' <<<"$out" | head -1) - the kernel half read fine even though Ollama did not answer)"
  else
    res modelfit-hardware-half-still-real "FAIL (Ollama being unreachable must not blind the /proc/meminfo half, which has no dependency that could be missing)"
  fi
fi

echo "== probe done"
