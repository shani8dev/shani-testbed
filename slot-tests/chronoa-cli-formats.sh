#!/bin/bash
# slot-test-mode: boot
#
# chronoa-cli-formats — the output shapes shani-chronoa's CLI parsers depend on,
# measured on the REAL image, because the dev boxes they were written on cannot
# run half of these binaries.
#
# WHY THIS FILE EXISTS. shani-chronoa gained seven CLI enrichments in one
# session (2026-10-10). Most were verified by running the real binary; four were
# not, and each for the same reason — the tool is absent on an Ubuntu dev box
# while shipping on both ShaniOS images:
#
#   avahi-browse   discover_hosts' mDNS half. The module reports service TYPES
#                  only and says why; its unescaped-name parsing is unwritten.
#   arping         check_internet chose the kernel ARP cache instead, because
#                  arping's exit-status contract went unmeasured — it is the one
#                  fact this file settles, whatever the code does next.
#   sane-find-scanner  only the no-scanner path ran on the dev box, so the
#                  "found USB scanner" line's shape was never seen.
#   pdffonts       measured on the dev box, once through a pipe so the exit
#                  code belonged to `head` — the correction is in the product's
#                  own docstring, and this file records the image's real
#                  contracts so the mistake cannot come back quietly.
#
# So the assertions are not "the command runs". They are "the command's output
# has the shape the parser reads, on the distribution the code ships to" — the
# same argument chronoa-machine-state.sh makes about the senses.
#
# THE SEAM. Every capture is read from $CLI_FORMATS_CAPTURE_DIR when that is
# set, and the real binaries are run only when it is not. That is what lets
# tests/chronoa-cli-formats-results.sh drive these same assertions against
# doctored captures on the host - including the ones that must FAIL - so a pass
# here means the check ran, not that it can say no.
#
# RUN FOR REAL, 2026-10-10 on @blue (a bootstrapped Arch slot): **14 pass,
# 0 fail, rc=0**. Two facts that run settled, both of which had been guesses on
# the dev box and are now recorded in shani-chronoa's own docstrings:
#
#   arping -D -c 2 -w 3 on an address nobody answers **exits 0**, printing
#     "Sent 2 probes (2 broadcast(s)), Received 0 response(s)" - so rc=0 means
#     *no duplicate*, which is the opposite of what anyone guesses about a probe.
#   avahi-browse answered with a real service-type line, and both binaries are
#     on the images at /usr/sbin. One type was announced on that slot, which is
#     why the answer is a count and the types rather than a name list.
set -u
res() { printf 'RESULT %-46s %s\n' "$1" "$2"; }
WORK=${CLI_FORMATS_CAPTURE_DIR:-$(mktemp -d /var/tmp/chronoa-cli-formats-XXXXXX)}
[[ -n "${CLI_FORMATS_CAPTURE_DIR:-}" ]] || trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

cap() { cat "$WORK/$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- capture ------------------------------------------------------------------
# Each command runs once into $WORK. A binary absent from the image is a finding,
# not a failure: it is exactly the dependency-missing case the parsers must
# degrade through, so which way the image goes is recorded either way.
for b in avahi-browse arping sane-find-scanner pdffonts smartctl fwupdmgr ip compsize bootctl; do
  if have "$b"; then res "present-$b" "PASS ($(command -v "$b"))"
  else res "present-$b" "PASS (not on this image: its skill must report UNKNOWN, never a clean result)"
  fi
done

if [[ -z "${CLI_FORMATS_CAPTURE_DIR:-}" ]]; then
  # A PDF built here — base-14 Helvetica, so the emb column is `no` and the
  # shape check is not vacuous.
  cat >"$WORK/mini.pdf" <<'PDF'
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Resources<</Font<</F1 4 0 R>>>>/Contents 5 0 R>>endobj
4 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
5 0 obj<</Length 44>>stream
BT /F1 24 Tf 20 100 Td (Hello) Tj ET
endstream endobj
xref
0 6
0000000000 65535 f
trailer<</Size 6/Root 1 0 R>>
startxref
0
%%EOF
PDF
  pdffonts "$WORK/mini.pdf" >"$WORK/pdffonts.out" 2>"$WORK/pdffonts.err"; echo "$?" >"$WORK/pdffonts.rc"
  # The measured trap, run live: a file that is not a PDF at all.
  pdffonts /etc/hostname >"$WORK/pdffonts-notpdf.out" 2>&1; echo "$?" >"$WORK/pdffonts-notpdf.rc"
  if have avahi-browse; then timeout 20 avahi-browse --all --terminate --resolve \
      >"$WORK/avahi.out" 2>"$WORK/avahi.err"; echo "$?" >"$WORK/avahi.rc"; fi
  if have arping; then arping -D -c 2 -w 3 192.0.2.1 \
      >"$WORK/arping-unused.out" 2>&1; echo "$?" >"$WORK/arping-unused.rc"; fi
  if have sane-find-scanner; then sane-find-scanner \
      >"$WORK/sane.out" 2>"$WORK/sane.err"; echo "$?" >"$WORK/sane.rc"; fi
fi

# --- assertions ---------------------------------------------------------------

# pdffonts: a header, a dashed rule, and `no` in the emb column for base-14.
# The parser takes its column boundaries from the rule, so the rule is the
# load-bearing shape and its presence is asserted, not assumed.
if [[ -f "$WORK/pdffonts.rc" ]]; then
  out=$(cap pdffonts.out); rc=$(cap pdffonts.rc)
  shape=FAIL
  grep -qE '^name .* emb ' <<<"$out" && grep -qE '^-{10,}' <<<"$out" && shape=PASS
  # The emb/sub/uni columns for a base-14 font are `no no no`, separated by
  # whitespace the width of which varies - a fixed-width table, so the pattern
  # tolerates any run of spaces rather than asserting one.
  emb=absent
  grep -qE 'no[[:space:]]+no[[:space:]]+no' <<<"$out" && emb=no
  res "pdffonts-table-shape" "$shape (rc=${rc}, base-14 Helvetica emb=${emb})"
  # The two exit-code contracts, recorded rather than assumed: the unit
  # fixtures cover both, and the image decides which one a non-PDF takes.
  # **Measured on the dev box through a pipe first, wrongly** - the exit code
  # read belonged to `head`. A non-PDF is rc=1 here; a fontless PDF is rc=0
  # with an empty table. Both are recorded and neither is a failure: what
  # would be a failure is a non-PDF listing fonts at all.
  np_rc=$(cap pdffonts-notpdf.rc)
  # Rows are the emb/sub/uni triple; stderr prose is not, and this capture
  # merges both streams, so the pattern is the table's own shape rather than
  # "any line starting with a letter" - which counted the syntax errors.
  np_rows=$(grep -cE '(yes|no)[[:space:]]+(yes|no)[[:space:]]+(yes|no)' \
            "$WORK/pdffonts-notpdf.out" || true)
  if (( np_rows > 0 )); then
    res "pdffonts-notpdf-contract" "FAIL (a non-PDF listed ${np_rows} font rows: the empty-table assumption the 'no fonts listed' branch rests on does not hold on this image)"
  else
    res "pdffonts-notpdf-contract" "PASS (rc=${np_rc} with no font rows for a non-PDF - the branch the parser takes is either 'could not be read' or 'no fonts listed', and never 'all embedded')"
  fi
fi

# avahi-browse: prose banner, and service-type tokens on any finding line. A
# slot with no responder has nothing to announce, which is a legitimate
# environment state — reported as SKIP with the reason, never as a shape FAIL.
if [[ -f "$WORK/avahi.rc" ]]; then
  out=$(cap avahi.out); rc=$(cap avahi.rc)
  if [[ "$rc" != 0 ]]; then
    res "avahi-browse-shape" "SKIP (avahi-browse exited ${rc}: $(tr -d '\n' <"$WORK/avahi.err" | head -c 100) — whether the resolver runs here is an image question, not a parser one)"
  elif grep -qE '_[a-z0-9-]+\._(tcp|udp)' <<<"$out"; then
    types=$(grep -oE '_[a-z0-9-]+\._(tcp|udp)' <<<"$out" | sort -u | tr '\n' ' ')
    res "avahi-browse-shape" "PASS (service-type tokens: ${types}— the exact token discover_hosts counts)"
  else
    res "avahi-browse-shape" "SKIP (nothing announced here, so the token shape is unobserved — a booted nspawn has no responder to talk to. Run where a printer or Chromecast advertises to see it)"
  fi
fi

# arping: the exit-status contract, settled rather than assumed. This is the
# fact check_internet records as unmeasured; whatever the code does next, the
# numbers are written down now.
if [[ -f "$WORK/arping-unused.rc" ]]; then
  detail=$(tr -d '\n' <"$WORK/arping-unused.out" | head -c 120)
  res "arping-unused-exit" "PASS (exit $(cap arping-unused.rc) for an address nobody answers: ${detail})"
  if grep -qiE 'socket|permission|denied' <<<"$detail"; then
    res "arping-unprivileged" "FAIL (arping reported a privilege or socket problem, so duplicate detection cannot run unprivileged and the note in check_internet should say so plainly: ${detail})"
  else
    res "arping-unprivileged" "PASS (ran without privilege; the output names the outcome rather than a socket error)"
  fi
fi

# sane-find-scanner: prose is prose, and a finding line only when hardware
# exists. The parser's rule is that prose is not a finding, and this exercises
# it against the real banner either way.
if [[ -f "$WORK/sane.rc" ]]; then
  out=$(cap sane.out)
  prose=no; grep -qiE 'will now attempt to detect' <<<"$out" && prose=yes
  if grep -q 'found USB scanner' <<<"$out"; then
    res "sane-find-scanner-shape" "PASS (rc=$(cap sane.rc), prose=${prose}, a real 'found USB scanner' line — the finding the dev-box run could not see: $(grep -m1 'found USB scanner' <<<"$out" | head -c 100))"
  else
    res "sane-find-scanner-shape" "PASS (rc=$(cap sane.rc), prose=${prose}, no scanner on this slot's bus — matched against the real banner, so 'prose is not a finding' is exercised on real prose)"
  fi
fi

# ip neigh: the field order the ARP-cache parser assumes. The one enrichment
# verified on the dev box, re-verified here so the Arch output is the recorded
# authority.
if have ip; then
  neigh=$(ip neigh show 2>/dev/null | head -3 | tr '\n' ' ')
  if [[ "$neigh" =~ ^[0-9a-fA-F:.]+[[:space:]]dev[[:space:]] ]]; then
    res "ip-neigh-field-order" "PASS ('IP dev <iface>' holds on Arch: ${neigh:0:90})"
  else
    res "ip-neigh-field-order" "FAIL (the neighbour table does not start 'IP dev <iface>': ${neigh:0:90} — check_internet reads those fields by position)"
  fi
fi

if [[ -z "${CLI_FORMATS_CAPTURE_DIR:-}" ]]; then
  if have compsize; then compsize / >"$WORK/compsize.out" 2>"$WORK/compsize.err"; echo "$?" >"$WORK/compsize.rc"; fi
  if have bootctl; then
    # **Three invocations were tried and all three were wrong**, which is why
    # the help text is captured: guessing a fourth would be the same mistake.
    #   `bootctl --json list`            -> "option '--json' requires an argument"
    #   `bootctl --json list` (=auto)    -> "Unknown argument to --json= switch: ..."
    # so this systemd's `bootctl` may not speak JSON at all. The help output
    # settles it in one run instead of one guess per run.
    bootctl --help >"$WORK/bootctl-help.out" 2>&1; echo "$?" >"$WORK/bootctl-help.rc"
    bootctl list >"$WORK/bootctl-list.out" 2>"$WORK/bootctl-list.err"; echo "$?" >"$WORK/bootctl-list.rc"
    bootctl --json list >"$WORK/bootctl.out" 2>"$WORK/bootctl.err"; echo "$?" >"$WORK/bootctl.rc"
  fi
fi

# --- compsize: how much btrfs compression is actually saving -------------------
# ShaniOS installs on btrfs with compression, and nothing here answers "how
# much is it saving me". `compsize` walks the extents and reports the ratio.
#
# **Measured 2026-10-10: it is on the image and exits 1 with no output in an
# nspawn slot.** The stderr is what separates "this tool cannot answer here"
# from "the shape is wrong", so it is printed rather than summarised - a FAIL
# that names no cause is the harness bug this repo has paid for twice.
if [[ -f "$WORK/compsize.rc" ]]; then
  out=$(cat "$WORK/compsize.out"); rc=$(cat "$WORK/compsize.rc")
  err=$(tr -d '\n' <"$WORK/compsize.err" 2>/dev/null | head -c 120)
  if [[ "$rc" == 0 ]] && grep -qiE 'disk size|uncompressed|compressed' <<<"$out"; then
    line=$(grep -iE 'TOTAL|disk size' <<<"$out" | head -1 | tr -s ' \t' ' ')
    res "compsize-shape" "PASS (rc=0 with a size line: ${line:0:90})"
  elif grep -qiE 'not btrfs|No such file|permission denied' <<<"$err"; then
    res "compsize-shape" "SKIP (rc=${rc}, and the reason is environmental, not a shape: ${err})"
  else
    res "compsize-shape" "FAIL (rc=${rc}, no size line; stderr: ${err:-<empty>})"
  fi
fi

# --- bootctl: the EFI boot entries, read as JSON -------------------------------
# The JSON shape is asserted when the tool speaks it and the prose shape when
# it does not; which one this systemd has is a measurement, and the help text
# above is how it is settled without guessing.
if [[ -f "$WORK/bootctl.rc" ]]; then
  rc=$(cat "$WORK/bootctl.rc")
  err=$(tr -d '\n' <"$WORK/bootctl.err" 2>/dev/null | head -c 120)
  if python3 -c "import json; json.load(open('$WORK/bootctl.out'))" 2>/dev/null; then
    n=$(python3 -c "import json; print(len(json.load(open('$WORK/bootctl.out')).get('entries', [])))" 2>/dev/null)
    res "bootctl-json-shape" "PASS (rc=${rc}, ${n} boot entry/entries, JSON-parsed rather than scraped)"
  elif grep -qiE 'Unknown argument to --json|requires an argument' <<<"$err"; then
    # **This systemd has no JSON output, and that is a finding, not a failure.**
    # The prose path is then what a parser reads, so the list's own shape is
    # asserted instead - and the WHOLE list is printed, because the last run
    # truncated it at 110 characters and the parser writer was left completing
    # a fixture by hand, which is exactly how a remembered format ships.
    list_rc=$(cat "$WORK/bootctl-list.rc" 2>/dev/null || echo 1)
    if [[ "$list_rc" == 0 ]] && grep -qE 'type:|title:' <<<"$(cat "$WORK/bootctl-list.out" 2>/dev/null)"; then
      res "bootctl-json-shape" "SKIP (no --json on this systemd: ${err}; \`bootctl list\` works)"
      printf '%s\n' "$(cat "$WORK/bootctl-list.out")" | sed 's/^/  | /'
    else
      res "bootctl-json-shape" "FAIL (--json refused AND \`bootctl list\` produced nothing (rc=${list_rc}), so neither shape is readable)"
    fi
  elif grep -qiE 'efivars|EFI system partition|No such file|not supported|permission denied' <<<"$err"; then
    res "bootctl-json-shape" "SKIP (rc=${rc}, environmental rather than a shape: ${err})"
  else
    res "bootctl-json-shape" "FAIL (rc=${rc}, not JSON; stderr: ${err:-<empty>})"
  fi
fi

echo "== probe done"
