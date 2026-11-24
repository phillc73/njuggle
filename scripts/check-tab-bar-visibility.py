#!/usr/bin/env python3
"""Check the top tab bar against the tab-visibility decision table, on live
windows under X.

The decision table is `tabsVisibleFor` in src/apprt/gtk/class/window.zig; the
unit tests cover what it ANSWERS. This script covers what the WINDOW SHOWS
and ACCEPTS: whether the answer reached the widget, and whether the widget
shows a bar the table says nothing about.

Two independent observations per cell, both taken from the live window:

  rendered  whether the window paints a tab bar at all. Read from the
            header region: a rendered tab strip starts at the window's left
            edge with content (its add-tab button) and carries tab labels
            across the row. Neither exists in a header row without a bar.
  reach     which y-bands of the header pass a click through to the
            terminal. A band the bar occupies swallows the click; a gap
            between built chrome passes it through. This is what catches a
            bar that renders at zero height: the row is there, nothing is
            drawn, and clicks sail through the space it occupies.

Cells (the letters are the change request's):
  a   sidebar on, window-show-tab-bar at its default (auto), two tabs.
      Neither observation may find a bar: a sidebar and a top bar at once
      is the double-tab defect.
  b   sidebar on, window-show-tab-bar = always, two tabs. The user's pin
      wins over the sidebar: the bar renders AND the band it occupies
      swallows the probe click. A bar that renders at zero height passes
      the first observation and fails the second.
  c   sidebar off (none), default (auto), two tabs: upstream's own answer,
      bar renders and occupies its band.
  d   gtk-titlebar-style = tabs, sidebar on: the window's own tab strip
      stands whatever the sidebar does, bar renders and occupies its band.

Usage:  xvfb-run --auto-servernum python3 scripts/check-tab-bar-visibility.py
Exit 0 when every cell passes, 1 otherwise, 2 on a missing prerequisite.
Needs Xlib, Pillow and a built zig-out/bin/njuggle.
"""

import os
import subprocess
import sys
import tempfile
import time

from PIL import Image
from Xlib import X, display
from Xlib.ext import xtest


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(REPO_ROOT, "zig-out", "bin", "njuggle")

# The band the tab bar occupies in the 800x600 default window this script
# launches: below the header's top padding, above the row's bottom edge.
BAR_BAND = range(10, 50, 8)
# Left of the window controls on every window width; inside the header row.
PROBE_X = 380
# Well inside the terminal: the click that hands the window keyboard focus.
TERMINAL_X = 600
TERMINAL_Y = 300
# Typed after each probe click. Three letters, so one stray event cannot read
# as the shell echoing them.
MARKER = "qzx"
# A rendered tab label is text on the tab's card; the card fill is not text.
LABEL_BRIGHT = 150


def launch(config, settle=6.0):
    cfgdir = tempfile.mkdtemp(prefix="tab-bar-visibility-")
    os.makedirs(os.path.join(cfgdir, "njuggle"), exist_ok=True)
    with open(os.path.join(cfgdir, "njuggle", "config"), "w") as f:
        f.write(config)
    env = dict(os.environ)
    env["XDG_CONFIG_HOME"] = cfgdir
    env["GDK_BACKEND"] = "x11"
    env.pop("WAYLAND_DISPLAY", None)
    proc = subprocess.Popen([BIN], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(settle)
    d = display.Display(os.environ.get("DISPLAY", ":0"))
    root = d.screen().root
    deadline = time.time() + 8.0
    while time.time() < deadline:
        for c in root.query_tree().children:
            try:
                cls = c.get_wm_class() or ()
                g = c.get_geometry()
                if any("njuggle" in s for s in cls) and g.width > 300 and g.height > 200:
                    return proc, d, c
            except Exception:
                continue
        time.sleep(0.3)
    proc.kill()
    raise RuntimeError("no njuggle window")


def open_second_tab(d):
    ctrl = d.keysym_to_keycode(0xFFE3)
    shift = d.keysym_to_keycode(0xFFE1)
    t = d.keysym_to_keycode(0x0074)
    xtest.fake_input(d, X.KeyPress, ctrl)
    xtest.fake_input(d, X.KeyPress, shift)
    xtest.fake_input(d, X.KeyPress, t)
    d.sync()
    time.sleep(0.15)
    xtest.fake_input(d, X.KeyRelease, t)
    xtest.fake_input(d, X.KeyRelease, shift)
    xtest.fake_input(d, X.KeyRelease, ctrl)
    d.sync()
    time.sleep(1.5)


def click(d, x, y):
    xtest.fake_input(d, X.MotionNotify, x=x, y=y)
    d.sync()
    time.sleep(0.2)
    xtest.fake_input(d, X.ButtonPress, 1)
    xtest.fake_input(d, X.ButtonRelease, 1)
    d.sync()
    time.sleep(0.5)


def type_marker(d):
    for ch in MARKER:
        code = d.keysym_to_keycode(ord(ch))
        xtest.fake_input(d, X.KeyPress, code)
        xtest.fake_input(d, X.KeyRelease, code)
    d.sync()
    time.sleep(0.8)


def header_pixels(win, height=90):
    g = win.get_geometry()
    h = min(height, g.height)
    raw = win.get_image(0, 0, max(1, g.width), max(1, h), X.ZPixmap, 0xFFFFFFFF)
    return Image.frombytes("RGB", (g.width, h), raw.data, "raw", "BGRX")


def terminal_pixels(win):
    """The window below its header row: under every header shape here."""
    g = win.get_geometry()
    raw = win.get_image(0, 90, max(1, g.width), max(1, g.height - 90),
                        X.ZPixmap, 0xFFFFFFFF)
    return raw.data


def bar_rendered(win):
    """A rendered tab bar puts bright label text in the tab card near the
    window's tab-label column, right of the add-tab button."""
    img = header_pixels(win)
    px = img.load()
    for y in BAR_BAND:
        for x in range(120, 240):
            if sum(px[x, y][:3]) / 3 > LABEL_BRIGHT:
                return True
    return False


def band_passes_click(win, d):
    """Every probe y-band lets the click through to the terminal."""
    for y in BAR_BAND:
        click(d, TERMINAL_X, TERMINAL_Y)          # hand the window focus
        click(d, PROBE_X, y)
        before = terminal_pixels(win)
        type_marker(d)
        if terminal_pixels(win) == before:
            return False
    return True


def observe(config):
    proc, d, win = launch(config)
    try:
        open_second_tab(d)
        return {
            "rendered": bar_rendered(win),
            "reach": band_passes_click(win, d),
        }
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()


def main():
    if not os.path.exists(BIN):
        print(f"no binary at {BIN}; build first", file=sys.stderr)
        return 2

    cells = [
        ("a sidebar on, show-tab-bar default", False,
         "gtk-sidebar-tabs = left\n"),
        ("b sidebar on, show-tab-bar always", True,
         "gtk-sidebar-tabs = left\nwindow-show-tab-bar = always\n"),
        ("c sidebar none, show-tab-bar default", True,
         "gtk-sidebar-tabs = none\n"),
        ("d titlebar-style tabs, sidebar on", True,
         "gtk-sidebar-tabs = left\ngtk-titlebar-style = tabs\n"),
    ]

    failures = 0
    for name, want, cfg in cells:
        try:
            got = observe(cfg)
        except RuntimeError as e:
            print(f"FAIL  {name}: {e}", flush=True)
            failures += 1
            continue
        bar = got["rendered"] and not got["reach"]
        ok = bar == want
        if not ok:
            failures += 1
        print(f"{'PASS' if ok else 'FAIL'}  {name}: bar {'present' if bar else 'absent'}"
              f" (want {'present' if want else 'absent'});"
              f" rendered={got['rendered']} click_through={got['reach']}", flush=True)

    print()
    if failures:
        print(f"FAIL - {failures} of {len(cells)} cells disagree with the decision table.")
        return 1
    print(f"PASS - all {len(cells)} cells agree with the decision table.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
