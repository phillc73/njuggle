# The divider-drag cell, runnable on its own:
#   ~/.local/bin/strict scripts/check-sidebar-drag.janet <njuggle-repo-root>
#
# The report was "dragging the sidebar divider does nothing". Adw.OverlaySplitView
# in the toolkit this ships against (libadwaita 1.7) has no drag handle: its
# property setters are the width, the position, the pin and the two swipe
# gestures, so its boundary is not a hit region at all. The window therefore
# owns the drag: a gesture on the split view claims a press that lands in the
# edge band, moves the width on every pointer step, and writes the config once
# on release.
#
# Headless lanes can prove the pieces exist and the rules hold (the arithmetic
# is a unit test beside the function); the drag itself is the owner's cell.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def window-blp (string root "/src/apprt/gtk/ui/1.4/window.blp"))
(def window-zig (string root "/src/apprt/gtk/class/window.zig"))
(def sidebar-blp-path (string root "/src/apprt/gtk/ui/1.4/sidebar.blp"))

(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(defn read-or-nil [p]
  (if (not (nil? (os/stat p :mode))) (string (slurp p)) nil))

(def blp (read-or-nil window-blp))
(def zig (read-or-nil window-zig))
(def sidebar-blp (read-or-nil sidebar-blp-path))

(check "drag: the window blueprint declares the split view"
       (and blp (not (nil? (string/find "Adw.OverlaySplitView split_view" blp))))
       (string "no split view in " window-blp))

(check "drag: the split view carries a divider gesture"
       (and zig (not (nil? (string/find "GestureDrag" zig))))
       "window.zig adds no drag gesture, so the divider has no hit region")

# One writer: the drag ends through the same single-key persist the keybinding
# uses. A second writer would be a second place for the config to go wrong.
(check "drag: the release writes through the one config writer"
       (and zig (not (nil? (string/find "persistSidebarWidth" zig))))
       "the drag does not persist through persistSidebarWidth")

# The width must follow the pointer, not the release: an update handler has to
# apply with persist = false (the file is owed one edit, at the end).
(check "drag: every pointer step moves the width without writing"
       (and zig
            (not (nil? (string/find "setSidebarWidth(base + edge * moved, false)" zig))))
       "the width only changes on release, so the drag has no live feedback")

# A desktop report: the drag narrowed only AFTER a widen. The gesture's
# base was the STORED width, which is 0 until a gesture sets it, and the
# launch apply left the split view on a pixel unit with cleared bounds - the
# launch width it could not cross. Cells: one writer, live start, pixel unit
# on every write.
(check "drag: the drag starts from the width on screen, not the stored one"
       (and zig
            (not (nil? (string/find
                         "priv.sidebar_drag_start = @intCast(@max(priv.sidebar.as(gtk.Widget).getWidth(), 0));"
                         zig))))
       "the drag start is the stored width, which is 0 at launch width")

(check "drag: the drag and the apply place the width through one writer"
       (and zig
            (not (nil? (string/find "fn placeSidebarWidth" zig)))
            (nil? (string/find "priv.split_view.setMinSidebarWidth(@floatFromInt(clamped))" zig)))
       "two writers put the width on the split view; they drift and the drag clamps against the wrong one")

(check "drag: the pixel writer sets the unit on every write"
       (and zig
            (not (nil? (string/find "priv.split_view.setSidebarWidthUnit(.px);" zig))))
       "the unit is not set by the writer, so a reset to the toolkit width leaves a stray pixel unit")

# DRAG AFFORDANCE LAW (requirements): two parallel lines with arrows in the
# band, present whenever the sidebar is shown expanded. The headless lane can
# prove the mark exists, is placed on the boundary's arithmetic, and is
# suppressed under the same conditions the gesture is.
# THE HOST HISTORY. Round 2 hosted this mark on an overlay wrapping the split
# view and the terminal stopped spawning entirely; an overlay around the
# terminal's content did the same. A later widget-hosted mark carried the
# same class of defect (a Gtk.Overlay wrapper left the sidebar unallocated),
# so the affordance is no longer a widget at all: it is a HIT BAND around the
# sidebar's trailing edge, computed from the sidebar's measured width. The
# cell asserts both halves: nothing anywhere wraps the terminal, and the band
# is derived from the boundary the drag actually moves.
(check "drag affordance: the band is derived from the sidebar's measured width"
       (and zig
            (not (nil? (string/find "sidebarDividerHit(" zig)))
            (not (nil? (string/find "priv.sidebar.as(gtk.Widget).getWidth()" zig))))
       "the hit region is not placed from the sidebar's measured width")

(check "drag affordance: the band is placed from the split view's own geometry"
       (and zig
            (not (nil? (string/find "priv.split_view.as(gtk.Widget).getWidth()" zig))))
       "the press is compared with the sidebar's width alone; a right-hand sidebar's divider is somewhere else")

# A later report widened this. The band was
# computed from the sidebar width alone, which is the left-hand boundary only;
# then from PackType alone, which is text-direction relative and wrong in RTL.
# The boundary now follows the widget's physical side.
(check "drag affordance: the band follows the sidebar's side"
       (and zig
            (not (nil? (string/find "const boundary: f64 = if (sidebarIsPhysicalStart(position, direction))" zig)))
            (not (nil? (string/find "priv.split_view.getSidebarPosition()," zig)))
            (not (nil? (string/find "priv.split_view.as(gtk.Widget).getDirection()," zig))))
       "the band is computed for a left-hand sidebar whatever gtk-sidebar-tabs or the text direction says")

(check "drag affordance: the hit test is exercised for both sides, both directions"
       (and zig
            (not (nil? (string/find "sidebarDividerHit(1000, 200, 1200, end, ltr)" zig)))
            (not (nil? (string/find "sidebarDividerHit(200, 200, 1200, start, ltr)" zig)))
            (not (nil? (string/find "sidebarDividerHit(200, 200, 1200, end, rtl)" zig)))
            (not (nil? (string/find "sidebarDividerHit(1000, 200, 1200, start, rtl)" zig))))
       "the unit cell misses a physical side or a text direction, so that band can regress unnoticed")

(check "drag affordance: the mark is not hosted on the terminal's container"
       (and blp
            (nil? (string/find "affordance" blp))
            (nil? (string/find "split_overlay" blp)))
       "the split view or its content is wrapped in an overlay again: that stops the terminal surface spawning")

(check "drag affordance: no overlay wrapper carries the mark"
       (and sidebar-blp
            (nil? (string/find "affordance_image" sidebar-blp))
            (nil? (string/find "template $GhosttySidebar: Gtk.Overlay" sidebar-blp)))
       "the sidebar is a plain overlay again: with no main child the tab list never gets allocated")

(check "drag affordance: the gesture is inert with the sidebar off"
       (and zig
            (not (nil? (string/find "gtk-sidebar-tabs\" == .none) return;" zig))))
       "the two-handle divider shows in none mode, where the gesture does nothing")

(check "drag affordance: the icon ships with the app"
       (not (nil? (os/stat (string root "/images/njuggle/icons/hicolor/scalable/actions/njuggle-divider.svg")
                           :mode)))
       "the icon name has no file in the hicolor tree the installer copies")

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do (print (string "RESULT: fail (" (length fails) " cells)")) (os/exit 1)))
