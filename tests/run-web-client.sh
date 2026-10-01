#!/bin/bash
# Runs tests/web-client.sh — a real headless-Chromium test of lib/web_client.py
# against tests/web-fixtures/ — in a throwaway archlinux container. Mounts the
# workspace pacman cache (../shani-install-media/cache/pacman_cache) when it is
# there, so chromium is not downloaded again. Exit 1 unless every RESULT passes.
set -euo pipefail
here="$(dirname "$(realpath "$0")")"
cache=()
c="${here}/../../shani-install-media/cache/pacman_cache"
[[ -d "$c" ]] && cache=(-v "$(realpath "$c"):/var/cache/pacman")
out="$(docker run --rm "${cache[@]}" -v "${here}/../lib:/lib-under-test:ro" \
       -v "${here}/web-fixtures:/fixtures:ro" -v "${here}/web-client.sh:/t.sh:ro" \
       archlinux:latest bash /t.sh 2>&1)"
printf '%s\n' "$out" | grep -E '^(RESULT|  (good|bad )\|)'
pass=$(grep -c '^RESULT.* PASS$' <<<"$out" || true); total=$(grep -c '^RESULT' <<<"$out" || true)
echo "${pass}/${total} passed"
[[ "$total" -gt 0 && "$pass" -eq "$total" ]]
