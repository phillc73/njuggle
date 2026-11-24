# Sidebar width across launches, headless: the launch bounds and the
# Ctrl+Shift+R step sequence, driven through the window's own action.
#   ~/.local/bin/strict scripts/check-sidebar-resize.janet <njuggle-repo-root>
#
# WHY THIS EXISTS. The owner's UAT saw two step counts (four on the first
# launch of a config, three on every later one) and two different clamp
# readings. The bounds in the dbg line were read BEFORE the apply, and the
# gesture started from a stored width of 0 on a fresh launch, so its first
# press landed on the floor and changed nothing visible.
#
# WHAT THIS ASSERTS:
#   - three launches on the same config report the same launch bounds;
#   - the first press of a launch moves the sidebar (no wasted press), both
#     on a config with no stored width and on one that already holds a width;
#   - the step is one eighth of the window;
#   - the gesture sequence depends only on the width it starts from, not on
#     how many launches ago the config was written: a launch that starts at
#     the fresh launch's first step produces that launch's second step next.
#
# The gesture is `org.gtk.Actions.Activate resize-sidebar` on the window's
# action group - the same action Ctrl+Shift+R is bound to - so no keyboard
# injection is needed.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def bin (string root "/zig-out/bin/njuggle"))
(def base "/tmp/njuggle-sidebar-resize")
(def cfg-dir (string base "/cfg"))
(def cfg (string cfg-dir "/njuggle/config"))
(def app-log (string base "/app.log"))

(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(defn write-config [extra]
  (os/execute ["/bin/mkdir" "-p" (string cfg-dir "/njuggle")])
  (spit cfg (string "gtk-sidebar-tabs = left\nfont-size = 12\n" extra)))

# One session: start the application, press the gesture `presses` times, stop.
(defn run-session [presses]
  (os/execute ["/bin/rm" "-f" app-log])
  (def lines
    @[(string "timeout 60 " bin " > " app-log " 2>&1 &")
      "sleep 7"
      "i=0"
      (string "while [ $i -lt " presses " ]; do")
      (string "gdbus call --session --dest org.mimosadev.njuggle"
              " --object-path /org/mimosadev/njuggle/window/1"
              " --method org.gtk.Actions.Activate resize-sidebar '[]' '{}'"
              " > /dev/null 2>&1")
      "sleep 0.4"
      "i=$((i+1))"
      "done"
      "sleep 0.5"
      "pkill -f '" bin "' || true"])
  (def f (string base "/lane.sh"))
  (spit f (string "#!/bin/sh\n" (string/join lines "\n") "\n"))
  (os/execute ["/bin/sh" "-c"
               (string "env XDG_CONFIG_HOME=" cfg-dir " XDG_STATE_HOME=" base "/st"
                      " XDG_CACHE_HOME=" base "/ca GSETTINGS_BACKEND=memory"
                      " NO_AT_BRIDGE=1 GTK_A11Y=none"
                      " xvfb-run -a -s '-screen 0 1600x1000x24'"
                      " dbus-run-session -- /bin/sh " f " > " base "/run.out 2>&1")])
  (os/execute ["/bin/rm" "-f" f])
  (if (nil? (os/stat app-log :mode)) "" (string (slurp app-log))))

(defn fields [line]
  (def t @{})
  (each field (string/split " " (or line ""))
    (def kv (string/split "=" field))
    (when (= 2 (length kv))
      (put t (get kv 0) (get kv 1))))
  t)

# The dbg line carries the bounds AFTER the apply, so these are what the split
# view was told, not what it held before.
(defn dbg-lines [text which]
  (filter |(and (not (nil? (string/find (string "sidebar dbg which=" which) $)))
                (not (nil? (string/find "placed=" $))))
          (string/split "\n" (or text ""))))

(defn gesture-placed [text]
  (def out @[])
  (each line (dbg-lines text "gesture")
    (array/push out (scan-number (get (fields line) "placed"))))
  out)

(defn launch-bounds [text]
  (def line (last (dbg-lines text "launch")))
  (when line
    (def f (fields line))
    @[(get f "placed") (get f "min") (get f "max")]))

# --- setup -----------------------------------------------------------------
(os/execute ["/bin/rm" "-rf" base])
(os/execute ["/bin/mkdir" "-p" (string cfg-dir "/njuggle")])

# --- cell A: three launches on one config report the same launch bounds ----
(def fresh-bounds @[])
(for i 0 3
  (write-config "")
  (array/push fresh-bounds (launch-bounds (run-session 0))))
(check "A: every launch has a bounds line to read"
       (not (nil? (fresh-bounds 0)))
       (string/format "%q" fresh-bounds))
(check "A: three launches on one config report the same bounds"
       (and (not (nil? (fresh-bounds 0)))
            (deep= (fresh-bounds 0) (fresh-bounds 1))
            (deep= (fresh-bounds 0) (fresh-bounds 2)))
       (string/format "%q" fresh-bounds))

# --- cell B: a config that already holds a width ---------------------------
(def stored-bounds @[])
(for i 0 3
  (write-config "gtk-sidebar-width = 240\n")
  (array/push stored-bounds (launch-bounds (run-session 0))))
(check "B: the stored width is the one applied, every launch"
       (and (not (nil? (stored-bounds 0)))
            (= "240" ((stored-bounds 0) 0))
            (deep= (stored-bounds 0) (stored-bounds 1))
            (deep= (stored-bounds 0) (stored-bounds 2)))
       (string/format "%q" stored-bounds))

# --- cell C: the gesture sequence, from a fresh config ---------------------
(write-config "")
(def fresh-log (run-session 5))
(def fresh-seq (gesture-placed fresh-log))
(def launch-line (last (dbg-lines fresh-log "launch")))
(def window-w (when launch-line (scan-number (get (fields launch-line) "w"))))
(check "C: the five presses each wrote a width"
       (= 5 (length fresh-seq))
       (string/format "%q" fresh-seq))
(check "C: the first press of a fresh launch does not land on the floor"
       (and (= 5 (length fresh-seq)) (> (fresh-seq 0) 150))
       (string/format "%q" fresh-seq))
(check "C: the step is eighth of the window"
       (and (= 5 (length fresh-seq)) window-w
            (= (- (fresh-seq 1) (fresh-seq 0)) (math/floor (/ window-w 8))))
       (string (string/format "%q" fresh-seq) " w=" window-w))

# --- cell D: the same sequence from a launch that starts one step on -------
(write-config (string "gtk-sidebar-width = " (fresh-seq 0) "\n"))
(def stored-seq (gesture-placed (run-session 4)))
(check "D: a launch that starts at the previous launch's first step continues the sequence"
       (and (= 4 (length stored-seq))
            (= (stored-seq 0) (fresh-seq 1))
            (= (stored-seq 1) (fresh-seq 2))
            (= (stored-seq 2) (fresh-seq 3))
            (= (stored-seq 3) (fresh-seq 4)))
       (string "fresh=" (string/format "%q" fresh-seq)
               " stored=" (string/format "%q" stored-seq)))
(check "D: a launch holding a width still moves on the first press"
       (and (= 4 (length stored-seq))
            (not (= (stored-seq 0) (fresh-seq 0))))
       (string/format "%q" stored-seq))

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (print "--- last app log ---")
    (print (if (nil? (os/stat app-log :mode)) "" (string (slurp app-log))))
    (os/exit 1)))
