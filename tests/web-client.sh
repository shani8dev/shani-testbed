#!/bin/bash
# Real-browser test of lib/web_client.py, run in a throwaway Arch container by
# tests/run-web-client.sh: a clean fixture site must PASS every check, and a
# broken one must FAIL each check it plants a fault for — a check that cannot
# fail is not a check.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
pacman -Sy --noconfirm --needed chromium python >/dev/null 2>&1 || { res install "FAIL"; exit 1; }
F=/fixtures C=/lib-under-test/web_client.py
# served the way GitHub Pages serves the real sites (lib/web_serve.py)
python3 /lib-under-test/web_serve.py "$F/good" 8701 >/dev/null 2>&1 &
python3 /lib-under-test/web_serve.py "$F/bad"  8702 >/dev/null 2>&1 &
python3 /lib-under-test/web_serve.py "$F/smooth-scroll" 8703 >/dev/null 2>&1 &
sleep 1

good=$(python3 "$C" --url=http://127.0.0.1:8701/ --expect='#app' --offline --crawl=5 \
        --shots=/tmp/shots --json=/tmp/good.json 2>&1); grc=$?
echo "$good" | sed 's/^/  good| /'
[ "$grc" -eq 0 ] && res good-site-passes PASS || res good-site-passes "FAIL (rc=$grc)"
for c in errors egress title lang a11y-names offline crawl "overflow desktop" "overflow tablet" "overflow mobile" "tap-targets tablet" "tap-targets mobile" "errors tablet" "errors mobile" "clipped desktop" "clipped mobile" "text-overlap desktop" "text-overlap mobile"; do
    grep -qE "^RESULT $c +PASS" <<<"$good" && res "good $c" PASS || res "good $c" FAIL
done
# 3 built-in devices x 2 modes, full page
[ "$(ls /tmp/shots/*.png 2>/dev/null | wc -l)" -eq 6 ] && ls /tmp/shots/tablet-dark.png >/dev/null 2>&1 && res good-shots-written PASS || res good-shots-written "FAIL ($(ls /tmp/shots 2>/dev/null | tr '\n' ' '))"

# the bad site: tracker.example is mapped to the bad server itself, so the
# request really happens (a 404) and egress has a foreign host to see
bad=$(python3 "$C" --url=http://127.0.0.1:8702/ --resolve='MAP tracker.example 127.0.0.1:8702' --crawl=5 2>&1); brc=$?
echo "$bad" | sed 's/^/  bad | /'
[ "$brc" -eq 1 ] && res bad-site-fails PASS || res bad-site-fails "FAIL (rc=$brc)"
for c in errors egress title lang a11y-names "overflow desktop" "overflow mobile" "tap-targets mobile" "clipped mobile"; do
    grep -qE "^RESULT $c +FAIL" <<<"$bad" && res "bad $c caught" PASS || res "bad $c caught" FAIL
done
grep -q 'planted exception' <<<"$bad" && res bad-exception-named PASS || res bad-exception-named FAIL
grep -q 'planted console error' <<<"$bad" && res bad-console-error-named PASS || res bad-console-error-named FAIL
grep -q 'div.clipped-probe' <<<"$bad" && res bad-clipped-element-named PASS || res bad-clipped-element-named FAIL
grep -q 'button 10x10 "x"' <<<"$bad" && res bad-small-target-named PASS || res bad-small-target-named FAIL
# a full-page shot is taller than the viewport on a long page
python3 -c "import struct,sys; d=open('/tmp/shots/mobile-light.png','rb').read(24); w,h=struct.unpack('>II',d[16:24]); sys.exit(0 if w==390*3 or w==390 else 1)" && res good-mobile-shot-is-mobile-width PASS || res good-mobile-shot-is-mobile-width FAIL
grep -q 'HTTP 404 .*missing.png' <<<"$bad" && res bad-404-named PASS || res bad-404-named FAIL
grep -q 'contacted tracker.example' <<<"$bad" && res bad-egress-host-named PASS || res bad-egress-host-named FAIL
grep -qE '^RESULT crawl +FAIL' <<<"$bad" && grep -q 'dead-link.html: HTTP 404' <<<"$bad" && res bad-dead-link-caught PASS || res bad-dead-link-caught FAIL
# the good site's /saved is a client-side route behind the 404.html hop: crawled
# and clean, so a working SPA redirect is not reported as a broken page
grep -qE '^RESULT crawl +PASS \(2/2' <<<"$good" && res spa-redirect-route-clean PASS || res spa-redirect-route-clean "FAIL ($(grep '^RESULT crawl' <<<"$good"))"

# A start page whose destinations are buttons with onclick handlers rather than
# anchors: the crawler follows nothing, so it must FAIL as having crawled
# nothing. Before this existed, such a site reported "0/0 same-origin pages
# clean" and a PASS - the confidence of a green check with no evidence behind
# it. That is how shani-docs and shani-blog looked on the real site, where the
# home page's cards are <button onclick="navigate(...)">.
python3 /lib-under-test/web_serve.py "$F/anchors-but-not-links" 8703 >/dev/null 2>&1 &
sleep 1
nolinks=$(python3 "$C" --url=http://127.0.0.1:8703/ --offline --crawl=5 2>&1)
echo "$nolinks" | sed 's/^/  nolink| /'
grep -qE '^RESULT crawl +FAIL' <<<"$nolinks" \
  && grep -q '0 pages crawled' <<<"$nolinks" \
  && res crawl-of-zero-pages-fails PASS \
  || res crawl-of-zero-pages-fails "FAIL ($(grep '^RESULT crawl' <<<"$nolinks"))"
# and the detail must name the cause, so the failure is actionable rather
# than just a red line
grep -q 'onclick rather than href' <<<"$nolinks" && res crawl-zero-names-the-cause PASS || res crawl-zero-names-the-cause FAIL

# the same buttons-only page with a sitemap.xml: the crawl falls back to the
# sitemap (on this host, not the production one it names) and finds both its
# clean page and its dead one - the docs and blog home pages are this shape
python3 /lib-under-test/web_serve.py "$F/buttons-with-sitemap" 8704 >/dev/null 2>&1 &
sleep 1
smap=$(python3 "$C" --url=http://127.0.0.1:8704/ --crawl=5 2>&1)
grep -qE '^RESULT crawl +FAIL \(1/2 .*from sitemap.xml' <<<"$smap" && grep -q 'gone.html: HTTP 404' <<<"$smap" \
  && res crawl-falls-back-to-sitemap PASS || res crawl-falls-back-to-sitemap "FAIL ($(grep '^RESULT crawl' <<<"$smap"))"

# with scripts off a page must show something: the good fixture does, and a
# full-screen loader only script removes (shani-blog's, before its fix) FAILs
grep -qE '^RESULT no-js +PASS' <<<"$good" && res nojs-good-page-passes PASS || res nojs-good-page-passes "FAIL ($(grep '^RESULT no-js' <<<"$good"))"
python3 /lib-under-test/web_serve.py "$F/script-only-overlay" 8705 >/dev/null 2>&1 &
sleep 1
ov=$(python3 "$C" --url=http://127.0.0.1:8705/ --devices=mobile --schemes=light --no-features 2>&1)
grep -qE '^RESULT no-js +FAIL .*div#loader covers' <<<"$ov" && res nojs-overlay-caught PASS || res nojs-overlay-caught "FAIL ($(grep '^RESULT no-js' <<<"$ov"))"

# --allow-host and --ignore really relax what they name
relaxed=$(python3 "$C" --url=http://127.0.0.1:8702/ --resolve='MAP tracker.example 127.0.0.1:8702' \
          --allow-host=tracker.example 2>&1)
grep -qE '^RESULT egress +PASS' <<<"$relaxed" && res allow-host-relaxes-egress PASS || res allow-host-relaxes-egress FAIL

# a page that cannot load at all is a FAIL, not a crash or a pass
nl=$(python3 "$C" --url=http://127.0.0.1:8709/ 2>&1); nrc=$?
[ "$nrc" -eq 1 ] && grep -qE '^RESULT load +FAIL' <<<"$nl" && res unreachable-is-fail PASS || res unreachable-is-fail "FAIL (rc=$nrc)"

# --- feature checks: every one PASSes on a page that has the feature working,
# and FAILs on a page where it is broken (each a deliberate fault) -----------
gf=$(python3 "$C" --url=http://127.0.0.1:8701/docs/ --devices=desktop,mobile --schemes=light --shots= 2>&1)
echo "$gf" | grep -E '^RESULT' | sed 's/^/  gfeat| /'
for c in "search desktop" "search-shortcut desktop" "theme desktop" "breadcrumbs desktop" "skip-link desktop" \
         "focus-visible desktop" "anchors desktop" "meta desktop" "new-tab-links desktop" "print desktop" \
         "disclosure desktop" "dialog desktop" "landmarks desktop" "headings desktop" "ids desktop" \
         "forms desktop" "head-meta desktop" "contrast desktop" "copy-code desktop" "toc desktop" \
         "focus-not-obscured desktop" "keyboard-trap desktop" "reading-progress desktop" "theme-persists desktop" \
         "color-scheme desktop" "back-to-top desktop" "site-files desktop" "menu mobile" "reflow-320 mobile"; do
    grep -qE "^RESULT $c +PASS" <<<"$gf" && res "good feature: $c" PASS || res "good feature: $c" "FAIL ($(grep -E "^RESULT $c " <<<"$gf" | cut -c42-160))"
done
# the inner page is judged on the device it is reported as: reflow-320 on the
# start page used to leave it at 320 px, and "mobile (inner page)" was 320
grep -q 'mobile inner page judged at 390x' <<<"$gf" && res inner-page-keeps-device PASS \
  || res inner-page-keeps-device "FAIL ($(grep 'inner page judged' <<<"$gf" | tr '\n' ' '))"
# a closed <details>' content has boxes but is never painted: not an overlap
grep -qE '^RESULT text-overlap desktop +PASS' <<<"$gf" && res closed-details-not-overlap PASS \
  || res closed-details-not-overlap "FAIL ($(grep -A2 '^RESULT text-overlap desktop' <<<"$gf" | tr '\n' ' '))"
bf=$(python3 "$C" --url=http://127.0.0.1:8702/docs/ --devices=desktop,mobile --schemes=light --shots= 2>&1)
echo "$bf" | grep -E '^RESULT' | sed 's/^/  bfeat| /'
for c in "search desktop" "theme desktop" "breadcrumbs desktop" "focus-visible desktop" "anchors desktop" \
         "meta desktop" "new-tab-links desktop" "landmarks desktop" "headings desktop" "ids desktop" \
         "forms desktop" "head-meta desktop" "contrast desktop" "media desktop" "site-files desktop" "menu mobile" \
         "overflow mobile" "text-overlap desktop"; do
    # overflow mobile: a page with <meta viewport> that is wider than the
    # phone - innerWidth grows with it, so only clientWidth catches it
    grep -qE "^RESULT $c +FAIL" <<<"$bf" && res "bad feature caught: $c" PASS || res "bad feature caught: $c" "FAIL ($(grep -E "^RESULT $c " <<<"$bf" | cut -c42-160))"
done

# --- a click must not be dispatched at stale coordinates ------------------------
# A page with scroll-behavior: smooth is still animating when a check measures a
# control, so the box it measured is stale by the time the click lands and the
# click hits whatever moved into its place: shani-website's install-guide button
# was boxed at scrollY=189, the click itself advanced the scroll to 453, and the
# click arrived at <section class="hero-section"> with aria-expanded still false.
# click() now re-measures and waits for the scroll to hold still first, so this
# fixture's disclosure must expand. Run against the previous click() it FAILs -
# which is what makes this an assertion about the fix and not a green line.
sf=$(python3 "$C" --url=http://127.0.0.1:8703/ --devices=mobile --schemes=light --shots= 2>&1)
echo "$sf" | grep -E '^RESULT' | sed 's/^/  smooth| /'
grep -qE '^RESULT disclosure mobile +PASS' <<<"$sf" && res smooth-scroll-click-lands PASS \
  || res smooth-scroll-click-lands "FAIL ($(grep -E '^RESULT disclosure mobile ' <<<"$sf" | cut -c42-160))"
