#!/bin/bash
# web <--url=URL | --site=DIR [--path=/sub/]> [web_client.py options...]
#
# Real-browser checks of a web page or a static site with lib/web_client.py:
# headless Chromium driven over the DevTools protocol (no Node, no bundled
# browser). --site serves DIR on 127.0.0.1 itself, the way GitHub Pages serves
# the sites in production (lib/web_serve.py), so a docs/blog/
# website/wiki checkout can be checked as-is; run_in_container.sh mounts those
# sibling checkouts at /opt/<repo>. Screenshots and a JSON report go to
# disk/web-<epoch>/ unless --shots/--json say otherwise.
#
#   web --site=/opt/shani-docs --expect='#content' --offline --crawl=30
#   web --url=https://docs.shani.dev/ --allow-host=cdnjs.cloudflare.com
#
# Every web_client.py option passes through (--expect, --allow-host, --resolve,
# --offline, --spa, --crawl, --devices, --schemes, --budget-lcp, ...); see
# `python3 lib/web_client.py --help`.

WEB_TOOLS_PKGS=(chromium)

_web_ensure_browser() {
  local b
  for b in chromium google-chrome-stable google-chrome; do command -v "$b" >/dev/null 2>&1 && return 0; done
  [[ -n "${CHROME_PATH:-}" && -x "${CHROME_PATH}" ]] && return 0
  command -v pacman >/dev/null 2>&1 || die "web needs Chromium or Chrome (install one, or set CHROME_PATH)"
  log "Installing ${WEB_TOOLS_PKGS[*]} into the builder container (cached in cache/pacman_cache after the first run)..."
  pacman -Sy --noconfirm --needed "${WEB_TOOLS_PKGS[@]}" >/dev/null || die "could not install ${WEB_TOOLS_PKGS[*]}"
}

_web_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

cmd_web() {
  local usage_w="Usage: $(basename "$0") web <--url=URL | --site=DIR [--path=/sub/]> [web_client options...]"
  local url="" site="" path="/" out="" have_shots=0 have_json=0
  local -a pass=()
  while (( $# )); do
    case "$1" in
      --url=*)  url="${1#*=}" ;;
      --site=*) site="${1#*=}" ;;
      --path=*) path="${1#*=}" ;;
      --shots=*) have_shots=1; pass+=("$1") ;;
      --json=*)  have_json=1; pass+=("$1") ;;
      -h|--help) python3 "${LIB_DIR}/web_client.py" --help; return 0 ;;
      *) pass+=("$1") ;;
    esac
    shift
  done
  [[ -n "$url" || -n "$site" ]] || die "$usage_w"
  [[ -z "$url" || -z "$site" ]] || die "web: --url and --site are exclusive"
  _web_ensure_browser

  local srv_pid=""
  if [[ -n "$site" ]]; then
    [[ -d "$site" ]] || die "web: --site=${site} is not a directory (sibling checkouts are at /opt/<repo> in the builder container)"
    local port; port=$(_web_free_port)
    # GitHub Pages semantics (404.html for unknown paths, status 404): what
    # all four ShaniOS sites are served with - see lib/web_serve.py
    python3 "${LIB_DIR}/web_serve.py" "$site" "$port" >/dev/null 2>&1 &
    srv_pid=$!
    local i; for (( i=0; i<50; i++ )); do
      python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', $port), 0.2)" 2>/dev/null && break
      sleep 0.1
    done
    url="http://127.0.0.1:${port}${path}"
    log "web: serving ${site} at http://127.0.0.1:${port}/"
  fi

  out="${DATA_DIR}/web-$(date +%s)"
  (( have_shots )) || pass+=("--shots=${out}/shots")
  (( have_json ))  || pass+=("--json=${out}/report.json")
  mkdir -p "$out"
  local rc=0
  python3 "${LIB_DIR}/web_client.py" --url="$url" "${pass[@]}" || rc=$?
  [[ -n "$srv_pid" ]] && kill "$srv_pid" 2>/dev/null
  log "web: report and screenshots in ${out}"
  (( rc == 0 )) || die "web: checks FAILED (rc=${rc})"
  log "web PASSED"
}
