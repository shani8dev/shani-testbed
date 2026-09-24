#!/usr/bin/env python3
"""Accessibility-tree client for test-env's `app` command (AT-SPI).

The native-app analogue of a browser DOM: GTK, Qt, Electron/Chromium,
LibreOffice... publish their widget tree over AT-SPI. This walks it for the
app running in the harness session (DBUS_SESSION_BUS_ADDRESS is exported by
cmd_app and points at that app's private session bus).

  a11y_client.py tree [--max-depth N]    every element: ref role "name" =value [states] @x,y wxh
  a11y_client.py find QUERY              matching elements that are on screen
  a11y_client.py center QUERY [NTH]      "cx cy role 'name'" of the NTH match (1-based)

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


def extents(acc):
    try:
        comp = acc.get_component_iface()
        if comp is None:
            return None
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
