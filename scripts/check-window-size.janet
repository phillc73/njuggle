# Window size end to end, headless: config text -> load -> window geometry ->
# close -> config bytes -> restart -> the same geometry. Runnable on its own:
#
#   ~/.local/bin/strict scripts/check-window-size.janet <njuggle-repo-root>
#
# Why these cells exist: `window-size` is written into the user's config when a
# window closes and read back at launch. A field the parser does not know makes
# the whole config fail to load, so a config written by an older release would
# brick a newer one - the cell named "upgrade" below is the gate.
#
# What a headless lane can prove: the load (validate-config), the geometry the
# window actually gets under Xvfb, and the bytes the close writes back. What it
# cannot: how the size feels on the owner's desktop.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def bin (string root "/zig-out/bin/njuggle"))
(def stamp (math/floor (os/clock)))
(def base (string "/tmp/njuggle-window-size-" stamp))
(def cfg-dir (string base "/cfg"))
(def cfg (string cfg-dir "/njuggle/config"))
(def log (string base "/app.log"))
(def dpy (string ":" (+ 200 (% stamp 500))))

(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(defn run-capture [cmd]
  (def f (string base "/capture"))
  (os/execute ["/bin/rm" "-f" f])
  (def rc (os/execute ["/bin/sh" "-c" (string cmd " > " f " 2>&1")]))
  (def out (if (nil? (os/stat f :mode)) "" (string (slurp f))))
  @{:rc rc :out out})

(defn write-config [text]
  (os/execute ["/bin/mkdir" "-p" (string cfg-dir "/njuggle")])
  (spit cfg text))

(defn read-config [] (string (slurp cfg)))

# The terminal window's size, from the one child of the root that carries the
# app id. The 1x1 helper windows the toolkit keeps are excluded by size.
(defn window-size []
  (def r (run-capture (string "xwininfo -display " dpy " -root -children")))
  (var found nil)
  (each line (string/split "\n" (get r :out))
    (when (and (not (nil? (string/find "org.mimosadev.njuggle" line)))
               (not (nil? (string/find ")" line))))
      (def tail (last (string/split ")" line)))
      (def wh (string/split "x" (first (string/split "+" (string/trim tail)))))
      (when (= 2 (length wh))
        (def w (scan-number (get wh 0)))
        (def h (scan-number (get wh 1)))
        (when (and w h (> w 300) (> h 200))
          (set found (string w "x" h))))))
  found)

(defn start-xvfb []
  (os/execute ["/bin/sh" "-c"
               (string "Xvfb " dpy " -screen 0 1920x1080x24 > " base "/xvfb.log 2>&1 &")])
  (var tries 0)
  (while (and (< tries 60)
              (nil? (string/find "name of display"
                                 (get (run-capture (string "xdpyinfo -display " dpy)) :out))))
    (os/sleep 0.1)
    (++ tries))
  tries)

(defn app-pid [extra]
  (def pidfile (string base "/pid"))
  (os/execute ["/bin/rm" "-f" pidfile])
  (os/execute ["/bin/sh" "-c"
               (string "DISPLAY=" dpy " XDG_CONFIG_HOME=" cfg-dir
                       " GDK_BACKEND=x11 " bin " " extra " > " log " 2>&1 & echo $! > "
                       pidfile)])
  (string/trim (string (slurp pidfile))))

(defn running? [pid] (= 0 (os/execute ["/bin/kill" "-0" pid] :p)))

(defn wait-window [pid]
  (var tries 0)
  (var size nil)
  (while (and (< tries 80) (nil? size) (running? pid))
    (os/sleep 0.25)
    (set size (window-size))
    (++ tries))
  size)

(defn wait-exit [pid]
  (var tries 0)
  (while (and (< tries 200) (running? pid))
    (os/sleep 0.1)
    (++ tries))
  (not (running? pid)))

(defn kill-app [pid]
  (os/execute ["/bin/kill" "-TERM" pid])
  (var tries 0)
  (while (and (< tries 40) (running? pid))
    (os/sleep 0.1)
    (++ tries)))

(defn launch-size [text]
  (write-config text)
  (def pid (app-pid ""))
  (def size (wait-window pid))
  (kill-app pid)
  size)

# The load cell: exit status plus what the loader said about the file.
(defn validate [text]
  (write-config text)
  (run-capture (string bin " +validate-config --config-file=" cfg)))

(def base-config "font-size = 13\n")

# --- the X server ----------------------------------------------------------
(os/execute ["/bin/mkdir" "-p" (string cfg-dir "/njuggle")])
(def xvfb-tries (start-xvfb))
(check "xvfb: a display to measure on" (< xvfb-tries 60) (string "no display " dpy))

# --- cell A: a recorded size is the size the window gets -------------------
(def v-a (validate (string base-config "window-size = 900x640\n")))
(check "A: a config with window-size loads clean" (= 0 (get v-a :rc)) (get v-a :out))
(check "A: the load reports no unknown field"
       (nil? (string/find "unknown field" (get v-a :out)))
       (get v-a :out))
(def size-a (launch-size (string base-config "window-size = 900x640\n")))
(check "A: the window takes the recorded size" (= "900x640" size-a)
       (string/format "%q" size-a))

# --- cell B (THE gate): a config written by a release that had the key -----
(def template (string (slurp (string root "/dist/njuggle/config.default"))))
(def v-b (validate (string template "window-size = 900x640\n")))
(check "B upgrade: a v0.1.0-shaped config (the key present) loads unchanged"
       (= 0 (get v-b :rc))
       (get v-b :out))
(check "B upgrade: the owner's own line is accepted, not rejected"
       (nil? (string/find "unknown field" (get v-b :out)))
       (get v-b :out))
(def size-b (launch-size (string template "window-size = 900x640\n")))
(check "B upgrade: and that config opens a window at that size" (= "900x640" size-b)
       (string/format "%q" size-b))

# --- cell C: malformed values degrade to the default window ----------------
(def size-default (launch-size base-config))
(check "C: the control launch has a size to compare against"
       (not (nil? size-default))
       (string/format "%q" size-default))
(each bad ["900" "axb" "0x640"]
  (def v (validate (string base-config "window-size = " bad "\n")))
  (check (string "C malformed (" bad "): the config still loads")
         (and (= 0 (get v :rc))
              (nil? (string/find "unknown field" (get v :out))))
         (get v :out))
  (def got (launch-size (string base-config "window-size = " bad "\n")))
  (check (string "C malformed (" bad "): the window keeps its default size")
         (and (not (nil? got)) (= size-default got))
         (string/format "%q" got)))

# --- cell C2: a trailing comment is still the value -----
# The single-key writer keeps a trailing comment on its own line (`upsert`
# asserts it), so the app's own next launch reads one back. Before the fix the
# parser saw `900x640 # last size` as malformed and the window opened at the
# default, and every close rewrote the same unparseable line.
(each [tag text] [["spaced" "900x640 # last size"] ["tight" "900x640#last size"]]
  (def v (validate (string base-config "window-size = " text "\n")))
  (check (string "C2 comment (" tag "): the config loads clean")
         (and (= 0 (get v :rc))
              (nil? (string/find "unknown field" (get v :out))))
         (get v :out))
  (def got (launch-size (string base-config "window-size = " text "\n")))
  (check (string "C2 comment (" tag "): the window takes the recorded size")
         (= "900x640" got)
         (string/format "%q" got)))

# --- cell D: close writes the size, the next launch reads it back ----------
(def d-text "font-size = 13\n# a comment the writer must keep\n")
(write-config d-text)
(def pid-d (app-pid "-e sleep 8"))
(def size-d1 (wait-window pid-d))
(def exited? (wait-exit pid-d))
(def after-d (read-config))
(check "D: the close happens on its own (the tab's command ended)" exited?
       "the app did not exit")
(check "D: the close wrote window-size"
       (not (nil? (string/find "window-size = " after-d)))
       after-d)
(check "D: the written value is the size the window had"
       (and (not (nil? size-d1))
            (not (nil? (string/find (string "window-size = " size-d1 "\n") after-d))))
       (string "measured " (string/format "%q" size-d1) " in " after-d))
(check "D: the user's comment survived the write"
       (not (nil? (string/find "# a comment the writer must keep" after-d)))
       after-d)
(def size-d2 (launch-size after-d))
(check "D: the next launch opens at the recorded size"
       (and (not (nil? size-d1)) (= size-d1 size-d2))
       (string/format "%q" size-d2))

# --- a second close replaces the line, it does not add another -------------
(write-config after-d)
(def pid-d3 (app-pid "-e sleep 6"))
(wait-window pid-d3)
(wait-exit pid-d3)
(def after-d3 (read-config))
(def occurrences (length (filter |(not (nil? (string/find "window-size = " $)))
                                (string/split "\n" after-d3))))
(check "D: a second close replaces its own line, it does not add another"
       (= 1 occurrences)
       (string occurrences " lines in " after-d3))

# --- teardown --------------------------------------------------------------
(os/execute ["/bin/sh" "-c" (string "pkill -f 'Xvfb " dpy "' || true")])

(print (if (empty? fails)
         "RESULT: pass"
         (string "RESULT: fail: " (string/join fails ", "))))
