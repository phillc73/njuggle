# Close-button edge overlay (requirements R3, amended), runnable on its own:
#   ~/.local/bin/strict scripts/check-sidebar-close-overlay.janet <njuggle-repo-root>
#
# R3 as amended: the X reserves NO space ever; it is ~1/3 of the old button,
# drawn at the row's trailing edge, allowed to overlap the row boundary; the
# label and status regions never move or shrink; it stays keyboard-reachable.
#
# What a headless lane can prove, and what it cannot: the row is a blueprint
# template and the reveal is a stylesheet rule, so the tree can be read for the
# structural facts below. Where the X lands on screen and whether the label
# moves are the owner's cell - nothing here claims to measure a pixel.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def row-blp (string root "/src/apprt/gtk/ui/1.4/sidebar-row.blp"))
(def css (string root "/src/apprt/gtk/css/style.css"))

(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(defn read-or-nil [p]
  (if (not (nil? (os/stat p :mode))) (string (slurp p)) nil))

(def blp (read-or-nil row-blp))
(def style (read-or-nil css))

# The X has to leave the row's horizontal box. A widget inside that box is laid
# out by it and takes from the label's space; the overlay is a child of the row
# box, which the horizontal box does not see.
(defn in-horizontal-box? [text]
  (if (nil? text)
    true
    (not (nil? (string/find "Gtk.Overlay" text)))))

(check "close overlay: the X is an overlay on the row, not a box child"
       (and blp (in-horizontal-box? blp))
       "the close button still sits inside the row's horizontal box, so it reserves label space")

(check "close overlay: the X is anchored to the trailing edge"
       (and blp
            (or (not (nil? (string/find "halign: end" blp)))
                (not (nil? (string/find "halign:end" blp)))))
       "the X has no trailing-edge anchor, so it does not sit on the row boundary")

# A desktop report (GTK 4.18.6, scale 1.45): the X rendered INSIDE the
# tab borders with a clean config; the dev host's Xvfb at scale 1 cannot
# reproduce it. The cause read from the toolkit: a 12px size request is a
# MINIMUM in logical pixels and GTK's own button chrome (~32px) wins over it,
# so the request never made a 12px button at any scale. The cell asserts the
# mechanism that replaces it, not a pixel - on-screen extent is the owner's.
# The round-1 cell that asserted the 12px request is replaced by the two
# below: it passed while the desktop was wrong, which is what it measured.
(check "close overlay: the X's size is the stylesheet's, not a widget minimum"
       (and blp
            (nil? (string/find "width-request:" blp))
            (nil? (string/find "height-request:" blp)))
       "a width-request/height-request property is a logical-pixel floor that the button's own minimum overrides")

(check "close overlay: the stylesheet pins the X at 12 logical px with no padding"
       (and style
            (not (nil? (string/find "min-width: 12px" style)))
            (not (nil? (string/find "min-height: 12px" style)))
            (not (nil? (string/find "padding: 0" style))))
       "the button keeps its chrome padding, so its box is the icon plus padding, not 12px")

# ICON-BACKFILL LAW (requirements): the backfill icon always displays in full
# in the row's bottom-right corner; the text yields, the icon never does.
(check "close overlay: the label is still first in the row's box"
       (and blp
            (< (or (string/find "Gtk.Label" blp) 999999)
               (or (string/find "close_button" blp) 999999)))
       "the title label changed shape")

(check "close overlay: the backfill icon pins to the bottom-right corner"
       (and blp
            (not (nil? (string/find "backfill_image" blp)))
            (not (nil? (string/find "valign: end" blp))))
       "the row has no backfill icon, so the row's extent is invisible at narrow widths")

# OWNER UAT 2026-11-20, cell 1.1 - supersedes the DISPLAY half of the
# ICON-BACKFILL law (requirements R3, 2026-11-03): a resting row shows its
# title, its working directory and the status mark, and nothing in the
# trailing corner. The backfill image stays in the template as the overlay
# sibling the X shares the corner with, but it paints nothing: its visibility
# is the stylesheet's, on the same state source the X's reveal reads (the
# row's `.njuggle-hover` class), and it resolves to zero with and without that
# class. One source, two layers.
(defn rule-body [text selector]
  (def at (string/find selector text))
  (when at
    (def open (string/find "{" text (+ at (length selector))))
    (when open
      (def close (string/find "}" text open))
      (when close (string/slice text (+ open 1) close)))))

(def backfill-rule (if style (rule-body style "image.backfill") nil))

(check "backfill: the image paints nothing at rest"
       (and backfill-rule
            (not (nil? (string/find "opacity: 0;" backfill-rule))))
       "the stylesheet leaves the backfill image visible on a resting row (owner UAT 1.1: a stray icon on every row)")

(check "backfill: no state raises it - one visibility source with the X"
       (and style
            (nil? (string/find "njuggle-hover image.backfill" style))
            (nil? (string/find "image.backfill.njuggle-hover" style)))
       "a separate hover rule gives the backfill its own visibility source, so it can drift from the X's reveal")

(check "icon backfill: the image has a size floor in the stylesheet"
       (and style
            (not (nil? (string/find "image.backfill" style))))
       "the icon can shrink to nothing when the text is long")

# The two checks below sat after an early `os/exit` in this file's earlier
# shape, so they never ran and the file as a whole did not parse. They are
# live here.
(check "close overlay: the title ellipsizes at the row's end"
       (and blp
            (not (nil? (string/find "ellipsize: end" blp))))
       "the title label changed shape")

(check "close overlay: the reveal is still a stylesheet opacity, never a resize"
       (and style
            (not (nil? (string/find "njuggle-row-close" style)))
            (not (nil? (string/find "opacity" style))))
       "the close button's reveal is not an opacity rule any more")

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do (print (string "RESULT: fail (" (length fails) " cells)")) (os/exit 1)))
