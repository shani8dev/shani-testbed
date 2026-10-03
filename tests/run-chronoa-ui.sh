#!/bin/bash
# Runs tests/chronoa-ui.sh - shani-chronoa's ui_elements skill against a real
# Xvfb + GTK4 window over AT-SPI - in a throwaway archlinux container.
#   tests/run-chronoa-ui.sh [<shani-chronoa checkout>]   (default: ../shani-chronoa)
set -euo pipefail
here="$(dirname "$(realpath "$0")")"
chronoa="$(realpath "${1:-$here/../../shani-chronoa}")/usr/lib/shani-chronoa"
cache=()
c="${here}/../../shani-install-media/cache/pacman_cache"
[[ -d "$c" ]] && cache=(-v "$(realpath "$c"):/var/cache/pacman")
out="$(docker run --rm "${cache[@]}" -v "$chronoa:/chronoa:ro" -v "${here}/chronoa-ui.sh:/t.sh:ro" \
       -v "${here}/fixtures:/fixtures:ro" archlinux:latest bash /t.sh 2>&1)"
echo "$out" | grep -v '^RESULT' | tail -40
grep '^RESULT' <<<"$out"
pass=$(grep -c '^RESULT.* PASS$' <<<"$out" || true); total=$(grep -c '^RESULT' <<<"$out" || true)
echo "${pass}/${total} passed"
[[ "$total" -gt 0 && "$pass" -eq "$total" ]]
