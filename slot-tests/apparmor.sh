#!/bin/bash
# slot-test-mode: boot
#
# apparmor — every shipped profile parses. nspawn boots skip apparmor.service
# (ConditionSecurity=apparmor), so a profile that fails to compile is only
# seen as "Failed to start Load AppArmor profiles" on a real boot (the gate's
# iso-install boot showed exactly that). apparmor_parser -Q parses and
# compiles without loading into the kernel, so it runs here.
# NEGATIVE control: a planted broken profile is reported.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
command -v apparmor_parser >/dev/null || { res apparmor-profiles-parse "PASS (apparmor not installed on this profile)"; echo "== probe done"; exit 0; }

parse() {  # <profile file> -> 0 if it compiles
  apparmor_parser -Q -K -T "$1" >/dev/null 2>"$tmp/err"
}
tmp=$(mktemp -d)
bad=() n=0
for f in /etc/apparmor.d/*; do
  [[ -f "$f" ]] || continue
  n=$((n + 1))
  if ! parse "$f"; then
    bad+=("${f##*/}")
    # skip the cache warning every profile prints here (no apparmorfs in
    # the container); the compile error is what follows it
    echo "   ${f##*/}: $(grep -v -e '^$' -e 'Cache read/write disabled' "$tmp/err" | tail -3 | tr '\n' ' ' | cut -c1-300)"
  fi
done
if (( ${#bad[@]} )); then
  res apparmor-profiles-parse "FAIL (${#bad[@]}/${n} do not compile: ${bad[*]})"
else
  res apparmor-profiles-parse "PASS (${n} profiles compile)"
fi

printf 'profile shani-negative-control /usr/bin/true {\n  this is not a rule,\n}\n' > "$tmp/neg"
parse "$tmp/neg" && res apparmor-negative-control FAIL || res apparmor-negative-control PASS
rm -rf "$tmp"
echo "== probe done"
