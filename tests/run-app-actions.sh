#!/bin/bash
# Runs tests/app-actions.sh — a real Xvfb + GTK4/libadwaita test of lib/app.sh's
# action executor and lib/a11y_client.py — in a throwaway archlinux container.
# Needs docker and network (installs xorg-server-xvfb, xdotool, imagemagick,
# python-gobject, at-spi2-core, gtk4, libadwaita, tesseract). Exit 1 if any RESULT is not PASS.
set -euo pipefail
here="$(dirname "$(realpath "$0")")"
# the workspace pacman cache, when it is there: nothing is downloaded twice
cache=()
c="${here}/../../shani-install-media/cache/pacman_cache"
[[ -d "$c" ]] && cache=(-v "$(realpath "$c"):/var/cache/pacman")
out="$(docker run --rm "${cache[@]}" -v "${here}/../lib:/lib-under-test:ro" -v "${here}/app-actions.sh:/t.sh:ro" -v "${here}/fixtures:/fixtures:ro" \
       archlinux:latest bash /t.sh 2>&1)"
grep '^RESULT' <<<"$out"
pass=$(grep -c '^RESULT.* PASS$' <<<"$out" || true); total=$(grep -c '^RESULT' <<<"$out" || true)
echo "${pass}/${total} passed"
[[ "$total" -gt 0 && "$pass" -eq "$total" ]]
