#!/usr/bin/env python3
"""A tiny GTK4 + libadwaita app for the harness's own tests of `app`.

It is built from the widgets Shani Cassini and Chronoa are made of
(Adw.ApplicationWindow, HeaderBar, PreferencesGroup, EntryRow, SwitchRow,
ActionRow), so `app`'s actions are proven against the toolkit the ShaniOS apps
actually use - GTK4's accessibility roles, focus handling and rendering - not
against a GTK3 stand-in.

  adw_fixture.py entry TITLE [--text=T] [--unnamed-button]
      An EntryRow titled "Name", Cancel and OK buttons. OK (or Enter in the
      entry) prints the entry's text and exits 0; Cancel exits 1.
      --unnamed-button adds an icon-only button with no tooltip and a search
      box named only by its placeholder: the a11y lint's negative controls (a
      screen reader announces them as just "button" and "entry").
  adw_fixture.py form TITLE
      Three named SwitchRows and an Adw.ComboRow, nothing that closes the
      window: a monkey run can click everything and the app must survive.
"""
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, Gtk  # noqa: E402

Adw.init()

MODE, TITLE = sys.argv[1], sys.argv[2]
OPTS = sys.argv[3:]
TEXT = next((o.split("=", 1)[1] for o in OPTS if o.startswith("--text=")), "")


def on_activate(app):
    win = Adw.ApplicationWindow(application=app, title=TITLE, default_width=480, default_height=320)
    body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                   margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
    view = Adw.ToolbarView()
    view.add_top_bar(Adw.HeaderBar())
    view.set_content(body)
    win.set_content(view)
    if TEXT:
        body.append(Gtk.Label(label=TEXT))
    group = Adw.PreferencesGroup()
    body.append(group)

    def done(rc, out=None):
        if out is not None:
            print(out, flush=True)
        app.exit_code = rc
        app.quit()

    if MODE == "entry":
        row = Adw.EntryRow(title="Name")
        row.connect("entry-activated", lambda r: done(0, r.get_text()))
        group.add(row)
        buttons = Gtk.Box(spacing=6, halign=Gtk.Align.END)
        if "--unnamed-button" in OPTS:
            buttons.append(Gtk.Button.new_from_icon_name("dialog-information-symbolic"))
            # and a search box named only by its placeholder - Cassini's
            # Services page had one: placeholder text is not a name
            body.append(Gtk.SearchEntry(placeholder_text="Search things"))
        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda b: done(1))
        ok = Gtk.Button(label="OK")
        ok.add_css_class("suggested-action")
        ok.connect("clicked", lambda b: done(0, row.get_text()))
        buttons.append(cancel)
        buttons.append(ok)
        body.append(buttons)
        win.present()
        row.grab_focus()
    elif MODE == "long":
        # 40 rows in a scrolled list, most of them below the window: a click
        # on "Item 40" works only if the driver scrolls it into view first
        # two panes, like Cassini: a scrolled sidebar on the left and a
        # content pane on the right - wheel-scrolling the window centre would
        # scroll the wrong pane
        panes = Gtk.Box(spacing=12, vexpand=True)
        sw = Gtk.ScrolledWindow(vexpand=True, width_request=180)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        for i in range(1, 41):
            b = Gtk.Button(label=f"Item {i}")
            b.connect("clicked", lambda b, i=i: done(0, f"clicked {i}"))
            box.append(b)
        sw.set_child(box)
        panes.append(sw)
        panes.append(Gtk.Label(label="Content pane", hexpand=True))
        body.append(panes)
        win.present()
    else:
        for name in ("Alpha", "Beta", "Gamma"):
            group.add(Adw.SwitchRow(title=name))
        # Cassini's update-channel picker: libadwaita shows the selected value
        # as an unnamed list item around a named label - named by its content
        group.add(Adw.ComboRow(title="Channel", model=Gtk.StringList.new(["stable", "latest", "testing"])))
        win.present()


# NON_UNIQUE: each test starts its own instance, never re-activates the last one
app = Adw.Application(application_id="dev.shani.testbed.fixture", flags=Gio.ApplicationFlags.NON_UNIQUE)
app.exit_code = 0
app.connect("activate", on_activate)
app.run([])
sys.exit(app.exit_code)
