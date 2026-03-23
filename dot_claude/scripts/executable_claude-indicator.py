#!/usr/bin/env python3
"""Pulsating Claude indicator overlay for Hyprland via gtk-layer-shell.

Shows a pulsating indicator in the top-right of the *active window*
when Claude is working.
Controlled via signals: SIGUSR1 = show, SIGUSR2 = hide.
"""

import json
import os
import signal
import subprocess

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gtk, GLib, GtkLayerShell

CSS = """
@keyframes pulse {
    0%   { opacity: 1.0; background-color: #e67e22; }
    50%  { opacity: 0.6; background-color: #f39c12; }
    100% { opacity: 1.0; background-color: #e67e22; }
}

@keyframes glow {
    0%   { box-shadow: 0 0 8px rgba(243, 156, 18, 0.6); }
    50%  { box-shadow: 0 0 20px rgba(243, 156, 18, 0.9); }
    100% { box-shadow: 0 0 8px rgba(243, 156, 18, 0.6); }
}

window {
    background-color: transparent;
}

#indicator {
    background-color: #e67e22;
    border-radius: 12px;
    padding: 8px 16px;
    color: white;
    font-family: monospace;
    font-size: 14px;
    font-weight: bold;
    letter-spacing: 1px;
    border: 2px solid rgba(255, 255, 255, 0.3);
    animation: pulse 1.2s ease-in-out infinite, glow 1.2s ease-in-out infinite;
}
"""


def get_active_window_geometry() -> tuple[int, int, int, int] | None:
    """Return (x, y, w, h) of the active Hyprland window, or None."""
    try:
        result = subprocess.run(
            ["hyprctl", "activewindow", "-j"],
            capture_output=True, text=True, timeout=1,
        )
        data = json.loads(result.stdout)
        return data["at"][0], data["at"][1], data["size"][0], data["size"][1]
    except Exception:
        return None


def get_monitor_size() -> tuple[int, int]:
    """Return (width, height) of the primary monitor."""
    try:
        result = subprocess.run(
            ["hyprctl", "monitors", "-j"],
            capture_output=True, text=True, timeout=1,
        )
        monitors = json.loads(result.stdout)
        m = monitors[0]
        return m["width"], m["height"]
    except Exception:
        return 3840, 2160  # fallback


def build_window() -> Gtk.Window:
    win = Gtk.Window()

    GtkLayerShell.init_for_window(win)
    GtkLayerShell.set_layer(win, GtkLayerShell.Layer.OVERLAY)
    GtkLayerShell.set_anchor(win, GtkLayerShell.Edge.TOP, True)
    GtkLayerShell.set_anchor(win, GtkLayerShell.Edge.RIGHT, True)
    GtkLayerShell.set_margin(win, GtkLayerShell.Edge.TOP, 8)
    GtkLayerShell.set_margin(win, GtkLayerShell.Edge.RIGHT, 8)
    GtkLayerShell.set_keyboard_mode(
        win, GtkLayerShell.KeyboardMode.NONE
    )
    GtkLayerShell.set_exclusive_zone(win, -1)

    label = Gtk.Label(label="\u26a1 CLAUDE WORKING")
    label.set_name("indicator")
    win.add(label)

    provider = Gtk.CssProvider()
    provider.load_from_data(CSS.encode())
    Gtk.StyleContext.add_provider_for_screen(
        win.get_screen(),
        provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    )

    win.set_decorated(False)
    win.set_app_paintable(True)

    win.show_all()
    win.hide()

    return win


def position_over_window(win: Gtk.Window) -> None:
    """Reposition the overlay to the top-right of the active Hyprland window."""
    geom = get_active_window_geometry()
    if geom is None:
        return

    wx, wy, ww, _wh = geom
    screen_w, _screen_h = get_monitor_size()

    # Margin from right edge of screen to right edge of active window
    margin_right = screen_w - (wx + ww) + 6
    # Margin from top of screen to top of active window
    margin_top = wy + 6

    GtkLayerShell.set_margin(win, GtkLayerShell.Edge.RIGHT, max(0, margin_right))
    GtkLayerShell.set_margin(win, GtkLayerShell.Edge.TOP, max(0, margin_top))


def main() -> None:
    win = build_window()

    def on_show():
        position_over_window(win)
        win.show_all()
        return GLib.SOURCE_CONTINUE

    def on_hide():
        win.hide()
        return GLib.SOURCE_CONTINUE

    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGUSR1, on_show)
    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGUSR2, on_hide)

    pid_path = "/tmp/claude-indicator.pid"
    with open(pid_path, "w") as f:
        f.write(str(os.getpid()))

    Gtk.main()


if __name__ == "__main__":
    main()
