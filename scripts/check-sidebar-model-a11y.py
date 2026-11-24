# R3-B: the sidebar tab model, read from OUTSIDE the binary.
#
# TIER 1, the accessibility tree over D-Bus (Atspi GI binding). This is the
# verification law's mechanism pin: the dump works on v0.1.0 and on any fix
# alike, so before/after is comparable. It reads the widget structure GTK
# publishes - one frame, the sidebar's list and its rows, the terminal's
# scroll pane - and never the app's log.
#
# WHAT THE BRACKET PROVES (2026-11-04, this host). The same probe run twice,
# gtk-sidebar-tabs = left and then none, on one binary: with the sidebar off
# the tree shows the horizontal title bar's `page tab list`; with it on it
# does not. A11y therefore CAN see both tab widgets, and an empty sidebar in
# the tree is an empty sidebar, not a blind instrument. That bracket is the
# cell's own coverage proof and is part of the gate.
#
# TIER 2 (not used by the verdict, and stated because the mechanism pin asks
# where each assertion lives): surface-as-content-child is asserted from
# tier 1 only - a scroll pane and a focusable terminal panel under the split
# view. AT-SPI does not name the split view's child relationship, so the
# tier-2 log line (`surface content scale`) is reported alongside it, never
# instead of it.
#
# Licence: AGPLv3 (njuggle).

import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

STATES = ("showing", "visible", "enabled", "focusable", "selected",
          "horizontal", "vertical")
ROW_ROLES = ("row header", "list item", "page tab")
LIST_ROLES = ("list", "page tab list")


def states(node):
    try:
        st = node.get_state_set()
    except Exception:
        return ""
    out = []
    for name in STATES:
        try:
            if st.contains(getattr(Atspi.StateType, name.upper())):
                out.append(name)
        except Exception:
            pass
    return ",".join(out)


def ifaces(node):
    try:
        got = node.get_interfaces() or ""
    except Exception:
        return ""
    return ",".join(x for x in ("Text", "Selection", "Table", "Action")
                    if x in got)


def walk(node, depth, out, budget=4000):
    if len(out) >= budget:
        return
    try:
        role = node.get_role_name() or "?"
    except Exception:
        role = "?"
    try:
        name = (node.get_name() or "").replace("\n", " ").replace("|", "/")
    except Exception:
        name = ""
    try:
        n = node.get_child_count()
    except Exception:
        n = 0
    out.append("%d|%s|%s|%d|%s|%s" % (depth, role, name[:60], n,
                                      states(node), ifaces(node)))
    for i in range(n):
        try:
            child = node.get_child_at_index(i)
        except Exception:
            continue
        if child is not None:
            walk(child, depth + 1, out)


def snapshot():
    lines = []
    try:
        desktop = Atspi.get_desktop(0)
    except Exception as e:
        return ["A %s" % e]
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is None:
            continue
        name = app.get_name() or "?"
        if "ghostty" not in name.lower():
            continue
        out = []
        walk(app, 0, out)
        frames = sum(1 for l in out if "|frame|" in l)
        lines.append("A %s|%d" % (name, frames))
        lines.extend("N " + l for l in out)
    if not lines:
        lines.append("A none|0")
    return lines


def main():
    dest = sys.argv[1]
    wait = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
    deadline = time.time() + wait
    lines = ["A none|0"]
    while time.time() < deadline:
        lines = snapshot()
        if len(lines) > 1:
            break
        time.sleep(0.5)
    with open(dest, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
