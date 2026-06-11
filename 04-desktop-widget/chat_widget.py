#!/usr/bin/env python3
# BEREICH 4.2 + 4.3 — Transparentes, randloses KI-Chat-Widget (GTK3 + Cairo)
# ===========================================================================
# Zeichnet ein rahmenloses, halbtransparentes Chat-Fenster direkt auf den
# Desktop und bildet zugleich die Bruecke zur Mojo-KI:
#
#   Eingabe  --(Unix-Socket /run/mojo_ai.sock)-->  Mojo-Daemon
#   Antwort  <--(gleicher Socket)---------------   Mojo-Daemon
#
# Die Socket-Kommunikation laeuft in einem Hintergrund-Thread, damit die GUI
# nie blockiert; Antworten werden via GLib.idle_add thread-sicher angezeigt.
#
# Installation:
#   sudo install -m 0755 chat_widget.py /usr/local/bin/mojo-chat-widget
#
# Abhaengigkeiten (BLFS): python3, PyGObject (gi), GTK3, Cairo.
# Echte Transparenz unter X11 erfordert einen Compositor (picom, siehe xinitrc).
#
# Start (zum Testen):
#   ./chat_widget.py --sock /tmp/ai.sock
# ===========================================================================
import argparse
import socket
import threading

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GLib, Gtk, Pango  # noqa: E402

CSS = b"""
#chat-root      { background-color: rgba(20, 22, 35, 0.0); }
#chat-history   { background-color: rgba(0, 0, 0, 0.0); color: #e6e6ef;
                  font-family: "DejaVu Sans"; font-size: 11pt; padding: 8px; }
#chat-history text { background-color: rgba(0, 0, 0, 0.0); }
#chat-entry     { background-color: rgba(40, 44, 70, 0.85); color: #ffffff;
                  border-radius: 8px; padding: 8px; margin: 6px; }
#chat-title     { color: #8be9fd; font-weight: bold; font-size: 12pt;
                  padding: 8px 8px 0 8px; }
"""


class AIClient:
    """Bruecke: schickt eine Zeile an den Socket und liefert die Antwort."""

    def __init__(self, sock_path: str, timeout: float = 5.0):
        self.sock_path = sock_path
        self.timeout = timeout

    def query(self, text: str) -> str:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(self.timeout)
                s.connect(self.sock_path)
                s.sendall((text.rstrip("\n") + "\n").encode("utf-8"))
                chunks = []
                while True:
                    data = s.recv(4096)
                    if not data:
                        break
                    chunks.append(data)
                return b"".join(chunks).decode("utf-8", "replace").rstrip("\n")
        except OSError as e:
            return f"[Fehler] KI-Daemon nicht erreichbar unter {self.sock_path}: {e}"


class ChatWidget(Gtk.Window):
    def __init__(self, client: AIClient, backend: str):
        super().__init__(title="mojo-chat")
        self.client = client

        # --- Fenster: randlos, transparent, immer als Overlay --------------
        self.set_decorated(False)
        self.set_app_paintable(True)
        self.set_default_size(420, 560)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        # app_id / WM_CLASS, damit Sway/Openbox-Regeln greifen.
        self.set_wmclass("mojo-chat-widget", "mojo-chat-widget")
        try:
            self.set_role("mojo-chat-widget")
        except Exception:
            pass

        # RGBA-Visual für echtes Alpha-Blending.
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None:
            self.set_visual(visual)
        self.connect("draw", self._on_draw)

        # Optional: GTK-Layer-Shell, um unter Wayland direkt auf den
        # Hintergrund/Overlay-Layer zu zeichnen (falls installiert).
        if backend == "wayland":
            self._try_layer_shell()

        # --- Aufbau: Titel, Verlauf, Eingabe -------------------------------
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.set_name("chat-root")
        self.add(root)

        title = Gtk.Label(label="KI-Assistent")
        title.set_name("chat-title")
        title.set_xalign(0.0)
        root.pack_start(title, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_vexpand(True)
        self.history = Gtk.TextView()
        self.history.set_name("chat-history")
        self.history.set_editable(False)
        self.history.set_cursor_visible(False)
        self.history.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.buffer = self.history.get_buffer()
        scroll.add(self.history)
        root.pack_start(scroll, True, True, 0)

        self.entry = Gtk.Entry()
        self.entry.set_name("chat-entry")
        self.entry.set_placeholder_text("Nachricht eingeben und Enter druecken …")
        self.entry.connect("activate", self._on_submit)
        root.pack_start(self.entry, False, False, 0)

        # Esc schliesst das Widget.
        self.connect("key-press-event", self._on_key)
        self.connect("destroy", Gtk.main_quit)

        self._append("system", "Verbunden. Stelle eine Frage.")

    # --- Cairo: halbtransparenter, abgerundeter Hintergrund ----------------
    def _on_draw(self, _widget, cr):
        w = self.get_allocated_width()
        h = self.get_allocated_height()
        cr.set_operator(1)  # CAIRO_OPERATOR_SOURCE
        r, g, b, a = 0.08, 0.09, 0.14, 0.82
        radius = 16.0
        cr.new_sub_path()
        cr.arc(w - radius, radius, radius, -1.5708, 0)
        cr.arc(w - radius, h - radius, radius, 0, 1.5708)
        cr.arc(radius, h - radius, radius, 1.5708, 3.14159)
        cr.arc(radius, radius, radius, 3.14159, 4.71239)
        cr.close_path()
        cr.set_source_rgba(r, g, b, a)
        cr.fill()
        return False

    def _try_layer_shell(self):
        try:
            gi.require_version("GtkLayerShell", "0.1")
            from gi.repository import GtkLayerShell

            GtkLayerShell.init_for_window(self)
            GtkLayerShell.set_layer(self, GtkLayerShell.Layer.BOTTOM)
            GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.LEFT, True)
            GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.TOP, True)
            GtkLayerShell.set_margin(self, GtkLayerShell.Edge.LEFT, 40)
            GtkLayerShell.set_margin(self, GtkLayerShell.Edge.TOP, 60)
        except (ValueError, ImportError):
            # GTK-Layer-Shell nicht vorhanden — normales Overlay-Fenster.
            pass

    # --- Verlauf aktualisieren (thread-sicher via GLib.idle_add) -----------
    def _append(self, who: str, text: str):
        prefix = {"user": "Du:  ", "ai": "KI:  ", "system": "•    "}.get(who, "")
        end = self.buffer.get_end_iter()
        self.buffer.insert(end, f"{prefix}{text}\n")
        GLib.idle_add(self._scroll_to_end)

    def _scroll_to_end(self):
        end = self.buffer.get_end_iter()
        self.history.scroll_to_iter(end, 0.0, False, 0, 0)
        return False

    # --- Eingabe -> Hintergrund-Thread -> Socket -> Antwort ----------------
    def _on_submit(self, entry):
        text = entry.get_text().strip()
        if not text:
            return
        entry.set_text("")
        self._append("user", text)
        threading.Thread(target=self._worker, args=(text,), daemon=True).start()

    def _worker(self, text: str):
        reply = self.client.query(text)
        GLib.idle_add(self._append, "ai", reply)

    def _on_key(self, _w, event):
        if event.keyval == Gdk.KEY_Escape:
            self.destroy()
        return False


def main() -> int:
    ap = argparse.ArgumentParser(description="Transparentes KI-Chat-Widget")
    ap.add_argument("--sock", default="/run/mojo_ai.sock", help="Unix-Socket-Pfad")
    ap.add_argument(
        "--backend", choices=["x11", "wayland"], default="x11",
        help="Anzeige-Backend (beeinflusst nur GTK-Layer-Shell)",
    )
    args = ap.parse_args()

    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )

    win = ChatWidget(AIClient(args.sock), args.backend)
    win.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
