# R3-B verdict reader over check-sidebar-model-a11y.py's dump.
#
# One line per assertion, then RESULT. Exit 0 only when every assertion holds.
# The three assertions are the verification law's rule-1 contract:
#   WINDOWS : exactly one realized top-level window in the app
#   TABS    : the sidebar's tab model is non-empty at launch
#   SURFACE : the split view's content child is the terminal (a scroll pane
#             and a focusable terminal panel; tier 1 only, see the pin note
#             in the dump writer)
#
# The sidebar's list is the one NOT inside the title bar: the title bar's
# tabs are `page tab list` / `page tab`, the sidebar's are `list` /
# `row header`. Counting only the sidebar's is what makes TABS about the
# feature the owner reported, not about the tab bar upstream already had.
#
# Licence: AGPLv3 (njuggle).

import sys


def load(path):
    nodes = []
    meta = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("N "):
                p = line[2:].split("|")
                if len(p) < 5:
                    continue
                while len(p) < 6:
                    p.append("")
                nodes.append({"depth": int(p[0]), "role": p[1], "name": p[2],
                              "children": int(p[3]), "states": p[4].split(","),
                              "ifaces": p[5].split(",")})
            elif line.startswith("A "):
                app, _, frames = line[2:].partition("|")
                meta["app"] = app
                meta["frames"] = int(frames) if frames.isdigit() else 0
    return meta, nodes


def main():
    meta, nodes = load(sys.argv[1])
    fails = []

    def metric(name, detail, ok):
        print("%-8s %-4s %s" % (name, "ok" if ok else "FAIL", detail))
        if not ok:
            fails.append(name)

    frames = meta.get("frames", 0)
    metric("WINDOWS", "%d realized window (role frame)" % frames, frames == 1)

    sidebar_lists = [n for n in nodes if n["role"] == "list"]
    sidebar_rows = [n for n in nodes if n["role"] in ("row header", "list item")]
    tabbar_lists = [n for n in nodes if n["role"] == "page tab list"]
    metric("TABS", "sidebar model: %d row(s) in %d list(s); title bar: %d page tab list(s)"
           % (len(sidebar_rows), len(sidebar_lists), len(tabbar_lists)),
           len(sidebar_rows) > 0)

    spanes = [n for n in nodes if n["role"] == "scroll pane"]
    terminal = [n for n in nodes if n["role"] == "panel"
                and n["children"] == 0 and ("focusable" in n["states"])]
    metric("SURFACE", "scroll pane x%d, focusable terminal panel x%d"
           % (len(spanes), len(terminal)),
           len(spanes) >= 1 and len(terminal) >= 1)

    print("")
    print("RESULT: %s" % ("pass" if not fails else "fail (%s)" % ",".join(fails)))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
