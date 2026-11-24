# Sidebar row content, headless: the row carries its title, its working-directory
# subtitle and its status indicator before any pointer touches it.
#   ~/.local/bin/strict scripts/check-sidebar-row-content.janet <njuggle-repo-root>
#
# WHY THIS EXISTS. The owner's UAT found rows that rendered an empty card: no
# title, no description, no status icon, while the hover X still worked. The
# close path only needs the row's `page` property; the CONTENT is built by the
# template, and the template's content box was never attached: the backfill
# image and the close button were plain children of the row's Gtk.Overlay, so
# the overlay kept one of them as its main child and detached the box holding
# the labels and the status image. The fix is the `[overlay]` markers; this
# cell is what fails without them.
#
# WHAT IS MEASURED, FROM WHERE. The accessibility tree (AT-SPI over D-Bus), read
# by the shipped dumper with the window untouched: no hover, no click. A label
# that is not in the widget tree is not in the accessibility tree either, so a
# detached content box reads as zero labels. The values are made deterministic:
# `--working-directory=/tmp` gives the subtitle the basename `tmp`.
#
# Not asserted here: the icon's pixel appearance; that is the owner's on-screen
# cell (the 12px status mark passed every code gate and was too small to read).
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def bin (string root "/zig-out/bin/njuggle"))
(def base "/tmp/njuggle-row-content")
(def cfg-dir (string base "/cfg"))
(def dump (string base "/a11y.txt"))

(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(os/execute ["/bin/rm" "-rf" base])
(os/execute ["/bin/mkdir" "-p" (string cfg-dir "/njuggle")])
(spit (string cfg-dir "/njuggle/config") "gtk-sidebar-tabs = left\nfont-size = 12\n")

(def lane (string base "/lane.sh"))
(spit lane
      (string "#!/bin/sh\n"
              "timeout 45 " bin " --working-directory=/tmp > " base "/app.log 2>&1 &\n"
              "sleep 9\n"
              "python3 " root "/scripts/check-sidebar-model-a11y.py " dump " 15\n"
              "pkill -f '" bin "' || true\n"))
(os/execute ["/bin/sh" "-c"
             (string "env XDG_CONFIG_HOME=" cfg-dir " XDG_STATE_HOME=" base "/st"
                    " XDG_CACHE_HOME=" base "/ca GSETTINGS_BACKEND=memory"
                    " xvfb-run -a -s '-screen 0 1600x1000x24'"
                    " dbus-run-session -- /bin/sh " lane " > " base "/run.out 2>&1")])

(def text (if (nil? (os/stat dump :mode)) "" (string (slurp dump))))

# Node lines are "N <depth>|<role>|<name>|<children>|<states>|<interfaces>".
(defn nodes []
  (def out @[])
  (each line (string/split "\n" text)
    (when (string/has-prefix? "N " line)
      (def body (string/slice line 2))
      (def parts (string/split "|" body))
      (when (>= (length parts) 3)
        (array/push out @{
          :depth (scan-number ((string/split " " (get parts 0)) 0))
          :role (get parts 1)
          :name (get parts 2)
        }))))
  out)

(def all (nodes))

# The row's own subtree: the dump is a pre-order walk, so the subtree of the
# list item is the run of nodes after it whose depth is greater. Labels from
# the title bar's tab list are elsewhere in the tree and must not count.
(defn row-subtree [ns]
  (var start nil)
  (var i 0)
  (while (and (nil? start) (< i (length ns)))
    (when (= "list item" ((ns i) :role)) (set start i))
    (++ i))
  (if (nil? start)
    @[]
    (do
      (def d ((ns start) :depth))
      (def out @[])
      (var j (+ start 1))
      (while (and (< j (length ns)) (> ((ns j) :depth) d))
        (array/push out (ns j))
        (++ j))
      out)))

(def row (first (filter |(= "list item" ($ :role)) all)))
(def inner (row-subtree all))
(def labels (filter |(= "label" ($ :role)) inner))

(check "row: the sidebar list has a row item"
       (not (nil? row))
       (string "no list item in " (length all) " a11y nodes"))
(check "row: the row shows its working-directory subtitle"
       (not (nil? (first (filter |(= "tmp" ($ :name)) labels))))
       (string/format "row labels=%q" (map |($ :name) labels)))
(check "row: the row shows its title as well"
       (not (nil? (first (filter |(and (not (empty? ($ :name))) (not (= "tmp" ($ :name)))) labels))))
       (string/format "row labels=%q" (map |($ :name) labels)))
(check "row: both labels are inside the row item, not loose in the window"
       (>= (length labels) 2)
       (string/format "row depth=%d nodes=%d labels=%q"
                      (or (row :depth) -1)
                      (length inner)
                      (map |@[($ :depth) ($ :name)] labels)))

# The resting row's content is exactly the title, the working-directory
# subtitle, the status mark and the close control. The backfill image is
# hidden with a stylesheet opacity (owner UAT 2026-11-20, cell 1.1), and
# opacity is not a visibility state to the a11y tree - the node stays
# `showing` - so the pixel cell proves its absence and this cell proves the
# rest of the row is intact.
(def images (filter |(= "image" ($ :role)) inner))
(def buttons (filter |(= "button" ($ :role)) inner))

(check "row: the status mark is inside the row item"
       (not (nil? (first images)))
       (string/format "row nodes=%d roles=%q" (length inner) (map |($ :role) inner)))
(check "row: the close control is inside the row item"
       (not (nil? (first (filter |(= "Close Tab" ($ :name)) buttons))))
       (string/format "row buttons=%q" (map |($ :name) buttons)))
(check "row: exactly the title and the working-directory labels, no third line"
       (= 2 (length labels))
       (string/format "row labels=%q" (map |($ :name) labels)))

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (print "--- a11y dump ---")
    (print text)
    (os/exit 1)))
