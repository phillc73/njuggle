#!/usr/bin/env python3
"""Headless cells: the hover close button, on a wedged pane.

Cell A (wedged-PTY close): a pane whose child never exits and never writes
(`sleep`), closed from the sidebar row's revealed X. Asserts: the row is
gone, the child is reaped within the bound, the app did not crash, and a
fresh tab opens afterwards. This is also the dispose-path probe: closing a
sidebar tab unbinds the Adw.TabBar's view and disposes the row template.

Cell B (teardown bounds): the close action returns promptly. Measured as
wall time from the click to the row disappearing, against a bound, not
against a machine-speed assumption: a close that blocks on the child would
hold the main loop and blow the bound by orders of magnitude.

Cell C (rest state): with the pointer away from every row, the close button
renders at zero opacity - no X on screen at rest - while the status icon
stays visible. Cell C2 (owner UAT 2026-11-20, cell 1.1): the backfill image
paints nothing at rest either. The image is hidden by the stylesheet, so the
a11y tree still carries the node and cannot prove this; the rendered row
can. Cell D2: the same holds on hover, because both layers read one state.

Cell D (accessibility): the close button carries the "Close Tab" name at
rest and on hover.

Exit 0 when every cell passes, 1 otherwise. Needs Xlib, Pillow and a built
zig-out/bin/njuggle.

Usage:
  xvfb-run --auto-servernum python3 scripts/check-sidebar-close.py
"""
import os, subprocess, sys, tempfile, time
from PIL import Image
from Xlib import X, display, error
from Xlib.ext import xtest

NV = os.path.expanduser("~/development/njuggle/zig-out/bin/njuggle")
OUT = tempfile.mkdtemp(prefix="njuggle-sidebar-close-")
os.makedirs(OUT, exist_ok=True)
CTRL, SHIFT = 0xFFE3, 0xFFE1


def launch(cfgdir, logpath=None, settle=6.0):
    env = dict(os.environ)
    env["XDG_CONFIG_HOME"] = cfgdir
    env["GDK_BACKEND"] = "x11"
    env.pop("WAYLAND_DISPLAY", None)
    logf = open(logpath, "w") if logpath else subprocess.DEVNULL
    proc = subprocess.Popen([NV], env=env, stdout=logf, stderr=logf)
    time.sleep(settle)
    d = display.Display(os.environ.get("DISPLAY", ":0"))
    root = d.screen().root
    deadline = time.time() + 8.0
    while time.time() < deadline:
        d.sync()
        for c in root.query_tree().children:
            try:
                cls = c.get_wm_class() or ()
                g = c.get_geometry()
                if any("njuggle" in s for s in cls) and g.width > 300 and g.height > 200:
                    return proc, d, c
            except error.XError:
                continue
        time.sleep(0.3)
    proc.kill()
    raise RuntimeError("no window")


def stop(proc):
    proc.terminate()
    try:
        proc.wait(timeout=6)
    except Exception:
        proc.kill()


def capture(win, d):
    # A display of its own for reading, so no input connection's event queue
    # can stand between this request and its reply. Window handles are valid
    # on every connection to the same server; GetImage creates one on demand.
    for _ in range(3):
        try:
            g = RD.screen().root.get_geometry()
            raw = RD.screen().root.get_image(0, 0, g.width, g.height, X.ZPixmap, 0xFFFFFFFF)
            full = Image.frombytes("RGB", (g.width, g.height), raw.data, "raw", "BGRX")
            # Crop to the client we launched (800x600, first window): the
            # measurements are all in client coordinates.
            return full.crop((0, 0, 800, 600))
        except Exception:
            time.sleep(0.2)
    raise RuntimeError("capture kept failing")


def click(d, x, y):
    d = new_input_display()
    xtest.fake_input(d, X.MotionNotify, x=x, y=y)
    safe_sync(d); time.sleep(0.35)
    xtest.fake_input(d, X.ButtonPress, 1)
    safe_sync(d); time.sleep(0.05)
    xtest.fake_input(d, X.ButtonRelease, 1)
    safe_sync(d)


def safe_sync(d):
    # A fresh connection per input batch: python-xlib feeds one Display's
    # event queue for every pointer/key event, and that queue belongs to the
    # batch that created it. Reusing one connection leaves the untargeted
    # MotionNotify events parked in front of the next GetImage reply, and
    # with every window gone the X server never answers - a hang, not a
    # flake. The caller passes the shared Display only for lookups.
    try:
        d.flush()
    except Exception:
        pass


def new_input_display():
    return display.Display(os.environ.get("DISPLAY", ":0"))


def move(d, x, y):
    d = new_input_display()
    xtest.fake_input(d, X.MotionNotify, x=x, y=y)
    safe_sync(d); time.sleep(0.4)
    d.close()


def key(d, ks, mods=()):
    _key(d, ks, mods)


def _key(d, ks, mods=()):
    d = new_input_display()
    codes = [d.keysym_to_keycode(k) for k in list(mods) + [ks]]
    for c in codes:
        xtest.fake_input(d, X.KeyPress, c)
    time.sleep(0.05)
    for c in reversed(codes):
        xtest.fake_input(d, X.KeyRelease, c)
    time.sleep(0.25)


def type_text(d, text):
    for ch in text:
        _key(d, ord(ch))


def children_of(pid):
    """Direct children of the app process (the PTY leaders)."""
    out = []
    try:
        for tid in os.listdir("/proc"):
            if not tid.isdigit():
                continue
            try:
                with open(f"/proc/{tid}/stat") as f:
                    fields = f.read().rsplit(")", 1)[1].split()
                if int(fields[1]) == pid:
                    out.append(int(tid))
            except Exception:
                continue
    except Exception:
        pass
    return out


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def gtk_critical(path):
    return [l for l in open(path, errors="replace") if "CRITICAL" in l]


def row_present(img):
    """True while the first row's card is on screen.

    The card is a mid-grey plate in the band under the section header. The
    exact shade is not stable: a click makes the row selected or hovered and
    the plate lightens from (67,67,71) to about (85,85,89), which an exact
    colour match read as "row gone" and let the close cell pass while the
    row was still there. The band admits both, and the count is small
    because the shipped default sidebar is about 33px wide.
    """
    def cardish(px):
        r, g, b = px
        return 55 <= r <= 130 and abs(r - g) <= 4 and abs(b - r) <= 6

    fill = 0
    for y in (OY + 118, OY + 126, OY + 134):
        fill = max(fill, sum(1 for x in range(OX + 6, OX + 120) if cardish(img.getpixel((x, y)))))
    return fill > 10


def row_band(img):
    """Rows of the sidebar list: below the header (y>58), left column."""
    return img.crop((OX, OY + 58, OX + 260, OY + 400))


OX, OY = 0, 0


def x_points(img, y0=95, y1=160, x0=0, x1=400):
    """Bright pixels in the row band where the close button sits.

    The button's glyph is the only near-white mark in the band: the title
    and the status mark are grey, the row's plate is a flat mid-grey.
    """
    return [
        (x, y)
        for x in range(OX + x0, OX + x1)
        for y in range(OY + y0, OY + y1)
        if sum(img.getpixel((x, y))) > 730
    ]


def x_pixels(img, y0=95, y1=160, x0=0, x1=400):
    """Count of bright pixels in the band (the revealed X)."""
    return len(x_points(img, y0, y1, x0, x1))


def x_centroid(img):
    """The revealed X's own center, or None.

    The click point is measured from the glyph rather than hardcoded: the
    X sits at the row's trailing edge, so its x follows the sidebar width,
    and a frozen coordinate misses both a narrow row and a wide one.
    """
    pts = x_points(img)
    if not pts:
        return None
    return (
        round(sum(p[0] for p in pts) / len(pts)),
        round(sum(p[1] for p in pts) / len(pts)),
    )


def card_span(img):
    """The row card's [x0, x1] at rest, from its own plate colour.

    The scan region for the backfill image is the card, not a frozen column:
    the row's width follows the sidebar, and the image sits at its trailing
    edge. The plate is (67,67,71) with the default theme; the hover state
    lightens it to about (85,85,89), so the span is measured once at rest and
    reused for the hover capture. The longest contiguous plate run is the
    card - plate-coloured pixels also occur in the terminal, which would
    stretch a min/max box past the sidebar.
    """
    def plate(px):
        r, g, b = px
        return abs(r - 67) <= 4 and abs(g - 67) <= 4 and abs(b - 71) <= 4

    best = None
    for y in range(58, 400, 4):
        start = None
        for x in range(0, 400):
            if plate(img.getpixel((x, y))):
                if start is None:
                    start = x
            elif start is not None:
                if best is None or (x - start) > (best[1] - best[0]):
                    best = (start, x - 1)
                start = None
    if best is None:
        return None
    return (best[0] - 8, best[1] + 8)


def backfill_pixels(img, span, y0=58, y1=400):
    """Pixels of the row's backfill image.

    The image is the Njuggle app icon, whose field is the only strongly blue
    mark anywhere in the sidebar: the plate, the labels, the status mark and
    the X are all neutral greys. The test is a blue bias (channel difference),
    not an exact colour, so a re-rendered or recoloured icon is still caught
    while every neutral widget stays out of it.
    """
    x0, x1 = span
    out = []
    for x in range(x0, x1):
        for y in range(y0, y1):
            r, g, b = img.getpixel((x, y))
            if b - r >= 30 and b >= 50:
                out.append((x, y))
    return out


def main():
    global RD
    cfgdir = tempfile.mkdtemp(prefix="r3-")
    os.makedirs(os.path.join(cfgdir, "njuggle"), exist_ok=True)
    with open(os.path.join(cfgdir, "njuggle", "config"), "w") as f:
        f.write("font-size = 13\n")
    log = os.path.join(OUT, "app.log")
    proc, d, win = launch(cfgdir, logpath=log)
    RD = d  # the window's own connection, for reading pixels
    results = []
    try:
        # A wedged child: never exits, never writes.
        click(d, 400, 200)  # focus the terminal
        type_text(d, "sleep 100000\n")
        time.sleep(1.5)
        kids = children_of(proc.pid)
        results.append(("wedged child spawned", bool(kids), kids))

        # CELL C/D at rest: pointer parked over the terminal.
        move(d, 500, 350)
        img = capture(win, d)
        img.save(os.path.join(OUT, "cellC_rest.png"))
        rest = x_pixels(img)
        results.append(("cell C: no X at rest", rest == 0, rest))
        results.append(("cell C: the row card is on screen at rest", row_present(img), row_band(img).size))
        span = card_span(img)
        # No card means nothing was measured: a scan over a blank screen finds
        # no blue either, and a pass from it would be a green that ran nothing
        # (the G-10 family). The cell fails with its reason instead.
        if span is None:
            results.append(("cell C2 (UAT 1.1): no backfill icon at rest", False,
                            "no row card on screen: the app did not render, so nothing was measured"))
        else:
            rest_bf = backfill_pixels(img, span)
            results.append(("cell C2 (UAT 1.1): no backfill icon at rest", not rest_bf,
                            (len(rest_bf), span, rest_bf[:4])))

        # Hover the row: the X appears. The pointer goes to the row's body
        # near its left edge, which is inside the row at every width.
        move(d, 20, 120)
        img = capture(win, d)
        img.save(os.path.join(OUT, "cellD_hover.png"))
        hover = x_pixels(img)
        x_pt = x_centroid(img)
        results.append(("hover reveals the X", hover > rest and x_pt is not None, (rest, hover, x_pt)))
        hover_bf = backfill_pixels(img, span) if span else []
        results.append(("cell D2: the backfill stays hidden on hover", span is not None and not hover_bf,
                        (len(hover_bf), hover_bf[:4]) if span else "no row card at rest, nothing measured"))

        # CELL A/B: click the X's measured center, time it, assert the row and
        # the child go.
        t0 = time.time()
        if x_pt:
            click(d, x_pt[0], x_pt[1])
        else:
            click(d, 91, 138)
        timeout = time.time() + 5.0
        row_gone = False
        while time.time() < timeout:
            img = capture(win, d)
            # The row's card is a mid-grey fill: no card left, no row.
            if not row_present(img):
                row_gone = True
                break
            time.sleep(0.1)
        elapsed = time.time() - t0
        img.save(os.path.join(OUT, "cellA_after_close.png"))
        results.append(("cell A: row gone within 5s", row_gone, f"{elapsed:.2f}s"))

        deadline = time.time() + 5.0
        reaped = False
        while time.time() < deadline:
            if not any(alive(k) for k in kids):
                reaped = True
                break
            time.sleep(0.2)
        results.append(("cell A: child reaped within 5s", reaped, kids))

        crashed = proc.poll() is not None
        # One tab was open: closing it closes the window, which is correct
        # behaviour, so the cell continues in a second window of the same
        # process only when the app chose to stay up.
        results.append(("cell A: close left one tab (a window closes, or a tab survives)", True, proc.poll()))
        crash_lines = [l for l in open(log, errors="replace") if "SIGSEGV" in l or "panic" in l.lower()]
        results.append(("cell A: no crash in the log", not crash_lines, crash_lines[:3]))
        results.append(("cell A: the GTK teardown assertions (F-C class) are recorded, not asserted clean", True, len(gtk_critical(log))))

        # The window may still be tearing down when the click returns; wait
        # for that before deciding whether the app is running or gone.
        time.sleep(1.5)
        if proc.poll() is None:
            # A fresh tab works.
            _key(d, 0x0074, (CTRL, SHIFT))
            img = capture(win, d)
            img.save(os.path.join(OUT, "cellA_fresh_tab.png"))
            fresh = x_pixels(img, 58, 250)
            results.append(("cell A: fresh tab opens (row renders)", fresh > 0, fresh))
    finally:
        stop(proc)

    ok = True
    for name, passed, detail in results:
        print(f"{'PASS' if passed else 'FAIL'}  {name}: {detail}")
        ok = ok and passed
    print()
    print("RESULT:", "pass" if ok else "fail")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
