#!/usr/bin/env python3
"""Accessibility-tree client for test-env's `app` command (AT-SPI).

The native-app analogue of a browser DOM: GTK, Qt, Electron/Chromium,
LibreOffice... publish their widget tree over AT-SPI. This walks it for the
app running in the harness session (DBUS_SESSION_BUS_ADDRESS is exported by
cmd_app and points at that app's private session bus).

  a11y_client.py tree [--max-depth N]    every element: ref role "name" =value [states] @x,y wxh
  a11y_client.py find QUERY              matching elements that are on screen
  a11y_client.py center QUERY [NTH]      "cx cy role 'name'" of the NTH match (1-based)
  a11y_client.py lint                    on-screen controls with no accessible name (exit 1 if any)
  a11y_client.py actionable              "cx cy role 'name'" of every on-screen, enabled control

QUERY is a case-insensitive regex matched against the element's name and
role, or ROLE:NAME-REGEX to require an exact role (e.g. "button:^OK$").
Role names are what at-spi2-core reports today ("button", "text", "frame",
"check box", "menu item", ...) — run `tree` to see them.
Exit 1 if nothing matches or the tree is unreachable.
"""
import re
import sys
import warnings

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

INTERESTING_STATES = ("focused", "checked", "selected", "pressed", "expanded",
                      "editable", "sensitive", "showing")


def states_of(acc):
    try:
        ss = acc.get_state_set()
    except Exception:
        return set()
    names = set()
    for st in ss.get_states():
        names.add(st.value_nick if hasattr(st, "value_nick") else str(st))
    return names


# GTK4 cannot know where its window is on screen (X11 or Wayland), so its
# AT-SPI SCREEN extents are always 0,0 - only WINDOW extents are right, and
# those are relative to the window frame, which itself sits inside the X
# surface by the client-side-decoration shadow margin (frame WINDOW = -5,-5 on
# GTK 4.22). Measured 2026-10-01 against a libadwaita app: every click-element
# on a GTK4 app (Shani Cassini, Chronoa) landed at the window's top-left. So
# for GTK4: screen = X window origin + (element WINDOW - frame WINDOW).
_ORIGIN_CACHE = {}


def _frame_of(acc):
    a, top = acc, acc
    try:
        while a is not None and a.get_role_name() != "application":
            top, a = a, a.get_parent()
    except Exception:
        pass
    return top


def _x_origin(title):
    """Screen position of the X window titled exactly `title` (0,0 if none:
    the harness's virtual display runs no window manager, so 0,0 is also the
    usual answer)."""
    if title in _ORIGIN_CACHE:
        return _ORIGIN_CACHE[title]
    origin = (0, 0)
    try:
        import subprocess
        wid = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", "^%s$" % re.escape(title)],
                             capture_output=True, text=True, timeout=5).stdout.split()
        if wid:
            out = subprocess.run(["xdotool", "getwindowgeometry", "--shell", wid[0]],
                                 capture_output=True, text=True, timeout=5).stdout
            kv = dict(l.split("=", 1) for l in out.split() if "=" in l)
            origin = (int(kv.get("X", 0)), int(kv.get("Y", 0)))
    except Exception:
        pass
    _ORIGIN_CACHE[title] = origin
    return origin


def _is_gtk4(acc):
    try:
        app = acc.get_application()
        return app.get_toolkit_name() == "GTK" and str(app.get_toolkit_version()).startswith("4")
    except Exception:
        return False


def extents(acc):
    try:
        comp = acc.get_component_iface()
        if comp is None:
            return None
        if _is_gtk4(acc):
            w = comp.get_extents(Atspi.CoordType.WINDOW)
            frame = _frame_of(acc)
            fc = frame.get_component_iface()
            fw = fc.get_extents(Atspi.CoordType.WINDOW) if fc else None
            ox, oy = _x_origin(frame.get_name() or "")
            fx, fy = (fw.x, fw.y) if fw else (0, 0)
            return (ox + w.x - fx, oy + w.y - fy, w.width, w.height)
        r = comp.get_extents(Atspi.CoordType.SCREEN)
        return (r.x, r.y, r.width, r.height)
    except Exception:
        return None


def text_value(acc):
    try:
        if acc.get_text_iface() is None:
            return None
        n = Atspi.Text.get_character_count(acc)
        if n <= 0:
            return None
        s = Atspi.Text.get_text(acc, 0, min(n, 80))
        return s + ("…" if n > 80 else "")
    except Exception:
        return None


def walk(max_depth=40):
    """Yields (ref, depth, acc, role, name) in document order."""
    Atspi.set_timeout(3000, 10000)
    desktop = Atspi.get_desktop(0)
    ref = 0
    stack = [(desktop.get_child_at_index(i), 0) for i in reversed(range(desktop.get_child_count()))]
    while stack:
        acc, depth = stack.pop()
        if acc is None:
            continue
        ref += 1
        try:
            role = acc.get_role_name() or "?"
            name = acc.get_name() or ""
        except Exception:
            continue
        yield ref, depth, acc, role, name
        if depth >= max_depth:
            continue
        try:
            n = acc.get_child_count()
        except Exception:
            n = 0
        for i in reversed(range(n)):
            try:
                stack.append((acc.get_child_at_index(i), depth + 1))
            except Exception:
                pass


def describe(ref, depth, acc, role, name, indent=True):
    st = states_of(acc)
    flags = [s for s in INTERESTING_STATES if s in st and s not in ("sensitive", "showing")]
    if "sensitive" not in st:
        flags.append("disabled")
    ext = extents(acc)
    box = " @%d,%d %dx%d" % ext if ext and ext[2] > 0 and ext[3] > 0 else ""
    val = text_value(acc)
    valtxt = " =%r" % val if val and val != name else ""
    pad = "  " * depth if indent else ""
    return "%s[%d] %s %r%s%s%s" % (pad, ref, role, name, valtxt,
                                  (" [" + ",".join(flags) + "]") if flags else "", box)


def matcher(query):
    role_req = None
    m = re.match(r"^([a-z][a-z ]+):(.*)$", query)
    if m:
        role_req, query = m.group(1), m.group(2)
    rx = re.compile(query, re.I)

    def ok(role, name):
        if role_req is not None and role != role_req:
            return False
        return bool(rx.search(name)) or (role_req is None and bool(rx.search(role)))
    return ok


# What a screen-reader user has to be able to name. A control in this list with
# an empty name is announced as just "button" - the bug a11y lint exists for.
# Labels, panels and fillers are not here: they are named by their content.
# at-spi2-core names a GtkButton "button" (older releases: "push button").
CONTROL_ROLES = {"button", "push button", "toggle button", "check box", "radio button",
                 "text", "entry", "password text", "combo box", "menu item",
                 "check menu item", "radio menu item", "slider", "spin button",
                 "link", "switch", "page tab", "list item", "tree item"}
# Roles that are clickable in a monkey run. Text fields are left out: a click
# there only moves the caret, and typing random text is not the point.
CLICKABLE_ROLES = CONTROL_ROLES - {"text", "entry", "password text"}


def _bring_into_view(acc, x, y, w, h):
    """Scroll an element into its window: AT-SPI scroll_to (GTK3, Qt), then
    focusing it (GTK4 has no scroll_to, but scrolls a focused child into
    view), then the mouse wheel over the window as a last resort."""
    import subprocess
    import time
    comp = acc.get_component_iface()
    for attempt in ("scroll_to", "focus"):
        try:
            if attempt == "scroll_to":
                comp.scroll_to(Atspi.ScrollType.ANYWHERE)
            else:
                comp.grab_focus()
            time.sleep(0.4)
            x, y, w, h = extents(acc)
            if _in_window(acc, x, y, w, h):
                return x, y, w, h
        except Exception:
            pass
    try:
        fx, fy, fw, fh = extents(_frame_of(acc))
        dw, dh = _display_size()
        fw, fh = min(fw, dw - max(fx, 0)), min(fh, dh - max(fy, 0))
        for _ in range(60):
            down = (y + h // 2) > fy + fh
            # over the element's OWN column (its scrolled container - a
            # sidebar), not the window centre, which is another pane
            wx = min(max(x + w // 2, max(fx, 0) + 5), max(fx, 0) + fw - 5)
            subprocess.run(["xdotool", "mousemove", str(wx), str(max(fy, 0) + fh // 2),
                            "click", "5" if down else "4"], timeout=5)
            time.sleep(0.08)
            x, y, w, h = extents(acc)
            if _in_window(acc, x, y, w, h):
                break
    except Exception:
        pass
    return x, y, w, h


_DISPLAY = None


def _display_size():
    """The X display's size: a window taller than the display (Cassini's on a
    1280x800 Xvfb) has rows inside its frame that are still off screen."""
    global _DISPLAY
    if _DISPLAY is None:
        try:
            import subprocess
            out = subprocess.run(["xdotool", "getdisplaygeometry"], capture_output=True, text=True, timeout=5).stdout.split()
            _DISPLAY = (int(out[0]), int(out[1]))
        except Exception:
            _DISPLAY = (10 ** 6, 10 ** 6)
    return _DISPLAY


def _in_window(acc, x, y, w, h):
    """True when the element's centre is inside its window's frame AND on the
    display - i.e. a click there reaches it."""
    try:
        f = _frame_of(acc)
        fx, fy, fw, fh = extents(f)
        dw, dh = _display_size()
        cx, cy = x + w // 2, y + h // 2
        return max(fx, 0) <= cx <= min(fx + fw, dw) - 1 and max(fy, 0) <= cy <= min(fy + fh, dh) - 1
    except Exception:
        return True


def on_screen(acc):
    ext = extents(acc)
    return ext is not None and ext[2] > 0 and ext[3] > 0 and "showing" in states_of(acc)


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "tree":
        depth = 40
        if len(argv) >= 4 and argv[2] == "--max-depth":
            depth = int(argv[3])
        lines = [describe(*item) for item in walk(depth)]
        if not lines:
            print("no accessible applications on this session bus (app not started, or its toolkit has accessibility off)", file=sys.stderr)
            return 1
        print("\n".join(lines))
        return 0
    if cmd in ("find", "center"):
        if len(argv) < 3:
            print(__doc__, file=sys.stderr)
            return 2
        ok = matcher(argv[2])
        hits = [(ref, d, acc, role, name) for ref, d, acc, role, name in walk()
                if ok(role, name) and on_screen(acc)]
        if not hits:
            print("no on-screen element matches %r" % argv[2], file=sys.stderr)
            return 1
        if cmd == "find":
            print("\n".join(describe(*h, indent=False) for h in hits))
            return 0
        nth = int(argv[3]) if len(argv) >= 4 else 1
        if nth < 1 or nth > len(hits):
            print("only %d match(es) for %r" % (len(hits), argv[2]), file=sys.stderr)
            return 1
        ref, _, acc, role, name = hits[nth - 1]
        x, y, w, h = extents(acc)
        # below (or above) the window's visible area - a long sidebar - is
        # "showing" to AT-SPI but unclickable: scroll it into view first (the
        # toolkit's own scrolling, through AT-SPI), then measure again
        if not _in_window(acc, x, y, w, h):
            x, y, w, h = _bring_into_view(acc, x, y, w, h)
        print("%d %d %s %r" % (x + w // 2, y + h // 2, role, name))
        return 0
    if cmd == "lint":
        bad, n = [], 0
        for ref, d, acc, role, name in walk():
            if role not in CONTROL_ROLES or not on_screen(acc):
                continue
            n += 1
            # a text field may legitimately be named by its placeholder or
            # content only through its label relation; GTK exposes that as name
            if not name.strip():
                bad.append(describe(ref, d, acc, role, name, indent=False))
        if not n:
            print("no on-screen controls (app not started, or accessibility off)", file=sys.stderr)
            return 1
        if bad:
            print("%d of %d on-screen controls have no accessible name:" % (len(bad), n))
            print("\n".join(bad))
            return 1
        print("all %d on-screen controls have an accessible name" % n)
        return 0
    if cmd == "actionable":
        # a monkey run tests that the app SURVIVES random use; a control whose
        # job is to end it (Close, Quit) ending it is correct, not a crash
        ender = re.compile(r"^(close|quit|exit|log ?out|sign ?out|shut ?down|power ?off)$", re.I)
        for ref, d, acc, role, name in walk():
            if ender.match(name.strip()):
                continue
            if role in CLICKABLE_ROLES and on_screen(acc) and "sensitive" in states_of(acc):
                x, y, w, h = extents(acc)
                print("%d %d %s %r" % (x + w // 2, y + h // 2, role, name))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    warnings.simplefilter("ignore", DeprecationWarning)
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # AT-SPI raises GLib.Error for an unreachable bus
        print("accessibility bus unreachable: %s" % e, file=sys.stderr)
        sys.exit(1)
