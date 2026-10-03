"""A GTK4 window for testing shani-chronoa's ui_elements skill: a menu, a named field, a button, a checkbox.

Prints EXPORTED / SAVED <text> / CHECKED <bool> to stdout when each control is
used, so the test asserts on what the app did, not on what the skill said.
"""
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gio, Gtk  # noqa: E402

app = Gtk.Application(application_id="dev.shani.test.UiProbe", flags=Gio.ApplicationFlags.NON_UNIQUE)


def activate(a):
    w = Gtk.ApplicationWindow(application=a, title="UI Probe")
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    model, sub = Gio.Menu(), Gio.Menu()
    sub.append("Export", "app.export")
    model.append_submenu("File", sub)
    act = Gio.SimpleAction.new("export", None)
    act.connect("activate", lambda *_: print("EXPORTED", flush=True))
    a.add_action(act)
    box.append(Gtk.PopoverMenuBar.new_from_model(model))
    entry = Gtk.Entry()
    entry.update_property([Gtk.AccessibleProperty.LABEL], ["Name"])
    box.append(entry)
    save = Gtk.Button(label="Save")
    save.connect("clicked", lambda _b: print("SAVED", entry.get_text(), flush=True))
    box.append(save)
    check = Gtk.CheckButton(label="Remember me")
    check.connect("toggled", lambda c: print("CHECKED", c.get_active(), flush=True))
    box.append(check)
    w.set_child(box)
    w.set_default_size(400, 300)
    w.present()


app.connect("activate", activate)
app.run([])
