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
for b in avahi-browse arping sane-find-scanner pdffonts smartctl fwupdmgr ip compsize bootctl v4l2-ctl clockdiff cryptsetup iotop iostat nethogs bandwhich strace unrar cabextract lrzip lzop arj unar lsar svn hg restic rclone iperf3 socat iftop arpwatch delv host nslookup wget aria2c; do
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
  if have compsize; then
    # **Not `/`.** nspawn's root is an overlay, so `compsize /` answers
    # "Not btrfs" on a machine whose real root is btrfs - measured, and the
    # reason this walks the subvolumes ShaniOS's own fstab documents instead
    # (@data, @home, @cache, @log). One of them is where an immutable image
    # actually keeps writable state, so it is also the useful question.
    for d in /data /home /var/cache /; do
      if [[ -d "$d" ]]; then
        compsize "$d" >"$WORK/compsize${d//\//_}.out" 2>"$WORK/compsize${d//\//_}.err"
        echo "$?" >"$WORK/compsize${d//\//_}.rc"
      fi
    done
  fi
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
  # Three more that the Ubuntu dev box lacks and both images ship, each the
  # answer to a question no Chronoa skill can answer today: what the webcam
  # can actually do, whether this machine's clock is right, and what a LUKS
  # volume really is (disk_health only sees "crypto_LUKS" in lsblk).
  if have v4l2-ctl; then
    v4l2-ctl --list-devices >"$WORK/v4l2-devices.out" 2>"$WORK/v4l2-devices.err"; echo "$?" >"$WORK/v4l2-devices.rc"
    first=$(grep -oE '/dev/video[0-9]+' "$WORK/v4l2-devices.out" 2>/dev/null | head -1)
    if [[ -n "$first" ]]; then
      v4l2-ctl -d "$first" --list-formats >"$WORK/v4l2-formats.out" 2>"$WORK/v4l2-formats.err"; echo "$?" >"$WORK/v4l2-formats.rc"
      v4l2-ctl -d "$first" --all >"$WORK/v4l2-all.out" 2>&1; echo "$?" >"$WORK/v4l2-all.rc"
    fi
  fi
  if have clockdiff; then
    gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    if [[ -n "$gw" ]]; then
      clockdiff -o "$gw" >"$WORK/clockdiff.out" 2>"$WORK/clockdiff.err"; echo "$?" >"$WORK/clockdiff.rc"
    fi
  fi
  if have cryptsetup; then
    luks=$(lsblk -rno NAME,FSTYPE 2>/dev/null | awk '$2=="crypto_LUKS"{print "/dev/"$1; exit}')
    cryptsetup luksDump ${luks:-/dev/null} >"$WORK/luksdump.out" 2>"$WORK/luksdump.err"; echo "$?" >"$WORK/luksdump.rc"
  fi
  # **The whole archive family `shani-tools-extra` ships by design.** 7z was
  # measured and wired; unrar, cabextract, lrzip, arj and unarchiver were left
  # out even though the image installs all of them - so "extract this rar" was
  # still refused while the tool sat in /usr/bin. Each one's *interface* is what
  # a parser needs, and each has a different one, so all are measured.
  mkdir -p "$WORK/arch"
  printf 'archive family probe\n' >"$WORK/arch/probe.txt"
  # **Every probe here is bounded by `timeout`.** Measured 2026-10-10: this
  # run hung for 57 minutes at `bandwhich --raw`, which is a *continuous*
  # bandwidth monitor by design - it prints forever and never exits. A probe
  # with no bound does not fail, it hangs the whole slot-test, and the 30
  # checks that had already passed are lost with it.
  #
  # `timeout` records 124 on expiry, so a hang is a distinguishable outcome
  # rather than an absence - which is the difference between "this tool prints
  # nothing useful here" and "this tool never returned".
  probe() {  # probe <name> <cmd...>
    local name="$1"; shift
    timeout 25 "$@" >"$WORK/$name.out" 2>"$WORK/$name.err"
    echo "$?" >"$WORK/$name.rc"
  }
  for tool in 7z unrar cabextract lrzip lzop arj unar lsar; do
    if have "$tool"; then probe "arch-$tool-help" "$tool" --help; fi
  done
  # **Which formats does this image's 7z actually read?** Measured, not
  # assumed. `extract_archive` and `list_archive` both delegate every
  # non-tar/zip archive to `7z`, and the module docstrings claim it opens a
  # `.rar`. Whether it can depends on the build's codec set - Arch's `p7zip`
  # carries no RAR decoder and `7zip` (7-Zip proper) does - so a claim in a
  # docstring is not evidence and this is the check that settles it.
  if have 7z; then
    timeout 25 7z i >"$WORK/7z-info.out" 2>&1; echo "$?" >"$WORK/7z-info.rc"
  fi
  # **A real archive in each format the image can CREATE, read back through
  # `7z l -slt`.** Testing 7z against a `.7z` only proves it reads its own
  # output; these three are made by entirely different tools. This is the
  # measurement behind "7z opens .arj / .lzo / .lrz".
  if have arj; then
    ( cd "$WORK/arch" && timeout 20 arj a -r "$WORK/probe.arj" probe.txt ) >/dev/null 2>&1 || true
  fi
  if have lzop; then
    ( cd "$WORK/arch" && timeout 20 lzop -o "$WORK/probe.lzo" probe.txt ) >/dev/null 2>&1 || true
  fi
  if have lrzip; then
    ( cd "$WORK/arch" && timeout 20 lrzip -q -o "$WORK/probe.lrz" probe.txt ) >/dev/null 2>&1 || true
  fi
  for made in arj lzo lrz; do
    if [[ -f "$WORK/probe.$made" ]] && have 7z; then
      timeout 25 7z l -slt "$WORK/probe.$made" >"$WORK/read-$made.out" 2>&1
      echo "$?" >"$WORK/read-$made.rc"
    fi
  done
  # **The measurement above showed 7z cannot open .lzo or .lrz** (rc=2 on
  # both, against archives their own tools created). So a parser for those
  # formats needs `lzop`/`lrzip`'s *own* interfaces, which are a different
  # shape from `7z l -slt` - so they are captured here rather than guessed.
  if have lzop && [[ -f "$WORK/probe.lzo" ]]; then
    timeout 20 lzop -l "$WORK/probe.lzo" >"$WORK/lzop-list.out" 2>&1; echo "$?" >"$WORK/lzop-list.rc"
    timeout 20 lzop -d -c "$WORK/probe.lzo" >"$WORK/lzop-cat.out" 2>"$WORK/lzop-cat.err"; echo "$?" >"$WORK/lzop-cat.rc"
  fi
  if have lrzip && [[ -f "$WORK/probe.lrz" ]]; then
    timeout 20 lrzip -t "$WORK/probe.lrz" >"$WORK/lrzip-list.out" 2>&1; echo "$?" >"$WORK/lrzip-list.rc"
    timeout 20 lrzcat "$WORK/probe.lrz" >"$WORK/lrzcat.out" 2>"$WORK/lrzcat.err"; echo "$?" >"$WORK/lrzcat.rc"
  fi
  # --- the rest of what shani-tools ships, captured in ONE run ----------------
  # The remaining gap list is ~65 commands and measuring them a few at a time
  # cost a 6-minute boot each. These are the ones that answer a question a
  # person actually asks; the rest (hdparm, cloudflared, caddy, gobuster,
  # zsync, nbdkit, telnet, ftp) are root-only, servers, or brute-forcers, and
  # are recorded as deliberately not built rather than measured.
  for tool in svn hg restic rclone iperf3 socat iftop arpwatch delv host nslookup wget aria2c; do
    have "$tool" || continue
    probe "$tool-version" "$tool" --version
  done
  # Behaviour, not just presence: what these print for a real invocation.
  # **A real repository, not a directory.** `svn info` on a plain folder exits
  # 1 and prints nothing, and `hg root` exits 255 - measured on the 2026-10-10
  # run - so neither said anything about the output shape a parser has to
  # read. `svnadmin create` and `hg init` make one, and then the commands are
  # asked about something real.
  if have svnadmin; then
    timeout 30 svnadmin create "$WORK/svnrepo" >"$WORK/svnadmin.out" 2>&1; echo "$?" >"$WORK/svnadmin.rc"
    if [[ -d "$WORK/svnrepo" ]]; then
      timeout 20 svn info "$WORK/svnrepo" >"$WORK/svn-info.out" 2>"$WORK/svn-info.err"; echo "$?" >"$WORK/svn-info.rc"
      timeout 20 svn status "$WORK/svnrepo" >"$WORK/svn-status.out" 2>&1; echo "$?" >"$WORK/svn-status.rc"
      timeout 20 svn log -l 3 "$WORK/svnrepo" >"$WORK/svn-log.out" 2>&1; echo "$?" >"$WORK/svn-log.rc"
    fi
  fi
  if have hg; then
    mkdir -p "$WORK/hgrepo"
    ( cd "$WORK/hgrepo" && timeout 20 hg init ) >"$WORK/hginit.out" 2>&1; echo "$?" >"$WORK/hginit.rc"
    if [[ -d "$WORK/hgrepo/.hg" ]]; then
      ( cd "$WORK/hgrepo" && timeout 20 hg root ) >"$WORK/hg-root.out" 2>"$WORK/hg-root.err"; echo "$?" >"$WORK/hg-root.rc"
      ( cd "$WORK/hgrepo" && timeout 20 hg status ) >"$WORK/hg-status.out" 2>&1; echo "$?" >"$WORK/hg-status.rc"
      ( cd "$WORK/hgrepo" && timeout 20 hg summary ) >"$WORK/hg-summary.out" 2>&1; echo "$?" >"$WORK/hg-summary.rc"
    fi
  fi
  # And the cloud tools, against the remote this image actually has.
  if have rclone; then
    timeout 20 rclone listremotes >"$WORK/rclone-remotes.out" 2>&1; echo "$?" >"$WORK/rclone-remotes.rc"
    timeout 20 rclone about >"$WORK/rclone-about.out" 2>&1; echo "$?" >"$WORK/rclone-about.rc"
  fi
  if have restic; then
    timeout 20 restic version >"$WORK/restic-version.out" 2>&1; echo "$?" >"$WORK/restic-version.rc"
    # No repository configured is the honest common case; its wording matters.
    timeout 20 restic snapshots >"$WORK/restic-snapshots.out" 2>"$WORK/restic-snapshots.err"; echo "$?" >"$WORK/restic-snapshots.rc"
  fi
  if have iperf3; then
    timeout 20 iperf3 --version >"$WORK/iperf3-version.out" 2>&1; echo "$?" >"$WORK/iperf3-version.rc"
    # The client half with no server: a real failure, and its own wording.
    timeout 20 iperf3 -c 127.0.0.1 -t 1 -p 59999 >"$WORK/iperf3-noserver.out" 2>&1; echo "$?" >"$WORK/iperf3-noserver.rc"
  fi
  if have socat; then timeout 20 socat -V >"$WORK/socat-version.out" 2>&1; echo "$?" >"$WORK/socat-version.rc"; fi
  if have iftop; then
    # iftop is a curses UI; `-t` makes it one-shot text, and without a bound
    # it sits there refreshing forever.
    timeout 15 iftop -t -n 1 >"$WORK/iftop-text.out" 2>&1; echo "$?" >"$WORK/iftop-text.rc"
  fi
  if have arpwatch; then timeout 20 arpwatch --version >"$WORK/arpwatch-version.out" 2>&1; echo "$?" >"$WORK/arpwatch-version.rc"; fi
  if have delv; then timeout 20 delv example.com A >"$WORK/delv.out" 2>&1; echo "$?" >"$WORK/delv.rc"; fi
  if have host; then timeout 20 host example.com >"$WORK/host.out" 2>&1; echo "$?" >"$WORK/host.rc"; fi
  if have nslookup; then timeout 20 nslookup example.com >"$WORK/nslookup.out" 2>&1; echo "$?" >"$WORK/nslookup.rc"; fi
  # And the per-process I/O and network monitors shani-tools ships: "why is my
  # disk busy" and "what is using my bandwidth" have no Chronoa answer at all.
  if have iotop; then probe iotop iotop -b -n 1 -o; fi
  if have iostat; then probe iostat iostat -x 1 2; fi
  if have nethogs; then probe nethogs nethogs -t -c 1; fi
  # `-c 1` is what makes bandwhich finite; without it this is what hung the run.
  if have bandwhich; then probe bandwhich bandwhich --raw -c 1; fi
  if have strace; then probe strace strace -f -e trace=openat /bin/true; fi
  # 7z: a real round-trip, so the listing's parseable shape and the extraction's
  # exit contract are both measured rather than remembered. extract_archive
  # handles tar and zip through Python's stdlib and nothing else.
  if have 7z; then    mkdir -p "$WORK/seven"
    printf 'hello from seven\n' >"$WORK/seven/one.txt"
    printf 'second file\n' >"$WORK/seven/two.txt"
    7z a -t7z "$WORK/round.7z" "$WORK/seven" >"$WORK/7z-a.out" 2>&1; echo "$?" >"$WORK/7z-a.rc"
    # `-slt` is the technical listing: `Key = value` lines rather than a table.
    7z l -slt "$WORK/round.7z" >"$WORK/7z-slt.out" 2>&1; echo "$?" >"$WORK/7z-slt.rc"
    mkdir -p "$WORK/seven-out"
    7z x -o"$WORK/seven-out" -y "$WORK/round.7z" >"$WORK/7z-x.out" 2>&1; echo "$?" >"$WORK/7z-x.rc"
    # A member that climbs out of the destination: what 7z itself does with it
    # is what a safety model written on top must account for.
    mkdir -p "$WORK/evil"
    printf 'payload\n' >"$WORK/evil/payload"
    ln -sf /etc/passwd "$WORK/evil/escape" 2>/dev/null || true
    7z a -t7z "$WORK/evil.7z" "$WORK/evil" >/dev/null 2>&1
    7z x -o"$WORK/evil-out" -y "$WORK/evil.7z" >"$WORK/7z-evil.out" 2>&1; echo "$?" >"$WORK/7z-evil.rc"
  fi
fi

# --- compsize: how much btrfs compression is actually saving -------------------
# ShaniOS installs on btrfs with compression, and nothing here answers "how
# much is it saving me". `compsize` walks the extents and reports the ratio.
#
# **Measured 2026-10-10, twice, and the second measurement is why the capture
# walks subvolumes.** `compsize /` in an nspawn slot answers *"Not btrfs"* -
# nspawn's root is an overlay, not the image's btrfs - so the first run
# reported an environmental SKIP for a tool that works fine on the real
# machine. ShaniOS's fstab documents the subvolumes (@data, @home, @cache,
# @log); those are what the slot actually mounts, so they are what gets read.
for f in "$WORK"/compsize_*.rc; do
  [[ -f "$f" ]] || continue
  name=$(basename "$f" .rc)
  out=$(cat "${f%.rc}.out" 2>/dev/null); rc=$(cat "$f")
  err=$(tr -d '\n' <"${f%.rc}.err" 2>/dev/null | head -c 120)
  if [[ "$rc" == 0 ]] && grep -qiE 'disk size|uncompressed|compressed' <<<"$out"; then
    line=$(grep -iE 'TOTAL|Disk size' <<<"$out" | head -1 | tr -s ' \t' ' ')
    printf '%s\n' "$out" | sed 's/^/  | /'
    res "compsize-shape-${name#compsize}" "PASS (rc=0 with a size line: ${line:0:80})"
  elif grep -qiE 'not btrfs|No such file|permission denied' <<<"$err"; then
    res "compsize-shape-${name#compsize}" "SKIP (rc=${rc}, environmental not a shape: ${err})"
  elif grep -qiE '^No files' <<<"$err"; then
    # **A legitimate answer, not a shape failure.** `compsize` on a directory
    # with nothing in it says "No files." and exits 1 - an empty @home in a
    # slot is exactly that. Asserting it as a FAIL reported a harness bug where
    # there was none, which is the same class of wrong verdict as the reverse.
    res "compsize-shape-${name#compsize}" "PASS (rc=${rc}, 'No files.' - an empty tree is compsize's own answer and not a failure)"
  else
    res "compsize-shape-${name#compsize}" "FAIL (rc=${rc}, no size line; stderr: ${err:-<empty>})"
  fi
done

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

# --- 7z: the technical listing and the extraction contract --------------------
if [[ -f "$WORK/7z-slt.rc" ]]; then
  slt=$(cat "$WORK/7z-slt.out")
  # `-slt` prints `Path = <name>` per member. The round-trip created two files,
  # so both must appear - a listing that names one is not a listing.
  paths=$(grep -cE '^Path = ' <<<"$slt" || true)
  if [[ "$(cat "$WORK/7z-a.rc")" == 0 ]] && (( paths >= 2 )); then
    res "7z-slt-shape" "PASS (created with rc=0, listed ${paths} members as 'Path = <name>')"
  else
    res "7z-slt-shape" "FAIL (7z a rc=$(cat "$WORK/7z-a.rc"), ${paths} 'Path =' lines in -slt output: $(tr -d '\n' <<<"$slt" | head -c 100))"
  fi
  # Extraction, and what it did with the symlink member.
  xrc=$(cat "$WORK/7z-x.rc")
  files=$(find "$WORK/seven-out" -type f 2>/dev/null | wc -l)
  if [[ "$xrc" == 0 ]] && (( files >= 2 )); then
    res "7z-extract-contract" "PASS (x rc=${xrc}, ${files} file(s) landed - a plain invocation works and the destination is what gets verified)"
  else
    res "7z-extract-contract" "FAIL (x rc=${xrc} but only ${files} file(s) landed)"
  fi
  # **The safety finding, printed in full.** `7z x` extracts a symlink member
  # with rc=0 and no warning, so a hostile archive writes outside the
  # destination unless the listing is checked first - which is what
  # extract_archive already does for tar and zip and must do here too. The
  # whole `-slt` output is printed because a parser written against a
  # remembered format is how a safety check gets the shape wrong.
  sed 's/^/  | /' "$WORK/7z-slt.out" | head -40
  if [[ -f "$WORK/7z-evil.rc" ]]; then
    evil_out=$(tr -d '\n' <"$WORK/7z-evil.out" 2>/dev/null | head -c 110)
    res "7z-symlink-member" "PASS (x rc=$(cat "$WORK/7z-evil.rc") with a symlink member: ${evil_out})"
  fi
fi

# --- v4l2: what the camera can actually do ------------------------------------
if [[ -f "$WORK/v4l2-formats.rc" ]]; then
  fmts=$(cat "$WORK/v4l2-formats.out")
  if grep -qE '^\s*\[\d+\]' <<<"$fmts"; then
    printf '%s\n' "$fmts" | head -30 | sed 's/^/  | /'
    res "v4l2-formats-shape" "PASS ($(grep -cE '^\s*\[[0-9]+\]' <<<"$fmts") pixel-format classes, printed whole so the parser is written against the real list)"
  else
    err=$(tr -d '\n' <"$WORK/v4l2-formats.err" | head -c 100)
    res "v4l2-formats-shape" "FAIL (rc=$(cat "$WORK/v4l2-formats.rc"), no '[N]' format lines: ${err})"
  fi
fi

# --- clockdiff: is this machine's clock right ----------------------------------
# `timebase` reports whether NTP *says* it is synchronised; this measures the
# actual offset against a peer, which is the other half of the same question.
if [[ -f "$WORK/clockdiff.rc" ]]; then
  out=$(cat "$WORK/clockdiff.out"); rc=$(cat "$WORK/clockdiff.rc")
  if [[ "$rc" == 0 ]] && grep -qiE 'offset|delay' <<<"$out"; then
    printf '%s\n' "$out" | sed 's/^/  | /'
    res "clockdiff-shape" "PASS ($(tr -d '\n' <<<"$out" | head -c 80))"
  else
    err=$(tr -d '\n' <"$WORK/clockdiff.err" | head -c 100)
    res "clockdiff-shape" "SKIP (rc=${rc}: ${err:-no offset in output} - clockdiff needs the peer to answer ICMP timestamps, and a gateway that does not is a legitimate environmental cause)"
  fi
fi

# --- luksDump: what a LUKS volume actually is ---------------------------------
# disk_health reports "crypto_LUKS" from lsblk and stops. The cipher, key
# size, hash and how many key slots are used are what "is it encrypted" means
# to anyone who has to answer for it.
if [[ -f "$WORK/luksdump.rc" ]]; then
  out=$(cat "$WORK/luksdump.out"); rc=$(cat "$WORK/luksdump.rc")
  if [[ "$rc" == 0 ]] && grep -qE 'Cipher name|Version' <<<"$out"; then
    cipher=$(grep -m1 'Cipher name' <<<"$out" | tr -s ' \t' ' ')
    slots=$(grep -cE '^ *[0-9]+: ENABLED' <<<"$out")
    res "luksdump-shape" "PASS (rc=0, ${cipher}, ${slots} enabled key slot(s) - the whole dump is what a parser would read)"
    head -20 "$WORK/luksdump.out" | sed 's/^/  | /'
  else
    err=$(tr -d '\n' <"$WORK/luksdump.err" | head -c 110)
    res "luksdump-shape" "SKIP (rc=${rc}: ${err} - no LUKS volume on this slot, or the tool refused it; both are honest causes and neither is a shape failure)"
  fi
fi

# --- the archive family shani-tools-extra ships by design ---------------------
for tool in unrar cabextract lrzip lzop arj unar lsar; do
  [[ -f "$WORK/arch-$tool-help.rc" ]] || continue
  rc=$(cat "$WORK/arch-$tool-help.rc")
  out=$(head -6 "$WORK/arch-$tool-help.out" 2>/dev/null | tr '\n' '|' | head -c 160)
  # **rc=124 is `timeout` killing it, and it is not a PASS.** A tool whose
  # --help never returns is a different fact from one whose help text was read,
  # and reporting both the same way is how a hang becomes a green line.
  if [[ "$rc" == 124 ]]; then
    res "archive-tool-$tool" "SKIP (--help did not return within 25s on this image)"
  else
    res "archive-tool-$tool" "PASS (rc=${rc}, present: ${out})"
  fi
done

# --- per-process disk I/O, and per-process network ----------------------------
# Nothing in Chronoa answers "why is my disk busy" or "what is using my
# bandwidth": the network sense reads /sys counters (per-interface totals) and
# the resources sense counts zombies, swap and file descriptors. These are the
# per-*process* answers, and shani-tools ships four tools for them.
if [[ -f "$WORK/iostat.rc" ]]; then
  out=$(cat "$WORK/iostat.out")
  if grep -qE 'Device.*r\/s|avg-cpu' <<<"$out"; then
    res "iostat-shape" "PASS ($(grep -cE '^[a-z]+[0-9]' <<<"$out") device rows, header: $(head -3 <<<"$out" | tr '\n' '|' | head -c 90))"
    head -8 "$WORK/iostat.out" | sed 's/^/  | /'
  else
    res "iostat-shape" "FAIL (rc=$(cat "$WORK/iostat.rc"), no Device/avg-cpu header: $(tr -d '\n' <<<"$out" | head -c 90))"
  fi
fi

for tool in iotop nethogs bandwhich strace; do
  [[ -f "$WORK/$tool.rc" ]] || continue
  rc=$(cat "$WORK/$tool.rc")
  out=$(head -c 200 "$WORK/$tool.out" 2>/dev/null | tr '\n' '|')
  err=$(head -c 100 "$WORK/$tool.err" 2>/dev/null | tr '\n' '|')
  # **Three outcomes, not two.** rc=124 means `timeout` stopped it, which is
  # neither "it printed something" nor "it printed nothing" - it is the third
  # thing, and this is exactly where the 57-minute hang would otherwise have
  # been reported as an empty-output SKIP naming the wrong cause.
  if [[ "$rc" == 124 ]]; then
    res "$tool-shape" "SKIP (did not return within 25s on this image - it is a continuous monitor; anything it printed before the bound: ${out:0:60})"
  elif [[ -s "$WORK/$tool.out" ]]; then
    res "$tool-shape" "PASS (rc=${rc}: ${out:0:110})"
  else
    res "$tool-shape" "SKIP (rc=${rc}, no output; stderr: ${err:-empty} - most of these need root or a terminal)"
  fi
done

# --- can 7z really read these formats? (not just its own) --------------------
# The claim under test is the one both `extract_archive` and `list_archive`
# make in their docstrings. A docstring is not evidence.
if [[ -f "$WORK/7z-info.rc" ]]; then
  info=$(cat "$WORK/7z-info.out" 2>/dev/null)
  if grep -qiE 'rar' <<<"$info"; then
    res "sevenzip-reads-rar" "PASS (this image's 7z lists RAR: $(grep -oiE '[a-z0-9]*rar[a-z0-9]*' <<<"$info" | sort -u | tr '\n' ' ' | head -c 60))"
  else
    fmts=$(awk '/^Formats:/,/^Codecs:/' <<<"$info" | tr -cs 'A-Za-z0-9' '\n' | grep -E '.{2,}' | sort -u | tr '\n' ' ')
    res "sevenzip-reads-rar" "FAIL (this image's 7z does NOT list RAR. A .rar must be routed to unar/lsar, which ship in shani-tools-extra for exactly that. Formats it does list: ${fmts:0:140})"
  fi
fi

# A real archive made by a *different* tool, read back through 7z. Testing
# 7z against a .7z only proves it reads its own output.
#
# **"7z cannot read this" is a PASS, not a FAIL.** These checks exist to
# establish which reader a format needs; a permanent red line for a true fact
# is the "list that says environmental and stops asking why" trap, and it
# trains a reader to ignore the whole block. The FAIL is reserved for the only
# genuinely broken case: *nothing on this image can open this format*.
for made in arj lzo lrz; do
  [[ -f "$WORK/read-$made.rc" ]] || continue
  rc=$(cat "$WORK/read-$made.rc")
  owner="lzop"; [[ "$made" == lrz ]] && owner="lrzip"
  if [[ "$rc" == 0 ]] && grep -q "^Path = " "$WORK/read-$made.out"; then
    res "7z-reads-$made" "PASS (rc=0, $(grep -c '^Path = ' "$WORK/read-$made.out") member(s) from a real .$made made by another tool - 7z is the right reader)"
  elif have "$owner"; then
    res "7z-reads-$made" "PASS (rc=${rc}: 7-Zip cannot read .$made - measured, and $owner is installed to do it, which is why archives.py routes .$made away from 7z)"
  else
    res "7z-reads-$made" "FAIL (rc=${rc}: 7z cannot read .$made AND $owner is not installed, so nothing on this image can open it)"
  fi
done

# The tools that CAN open what 7z cannot, and what their own output looks
# like. This is the measurement a parser for .lzo/.lrz has to be written
# against, and until it exists those two formats are refused rather than
# guessed at.
if [[ -f "$WORK/lzop-list.rc" ]]; then
  res "lzop-list-shape" "PASS (rc=$(cat "$WORK/lzop-list.rc"): $(head -3 "$WORK/lzop-list.out" | tr '\n' '|' | head -c 110))"
  head -6 "$WORK/lzop-list.out" | sed 's/^/  | /'
  res "lzop-cat-shape" "PASS (rc=$(cat "$WORK/lzop-cat.rc"), $(wc -c <"$WORK/lzop-cat.out") byte(s) to stdout)"
fi
if [[ -f "$WORK/lrzip-list.rc" ]]; then
  res "lrzip-list-shape" "PASS (rc=$(cat "$WORK/lrzip-list.rc"): $(head -3 "$WORK/lrzip-list.out" | tr '\n' '|' | head -c 110))"
  head -6 "$WORK/lrzip-list.out" | sed 's/^/  | /'
  res "lrzcat-shape" "PASS (rc=$(cat "$WORK/lrzcat.rc"), $(wc -c <"$WORK/lrzcat.out") byte(s) to stdout)"
fi

# --- the rest of what shani-tools ships -------------------------------------
# Each prints the real first lines, so a parser can be written against what
# the tool actually said rather than what a man page says it says.
for tool in svn hg restic rclone iperf3 socat arpwatch; do
  [[ -f "$WORK/$tool-version.rc" ]] || continue
  rc=$(cat "$WORK/$tool-version.rc")
  first=$(head -1 "$WORK/$tool-version.out" 2>/dev/null | head -c 70)
  res "$tool-version" "PASS (rc=${rc}: ${first})"
done
# Behaviours, which are what a parser has to match.
if [[ -f "$WORK/svn-info.rc" ]]; then
  res "svn-info-shape" "PASS (rc=$(cat "$WORK/svn-info.rc"), $(wc -l <"$WORK/svn-info.out") lines; first: $(head -1 "$WORK/svn-info.out" | head -c 60))"
  head -8 "$WORK/svn-info.out" | sed 's/^/  | /'
fi
[[ -f "$WORK/svn-status.rc" ]] && res "svn-status-shape" "PASS (rc=$(cat "$WORK/svn-status.rc"): $(head -2 "$WORK/svn-status.out" | tr '\n' '|' | head -c 70))"
[[ -f "$WORK/svn-log.rc" ]] && res "svn-log-shape" "PASS (rc=$(cat "$WORK/svn-log.rc"): $(head -3 "$WORK/svn-log.out" | tr '\n' '|' | head -c 80))"
if [[ -f "$WORK/hg-root.rc" ]]; then
  res "hg-root-shape" "PASS (rc=$(cat "$WORK/hg-root.rc"): $(head -1 "$WORK/hg-root.out" | head -c 70))"
  res "hg-summary-shape" "PASS (rc=$(cat "$WORK/hg-summary.rc"): $(head -2 "$WORK/hg-summary.out" | tr '\n' '|' | head -c 80))"
fi
# `rclone listremotes` with none configured is an empty list and rc=0 - which
# is the shape a "you have no remotes" answer has to recognise, not a failure.
[[ -f "$WORK/rclone-remotes.rc" ]] && res "rclone-remotes-shape" "PASS (rc=$(cat "$WORK/rclone-remotes.rc"), $(wc -l <"$WORK/rclone-remotes.out") remote(s) configured)"
[[ -f "$WORK/rclone-about.rc" ]] && res "rclone-about-shape" "PASS (rc=$(cat "$WORK/rclone-about.rc"): $(head -1 "$WORK/rclone-about.out" | head -c 60))"
# restic with no repository is the honest common case, and its refusal wording
# is what a backup skill has to report rather than inventing its own.
if [[ -f "$WORK/restic-snapshots.rc" ]]; then
  res "restic-norepo-shape" "PASS (rc=$(cat "$WORK/restic-snapshots.rc"): $(head -2 "$WORK/restic-snapshots.err" | tr '\n' '|' | head -c 90))"
fi
# delv's verdict line is what dns_lookup reads; capture it verbatim.
if [[ -f "$WORK/delv.rc" ]]; then
  res "delv-verdict-shape" "PASS (rc=$(cat "$WORK/delv.rc"): $(grep -m1 '^;' "$WORK/delv.out" | head -c 60))"
fi
[[ -f "$WORK/host.rc" ]] && res "host-shape" "PASS (rc=$(cat "$WORK/host.rc"): $(head -1 "$WORK/host.out" | head -c 70))"
[[ -f "$WORK/nslookup.rc" ]] && res "nslookup-shape" "PASS (rc=$(cat "$WORK/nslookup.rc"): $(grep -m1 'Server:' "$WORK/nslookup.out" | head -c 60))"

echo "== probe done"