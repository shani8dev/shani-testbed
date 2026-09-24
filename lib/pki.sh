# ------------------------------------------------------------------
# ca   [extra-host ...]   (was 00b-generate-test-ca.sh)
# ------------------------------------------------------------------
# Generalized beyond downloads.shani.dev: any hostname a test needs to
# intercept (raw.githubusercontent.com for a self-update-source test,
# api.example.com for some other external call, ...) gets its own leaf cert
# signed by the SAME throwaway CA, so a slot only ever needs to trust one CA
# (already done once, at bootstrap time) no matter how many hostnames a
# given test redirects to 127.0.0.1. This is the generalized form of what
# test-env/self-update-test.sh used to hand-roll for
# raw.githubusercontent.com alone — see that file's own comments for the
# end-to-end pattern (mint cert here, serve with `cmd_serve`, resolve via
# `cmd_enter`'s hosts file — see _ensure_test_hosts_file below).
#
# Filenames: downloads.shani.dev keeps its historical server.crt/server.key
# (predates multi-host support, and is still what run_in_container.sh's own
# --add-host hardcodes); every other hostname gets <host>.crt/<host>.key.
# Re-running `ca` is additive and idempotent per-hostname — it only
# generates a cert for a hostname that doesn't already have one; delete a
# specific <host>.crt/<host>.key (or the whole ca dir, which also forces the
# CA itself to regenerate) to force a re-mint.
# ------------------------------------------------------------------
cmd_ca() {
  mkdir -p "$CA_DIR"

  local -a hosts=("downloads.shani.dev" "$@")

  if [[ -f "${CA_DIR}/ca.crt" && -f "${CA_DIR}/ca.key" ]]; then
    log "Test CA already exists under ${CA_DIR} — reusing (delete ca.crt/ca.key, and every leaf cert, to regenerate from scratch)."
  else
    log "Generating throwaway CA (NOT FOR PRODUCTION) ..."
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "${CA_DIR}/ca.key" -out "${CA_DIR}/ca.crt" \
      -subj "/CN=shanios-test-env local CA (NOT FOR PRODUCTION)"
  fi

  local host crt key csr
  for host in "${hosts[@]}"; do
    _leaf_cert_paths "$host"; crt="$LEAF_CRT"; key="$LEAF_KEY"

    if [[ -f "$crt" && -f "$key" ]]; then
      log "Leaf cert for ${host} already exists (${crt}) — reusing (delete it to regenerate)."
      continue
    fi

    log "Minting leaf cert for ${host}, signed by the test CA ..."
    csr="$(mktemp)"
    openssl req -newkey rsa:2048 -nodes \
      -keyout "$key" -out "$csr" \
      -subj "/CN=${host}"
    openssl x509 -req -in "$csr" -sha256 -days 3650 \
      -CA "${CA_DIR}/ca.crt" -CAkey "${CA_DIR}/ca.key" -CAcreateserial \
      -out "$crt" \
      -extfile <(printf "subjectAltName=DNS:%s" "$host")
    rm -f "$csr" "${CA_DIR}/ca.srl"
    chmod 644 "$crt"
    chmod 600 "$key"
  done

  log "Done. CA + leaf cert(s) for: ${hosts[*]} — written under ${CA_DIR} (persists across runs)."
}

# ------------------------------------------------------------------
# serve   [port] [docroot] [cert-host]   (was 02-serve-update.sh)
# ------------------------------------------------------------------
# Defaults (port 443, OUTPUT_DIR, downloads.shani.dev) are unchanged from
# before this took extra args — every existing call site keeps working
# untouched. To stand in for a SECOND external hostname with genuinely
# different content (e.g. raw.githubusercontent.com serving a self-update
# payload while downloads.shani.dev keeps serving OUTPUT_DIR), run a second,
# independent `serve` in its own session on a different port with that
# hostname's own docroot and cert-host:
#   ./run_in_container.sh build.sh test ca raw.githubusercontent.com
#   ./run_in_container.sh build.sh test serve 8443 /some/other/docroot raw.githubusercontent.com &
# `cmd_enter`'s hosts file (_ensure_test_hosts_file) resolves
# raw.githubusercontent.com to 127.0.0.1 automatically once it's been `ca`'d
# — the two servers just need to listen on different ports since they share
# one loopback (or run one at a time on 443 if the scripts under test only
# ever hit one external host per invocation, like self-update-test.sh does).
# ------------------------------------------------------------------
cmd_serve() {
  local port="${1:-443}"
  local docroot="${2:-$OUTPUT_DIR}"
  local cert_host="${3:-downloads.shani.dev}"

  local crt key
  _leaf_cert_paths "$cert_host"; crt="$LEAF_CRT"; key="$LEAF_KEY"
  [[ -f "$crt" && -f "$key" ]] \
    || die "No leaf cert for '${cert_host}' under ${CA_DIR} — run '$(basename "$0") ca ${cert_host}' first."
  [[ -d "$docroot" ]] \
    || die "${docroot} not found."

  # Bind to loopback by default: this server hands out full system images and
  # uses a self-signed CA, so exposing it on all interfaces is a footgun.
  # Opt into 0.0.0.0 explicitly (e.g. containers on a bridge network) with
  # SHANIOS_TEST_SERVE_ALL=1.
  local bind_host="127.0.0.1"
  if [[ "${SHANIOS_TEST_SERVE_ALL:-0}" == "1" ]]; then
    bind_host="0.0.0.0"
  fi

  log "Serving ${docroot} on https://${bind_host}:${port} (CN=${cert_host})"
  log "Available profiles: $(find "$docroot" -maxdepth 1 -mindepth 1 -type d -printf '%f ' 2>/dev/null)"

  cd "$docroot" && exec python3 - "$port" "$crt" "$key" "$bind_host" <<'PYEOF'
import http.server, ssl, sys

port, certfile, keyfile, bind_host = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("  " + (fmt % args) + "\n")

httpd = http.server.HTTPServer((bind_host, int(port)), QuietHandler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile=certfile, keyfile=keyfile)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PYEOF
}

# Synthesizes an /etc/hosts to bind-mount into a slot: the container's own
# /etc/hosts (which already has run_in_container.sh's own
# --add-host=downloads.shani.dev:127.0.0.1 baked in) plus one
# "127.0.0.1 <host>" line for every extra hostname `cmd_ca` has minted a
# leaf cert for (any *.crt under CA_DIR besides ca.crt/server.crt — see
# cmd_ca). This is what makes "the next person testing something that calls
# out to an external URL" only need `ca <that-host>` — no manual /etc/hosts
# surgery, and nothing ever touches the actual host's /etc/hosts (this file
# lives under DATA_DIR and is bind-mounted BY PATH into the slot, same
# principle as _ensure_inhibit_stub). Regenerated on every call so a host
# `ca`'d after the slot was last entered is picked up on the next `enter`.
# Prints the generated file's path to stdout.
_ensure_test_hosts_file() {
  local out="${DATA_DIR}/.etc-hosts-test"
  cp /etc/hosts "$out"
  local crt host
  for crt in "${CA_DIR}"/*.crt; do
    [[ -e "$crt" ]] || continue
    host="$(basename "$crt" .crt)"
    [[ "$host" == "ca" || "$host" == "server" ]] && continue
    grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${host}([[:space:]]|\$)" "$out" \
      || echo "127.0.0.1 ${host}" >> "$out"
  done
  echo "$out"
}
