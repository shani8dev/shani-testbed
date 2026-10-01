"""Use a page's features the way a visitor does, on each device - for web_client.py.

Loading a page proves it loads. These checks prove its features work: each
one finds the feature by what it is (ARIA roles and states first, then the
names and classes sites conventionally use), operates it with real input
events (Input.dispatchMouseEvent / dispatchKeyEvent, not element.click()),
and requires the visible effect - a menu that opens, results that appear,
colours that change - plus no new exceptions or console errors while doing
it. A feature the page does not have is SKIP, never PASS.

  menu        (touch devices) the hamburger/nav toggle opens a menu and closes again
  search      typing a word from the page produces results; its advertised
              shortcut (/ or Ctrl+K in the placeholder) focuses the box
  theme       the dark/light toggle changes the page colours and changes them back
  print       print media keeps the main heading visible, and a PDF renders
  breadcrumbs present and marked (aria-current) wherever a page has them
  skip-link   the first Tab stop skips to an element that exists
  anchors     every in-page #fragment link points at an id that exists
  focus       each of the first Tab stops shows a visible focus indicator (WCAG 2.4.7)
  images      no <img> failed to decode
  meta        <meta viewport> and a description are present
  new-tab     every target=_blank link has rel=noopener (or noreferrer)
  back-to-top a back-to-top control returns the page to the top
"""

import json
import time

# One injected helper, so every probe walks the DOM the same way.
HELPERS = r"""
window.__sf = window.__sf || (() => {
  const vis = e => { if (!e) return false; const r = e.getBoundingClientRect(), s = getComputedStyle(e);
    // content of a closed <details> has a layout box but is never painted
    const d = e.closest && e.closest('details:not([open])');
    if (d && !e.closest('summary')) return false;
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && +s.opacity !== 0; };
  // a control a person could actually press now: visible AND horizontally on
  // screen (an off-canvas drawer's buttons are "visible" but at x < 0)
  const reach = e => vis(e) && (() => { const r = e.getBoundingClientRect(); return r.right > 1 && r.left < innerWidth - 1; })();
  const sel = e => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') +
    (e.classList && e.classList.length ? '.' + [...e.classList].slice(0, 2).join('.') : '');
  const label = e => [e.getAttribute('aria-label'), e.getAttribute('title'), e.id, e.className && String(e.className),
                      e.textContent && e.textContent.trim().slice(0, 40)].filter(Boolean).join(' ');
  // every picked element gets a unique tag, so a follow-up check finds THIS
  // element again - not the first of several sharing a selector (three
  // "button.btn.btn-secondary" on shani-website made a toggle look dead)
  let picks = 0;
  // behavior 'instant': a page with CSS scroll-behavior: smooth (shani-website)
  // would still be scrolling when the box is measured - y = -27792 once
  const box = e => { e.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'}); const r = e.getBoundingClientRect();
    if (!e.dataset.sfPick) e.dataset.sfPick = String(++picks + Math.floor(Math.random() * 1e6));
    return {x: r.left + r.width / 2, y: r.top + r.height / 2, sel: sel(e), label: label(e).slice(0, 60), pick: e.dataset.sfPick}; };
  const byPick = id => document.querySelector('[data-sf-pick="' + id + '"]');
  const controls = () => [...document.querySelectorAll('button, [role=button], a[href="#"], a:not([href]), summary, [aria-expanded], [aria-controls]')];
  // navigation entries: links AND buttons (an SPA's nav tree is often buttons)
  const navLinks = () => [...document.querySelectorAll('nav a, nav button, aside a, aside button, [role=navigation] a, [role=navigation] button, [role=menu] a, [role=menuitem], [role=treeitem], .menu a, .mobile-nav a, .sidebar a, .sidebar button, .nav a, .drawer a')].filter(reach).length;
  // the theme as a visitor sees it: the colours at the middle of the screen,
  // plus the declared scheme - not class names, which change for unrelated
  // reasons (a transition class, an open drawer) and made a correct
  // back-toggle look like a failure
  const bg = () => {
    // at the top of the page: a reload restores the scroll position, and the
    // middle of a scrolled page is a different element
    window.scrollTo(0, 0); for (const m of document.querySelectorAll('.content, main')) m.scrollTop = 0;
    const h = getComputedStyle(document.documentElement);
    let e = document.elementFromPoint(innerWidth / 2, innerHeight / 2), c = '';
    for (; e; e = e.parentElement) { const s = getComputedStyle(e); if (!/rgba\(0, 0, 0, 0\)|transparent/.test(s.backgroundColor)) { c = s.backgroundColor + '/' + s.color; break; } }
    if (!c) { const b = getComputedStyle(document.body); c = b.backgroundColor + '/' + b.color; }
    return [c, h.colorScheme, document.documentElement.dataset.theme || '', document.documentElement.getAttribute('data-bs-theme') || ''].join('|'); };
  return {vis, reach, sel, box, byPick, label, navLinks, bg,
    menuToggle() {
      // The control that opens the site navigation - not a disclosure INSIDE
      // the navigation (a sidebar tree's group buttons also carry
      // aria-expanded). Strong names first, then aria-controls naming a nav.
      const strong = /hamburger|burger|menu[-_ ]?(toggle|btn|button|open)|open (the )?(menu|navigation)|toggle (the )?(menu|navigation)|nav[-_ ]?toggle|navbar-toggler|sidebar[-_ ]?toggle|offcanvas|^menu$|main menu/i;
      const inNav = e => !!e.closest('nav, aside, [role=navigation], .sidebar, [role=tree]');
      const c = controls().filter(e => reach(e) && !inNav(e));
      const pick = c.find(e => strong.test(label(e)) || strong.test(e.id || '')) ||
                   c.find(e => /menu|navigation|sidebar|drawer/i.test(e.getAttribute('aria-controls') || '') ||
                               /^(menu|navigation)$/i.test((e.getAttribute('aria-label') || '').trim()));
      return pick ? box(pick) : null;
    },
    menuState(s) {
      const btn = [...document.querySelectorAll('[aria-expanded]')].find(e => vis(e));
      return {links: navLinks(), expanded: btn ? btn.getAttribute('aria-expanded') : null}; },
    searchInput() {
      const q = [...document.querySelectorAll('input[type=search], [role=searchbox], [role=search] input, input[placeholder*="earch" i], input[aria-label*="earch" i], input[name=q], input[name=s]')];
      const v = q.find(reach); if (v) return Object.assign(box(v), {placeholder: v.placeholder || ''});
      return q.length ? {hidden: true} : null;
    },
    searchToggle() {
      // named as a search control: by its accessible name, title, id or class
      // - not by body text (a FAQ <summary> about search is not a toggle)
      const nm = e => [e.getAttribute('aria-label'), e.getAttribute('title'), e.id, String(e.className || '')].join(' ');
      const c = controls().filter(e => reach(e) && e.tagName !== 'SUMMARY' && e.tagName !== 'INPUT' && /search/i.test(nm(e)));
      return c.length ? box(c[0]) : null;
    },
    queryWords() {
      // words the site is about: headings, title, nav labels - longest first
      const t = [...document.querySelectorAll('h1, h2, nav a, nav button')].slice(0, 30).map(e => e.textContent).join(' ') + ' ' + document.title;
      const w = [...new Set((t.match(/[A-Za-z][A-Za-z0-9-]{3,}/g) || []).map(x => x.toLowerCase()))];
      return w.sort((a, b) => b.length - a.length).slice(0, 5);
    },
    visibleCount() { let n = 0; for (const e of document.querySelectorAll('body *')) if (vis(e)) n++; return n; },
    resultsWith(word) {
      // visible elements whose own text contains the word, outside the input
      const re = new RegExp(word, 'i'); let n = 0;
      for (const e of document.querySelectorAll('body *')) {
        if (e.children.length > 3 || !vis(e) || e.tagName === 'INPUT' || e.tagName === 'SCRIPT') continue;
        if (re.test(e.textContent || '')) n++;
      }
      return n;
    },
    themeToggle() {
      const rx = /theme|dark|light|colou?r[- ]?scheme|night|day mode/i;
      const c = controls().concat([...document.querySelectorAll('input[type=checkbox]')]).filter(e => reach(e) && rx.test(label(e)));
      return c.length ? box(c[0]) : null;
    },
    breadcrumbs() {
      const n = document.querySelector('nav[aria-label*="readcrumb" i], [aria-label*="readcrumb" i], .breadcrumb, .breadcrumbs, ol[itemtype*="BreadcrumbList"], [class*="breadcrumb"]');
      if (!n || !vis(n)) return null;
      const items = [...n.querySelectorAll('li, a, span')].filter(vis);
      return {sel: sel(n), items: n.querySelectorAll('a').length, current: !!n.querySelector('[aria-current]')};
    },
    anchors() {
      const bad = [];
      for (const a of document.querySelectorAll('a[href^="#"]')) {
        const id = decodeURIComponent(a.getAttribute('href').slice(1));
        if (!id || id === 'top' || id.startsWith('/') || id.startsWith('!')) continue;
        if (!document.getElementById(id) && !document.getElementsByName(id).length) bad.push('#' + id);
      }
      return [...new Set(bad)];
    },
    focusInfo() {
      const e = document.activeElement;
      if (!e || e === document.body) return null;
      // A focus indicator is anything that LOOKS different while focused: an
      // outline or ring, but also a skip link sliding on screen or an input's
      // border changing colour. Compare the focused look with the unfocused one.
      const look = () => { const s = getComputedStyle(e), r = e.getBoundingClientRect();
        return [s.outlineStyle !== 'none' && parseFloat(s.outlineWidth) > 0 ? 'o' + s.outlineColor + s.outlineWidth : '',
                s.boxShadow, s.borderColor, s.borderWidth, s.backgroundColor, s.color, s.textDecorationLine,
                Math.round(r.left), Math.round(r.top), Math.round(r.width)].join('|'); };
      // no transitions while sampling: right after blur() an animated border
      // still shows its focused colour, and the two looks would match
      const prevT = e.style.getPropertyValue('transition'), prevP = e.style.getPropertyPriority('transition');
      e.style.setProperty('transition', 'none', 'important');
      const focused = look(), s = getComputedStyle(e);
      const ring = (s.outlineStyle !== 'none' && parseFloat(s.outlineWidth) > 0) || (s.boxShadow && s.boxShadow !== 'none');
      e.blur(); const plain = look(); e.focus({preventScroll: true});
      e.style.setProperty('transition', prevT, prevP);
      return {sel: sel(e), label: label(e).slice(0, 30), visible: ring || focused !== plain, href: e.getAttribute('href') || ''};
    },
    images() { return [...document.images].filter(i => i.complete && i.naturalWidth === 0 && vis(i) && i.currentSrc).map(i => i.currentSrc.slice(-60)); },
    meta() { return {viewport: !!document.querySelector('meta[name=viewport]'),
                     description: !!(document.querySelector('meta[name=description]') || {}).content}; },
    newTab() { return [...document.querySelectorAll('a[target=_blank]')].filter(a => !/noopener|noreferrer/i.test(a.rel)).map(a => (a.href || '').slice(0, 70)); },
    backToTop() {
      const rx = /back[- ]?to[- ]?top|scroll[- ]?to[- ]?top|to-top|go to top/i;
      const c = controls().concat([...document.querySelectorAll('a[href="#top"], a[href="#"]')]).filter(e => vis(e) && rx.test(label(e) + ' ' + (e.getAttribute('href') || '')));
      return c.length ? box(c[0]) : null;
    },
  };
})();
"""


class Features:
    def __init__(self, page, cdp, result, problems, ignore):
        self.page, self.cdp, self.result, self.problems, self.ignore = page, cdp, result, problems, ignore

    def js(self, expr, **kw):
        self.page.evaluate(HELPERS)
        return self.page.evaluate(expr, **kw)

    def click(self, b):
        for t in ("mouseMoved", "mousePressed", "mouseReleased"):
            self.cdp.send("Input.dispatchMouseEvent", {"type": t, "x": b["x"], "y": b["y"], "button": "left",
                                                       "buttons": 1 if t == "mousePressed" else 0, "clickCount": 1})

    def key(self, key, code=None, vk=0, modifiers=0, text=None):
        for t in ("keyDown", "keyUp"):
            p = {"type": t, "key": key, "code": code or key, "windowsVirtualKeyCode": vk, "modifiers": modifiers}
            if t == "keyDown" and text:
                p["text"] = text
            self.cdp.send("Input.dispatchKeyEvent", p)

    def errors_since(self, since):
        return self.problems(self.cdp.events[since:], self.ignore)

    def check(self, name, fn):
        """Run one feature; new exceptions/console errors during it are a FAIL."""
        since = len(self.cdp.events)
        try:
            status, detail = fn()
        except Exception as e:
            status, detail = "FAIL", f"{type(e).__name__}: {e}"
        errs = [p for p in self.errors_since(since) if "__shani_testbed" not in p]
        if errs and status != "SKIP":
            status, detail = "FAIL", f"{detail}; but it raised: {errs[0][:150]}"
        self.result(name, status, detail)

    # --- the features ---------------------------------------------------
    def menu(self, dname):
        b = self.js("__sf.menuToggle()")
        if not b:
            return "SKIP", f"no menu/hamburger toggle visible at {dname} width"
        before = self.js("__sf.menuState('')")
        self.click(b); self.cdp.pump(0.8)
        after = self.js("__sf.menuState('')")
        opened = after["links"] > before["links"] or (after["expanded"] == "true" and before["expanded"] != "true")
        if not opened:
            return "FAIL", f"tapping {b['sel']} ({b['label']}) opened nothing: {before['links']} -> {after['links']} visible nav links"
        self.key("Escape", vk=27); self.cdp.pump(0.6)
        closed = self.js("__sf.menuState('')")
        how = "Escape"
        if closed["links"] >= after["links"] and closed["expanded"] != "false":
            b2 = self.js("__sf.menuToggle()") or b
            self.click(b2); self.cdp.pump(0.6)
            closed = self.js("__sf.menuState('')")
            how = "a second tap"
        if closed["links"] >= after["links"] and closed["expanded"] == "true":
            return "FAIL", f"{b['sel']} opened the menu ({after['links']} links) but neither Escape nor a second tap closed it"
        return "PASS", f"{b['sel']} opens the menu ({before['links']} -> {after['links']} links), {how} closes it"

    def search(self, dname):
        inp = self.js("__sf.searchInput()")
        opened_by = ""
        if inp and inp.get("hidden") and self.js("__sf.menuToggle()"):
            # the box lives in a closed drawer: open the navigation first
            m = self.js("__sf.menuToggle()")
            self.click(m); self.cdp.pump(0.8)
            inp = self.js("__sf.searchInput()") or inp
            opened_by = f" (in the menu opened by {m['sel']})"
            if inp.get("hidden"):
                # not in the menu: close it again, or it covers the search toggle
                self.key("Escape", vk=27); self.cdp.pump(0.4)
                if self.js("__sf.menuState('')")["expanded"] == "true":
                    self.click(self.js("__sf.menuToggle()") or m); self.cdp.pump(0.6)
                opened_by = ""
        if not inp or inp.get("hidden"):
            t = self.js("__sf.searchToggle()")
            if not t:
                return ("SKIP", "no search box") if not inp else ("FAIL", "a search box exists but nothing visible opens it")
            hit = self.js(f"(() => {{ const e = document.elementFromPoint({t['x']}, {t['y']}); return e ? e.outerHTML.slice(0, 120) : ''; }})()")
            self.click(t); self.cdp.pump(0.8); opened_by = f" (opened by {t['sel']})"
            inp = self.js("__sf.searchInput()")
            if not inp or inp.get("hidden"):
                return "FAIL", f"{t['sel']} did not reveal the search box (the click at {t['x']},{t['y']} hit: {hit})"
        tried = []
        for word in (self.js("__sf.queryWords()") or ["linux"]):
            base = self.js(f"__sf.resultsWith({json.dumps(word)})")
            vbase = self.js("__sf.visibleCount()")
            self.click(inp); self.cdp.pump(0.2)
            self.js("(() => { const e = document.activeElement; if (e && 'value' in e) { e.value = ''; e.dispatchEvent(new Event('input', {bubbles: true})); } })()")
            self.cdp.send("Input.insertText", {"text": word}); self.cdp.pump(1.5)
            n = self.js(f"__sf.resultsWith({json.dumps(word)})")
            how = "as you type"
            if n <= base:
                url0 = self.js("location.href")
                self.key("Enter", vk=13, text="\r"); self.cdp.pump(2.0)
                n = self.js(f"__sf.resultsWith({json.dumps(word)})")
                how = "on Enter" if self.js("location.href") == url0 else "on a results page"
            if n > base:
                self.key("Escape", vk=27); self.cdp.pump(0.4)
                return "PASS", f"'{word}' -> {n - base} result element(s) {how}{opened_by}"
            vnow = self.js("__sf.visibleCount()")
            if abs(vnow - vbase) >= 3:
                # a search that FILTERS a list hides entries instead of adding
                self.key("Escape", vk=27); self.cdp.pump(0.4)
                return "PASS", f"'{word}' filtered the page ({vbase} -> {vnow} visible elements) {how}{opened_by}"
            tried.append(word)
            inp = self.js("__sf.searchInput()") or inp
            if inp.get("hidden"):
                break
        return "FAIL", f"typing words from the page into the search box{opened_by} showed no results (tried: {', '.join(tried)})"

    def search_shortcut(self, dname):
        inp = self.js("__sf.searchInput()")
        ph = (inp or {}).get("placeholder", "")
        if not inp or inp.get("hidden") or not ph:
            return "SKIP", "no search box advertising a shortcut"
        if "ctrl+k" in ph.lower() or "⌘k" in ph.lower():
            combo, mod = ("k", 2)
        elif "/" in ph:
            combo, mod = ("/", 0)
        else:
            return "SKIP", f"placeholder advertises no shortcut ({ph[:40]})"
        self.js("document.activeElement && document.activeElement.blur(); window.scrollTo(0, 0)")
        self.key(combo, code="Slash" if combo == "/" else "KeyK", vk=191 if combo == "/" else 75, modifiers=mod,
                 text=None if mod else combo)
        self.cdp.pump(0.5)
        focused = self.js("(() => { const e = document.activeElement; return !!e && (e.type === 'search' || /search/i.test((e.placeholder||'') + (e.getAttribute('aria-label')||''))); })()")
        self.key("Escape", vk=27)
        return ("PASS", f"{'Ctrl+K' if mod else '/'} focuses the search box") if focused else \
               ("FAIL", f"the placeholder promises {'Ctrl+K' if mod else '/'} but it does not focus the search box")

    def theme(self, dname):
        b = self.js("__sf.themeToggle()")
        if not b:
            return "SKIP", "no theme toggle"
        before = self.js("__sf.bg()")
        self.click(b); self.cdp.pump(0.8)
        after = self.js("__sf.bg()")
        if after == before:
            return "FAIL", f"clicking {b['sel']} ({b['label']}) changed nothing on the page"
        b2 = self.js("__sf.themeToggle()") or b
        self.click(b2); self.cdp.pump(0.8)
        back = self.js("__sf.bg()")
        return ("PASS", f"{b['sel']} switches the theme and back") if back == before else \
               ("FAIL", f"{b['sel']} switched the theme but a second click did not switch it back")

    def print_(self, dname):
        self.cdp.send("Emulation.setEmulatedMedia", {"media": "print"})
        self.cdp.pump(0.3)
        # the h1 a reader sees on screen (an SPA keeps other views' h1s hidden
        # in the DOM), then: is it still there in print?
        self.cdp.send("Emulation.setEmulatedMedia", {"media": ""})
        idx = self.js("[...document.querySelectorAll('h1')].findIndex(__sf.vis)")
        self.cdp.send("Emulation.setEmulatedMedia", {"media": "print"})
        self.cdp.pump(0.3)
        h1 = None if idx is None or idx < 0 else self.js(f"__sf.vis(document.querySelectorAll('h1')[{idx}])")
        chrome = self.js("[...document.querySelectorAll('nav, header, aside, [role=navigation], .topbar, .sidebar')].filter(__sf.vis).length")
        self.cdp.send("Emulation.setEmulatedMedia", {"media": ""})
        pdf = self.cdp.send("Page.printToPDF", {"printBackground": False}, timeout=90)
        import base64
        data = base64.b64decode(pdf.get("data", ""))
        pages = data.count(b"/Type /Page") - data.count(b"/Type /Pages")
        if not data.startswith(b"%PDF"):
            return "FAIL", "printing produced no PDF"
        if h1 is False:
            return "FAIL", f"the page's <h1> is hidden by the print stylesheet ({pages} page PDF)"
        return "PASS", f"{pages}-page PDF, heading visible, {chrome} nav/header element(s) still printed"

    def breadcrumbs(self, dname, inner):
        bc = self.js("__sf.breadcrumbs()")
        if not bc:
            return ("SKIP", "no breadcrumbs on this page") if not inner else ("SKIP", "no breadcrumbs (inner page)")
        if not bc["current"]:
            return "FAIL", f"{bc['sel']}: {bc['items']} link(s) but no aria-current on the current item"
        return "PASS", f"{bc['sel']}: {bc['items']} link(s), current item marked"

    def skip_link(self, dname):
        # a fresh load: after blur(), Chrome resumes Tab from the last focused
        # element, not the top of the page
        self.page.navigate(None, reload=True, settle=4)
        self.key("Tab", vk=9); self.cdp.pump(0.2)
        f = self.js("__sf.focusInfo()")
        if not f or not f["href"].startswith("#") or len(f["href"]) < 2:
            return "SKIP", f"the first Tab stop is not a skip link ({(f or {}).get('sel', 'nothing')})"
        ok = self.js(f"!!document.getElementById(decodeURIComponent({f['href'][1:]!r}))")
        return ("PASS", f"{f['sel']} skips to {f['href']}") if ok else ("FAIL", f"skip link {f['sel']} points at {f['href']}, which does not exist")

    def anchors(self, dname):
        bad = self.js("__sf.anchors()")
        return ("PASS", "every in-page #link has a target") if not bad else ("FAIL", f"{len(bad)} #link(s) with no target: {', '.join(bad[:6])}")

    def focus(self, dname):
        # a fresh load: after blur(), Chrome resumes Tab from the last focused
        # element, not the top of the page
        self.page.navigate(None, reload=True, settle=4)
        unseen, seen = [], 0
        for _ in range(12):
            self.key("Tab", vk=9); self.cdp.pump(0.1)
            f = self.js("__sf.focusInfo()")
            if not f:
                continue
            seen += 1
            if not f["visible"]:
                unseen.append(f"{f['sel']} {f['label']!r}")
        if not seen:
            return "SKIP", "nothing focusable by Tab"
        uniq = list(dict.fromkeys(unseen))
        return ("PASS", f"{seen} Tab stops, each with a visible focus indicator") if not uniq else \
               ("FAIL", f"{len(uniq)} of the first {seen} Tab stops show no focus outline: {'; '.join(uniq[:4])}")

    def images(self, dname):
        bad = self.js("__sf.images()")
        return ("PASS", "every visible image decoded") if not bad else ("FAIL", f"{len(bad)} broken image(s): {', '.join(bad[:4])}")

    def meta(self, dname):
        m = self.js("__sf.meta()")
        miss = [k for k, v in m.items() if not v]
        return ("PASS", "viewport and description present") if not miss else ("FAIL", "missing <meta> " + ", ".join(miss))

    def new_tab(self, dname):
        bad = self.js("__sf.newTab()")
        return ("PASS", "every target=_blank link has rel=noopener") if not bad else \
               ("FAIL", f"{len(bad)} target=_blank link(s) without rel=noopener: {', '.join(bad[:3])}")

    def back_to_top(self, dname):
        self.js("window.scrollTo(0, document.documentElement.scrollHeight)"); self.cdp.pump(0.8)
        b = self.js("__sf.backToTop()")
        if not b:
            self.js("window.scrollTo(0, 0)")
            return "SKIP", "no back-to-top control"
        self.click(b)
        # smooth scrolling up a very long page takes seconds: wait until it stops
        ypos = "Math.max(window.scrollY, document.scrollingElement.scrollTop, (document.querySelector('.content, main') || {}).scrollTop || 0)"
        # done when at the top, or when the position has not moved for 2 s
        # (a smooth scroll can take a moment to start)
        y, same, prev = None, 0, None
        for _ in range(60):
            self.cdp.pump(0.25)
            y = self.js(ypos)
            if y < 50:
                break
            same = same + 1 if y == prev else 0
            if same >= 8:
                break
            prev = y
        return ("PASS", f"{b['sel']} returns to the top") if y < 50 else ("FAIL", f"{b['sel']} left the page at y={int(y)}")

    def run(self, dname, prof, inner=False):
        """Every feature for one device; returns nothing, prints RESULT lines."""
        sfx = f" {dname}" + (" (inner page)" if inner else "")
        if prof["touch"]:
            self.check("menu" + sfx, lambda: self.menu(dname))
        self.check("search" + sfx, lambda: self.search(dname))
        if not prof["touch"]:
            self.check("search-shortcut" + sfx, lambda: self.search_shortcut(dname))
        self.check("theme" + sfx, lambda: self.theme(dname))
        self.check("breadcrumbs" + sfx, lambda: self.breadcrumbs(dname, inner))
        self.check("back-to-top" + sfx, lambda: self.back_to_top(dname))
        if dname == "desktop":
            # device-independent page properties: once, on desktop
            self.check("skip-link" + sfx, lambda: self.skip_link(dname))
            self.check("focus-visible" + sfx, lambda: self.focus(dname))
            self.check("anchors" + sfx, lambda: self.anchors(dname))
            self.check("images" + sfx, lambda: self.images(dname))
            self.check("meta" + sfx, lambda: self.meta(dname))
            self.check("new-tab-links" + sfx, lambda: self.new_tab(dname))
            self.check("print" + sfx, lambda: self.print_(dname))


# ---------------------------------------------------------------------------
# The wider set (2026-10-01): WCAG 2.2 criteria and the patterns the ARIA
# Authoring Practices define, each found generically and operated for real.
# ---------------------------------------------------------------------------
MORE = r"""
window.__sf2 = window.__sf2 || (() => {
  const vis = __sf.vis, sel = __sf.sel, label = __sf.label;
  // rgb()/rgba() give 0-255 channels; color(srgb ...) - what color-mix()
  // computes to - gives 0-1 channels and "/ alpha". Reading the latter as
  // 0-255 made a light pink look near-black (a false 3.42:1, 2026-10-01).
  const chans = c => { c = c || ''; const fn = /^color\(/.test(c);
    // drop the colour-space name first: "display-p3" has a digit in it
    const m = c.replace(/^color\(\s*[a-z0-9-]+/i, '').match(/[\d.]+/g); if (!m) return null;
    return {rgb: m.slice(0, 3).map(v => +v / (fn ? 1 : 255)), a: m.length > 3 ? +m[3] : (c === 'transparent' ? 0 : 1)}; };
  const lum = c => { const ch = chans(c); if (!ch) return null;
    const [r, g, b] = ch.rgb.map(v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  const alpha = c => { const ch = chans(c); return ch ? ch.a : 1; };
  const bgOf = e => { for (let a = e; a; a = a.parentElement) { const s = getComputedStyle(a);
      if (s.backgroundImage && s.backgroundImage !== 'none') return null;   // over an image: cannot judge
      if (alpha(s.backgroundColor) >= 0.95) return s.backgroundColor; }
    // CSS propagates body's background to the canvas when html has none
    const hb = getComputedStyle(document.documentElement).backgroundColor, bb = getComputedStyle(document.body).backgroundColor;
    return alpha(hb) >= 0.95 ? hb : (alpha(bb) >= 0.95 ? bb : 'rgb(255, 255, 255)'); };
  const ratio = (a, b) => { const x = lum(a), y = lum(b); if (x === null || y === null) return null;
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  return {
    landmarks() {
      const out = []; const main = [...document.querySelectorAll('main, [role=main]')].filter(vis);
      if (main.length !== 1) out.push(main.length + ' main landmarks (want exactly 1)');
      const navs = [...document.querySelectorAll('nav, [role=navigation]')].filter(vis);
      const names = navs.map(n => n.getAttribute('aria-label') || n.getAttribute('aria-labelledby') || '');
      if (navs.length > 1 && new Set(names).size < navs.length) out.push(navs.length + ' nav landmarks without distinct aria-labels');
      return out;
    },
    headings() {
      const hs = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(vis); const out = [];
      const h1 = hs.filter(h => h.tagName === 'H1').length;
      if (h1 !== 1) out.push(h1 + ' visible <h1> (want 1)');
      let prev = 0;
      for (const h of hs) { const l = +h.tagName[1]; if (prev && l > prev + 1) { out.push('h' + prev + ' -> h' + l + ' "' + h.textContent.trim().slice(0, 30) + '"'); } prev = l; }
      return out.slice(0, 6);
    },
    ids() {
      const seen = {}, dup = new Set(), bad = new Set();
      for (const e of document.querySelectorAll('[id]')) { if (seen[e.id]) dup.add(e.id); seen[e.id] = 1; }
      for (const a of ['aria-controls', 'aria-labelledby', 'aria-describedby', 'aria-owns', 'for'])
        for (const e of document.querySelectorAll('[' + a + ']'))
          for (const id of (e.getAttribute(a) || '').split(/\s+/)) if (id && !document.getElementById(id)) bad.add(a + '=' + id);
      return {dup: [...dup].slice(0, 6), bad: [...bad].slice(0, 6)};
    },
    media() {
      const out = [];
      // ad and captcha frames are injected by their providers' scripts, beyond
      // the site's control - every other untitled frame is the site's to fix
      const injected = /(googlesyndication|doubleclick|google\.com\/recaptcha|adtrafficquality|googletagmanager)/;
      for (const f of document.querySelectorAll('iframe')) if (!f.title && !f.getAttribute('aria-label') && !injected.test(f.src || '')) out.push('iframe without title ' + (f.src || '').slice(0, 50));
      for (const v of document.querySelectorAll('video')) {
        if (!v.querySelector('track[kind=captions], track[kind=subtitles]')) out.push('video without captions ' + (v.currentSrc || '').slice(-40));
        if (v.autoplay && !v.muted) out.push('video autoplays with sound');
      }
      return out;
    },
    forms() {
      const out = [];
      for (const i of document.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]), select, textarea')) {
        if (!vis(i)) continue;
        const named = i.getAttribute('aria-label') || i.getAttribute('aria-labelledby') || i.closest('label') ||
                      (i.id && document.querySelector('label[for="' + CSS.escape(i.id) + '"]')) || i.title;
        if (!named) out.push(sel(i) + (i.placeholder ? ' (placeholder only: "' + i.placeholder.slice(0, 20) + '")' : ''));
      }
      return out;
    },
    head() {
      const q = s => document.querySelector(s), out = [];
      if (!q('link[rel~=icon]')) out.push('no favicon <link rel=icon>');
      if (!q('meta[property="og:title"]')) out.push('no og:title');
      if (!q('meta[property="og:image"]')) out.push('no og:image');
      if (!q('link[rel=canonical]')) out.push('no canonical');
      for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
        try { const j = JSON.parse(s.textContent); const items = Array.isArray(j) ? j : (j['@graph'] || [j]);
          if (!items.every(x => x['@type'])) out.push('JSON-LD item without @type'); }
        catch (e) { out.push('JSON-LD does not parse: ' + e.message.slice(0, 40)); }
      }
      return out;
    },
    contrast() {
      const out = []; let n = 0;
      for (const e of document.querySelectorAll('body *')) {
        if (!vis(e) || !e.childNodes.length) continue;
        const own = [...e.childNodes].some(c => c.nodeType === 3 && c.textContent.trim().length > 1);
        if (!own) continue;
        // emoji are colour glyphs: the CSS text colour does not paint them
        if (/^[\p{Extended_Pictographic}\p{Emoji_Component}\uFE0F\u200D\s]+$/u.test(e.textContent.trim())) continue;
        const s = getComputedStyle(e); if (+s.opacity < 0.1) continue;
        const bg = bgOf(e); if (!bg) continue;
        const r = ratio(s.color, bg); if (r === null) continue; n++;
        const px = parseFloat(s.fontSize), bold = +s.fontWeight >= 700;
        const need = (px >= 24 || (bold && px >= 18.66)) ? 3 : 4.5;
        if (r < need) out.push(sel(e) + ' ' + r.toFixed(2) + ':1 (needs ' + need + ') "' + e.textContent.trim().slice(0, 24) + '"');
      }
      return {checked: n, bad: out};
    },
    // what a visitor sees, not <body>'s own colour: html and body are often
    // transparent with the real background on a layout container (docs)
    bodyLum() { const e = document.elementFromPoint(innerWidth / 2, innerHeight / 2) || document.body;
      return lum(bgOf(e) || 'rgb(255,255,255)'); },
    disclosure() {
      const inMenuBtn = e => /hamburger|menu[-_ ]?toggle|theme|search/i.test(label(e));
      const c = [...document.querySelectorAll('button[aria-expanded="false"], [role=button][aria-expanded="false"], summary')].filter(e => __sf.reach(e) && !inMenuBtn(e));
      return c.length ? __sf.box(c[0]) : null;
    },
    disclosureState(s) {
      const e = __sf.byPick(s);
      if (!e) return null;
      if (e.tagName === 'SUMMARY') return {expanded: String(e.parentElement.open)};
      const t = document.getElementById(e.getAttribute('aria-controls') || '');
      return {expanded: e.getAttribute('aria-expanded'), target: t ? vis(t) : null};
    },
    copyButton() {
      const c = [...document.querySelectorAll('button, [role=button]')].filter(e => vis(e) && /copy/i.test(label(e)));
      const b = c.find(e => e.closest('pre, .code, [class*=code]') || (e.parentElement && e.parentElement.querySelector('pre, code')));
      if (!b) return null;
      const box = __sf.box(b);
      // this button's own block: the pre it sits in, else the nearest
      // enclosing element that holds exactly one pre
      let pre = b.closest('pre');
      for (let a = b.parentElement; !pre && a && a !== document.body; a = a.parentElement) {
        const ps = a.querySelectorAll('pre'); if (ps.length === 1) pre = ps[0]; else if (ps.length > 1) break; }
      pre = pre || b.parentElement;
      return Object.assign(box, {text: (pre.innerText || '').trim().slice(0, 400)});
    },
    tocLinks() {
      const nav = [...document.querySelectorAll('nav, aside, [class*=toc], [id*=toc], [aria-label*=contents i], [aria-label*="on this page" i]')]
        .filter(n => vis(n) && /toc|contents|on this page/i.test(n.className + ' ' + n.id + ' ' + (n.getAttribute('aria-label') || '')));
      const links = nav.flatMap(n => [...n.querySelectorAll('a[href^="#"]')]).filter(vis);
      return links.slice(0, 4).map(a => a.getAttribute('href'));
    },
    stickyBottom() {
      let b = 0;
      for (const e of document.querySelectorAll('body *')) { const s = getComputedStyle(e);
        if ((s.position === 'fixed' || s.position === 'sticky') && vis(e)) { const r = e.getBoundingClientRect();
          if (r.top <= 2 && r.width > innerWidth * 0.5 && r.height < innerHeight * 0.4) b = Math.max(b, r.bottom); } }
      return b;
    },
    targetTop(h) { const t = document.getElementById(decodeURIComponent(h.slice(1))); return t ? t.getBoundingClientRect().top : null; },
    obscured() {
      const e = document.activeElement; if (!e || e === document.body) return null;
      const r = e.getBoundingClientRect(); if (!r.width) return null;
      // off screen (not scrolled into view): elementFromPoint cannot judge it
      if (r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) return null;
      const pts = [[r.left + r.width / 2, r.top + r.height / 2], [r.left + 2, r.top + 2], [r.right - 2, r.bottom - 2]];
      const ok = pts.some(([x, y]) => { const h = document.elementFromPoint(x, y); return h && (h === e || e.contains(h) || h.contains(e)); });
      return ok ? null : sel(e) + ' "' + label(e).slice(0, 24) + '"';
    },
    dialogTrigger() {
      const c = [...document.querySelectorAll('[aria-haspopup=dialog], [aria-haspopup=true][aria-controls], [data-modal], [data-bs-toggle=modal], [data-toggle=modal]')].filter(vis);
      return c.length ? __sf.box(c[0]) : null;
    },
    openDialog() {
      const d = [...document.querySelectorAll('dialog[open], [role=dialog], [role=alertdialog], [aria-modal=true]')].find(vis);
      return d ? __sf.sel(d) : null;
    },
    // Tab past a modal's last control may go to the browser's own UI
    // (activeElement = body): allowed - only landing on PAGE content behind
    // the dialog is leaving it
    focusInDialog() { const d = [...document.querySelectorAll('dialog[open], [role=dialog], [role=alertdialog], [aria-modal=true]')].find(vis);
      const a = document.activeElement;
      return !!d && (d.contains(a) || !a || a === document.body || a === document.documentElement); },
    progress() {
      // the moving bar first (its track is full width whatever the scroll)
      const p = ['[id*=reading-bar]', '[class*=progress__bar]', '[class*=progress-bar]', '[role=progressbar]', 'progress', '[class*=reading-progress]']
        .map(q => document.querySelector(q)).find(Boolean);
      if (!p) return null;
      const v = p.getAttribute('aria-valuenow'); const w = p.getBoundingClientRect().width;
      return {sel: __sf.sel(p), v: v !== null ? +v : null, w};
    },
    longAnimations() {
      return document.getAnimations().filter(a => a.playState === 'running').filter(a => {
        const t = a.effect && a.effect.getComputedTiming ? a.effect.getComputedTiming() : {};
        return t.iterations === Infinity || (t.endTime || 0) > 5000; })
        .map(a => (a.effect && a.effect.target ? __sf.sel(a.effect.target) : '?') + ' ' + (a.animationName || a.constructor.name)).slice(0, 5);
    },
    textClipped() {
      const out = [];
      for (const e of document.querySelectorAll('body *')) {
        if (!vis(e)) continue; const s = getComputedStyle(e);
        const hy = /(hidden|clip)/.test(s.overflowY), hx = /(hidden|clip)/.test(s.overflowX);
        if (!hx && !hy) continue;
        if (!(e.textContent || '').trim()) continue;
        // only the axis that is actually clipped (overflow-y: auto scrolls)
        if ((hy && e.scrollHeight > e.clientHeight + 4) || (hx && e.scrollWidth > e.clientWidth + 4)) {
          if (s.textOverflow === 'ellipsis' || s.webkitLineClamp !== 'none' && s.webkitLineClamp) continue;  // designed truncation
          out.push(sel(e));
        }
      }
      return out.slice(0, 6);
    },
  };
})();
"""

TEXT_SPACING_CSS = ("* { line-height: 1.5 !important; letter-spacing: 0.12em !important;"
                    " word-spacing: 0.16em !important; } p { margin-bottom: 2em !important; }")


def _more(self, expr, **kw):
    self.js("1")
    self.page.evaluate(MORE)
    return self.page.evaluate(expr, **kw)


def _landmarks(self, d):
    bad = self.js2("__sf2.landmarks()")
    return ("PASS", "one main; navigation landmarks distinguishable") if not bad else ("FAIL", "; ".join(bad))


def _headings(self, d):
    bad = self.js2("__sf2.headings()")
    return ("PASS", "one h1, no skipped heading levels") if not bad else ("FAIL", "; ".join(bad))


def _ids(self, d):
    r = self.js2("__sf2.ids()")
    msg = ([f"duplicate id(s): {', '.join(r['dup'])}"] if r["dup"] else []) + \
          ([f"reference(s) to missing ids: {', '.join(r['bad'])}"] if r["bad"] else [])
    return ("PASS", "ids unique; every aria-*/for reference resolves") if not msg else ("FAIL", "; ".join(msg))


def _media(self, d):
    bad = self.js2("__sf2.media()")
    return ("PASS", "iframes titled, videos captioned, nothing autoplays with sound") if not bad else ("FAIL", "; ".join(bad[:4]))


def _forms(self, d):
    bad = self.js2("__sf2.forms()")
    return ("PASS", "every visible field has a label") if not bad else ("FAIL", f"{len(bad)} unlabelled field(s): {'; '.join(bad[:4])}")


def _head(self, d):
    bad = self.js2("__sf2.head()")
    return ("PASS", "favicon, og:title/og:image, canonical, valid JSON-LD") if not bad else ("FAIL", "; ".join(bad))


def _contrast(self, d):
    out = []
    worst = 0
    for scheme in ("light", "dark"):
        # each scheme as a first visit in it (a saved theme would win)
        self.js("try { localStorage.clear(); sessionStorage.clear(); } catch (e) {}")
        self.cdp.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": scheme}]})
        self.page.navigate(None, reload=True, settle=4)
        r = self.js2("__sf2.contrast()")
        worst = max(worst, len(r["bad"]))
        if r["bad"]:
            out.append(f"{scheme}: {len(r['bad'])} of {r['checked']} text elements below the minimum")
            # every distinct failure, so all of them can be fixed, not the first
            for b in list(dict.fromkeys(r["bad"]))[:15]:
                print(f"  | contrast {scheme}: {b}")
    self.cdp.send("Emulation.setEmulatedMedia", {"features": []})
    self.page.navigate(None, reload=True, settle=4)
    return ("PASS", "text meets 4.5:1 (3:1 large) in light and dark") if not out else ("FAIL", " | ".join(out))


def _scheme(self, d):
    lums = {}
    for scheme in ("light", "dark"):
        # a first visit: a SAVED choice rightly overrides the OS setting, so
        # forget any (the theme checks above save one)
        self.js("try { localStorage.clear(); sessionStorage.clear(); } catch (e) {}")
        self.cdp.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": scheme}]})
        self.page.navigate(None, reload=True, settle=4)
        lums[scheme] = self.js2("__sf2.bodyLum()")
    self.cdp.send("Emulation.setEmulatedMedia", {"features": []})
    self.page.navigate(None, reload=True, settle=4)
    l, k = lums["light"], lums["dark"]
    if l is None or k is None:
        return "SKIP", "page background could not be measured"
    if abs(l - k) < 0.05:
        if not self.js("__sf.themeToggle()"):
            return "SKIP", f"a single-theme design (background luminance {l:.2f} either way, no theme toggle)"
        return "FAIL", f"the page offers a light and a dark theme but ignores the OS setting (background luminance {l:.2f} / {k:.2f} with the OS in light / dark)"
    return "PASS", f"follows the OS setting (background luminance light {l:.2f}, dark {k:.2f})"


def _persist(self, d):
    b = self.js("__sf.themeToggle()")
    if not b:
        return "SKIP", "no theme toggle"
    before = self.js("__sf.bg()")
    self.click(b); self.cdp.pump(0.8)
    chosen = self.js("__sf.bg()")
    self.page.navigate(None, reload=True, settle=4)
    after = self.js("__sf.bg()")
    b2 = self.js("__sf.themeToggle()")
    if b2:
        self.click(b2); self.cdp.pump(0.6)
    if chosen == before:
        return "SKIP", "the toggle changed nothing (reported by the theme check)"
    return ("PASS", "the chosen theme survives a reload") if after == chosen else \
           ("FAIL", "the theme choice is lost on reload")


def _disclosure(self, d):
    b = self.js2("__sf2.disclosure()")
    if not b:
        return "SKIP", "no collapsed disclosure/accordion"
    self.click(b); self.cdp.pump(0.6)
    # a toggle that smooth-scrolls to what it opened (shani-website's install
    # guide) is still moving the page: re-boxing it mid-scroll puts the
    # collapse click somewhere else. Wait for the position to hold still.
    prev = None
    for _ in range(24):
        y = self.js("Math.round(window.scrollY + document.scrollingElement.scrollTop)")
        if y == prev:
            break
        prev = y; self.cdp.pump(0.25)
    st = self.js2(f"__sf2.disclosureState({json.dumps(b['pick'])})") or {}
    if st.get("expanded") not in ("true",):
        return "FAIL", f"{b['sel']} ({b['label'][:30]}) did not expand (aria-expanded/open stayed false)"
    if st.get("target") is False:
        return "FAIL", f"{b['sel']} says expanded but its aria-controls panel is not visible"
    b2 = self.js2(f"(() => {{ const e = __sf.byPick({json.dumps(b['pick'])}); return e ? __sf.box(e) : null; }})()")
    if b2:
        self.click(b2); self.cdp.pump(0.5)
    st2 = self.js2(f"__sf2.disclosureState({json.dumps(b['pick'])})") or {}
    return ("PASS", f"{b['sel']} expands and collapses") if st2.get("expanded") in ("false",) else \
           ("FAIL", f"{b['sel']} expanded but did not collapse again")


def _copy(self, d):
    b = self.js2("__sf2.copyButton()")
    if not b:
        return "SKIP", "no copy-code button"
    origin = self.js("location.origin")
    try:
        self.cdp.send("Browser.grantPermissions", {"permissions": ["clipboardReadWrite", "clipboardSanitizedWrite"],
                                                    "origin": origin}, session=False)
    except Exception:
        pass
    self.click(b); self.cdp.pump(0.8)
    try:
        got = self.page.evaluate("navigator.clipboard.readText()", await_promise=True, timeout=5) or ""
    except Exception as e:
        return "FAIL", f"clipboard unreadable after clicking {b['sel']}: {e}"
    norm = lambda x: " ".join(x.split())
    want = norm(b["text"])[:120]
    if not got.strip():
        return "FAIL", f"clicking {b['sel']} put nothing on the clipboard"
    return ("PASS", f"{b['sel']} copies the code ({len(got)} chars)") if want[:60] in norm(got) or norm(got)[:60] in want else \
           ("FAIL", f"{b['sel']} copied something else: {norm(got)[:50]!r}")


def _toc(self, d):
    links = self.js2("__sf2.tocLinks()")
    if not links:
        return "SKIP", "no table of contents"
    hidden = []
    for h in links:
        self.js(f"(() => {{ const a = [...document.querySelectorAll('a')].find(x => x.getAttribute('href') === {json.dumps(h)} && __sf.vis(x)); if (a) a.click(); }})()")
        self.cdp.pump(1.0)
        top = self.js2(f"__sf2.targetTop({json.dumps(h)})")
        sticky = self.js2("__sf2.stickyBottom()")
        if top is None:
            hidden.append(f"{h} has no target")
        elif top < sticky - 2:
            hidden.append(f"{h} lands {int(sticky - top)}px under the sticky header")
    return ("PASS", f"{len(links)} contents link(s) land on their headings, below the sticky header") if not hidden else \
           ("FAIL", "; ".join(hidden[:3]) + " (scroll-margin-top)")


def _obscured(self, d):
    self.page.navigate(None, reload=True, settle=4)
    bad = []
    for _ in range(20):
        self.key("Tab", vk=9); self.cdp.pump(0.1)
        o = self.js2("__sf2.obscured()")
        if o:
            bad.append(o)
    bad = list(dict.fromkeys(bad))
    return ("PASS", "no focused control hidden behind sticky UI") if not bad else \
           ("FAIL", f"{len(bad)} focused control(s) covered by another element: {'; '.join(bad[:3])}")


def _keyboard_trap(self, d):
    self.page.navigate(None, reload=True, settle=4)
    seq = []
    for _ in range(120):
        self.key("Tab", vk=9)
        f = self.js("(() => { const e = document.activeElement; return e ? __sf.sel(e) + '@' + Math.round(e.getBoundingClientRect().top) : ''; })()")
        seq.append(f)
        # a trap: focus never gets back out to the browser (body) and keeps
        # circling one or two controls while the page has more. A page with
        # a single link cycling link -> browser UI -> link is not one.
        last = seq[-30:]
        if len(seq) > 30 and not any(x.startswith("body@") or not x for x in last) and len(set(last)) <= 2:
            total = self.js("document.querySelectorAll('a[href], button, input, select, textarea, [tabindex]:not([tabindex=\"-1\"])').length")
            if total > len(set(last)):
                return "FAIL", f"keyboard focus is stuck cycling {sorted(set(last))} (the page has {total} focusable elements)"
    return "PASS", f"{len(set(seq))} distinct Tab stops, no trap"


def _dialog(self, d):
    b = self.js2("__sf2.dialogTrigger()")
    if not b:
        return "SKIP", "no dialog trigger"
    self.click(b); self.cdp.pump(0.8)
    dlg = self.js2("__sf2.openDialog()")
    if not dlg:
        return "FAIL", f"{b['sel']} announces a dialog but none opened"
    inside = 0
    for _ in range(8):
        self.key("Tab", vk=9); self.cdp.pump(0.05)
        inside += 1 if self.js2("__sf2.focusInDialog()") else 0
    self.key("Escape", vk=27); self.cdp.pump(0.6)
    still = self.js2("__sf2.openDialog()")
    back = self.js(f"(() => {{ const e = document.activeElement; return !!e && __sf.sel(e) === {b['sel']!r}; }})()")
    probs = []
    if inside < 8:
        probs.append(f"focus left the dialog on {8 - inside} of 8 Tabs")
    if still:
        probs.append("Escape did not close it")
    if not back:
        probs.append("focus did not return to the trigger")
    return ("PASS", f"{dlg}: focus trapped, Escape closes, focus returns") if not probs else ("FAIL", f"{dlg}: " + "; ".join(probs))


def _progress(self, d):
    p0 = self.js2("__sf2.progress()")
    if not p0:
        return "SKIP", "no reading-progress indicator"
    vals = []
    for frac in (0, 0.5, 1.0):
        self.js(f"(() => {{ const s = document.scrollingElement, m = document.querySelector('.content, main'); "
                f"const t = (x) => {{ x.scrollTop = (x.scrollHeight - x.clientHeight) * {frac}; }}; t(s); if (m) t(m); "
                f"window.dispatchEvent(new Event('scroll')); }})()")
        self.cdp.pump(0.6)
        p = self.js2("__sf2.progress()") or {}
        vals.append(p.get("v") if p.get("v") is not None else p.get("w", 0))
    self.js("window.scrollTo(0, 0)")
    if not any(vals):
        return "SKIP", f"{p0['sel']} stays empty here (no article to track on this page)"
    return ("PASS", f"{p0['sel']} tracks scrolling ({', '.join(str(round(v)) for v in vals)})") if vals[0] < vals[1] < vals[2] or (vals[0] < vals[2] and vals[1] >= vals[0]) else \
           ("FAIL", f"{p0['sel']} does not follow the scroll position: {vals}")


def _reflow(self, d):
    # WCAG 1.4.10: content reflows at 320 CSS px (= 1280 px at 400 % zoom)
    self.cdp.send("Emulation.setDeviceMetricsOverride", {"width": 320, "height": 640, "deviceScaleFactor": 2, "mobile": True})
    self.page.navigate(None, reload=True, settle=5)
    # clientWidth, not innerWidth (innerWidth grows with the overflow on mobile)
    over = self.js("Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0) - document.documentElement.clientWidth")
    return ("PASS", "no horizontal scroll at 320 CSS px") if (over or 0) <= 1 else \
           ("FAIL", f"{over}px wider than a 320 CSS px viewport (400 % zoom)")


def _text_spacing(self, d):
    before = set(self.js2("__sf2.textClipped()"))
    self.js(f"(() => {{ const s = document.createElement('style'); s.id = '__sf_ts'; s.textContent = {TEXT_SPACING_CSS!r}; document.head.appendChild(s); }})()")
    self.cdp.pump(0.6)
    after = [x for x in self.js2("__sf2.textClipped()") if x not in before]
    self.js("(() => { const s = document.getElementById('__sf_ts'); if (s) s.remove(); })()")
    return ("PASS", "WCAG text-spacing overrides clip nothing") if not after else \
           ("FAIL", f"with WCAG 1.4.12 text spacing, text is cut off in: {', '.join(after[:4])}")


def _reduced_motion(self, d):
    self.cdp.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-reduced-motion", "value": "reduce"}]})
    self.page.navigate(None, reload=True, settle=4)
    self.cdp.pump(1.0)
    bad = self.js2("__sf2.longAnimations()")
    self.cdp.send("Emulation.setEmulatedMedia", {"features": []})
    return ("PASS", "no long or endless animation with reduced motion requested") if not bad else \
           ("FAIL", f"animations keep running with prefers-reduced-motion: {', '.join(bad[:3])}")


def _site_files(self, d):
    r = self.page.evaluate("""(async () => {
        const st = async p => { try { return (await fetch(p, {cache: 'no-store'})).status; } catch (e) { return 0; } };
        const sm = await fetch('/sitemap.xml').then(r => r.ok ? r.text() : '').catch(() => '');
        return {robots: await st('/robots.txt'), sitemap: sm ? 'ok' : 'missing',
                parses: sm ? !new DOMParser().parseFromString(sm, 'application/xml').querySelector('parsererror') : null,
                notfound: await st('/__shani_testbed_no_such_page__/')}; })()""", await_promise=True, timeout=20)
    probs = []
    if r["robots"] != 200:
        probs.append(f"/robots.txt -> {r['robots']}")
    if r["sitemap"] != "ok":
        probs.append("no /sitemap.xml")
    elif not r["parses"]:
        probs.append("/sitemap.xml is not valid XML")
    if r["notfound"] == 200:
        probs.append("an unknown path answers 200 (a soft 404)")
    return ("PASS", f"robots.txt, a valid sitemap.xml, unknown paths -> {r['notfound']}") if not probs else ("FAIL", "; ".join(probs))


Features.js2 = _more


def _run_more(self, dname, prof, inner=False):
    sfx = f" {dname}" + (" (inner page)" if inner else "")
    self.check("disclosure" + sfx, lambda: _disclosure(self, dname))
    self.check("dialog" + sfx, lambda: _dialog(self, dname))
    if dname == "desktop":
        for name, fn in (("landmarks", _landmarks), ("headings", _headings), ("ids", _ids), ("media", _media),
                         ("forms", _forms), ("head-meta", _head), ("contrast", _contrast), ("copy-code", _copy),
                         ("toc", _toc), ("focus-not-obscured", _obscured), ("keyboard-trap", _keyboard_trap),
                         ("reading-progress", _progress), ("text-spacing", _text_spacing),
                         ("theme-persists", _persist)):
            self.check(name + sfx, lambda fn=fn: fn(self, dname))
        if not inner:
            self.check("color-scheme" + sfx, lambda: _scheme(self, dname))
            self.check("reduced-motion" + sfx, lambda: _reduced_motion(self, dname))
            self.check("site-files" + sfx, lambda: _site_files(self, dname))
    if dname == "mobile" and not inner:
        self.check("reflow-320" + sfx, lambda: _reflow(self, dname))


_run_base = Features.run


def _run_all(self, dname, prof, inner=False):
    _run_base(self, dname, prof, inner)
    _run_more(self, dname, prof, inner)


Features.run = _run_all
