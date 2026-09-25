#!/bin/bash
# slot-test-mode: boot
#
# deploy-status — `shani-deploy --status [--check] --json`, what Shani
# Cassini reads: valid JSON, fields equal to the slot's own identity files,
# and it works WITHOUT root (the GUI runs as the desktop user) and without
# the deploy lock. NEGATIVE control: --json without --status is refused.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
command -v shani-deploy >/dev/null || { res deploy-status "FAIL (no shani-deploy)"; exit 0; }

check() {  # <label> <json>  -> validates against the slot's files
  python3 - "$1" "$2" <<'PY'
import json, sys, re
label, raw = sys.argv[1], sys.argv[2]
try:
    d = json.loads(raw)
except Exception as e:
    print(f"   {label}: not JSON ({e}): {raw[:200]}"); sys.exit(1)
def f(p):
    try: return re.sub(r'[^0-9a-z_-]', '', open(p).read().strip().lower())
    except OSError: return ""
want = {"version": re.sub(r'\D', '', f("/etc/shani-version")), "profile": f("/etc/shani-profile"),
        "current_slot": f("/data/current-slot")}
bad = [f"{k}={d.get(k)!r} (want {v!r})" for k, v in want.items() if d.get(k) != v]
if d.get("booted_slot") not in ("blue", "green"): bad.append(f"booted_slot={d.get('booted_slot')!r}")
if d.get("channel") not in ("stable", "latest"): bad.append(f"channel={d.get('channel')!r}")
print(f"   {label}: {raw.strip()}")
if bad: print(f"   {label}: mismatches: {'; '.join(bad)}"); sys.exit(1)
PY
}

out=$(shani-deploy --status --json 2>&1) && check root "$out" \
  && res deploy-status-json-root PASS || res deploy-status-json-root "FAIL (rc/validation, see above)"

user=$(getent passwd 1000 | cut -d: -f1 || true)
if [[ -n "$user" ]]; then
  out=$(runuser -u "$user" -- shani-deploy --status --json 2>&1) && check "$user" "$out" \
    && res deploy-status-json-unprivileged PASS || res deploy-status-json-unprivileged "FAIL (as ${user}, see above)"
else  # no desktop user on this slot: any unprivileged account proves it
  out=$(runuser -u nobody -- shani-deploy --status --json 2>&1) && check nobody "$out" \
    && res deploy-status-json-unprivileged "PASS (as nobody - no uid 1000 user on this slot)" \
    || res deploy-status-json-unprivileged "FAIL (as nobody, see above)"
fi

# --check reaches the release pointers: remote.stable is an 8-digit date
out=$(shani-deploy --status --check --json 2>&1)
if python3 -c 'import json,sys,re; d=json.loads(sys.argv[1]); assert re.fullmatch(r"\d{8}", d["remote"]["stable"]); assert d["update_available"] in (True, False)' "$out" 2>/dev/null; then
  res deploy-status-check "PASS ($(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("stable", d["remote"]["stable"], "latest", d["remote"]["latest"], "update", d["update_available"])' "$out"))"
else
  res deploy-status-check "FAIL (${out:0:200})"
fi

shani-deploy --json >/dev/null 2>&1 && res deploy-status-negative-control FAIL || res deploy-status-negative-control PASS
echo "== probe done"
