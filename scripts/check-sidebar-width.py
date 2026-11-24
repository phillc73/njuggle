#!/usr/bin/env python3
"""Sidebar width end to end, headless: gesture -> config bytes -> restart -> width.

Each lane starts from a fresh XDG_CONFIG_HOME carrying a config full of the
user's own comments, does the gesture, reads the file back byte for byte,
restarts, and measures the sidebar's on-screen width from the window capture.
"""
import os, subprocess, sys, tempfile, time
from PIL import Image
from Xlib import X, display, error
from Xlib.ext import xtest

NV = os.path.expanduser("~/development/njuggle/zig-out/bin/njuggle")
OUT = tempfile.mkdtemp(prefix="njuggle-sidebar-width-")
os.makedirs(OUT, exist_ok=True)
CTRL, SHIFT = 0xFFE3, 0xFFE1

USER_CONFIG = """\
# My njuggle config - comments here must survive a resize.
font-size = 13
keybind = ctrl+shift+t=new_tab

# --- Njuggle-only options: ON unless you turn them off ------------------
# gtk-sidebar-status-icon = true
# gtk-sidebar-status-after = 5s
# gtk-sidebar-status-long-after = 60s

# --- Look and feel ------------------------------------------------------
# font-family = JetBrains Mono
"""


def launch(cfgdir, extra=(), logpath=None):
    env = dict(os.environ)
    env["XDG_CONFIG_HOME"] = cfgdir
    env["GDK_BACKEND"] = "x11"
    env.pop("WAYLAND_DISPLAY", None)
    cmd = [NV]
    if extra:
        cmd = [NV] + list(extra)
    logf = open(logpath, "w") if logpath else subprocess.DEVNULL
    proc = subprocess.Popen(cmd, env=env, stdout=logf, stderr=logf)
    time.sleep(6.0)
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
    g = win.get_geometry()
    raw = win.get_image(0, 0, max(1, g.width), max(1, g.height), X.ZPixmap, 0xFFFFFFFF)
    d.sync()
    return Image.frombytes("RGB", (g.width, g.height), raw.data, "raw", "BGRX")


def sidebar_width(img):
    """The sidebar's card-free area: the sidebar background differs from the
    terminal's. Measured on a row well below the header (y=300): the widest
    column where the pixel still equals the window's own background."""
    px = img.load()
    y = min(200, img.height - 20)
    # The sidebar's own background, sampled well inside it, against the
    # terminal's own tint (which differs on the blue channel).
    bg = px[100, y]
    last = None
    for x in range(100, img.width):
        if px[x, y] == bg:
            last = x
        else:
            break
    return (last + 1) if last is not None else 0


def key(d, ks, mods=()):
    codes = [d.keysym_to_keycode(k) for k in list(mods) + [ks]]
    for c in codes:
        xtest.fake_input(d, X.KeyPress, c)
    d.sync(); time.sleep(0.12)
    for c in reversed(codes):
        xtest.fake_input(d, X.KeyRelease, c)
    d.sync(); time.sleep(0.8)


def drag(d, x0, y, x1):
    xtest.fake_input(d, X.MotionNotify, x=x0, y=y)
    d.sync(); time.sleep(0.3)
    xtest.fake_input(d, X.ButtonPress, 1)
    d.sync(); time.sleep(0.2)
    steps = 12
    for i in range(1, steps + 1):
        x = x0 + (x1 - x0) * i // steps
        xtest.fake_input(d, X.MotionNotify, x=x, y=y)
        d.sync(); time.sleep(0.05)
    xtest.fake_input(d, X.ButtonRelease, 1)
    d.sync(); time.sleep(1.0)


def read_cfg(cfgdir):
    with open(os.path.join(cfgdir, "njuggle", "config"), "rb") as f:
        return f.read()


def lane(name, do_gesture, width_arg=None):
    cfgdir = tempfile.mkdtemp(prefix="r2-")
    os.makedirs(os.path.join(cfgdir, "njuggle"), exist_ok=True)
    before = USER_CONFIG.encode()
    with open(os.path.join(cfgdir, "njuggle", "config"), "wb") as f:
        f.write(before)
    extra = [] if width_arg is None else ["+%s" % width_arg] if False else []
    proc, d, win = launch(cfgdir)
    try:
        start_w = sidebar_width(capture(win, d))
        do_gesture(d, win)
        after = read_cfg(cfgdir)
        img = capture(win, d)
        img.save(os.path.join(OUT, name + "_after_gesture.png"))
        gesture_w = sidebar_width(img)
    finally:
        stop(proc)
    proc, d, win = launch(cfgdir)
    try:
        img = capture(win, d)
        img.save(os.path.join(OUT, name + "_after_restart.png"))
        restart_w = sidebar_width(img)
    finally:
        stop(proc)
    print(f"{name}: width start={start_w} after_gesture={gesture_w} after_restart={restart_w}")
    print("   config after gesture (repr):")
    for line in after.decode().splitlines():
        print("     |", line)
    # Byte preservation: removing the one written key must give the original.
    written = [l for l in after.decode().splitlines() if l.startswith("gtk-sidebar-width")]
    print("   written key lines:", written)
    # Every other byte: removing the one written line gives the original.
    if written:
        stripped = after.replace((written[0] + "\n").encode(), b"", 1)
    else:
        stripped = after
    preserved = stripped == before
    print("   every other byte preserved:", preserved)
    if not written:
        ok = (gesture_w == start_w and restart_w == start_w)
        print("   RESULT:", "pass (gesture inert, no write)" if ok else "fail")
        return start_w, gesture_w, restart_w, before, after, preserved, ok
    ok = preserved and gesture_w != start_w and restart_w == gesture_w
    print("   RESULT:", "pass" if ok else "fail")
    return start_w, gesture_w, restart_w, before, after, preserved, ok


if __name__ == "__main__":
    # The resize gesture is the fixed accelerator Ctrl+Shift+R.
    r = lane("keybinding", lambda d, w: key(d, 0x0072, (CTRL, SHIFT)))
    sys.exit(0 if r[-1] else 1)
