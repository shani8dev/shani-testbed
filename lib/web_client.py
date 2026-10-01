#!/usr/bin/env python3
"""Drive a real Chromium over the DevTools protocol and check a web page.

The browser is the system one (Arch `chromium`, or whatever --browser names) —
nothing is downloaded, and there is no Node, Playwright or websocket library:
`--remote-debugging-pipe` speaks CDP as NUL-delimited JSON over file
descriptors 3 and 4, which the Python standard library handles. So the same
file runs in the builder container, in a booted ShaniOS slot (against the
browser the image ships) and on a plain CI runner.

Each check prints `RESULT <name> PASS|FAIL|SKIP (detail)` like every other
harness check; the exit code is 1 when any RESULT is FAIL.

Checks (each one exists because a browser shows it and a link checker does not):
  errors       uncaught exceptions, console.error, HTTP >= 400 responses and
               failed loads on the page, plus Chrome's own issue reports
               (mixed content, CSP, cookies) and CSP violation events
  egress       every host the page talked to is the page's own or allowed
  title/lang   the document has a <title> and a lang attribute
  a11y         every interactive or image node in the accessibility tree has
               an accessible name (the tree screen readers actually get)
  expect       given CSS selectors exist once the page settled
  devices      desktop (1280x800), tablet (820x1180, touch, 2x) and mobile
               (390x844, touch, 3x) by default: each gets a fresh load (its own
               errors), an overflow check, a clipped-content check (cut off
               at the edge and unreachable: overflow-x hidden on the page), a
               tap-target check on touch
               devices (WCAG 2.2: >= 24x24 px), and full-page screenshots
               in every mode (light and dark)
  perf         LCP and CLS from the page's own PerformanceObserver, with
               optional budgets
  offline      with a service worker: it takes control, and the page still
               renders with the network cut
  spa          an unknown route still serves the app shell
  crawl        same-origin links from the start page load without errors
  shots        a full-page screenshot per device x mode

Usage: web_client.py --url=URL [options]  (see --help)
"""

import argparse
import base64
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from web_features import Features  # noqa: E402

RESULTS = []


def result(name, status, detail=""):
    RESULTS.append((name, status))
    print(f"RESULT {name:<40} {status}{' (' + detail + ')' if detail else ''}", flush=True)


class CDP:
    """CDP over --remote-debugging-pipe: fd 3 is the browser's input, fd 4 its
    output, every message a JSON object followed by a NUL byte."""

    def __init__(self, argv, timeout):
        to_browser_r, self._w = os.pipe()
        self._r, from_browser_w = os.pipe()

        def child_fds():
            # The browser expects exactly fds 3 and 4. Move both ends above 10
            # first, so dup2 onto 3 cannot clobber the other end if it was 3/4.
            a = fcntl.fcntl(to_browser_r, fcntl.F_DUPFD, 10)
            b = fcntl.fcntl(from_browser_w, fcntl.F_DUPFD, 10)
            os.dup2(a, 3)
            os.dup2(b, 4)
            os.close(a)
            os.close(b)

        # close_fds=False: Popen closes every fd not in pass_fds AFTER
        # preexec_fn, which would close the 3/4 made above. Nothing else leaks:
        # os.pipe() fds are close-on-exec, and dup2 clears that only on 3 and 4.
        self.proc = subprocess.Popen(
            argv, preexec_fn=child_fds, close_fds=False,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        os.close(to_browser_r)
        os.close(from_browser_w)
        fl = fcntl.fcntl(self._r, fcntl.F_GETFL)
        fcntl.fcntl(self._r, fcntl.F_SETFL, fl | os.O_NONBLOCK)
        self._buf = b""
        self._id = 0
        self.timeout = timeout
        self.events = []      # every event received, in order
        self.session = None

    def _read_messages(self, wait):
        import select
        ready, _, _ = select.select([self._r], [], [], wait)
        if not ready:
            return []
        try:
            chunk = os.read(self._r, 1 << 20)
        except BlockingIOError:
            return []
        if not chunk:
            raise RuntimeError("browser closed the DevTools pipe: "
                               + (self.proc.stderr.read(2000).decode(errors="replace")
                                  if self.proc.poll() is not None else ""))
        self._buf += chunk
        out = []
        while b"\0" in self._buf:
            msg, self._buf = self._buf.split(b"\0", 1)
            out.append(json.loads(msg))
        return out

    def send(self, method, params=None, session=True, timeout=None):
        self._id += 1
        mid = self._id
        msg = {"id": mid, "method": method, "params": params or {}}
        if session and self.session:
            msg["sessionId"] = self.session
        data = json.dumps(msg).encode() + b"\0"
        while data:
            n = os.write(self._w, data)
            data = data[n:]
        deadline = time.time() + (timeout or self.timeout)
        while time.time() < deadline:
            for m in self._read_messages(0.2):
                if m.get("id") == mid:
                    if "error" in m:
                        raise RuntimeError(f"{method}: {m['error'].get('message')}")
                    return m.get("result", {})
                if "method" in m:
                    self.events.append(m)
        raise TimeoutError(f"{method}: no reply in {timeout or self.timeout}s")

    def pump(self, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            for m in self._read_messages(min(0.2, max(0.0, deadline - time.time()))):
                if "method" in m:
                    self.events.append(m)

    def wait_event(self, method, seconds, since=0):
        deadline = time.time() + seconds
        while time.time() < deadline:
            for e in self.events[since:]:
                if e["method"] == method:
                    return e
            self.pump(0.2)
        return None

    def close(self):
        try:
            self.send("Browser.close", session=False, timeout=5)
        except Exception:
            pass
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


# Runs in every document before its own scripts: CSP violations and the two
# Core Web Vitals a lab run can measure.
PRELUDE = r"""
window.__shani = {csp: [], lcp: 0, cls: 0, shifters: {}};
const __sel = n => !n || !n.tagName ? '?' : n.tagName.toLowerCase() + (n.id ? '#' + n.id : '') +
  (n.classList && n.classList.length ? '.' + [...n.classList].slice(0, 3).join('.') : '');
document.addEventListener('securitypolicyviolation', e =>
  window.__shani.csp.push(e.violatedDirective + ' ' + (e.blockedURI || '')));
try {
  new PerformanceObserver(l => { for (const e of l.getEntries())
    window.__shani.lcp = Math.max(window.__shani.lcp, e.startTime); })
    .observe({type: 'largest-contentful-paint', buffered: true});
  new PerformanceObserver(l => { for (const e of l.getEntries())
    if (!e.hadRecentInput) { window.__shani.cls += e.value;
      for (const src of (e.sources || [])) { const k = __sel(src.node);
        window.__shani.shifters[k] = (window.__shani.shifters[k] || 0) + e.value; } } })
    .observe({type: 'layout-shift', buffered: true});
} catch (e) {}
"""

OVERFLOW_CULPRITS = r"""
(() => {
  const W = document.documentElement.clientWidth, out = [];
  const sel = e => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') +
    (e.classList.length ? '.' + [...e.classList].slice(0, 3).join('.') : '');
  for (const e of document.querySelectorAll('body *')) {
    const r = e.getBoundingClientRect();
    if (r.width === 0 || r.right <= W + 1) continue;
    // content inside a scrolling/clipping box does not widen the page
    let clipped = false;
    for (let a = e.parentElement; a && a !== document.body; a = a.parentElement)
      if (getComputedStyle(a).overflowX !== 'visible') { clipped = true; break; }
    if (clipped) continue;
    // innermost only: skip an element if a child of it also overflows
    if ([...e.children].some(c => c.getBoundingClientRect().right > W + 1)) continue;
    let p = e.parentElement, path = [sel(e)];
    for (let i = 0; i < 2 && p && p !== document.body; i++, p = p.parentElement) path.unshift(sel(p));
    out.push(path.join(' > ') + ' (right edge ' + Math.round(r.right) + 'px, viewport ' + W + 'px)');
    if (out.length >= 3) break;
  }
  if (!out.length) {
    // nothing as an ELEMENT reaches past the edge: then it is text - a long
    // unbreakable word - so name the innermost box whose content overflows
    for (const e of document.querySelectorAll('body *')) {
      if (e.scrollWidth > e.clientWidth + 1 && e.clientWidth > 0 && getComputedStyle(e).overflowX === 'visible' &&
          ![...e.children].some(c => c.scrollWidth > c.clientWidth + 1)) {
        out.push(sel(e) + ' text overflows by ' + (e.scrollWidth - e.clientWidth) + 'px: "' + (e.textContent || '').trim().slice(0, 40) + '" (overflow-wrap)');
        if (out.length >= 3) break;
      }
    }
  }
  return out;
})()
"""

# Content cut off at the viewport's right edge that the page cannot scroll
# to: overflow-x hidden/clip on html, body or a layout wrapper turns "too
# wide" into "silently missing", so scrollWidth (OVERFLOW above) says fine.
# Found on docs.shani.dev's phone layout, 2026-10-01: the second column of the
# "Browse documentation" grid was half off-screen. Content inside a real
# scroll container (overflow auto/scroll - a carousel, a code block) is
# reachable and not reported; only the innermost element is.
CLIPPED = r"""
(() => {
  const W = document.documentElement.clientWidth, out = [];
  const sel = e => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') +
    (e.classList.length ? '.' + [...e.classList].slice(0, 3).join('.') : '');
  const scrollable = a => /(auto|scroll)/.test(getComputedStyle(a).overflowX);
  for (const e of document.querySelectorAll('body *')) {
    const r = e.getBoundingClientRect(), cs = getComputedStyle(e);
    if (r.width < 8 || r.height < 8 || cs.visibility === 'hidden' || cs.position === 'fixed') continue;
    if (r.right <= W + 2 || r.left >= W - 2) continue;      // fully inside, or wholly off-canvas
    let reachable = false;
    for (let a = e.parentElement; a && a !== document.documentElement; a = a.parentElement)
      if (scrollable(a)) { reachable = true; break; }
    if (reachable) continue;
    if ([...e.children].some(c => { const q = c.getBoundingClientRect(); return q.right > W + 2 && q.left < W - 2 && q.width >= 8; })) continue;
    let p = e.parentElement, path = [sel(e)];
    for (let i = 0; i < 2 && p && p !== document.body; i++, p = p.parentElement) path.unshift(sel(p));
    out.push(path.join(' > ') + ' (' + Math.round(r.right - W) + 'px past the edge)');
    if (out.length >= 4) break;
  }
  return out;
})()
"""

INFO_ISSUES = {"LazyLoadImageIssue"}

# Text drawn over other text: a wrapped nav running into a logo, a badge
# over a heading. No width check sees it - the page fits, it is just
# unreadable (shani-blog's header at 820 px, 2026-10-01). Leaf text boxes in
# the first three screens; a pair counts when they share more than 30 % of
# the smaller one's area and neither contains the other.
TEXT_OVERLAP = r"""
(() => {
  const sel = e => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') +
    (e.classList.length ? '.' + [...e.classList].slice(0, 2).join('.') : '');
  const H = innerHeight * 3, boxes = [];
  for (const e of document.querySelectorAll('body *')) {
    if (!e.childNodes.length || ![...e.childNodes].some(c => c.nodeType === 3 && c.textContent.trim())) continue;
    const s = getComputedStyle(e); if (s.visibility === 'hidden' || +s.opacity < 0.1 || e.closest('dialog, [role=dialog], [aria-hidden=true]')) continue;
    // a closed <details>' content still has boxes (Chrome lays it out) but is
    // never painted: shani-website's collapsed pain-card answers "overlapped"
    // the next card's quote
    const d = e.closest('details:not([open])'); if (d && !e.closest('summary')) continue;
    // what is actually painted: each box cut to every clipping ancestor (a
    // collapsed sidebar group hides its entries in a 0-height overflow box -
    // they are laid out on top of the next group but nobody sees them)
    let clip = {left: -1e9, top: -1e9, right: 1e9, bottom: 1e9};
    for (let a = e.parentElement; a && a !== document.documentElement; a = a.parentElement) {
      if (/(hidden|clip|auto|scroll)/.test(getComputedStyle(a).overflow)) { const q = a.getBoundingClientRect();
        clip = {left: Math.max(clip.left, q.left), top: Math.max(clip.top, q.top), right: Math.min(clip.right, q.right), bottom: Math.min(clip.bottom, q.bottom)}; }
    }
    for (const r0 of e.getClientRects()) {
      const r = {left: Math.max(r0.left, clip.left), top: Math.max(r0.top, clip.top), right: Math.min(r0.right, clip.right), bottom: Math.min(r0.bottom, clip.bottom)};
      r.width = r.right - r.left; r.height = r.bottom - r.top;
      if (r.width > 2 && r.height > 2 && r.bottom > 0 && r.top < H) boxes.push([e, r]);
    }
    if (boxes.length > 1500) break;
  }
  const out = [];
  for (let i = 0; i < boxes.length && out.length < 4; i++) for (let j = i + 1; j < boxes.length; j++) {
    const [a, ra] = boxes[i], [b, rb] = boxes[j];
    if (a === b || a.contains(b) || b.contains(a)) continue;
    const w = Math.min(ra.right, rb.right) - Math.max(ra.left, rb.left), h = Math.min(ra.bottom, rb.bottom) - Math.max(ra.top, rb.top);
    if (w <= 0 || h <= 0) continue;
    if (w * h > 0.3 * Math.min(ra.width * ra.height, rb.width * rb.height)) {
      out.push(sel(a) + ' "' + a.textContent.trim().slice(0, 20) + '" over ' + sel(b) + ' "' + b.textContent.trim().slice(0, 20) + '"');
      break;
    }
  }
  return out;
})()
"""

INTERACTIVE_ROLES = {"button", "link", "textbox", "searchbox", "checkbox", "radio",
                     "combobox", "listbox", "menuitem", "menuitemcheckbox",
                     "menuitemradio", "tab", "switch", "slider", "spinbutton",
                     "image", "img"}


class Page:
    def __init__(self, cdp, args):
        self.cdp, self.args = cdp, args

    def evaluate(self, expr, await_promise=False, timeout=None):
        r = self.cdp.send("Runtime.evaluate", {
            "expression": expr, "returnByValue": True, "awaitPromise": await_promise},
            timeout=timeout)
        if "exceptionDetails" in r:
            raise RuntimeError(r["exceptionDetails"].get("text", "evaluate failed"))
        return r.get("result", {}).get("value")

    def navigate(self, url, settle=None, reload=False):
        """Load url and wait for load + a quiet network. Returns the events this
        load produced and the main document's HTTP status."""
        since = len(self.cdp.events)
        if reload:
            self.cdp.send("Page.reload", {"ignoreCache": False})
        else:
            r = self.cdp.send("Page.navigate", {"url": url})
            if r.get("errorText"):
                return self.cdp.events[since:], None, r["errorText"]
        self.cdp.wait_event("Page.loadEventFired", self.args.timeout, since)
        # network idle: nothing in flight for 500 ms (or the settle cap)
        inflight, quiet_since = set(), time.time()
        cap = time.time() + (settle or self.args.settle)
        seen = since
        while time.time() < cap:
            self.cdp.pump(0.1)
            for e in self.cdp.events[seen:]:
                m, p = e["method"], e.get("params", {})
                if m == "Network.requestWillBeSent":
                    inflight.add(p["requestId"]); quiet_since = time.time()
                elif m in ("Network.loadingFinished", "Network.loadingFailed"):
                    inflight.discard(p["requestId"]); quiet_since = time.time()
            seen = len(self.cdp.events)
            if not inflight and time.time() - quiet_since > 0.5:
                break
        evs = self.cdp.events[since:]
        # The status of the document the browser ENDED on: a GitHub Pages SPA
        # answers a client-side route with 404.html (status 404) whose script
        # redirects to the app, which restores the route - the shani-blog's
        # /bookmarks. A 404 that a working redirect follows is not a broken
        # page; a 404 page that stays is.
        docs = [e["params"]["response"]["status"] for e in evs
                if e["method"] == "Network.responseReceived" and e["params"].get("type") == "Document"]
        status = docs[-1] if docs else None
        return evs, status, None


def problems(events, ignore):
    """Error-class problems in a load's events, as human strings."""
    out, failed_ids = [], {}
    # index of the last document that loaded fine: a failed document BEFORE it
    # was redirected away from (the GitHub Pages SPA 404.html hop), not shown
    ok_doc = max((i for i, e in enumerate(events) if e["method"] == "Network.responseReceived"
                  and e["params"].get("type") == "Document" and e["params"]["response"]["status"] < 400),
                 default=-1)
    for i, e in enumerate(events):
        m, p = e["method"], e.get("params", {})
        if m == "Runtime.exceptionThrown":
            d = p["exceptionDetails"]
            out.append("exception: " + (d.get("exception", {}).get("description") or d.get("text", "")).split("\n")[0])
        elif m == "Runtime.consoleAPICalled" and p.get("type") == "error":
            out.append("console.error: " + " ".join(str(a.get("value", a.get("description", ""))) for a in p.get("args", [])))
        elif m == "Network.responseReceived":
            st = p["response"]["status"]
            if st >= 400 and not (p.get("type") == "Document" and i < ok_doc):
                out.append(f"HTTP {st} {p['response']['url']}")
        elif m == "Network.requestWillBeSent":
            failed_ids[p["requestId"]] = p["request"]["url"]
        elif m == "Network.loadingFailed" and not p.get("canceled"):
            out.append(f"load failed ({p.get('errorText')}) {failed_ids.get(p['requestId'], '?')}")
        elif m == "Audits.issueAdded":
            issue = p.get("issue", {})
            # Chrome's informational interventions, not defects: a lazily
            # loaded image being deferred is the page working as designed
            if issue.get("code") in INFO_ISSUES:
                continue
            # details is {"<kind>IssueDetails": {...}}: name the kind's own
            # error type/reason, or "GenericIssue" alone says nothing
            det = next(iter((issue.get("details") or {}).values()), {}) or {}
            why = det.get("errorType") or det.get("violationType") or det.get("performanceIssueType") or det.get("contentSecurityPolicyViolationType") \
                or det.get("mixedContentResolutionStatus") or ",".join(det.get("cookieWarningReasons", []) or det.get("cookieExclusionReasons", []))
            url = (det.get("request") or {}).get("url") or det.get("insecureURL") or det.get("blockedURL") \
                or det.get("url") or ""
            out.append(f"issue: {issue.get('code', '?')} {why or ''} {url}".rstrip())
    seen, uniq = set(), []
    for s in out:
        if s in seen or (ignore and re.search(ignore, s)):
            continue
        seen.add(s); uniq.append(s)
    return uniq


def hosts_contacted(events):
    hosts = set()
    for e in events:
        if e["method"] == "Network.requestWillBeSent":
            u = urllib.parse.urlsplit(e["params"]["request"]["url"])
            if u.scheme in ("http", "https", "ws", "wss"):
                hosts.add(u.hostname)
    return hosts


def a11y_unnamed(cdp):
    tree = cdp.send("Accessibility.getFullAXTree").get("nodes", [])
    bad = []
    for n in tree:
        if n.get("ignored"):
            continue
        role = (n.get("role") or {}).get("value", "")
        name = (n.get("name") or {}).get("value", "")
        if role in INTERACTIVE_ROLES and not str(name).strip():
            bad.append(role)
    return bad


# Built-in device profiles: every run checks every one. Width, height,
# device pixel ratio and touch are what a page's CSS and JS can see; "mobile"
# makes Chrome honour <meta name=viewport> as a phone/tablet browser does.
DEVICES = {
    "desktop": {"width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": False, "touch": False},
    "tablet":  {"width": 820, "height": 1180, "deviceScaleFactor": 2, "mobile": True, "touch": True},
    "mobile":  {"width": 390, "height": 844, "deviceScaleFactor": 3, "mobile": True, "touch": True},
}


def parse_devices(spec):
    """--devices names (desktop,tablet,mobile) or WxH sizes -> [(name, profile)]."""
    out = []
    for v in spec.split(","):
        v = v.strip().lower()
        if not v:
            continue
        if v in DEVICES:
            out.append((v, DEVICES[v]))
        else:
            w, h = (int(x) for x in v.split("x"))
            out.append((f"{w}x{h}", {"width": w, "height": h, "deviceScaleFactor": 1,
                                     "mobile": w < 900, "touch": w < 900}))
    return out


def emulate(cdp, prof):
    cdp.send("Emulation.setDeviceMetricsOverride",
             {k: prof[k] for k in ("width", "height", "deviceScaleFactor", "mobile")})
    cdp.send("Emulation.setTouchEmulationEnabled", {"enabled": prof["touch"], "maxTouchPoints": 5 if prof["touch"] else 1})


# WCAG 2.2 2.5.8 (AA) target size: at least 24x24 CSS px, links inside a run
# of text exempt (the criterion's own "inline" exception).
SMALL_TARGETS = r"""
(() => {
  const sel = e => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') +
    (e.classList.length ? '.' + [...e.classList].slice(0, 2).join('.') : '');
  const out = [];
  for (const e of document.querySelectorAll('a[href], button, input:not([type=hidden]), select, textarea, [role=button], [role=link], [tabindex]:not([tabindex="-1"])')) {
    const r = e.getBoundingClientRect(), cs = getComputedStyle(e);
    if (r.width === 0 || r.height === 0 || cs.visibility === 'hidden' || r.bottom < 0 || r.top > innerHeight * 3) continue;
    if (r.width >= 24 && r.height >= 24) continue;
    const p = e.parentElement;
    if (e.tagName === 'A' && p && /^(P|LI|TD|SPAN|DD|BLOCKQUOTE|FIGCAPTION|LABEL)$/.test(p.tagName) &&
        (p.textContent || '').trim().length > (e.textContent || '').trim().length + 3) continue;
    out.push(sel(e) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) + ((e.textContent || '').trim() ? ' "' + e.textContent.trim().slice(0, 24) + '"' : ''));
  }
  return out;
})()
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True)
    ap.add_argument("--browser", default=os.environ.get("CHROME_PATH", ""),
                    help="browser binary (default: chromium / google-chrome on PATH)")
    ap.add_argument("--resolve", default="", help="Chrome --host-resolver-rules, e.g. 'MAP docs.shani.dev 127.0.0.1:8443'")
    ap.add_argument("--ca-trust-all", action="store_true",
                    help="accept any TLS certificate (only for a throwaway local CA)")
    ap.add_argument("--allow-host", action="append", default=[], help="extra host the page may contact (repeatable)")
    ap.add_argument("--expect", action="append", default=[], help="CSS selector that must exist (repeatable)")
    ap.add_argument("--ignore", default="", help="regex of problem strings to ignore")
    ap.add_argument("--devices", "--viewports", dest="devices", default="desktop,tablet,mobile",
                    help="device profiles (desktop,tablet,mobile) or WxH sizes; each gets its own load, "
                         "error, overflow and tap-target checks and screenshots")
    ap.add_argument("--schemes", default="light,dark", help="prefers-color-scheme modes to shoot on every device")
    ap.add_argument("--no-full-page", action="store_true", help="screenshot the viewport only, not the whole page")
    ap.add_argument("--no-features", action="store_true",
                    help="skip using the page's features (menu, search, theme, print, ...) on each device")
    ap.add_argument("--shots", default="", help="directory for screenshots (none if empty)")
    ap.add_argument("--offline", action="store_true", help="check the service worker serves the page offline")
    ap.add_argument("--spa", default="", help="unknown path that must still render --expect (e.g. /no/such/route/)")
    ap.add_argument("--crawl", type=int, default=0, help="also load up to N same-origin links for errors")
    ap.add_argument("--no-a11y", action="store_true")
    ap.add_argument("--budget-lcp", type=float, default=0, help="fail if LCP exceeds this many ms")
    ap.add_argument("--budget-cls", type=float, default=0, help="fail if CLS exceeds this")
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--settle", type=float, default=10, help="max seconds to wait for a quiet network")
    ap.add_argument("--json", default="", help="write a JSON report here")
    args = ap.parse_args()

    browser = args.browser or next((shutil.which(b) for b in
                                    ("chromium", "google-chrome-stable", "google-chrome", "chromium-browser")
                                    if shutil.which(b)), None)
    if not browser:
        print("web_client: no Chromium found (install chromium or pass --browser)", file=sys.stderr)
        return 2

    profile = tempfile.mkdtemp(prefix="shani-web-")
    argv = [browser, "--headless", "--remote-debugging-pipe", f"--user-data-dir={profile}",
            "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
            "--disable-component-update", "--disable-sync", "--metrics-recording-only",
            "--disable-features=Translate,OptimizationHints,MediaRouter", "about:blank"]
    if os.geteuid() == 0:
        # Chromium refuses to run as root with its sandbox; the builder
        # container is root. In a slot, run as an unprivileged user instead.
        argv.insert(1, "--no-sandbox")
    if args.resolve:
        argv.insert(1, f"--host-resolver-rules={args.resolve}")
    if args.ca_trust_all:
        argv.insert(1, "--ignore-certificate-errors")

    cdp = CDP(argv, args.timeout)
    report = {"url": args.url, "browser": browser}
    try:
        version = cdp.send("Browser.getVersion", session=False)
        report["product"] = version.get("product")
        print(f"web: {version.get('product')} -> {args.url}", flush=True)
        target = cdp.send("Target.createTarget", {"url": "about:blank"}, session=False)["targetId"]
        cdp.session = cdp.send("Target.attachToTarget", {"targetId": target, "flatten": True},
                               session=False)["sessionId"]
        for dom in ("Page", "Runtime", "Network", "Log", "Audits"):
            cdp.send(f"{dom}.enable")
        cdp.send("Page.addScriptToEvaluateOnNewDocument", {"source": PRELUDE})
        page = Page(cdp, args)
        devices = parse_devices(args.devices) or [("desktop", DEVICES["desktop"])]
        emulate(cdp, devices[0][1])

        evs, status, err = page.navigate(args.url)
        if err or (status is not None and status >= 400):
            result("load", "FAIL", err or f"HTTP {status}")
            return finish(report, args)
        result("load", "PASS", f"HTTP {status}")

        probs = problems(evs, args.ignore)
        csp = page.evaluate("window.__shani ? window.__shani.csp : []") or []
        probs += [f"CSP violation: {c}" for c in csp]
        report["problems"] = probs
        if probs:
            result("errors", "FAIL", f"{len(probs)} problem(s)")
            for p in probs[:20]:
                print(f"  | {p[:300]}")
        else:
            result("errors", "PASS", "no exceptions, console errors, failed loads or issues")

        own = urllib.parse.urlsplit(args.url).hostname
        hosts = hosts_contacted(evs)
        foreign = sorted(h for h in hosts if h != own and h not in args.allow_host)
        report["hosts"] = sorted(hosts)
        if foreign:
            result("egress", "FAIL", "contacted " + ", ".join(foreign))
        else:
            result("egress", "PASS", f"only {', '.join(sorted(hosts)) or own}")

        title = page.evaluate("document.title") or ""
        lang = page.evaluate("document.documentElement.lang") or ""
        result("title", "PASS" if title.strip() else "FAIL", title.strip()[:60] or "empty <title>")
        result("lang", "PASS" if lang else "FAIL", lang or "<html> has no lang attribute")

        if not args.no_a11y:
            bad = a11y_unnamed(cdp)
            report["a11y_unnamed"] = bad
            if bad:
                counts = {}
                for r in bad:
                    counts[r] = counts.get(r, 0) + 1
                result("a11y-names", "FAIL", "unnamed: " + ", ".join(f"{n} {r}" for r, n in sorted(counts.items())))
            else:
                result("a11y-names", "PASS", "every interactive/image node has an accessible name")

        for sel in args.expect:
            n = page.evaluate(f"document.querySelectorAll({json.dumps(sel)}).length")
            result(f"expect {sel}"[:40], "PASS" if n else "FAIL", f"{n} match(es)")

        vitals = page.evaluate("window.__shani ? {lcp: window.__shani.lcp, cls: window.__shani.cls} : null") or {}
        report["vitals"] = vitals
        if vitals:
            lcp, cls = vitals.get("lcp", 0), vitals.get("cls", 0)
            ok = (not args.budget_lcp or lcp <= args.budget_lcp) and (not args.budget_cls or cls <= args.budget_cls)
            result("perf", "PASS" if ok else "FAIL", f"LCP {lcp:.0f} ms, CLS {cls:.3f}")
            if cls > 0.1:
                # Google's "good" is <= 0.1: name what moved, biggest first
                sh = page.evaluate("window.__shani ? window.__shani.shifters : {}") or {}
                for k, v in sorted(sh.items(), key=lambda kv: -kv[1])[:5]:
                    print(f"  | layout shift {v:.3f} from {k}")

        if args.shots:
            os.makedirs(args.shots, exist_ok=True)
        base_probs = set(probs)
        # the first same-origin page link that leads somewhere else, for the
        # inner-page feature run
        inner_url = None
        if not args.no_features:
            for l in page.evaluate("[...document.querySelectorAll('a[href]')].map(a => a.href)") or []:
                u = l.split("#")[0]
                ext = os.path.splitext(urllib.parse.urlsplit(u).path)[1].lower()
                # a different PATH: "/?tag=x" is the start page again, filtered
                if urllib.parse.urlsplit(u).hostname == own \
                        and urllib.parse.urlsplit(u).path.rstrip("/") != urllib.parse.urlsplit(args.url).path.rstrip("/") \
                        and (not ext or ext in (".html", ".htm")):
                    inner_url = u
                    break
            if not inner_url:
                # an SPA that navigates with buttons: the site's own sitemap
                # names its pages; production URLs are mapped onto this origin
                sm = page.evaluate("fetch('/sitemap.xml').then(r => r.ok ? r.text() : '').catch(() => '')",
                                   await_promise=True) or ""
                base = urllib.parse.urlsplit(args.url)
                for loc in re.findall(r"<loc>\s*([^<\s]+)\s*</loc>", sm):
                    pth = urllib.parse.urlsplit(loc).path
                    if pth.strip("/") and pth.rstrip("/") != base.path.rstrip("/"):
                        inner_url = f"{base.scheme}://{base.netloc}{pth}"
                        break
            if inner_url:
                print(f"  | inner page for feature checks: {inner_url}")
        for i, (dname, prof) in enumerate(devices):
            tag = f"{dname} {prof['width']}x{prof['height']}"
            emulate(cdp, prof)
            if i > 0:
                # a fresh load under this device: <meta viewport>, JS that reads
                # the width or touch at start-up, and errors only phones hit
                devs, dstatus, derr = page.navigate(args.url)
                dprobs = [p for p in problems(devs, args.ignore) if p not in base_probs]
                if derr or (dstatus and dstatus >= 400):
                    result(f"load {dname}", "FAIL", derr or f"HTTP {dstatus}")
                    continue
                if dprobs:
                    result(f"errors {dname}", "FAIL", f"{len(dprobs)} problem(s) only on {tag}")
                    for p in dprobs[:10]:
                        print(f"  | {p[:300]}")
                else:
                    result(f"errors {dname}", "PASS", f"nothing new on {tag}")
            cdp.pump(0.5)
            # clientWidth, not innerWidth: on a mobile viewport innerWidth GROWS
            # with the overflow (898 on a 390 px phone for shani-wiki), so the
            # old comparison reported "no horizontal scroll" for a page twice
            # the screen's width (found 2026-10-01)
            over = page.evaluate("Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0) - document.documentElement.clientWidth")
            result(f"overflow {dname}", "PASS" if (over or 0) <= 1 else "FAIL",
                   f"no horizontal scroll at {tag}" if (over or 0) <= 1 else f"{over}px wider than {tag}")
            if (over or 0) > 1:
                # the culprits: the innermost elements reaching past the right
                # edge, as a selector a person can find in the source
                for c in page.evaluate(OVERFLOW_CULPRITS) or []:
                    print(f"  | {c}")
            clipped = page.evaluate(CLIPPED) or []
            result(f"clipped {dname}", "PASS" if not clipped else "FAIL",
                   f"nothing cut off at {tag}" if not clipped
                   else f"{len(clipped)} element(s) cut off at the right edge, unreachable by scrolling")
            for c in clipped:
                print(f"  | {c}")
            overlap = page.evaluate(TEXT_OVERLAP) or []
            result(f"text-overlap {dname}", "PASS" if not overlap else "FAIL",
                   f"no text drawn over other text at {tag}" if not overlap else f"{len(overlap)} overlap(s) at {tag}")
            for c in overlap:
                print(f"  | {c}")
            if prof["touch"]:
                small = page.evaluate(SMALL_TARGETS) or []
                result(f"tap-targets {dname}", "PASS" if not small else "FAIL",
                       "every control >= 24x24 px" if not small else f"{len(small)} control(s) under 24x24 px")
                for c in small[:8]:
                    print(f"  | {c}")
            if not args.no_features:
                Features(page, cdp, result, problems, args.ignore).run(dname, prof)
                if inner_url:
                    # one inner page too: doc pages have breadcrumbs, a TOC
                    # and an article layout the start page does not. Restore
                    # the device first: the start page's reflow-320 check left
                    # the viewport at 320 px (the blog's inner page was being
                    # judged at 320 and reported as "mobile")
                    emulate(cdp, prof)
                    cdp.send("Emulation.setEmulatedMedia", {"features": []})
                    page.navigate(inner_url, settle=6)
                    vw = page.evaluate("innerWidth + 'x' + innerHeight")
                    print(f"  | {dname} inner page judged at {vw}")
                    Features(page, cdp, result, problems, args.ignore).run(dname, prof, inner=True)
                # some checks change the emulation (reflow at 320 px, media
                # features): restore this device before its screenshots
                emulate(cdp, prof)
                cdp.send("Emulation.setEmulatedMedia", {"features": []})
                page.navigate(args.url, settle=6)
            if args.shots:
                for scheme in [x for x in args.schemes.split(",") if x]:
                    # each mode as a first visit in it: most sites read the
                    # preference once at load and a saved choice overrides
                    # it, so switching the media feature on a loaded page
                    # (what this did until 2026-10-01) shot light twice
                    page.evaluate("try { localStorage.clear(); sessionStorage.clear(); } catch (e) {}")
                    cdp.send("Emulation.setEmulatedMedia",
                             {"features": [{"name": "prefers-color-scheme", "value": scheme}]})
                    page.navigate(None, reload=True, settle=5)
                    cdp.pump(0.5)
                    opts = {"format": "png"}
                    if not args.no_full_page:
                        # the whole page, not just the first screen; capped so a
                        # very long page cannot produce a gigantic image
                        # capped in OUTPUT pixels too: a long page at mobile's 3x
                        # was a 36000-px-tall PNG and timed the capture out
                        hgt = min(page.evaluate("document.documentElement.scrollHeight") or prof["height"], 12000,
                                  int(16000 / prof["deviceScaleFactor"]))
                        opts.update({"captureBeyondViewport": True,
                                     "clip": {"x": 0, "y": 0, "width": prof["width"], "height": hgt, "scale": 1}})
                    shot = cdp.send("Page.captureScreenshot", opts, timeout=120)
                    f = os.path.join(args.shots, f"{dname}-{scheme}.png")
                    with open(f, "wb") as fh:
                        fh.write(base64.b64decode(shot["data"]))
                    print(f"  | shot {f}")
                cdp.send("Emulation.setEmulatedMedia", {"features": []})
        emulate(cdp, devices[0][1])
        if len(devices) > 1:
            page.navigate(args.url)

        if args.offline:
            check_offline(page, cdp, args)

        if args.spa:
            u = urllib.parse.urljoin(args.url, args.spa)
            evs, status, err = page.navigate(u)
            sel = args.expect[0] if args.expect else "body *"
            n = 0 if err else page.evaluate(f"document.querySelectorAll({json.dumps(sel)}).length")
            result("spa-fallback", "PASS" if n else "FAIL",
                   f"{args.spa} -> HTTP {status}, {n} x {sel}" if not err else err)

        if args.crawl:
            crawl(page, args, own)
    except Exception as e:  # a harness error is a FAIL, never a silent pass
        result("web-client", "FAIL", f"{type(e).__name__}: {e}")
    finally:
        cdp.close()
        shutil.rmtree(profile, ignore_errors=True)
    return finish(report, args)


def check_offline(page, cdp, args):
    has_sw = page.evaluate("'serviceWorker' in navigator && !!navigator.serviceWorker.getRegistration")
    if not has_sw:
        result("offline", "SKIP", "no service worker API")
        return
    reg = page.evaluate("navigator.serviceWorker.getRegistration().then(r => !!r)", await_promise=True)
    if not reg:
        result("offline", "SKIP", "the page registers no service worker")
        return
    ready = page.evaluate(
        "Promise.race([navigator.serviceWorker.ready.then(() => true),"
        " new Promise(r => setTimeout(() => r(false), 15000))])", await_promise=True, timeout=20)
    if not ready:
        result("offline", "FAIL", "service worker never became ready")
        return
    page.navigate(None, reload=True)   # the SW controls only pages loaded after it activated
    controlled = page.evaluate("!!navigator.serviceWorker.controller")
    cdp.send("Network.emulateNetworkConditions",
             {"offline": True, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})
    try:
        evs, status, err = page.navigate(None, reload=True, settle=5)
        sel = args.expect[0] if args.expect else "body *"
        n = page.evaluate(f"document.querySelectorAll({json.dumps(sel)}).length") or 0
        from_sw = any(e["method"] == "Network.responseReceived" and e["params"]["response"].get("fromServiceWorker")
                      for e in evs)
        ok = controlled and n and from_sw
        result("offline", "PASS" if ok else "FAIL",
               f"controlled={controlled}, served-by-sw={from_sw}, {n} x {sel} with the network cut")
    finally:
        cdp.send("Network.emulateNetworkConditions",
                 {"offline": False, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})


def crawl(page, args, own):
    page.navigate(args.url)
    links = page.evaluate("[...document.querySelectorAll('a[href]')].map(a => a.href)") or []
    seen, todo = {args.url.split("#")[0]}, []
    for l in links:
        u = l.split("#")[0]
        # pages only: an image or archive link is not a page to check for
        # errors (and Chrome requests /favicon.ico for any bare resource)
        ext = os.path.splitext(urllib.parse.urlsplit(u).path)[1].lower()
        if ext and ext not in (".html", ".htm", ".php", "/"):
            continue
        if urllib.parse.urlsplit(u).hostname == own and u not in seen:
            seen.add(u); todo.append(u)
    # The docs and blog home pages navigate with onclick buttons, so their
    # start page yields no <a href> pages; their sitemap.xml lists every page.
    # Fall back to it before declaring the crawl empty (the FAIL below stays
    # for a site that has neither).
    sitemap = ""
    if not todo:
        sm = urllib.parse.urljoin(args.url, "/sitemap.xml")
        try:
            with urllib.request.urlopen(sm, timeout=10) as r:
                locs = re.findall(r"<loc>\s*([^<\s]+)\s*</loc>", r.read().decode("utf-8", "replace"))
        except Exception:
            locs = []
        for u in locs:
            # a sitemap names the production host; crawl the same path here
            p = urllib.parse.urlsplit(u)
            u = urllib.parse.urljoin(args.url, p.path + (("?" + p.query) if p.query else ""))
            if u.split("#")[0] not in seen:
                seen.add(u); todo.append(u)
        if todo:
            sitemap = " (from sitemap.xml: the start page has no same-origin <a href> page)"
    bad = 0
    for u in todo[:args.crawl]:
        evs, status, err = page.navigate(u, settle=5)
        probs = problems(evs, args.ignore)
        why = err or (f"HTTP {status}" if status and status >= 400 else "") or (probs[0][:200] if probs else "")
        if why:
            bad += 1
            print(f"  | {u}: {why}")
    n = min(len(todo), args.crawl)
    # Zero pages crawled is a FAIL, not a PASS. A site whose start page has no
    # same-origin <a href> - or whose links are all buttons with an onclick
    # handler, which is how the docs and blog home pages navigate - collects
    # nothing, examines nothing, and would otherwise report "0/0 clean" with
    # the confidence of a green check. That is the tell of an absence, and this
    # repo has been bitten by it repeatedly: a crawl that quietly followed
    # nothing looked identical to a crawl that followed everything cleanly.
    if n == 0:
        result("crawl", "FAIL",
               f"0 pages crawled - the start page offers {len(links)} link(s), "
               f"none of them a same-origin page (a link that navigates via "
               f"onclick rather than href is invisible here)")
        return
    result("crawl", "PASS" if not bad else "FAIL", f"{n - bad}/{n} same-origin pages clean{sitemap}")


def finish(report, args):
    report["results"] = RESULTS
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=2)
    failed = [n for n, s in RESULTS if s == "FAIL"]
    print(f"web: {len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed" + (f"; FAILED: {', '.join(failed)}" if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
