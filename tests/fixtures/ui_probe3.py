"""GTK3 window with a real menu bar (File > Export) for the ui_elements menu-path test; prints EXPORTED."""
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

w = Gtk.Window(title="UI Probe 3")
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
bar, file_item, sub = Gtk.MenuBar(), Gtk.MenuItem(label="File"), Gtk.Menu()
export = Gtk.MenuItem(label="Export")
export.connect("activate", lambda *_: print("EXPORTED", flush=True))
sub.append(export)
file_item.set_submenu(sub)
bar.append(file_item)
box.pack_start(bar, False, False, 0)
box.pack_start(Gtk.Label(label="gtk3"), True, True, 0)
w.add(box)
w.connect("destroy", Gtk.main_quit)
w.show_all()
Gtk.main()
