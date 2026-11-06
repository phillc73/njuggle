# Cell D6b (F-D6): a drag to each extreme is remembered across restart.
#   janet celld6b.janet <bin-dir> <out> <scripts-dir>
#
# Drag hard left (past the floor) then relaunch: the minimum comes back.
# Drag hard right (but not past the window) then relaunch: that width comes
# back exactly. A drag past half the window is also checked: the config keeps
# the dragged value (F-D6, F-D8), and the screen shows the divider at the
# window's right edge.
(def args (dyn *args*))
(def bins (get args 1))
(def out (get args 2))
(def scripts (get args 3))
(def bin (string bins "/njuggle"))
(def xd (string bins "/njuggle-xdrag"))
(def edge-script (string scripts "/sidebar-edge.janet"))
(defn nullf [] (file/open "/dev/null" :w))
(defn capf [p] (file/open p :w))
(def disp ":89")
(def cfg-dir (string out "/c1"))
(def cfg-path (string cfg-dir "/njuggle/config"))

(defn sh [argv] (os/execute argv :p {:out (nullf) :err (nullf)}))

(defn stage [body]
  (sh ["/usr/bin/rm" "-rf" out])
  (sh ["/usr/bin/mkdir" "-p" (string cfg-dir "/njuggle") (string out "/rt")])
  (def f (file/open cfg-path :w))
  (unless f (error "cannot stage"))
  (file/write f body)
  (file/close f))

(defn launch [name]
  (def script (string out "/" name ".sh"))
  (def f (file/open script :w))
  (file/write f (string "#!/bin/sh\nexec env DISPLAY=" disp " GDK_BACKEND=x11 XDG_CONFIG_HOME=" cfg-dir
                        " XDG_RUNTIME_DIR=" out "/rt " bin " > " out "/" name ".log 2>&1\n"))
  (file/close f)
  (os/spawn ["/usr/bin/setsid" "/bin/sh" script] :p {:out (nullf) :err (nullf)})
  (os/sleep 9))

(defn stop []
  (sh ["/usr/bin/pkill" "-9" "-x" "njuggle"])
  (os/sleep 2))

(defn edge [name]
  (def png (string out "/" name ".png"))
  (sh ["/usr/bin/import" "-window" "root" "-display" disp png])
  (def cap (string png ".txt"))
  (os/execute ["/home/phillc/.local/bin/janet" edge-script png] :p {:out (capf cap)})
  (def m (peg/match ~(* "RESULT: edge " (capture (some :d))) (string (slurp cap))))
  (if m (scan-number (get m 0)) nil))

(defn recorded []
  (def t (string (slurp cfg-path)))
  (def at (peg/find ~(some (+ "gtk-sidebar-width = " (some :d))) t))
  (if at
    (do (def m (peg/match ~(* "gtk-sidebar-width = " (capture (some :d))) (string (slice t at))))
        (if m (scan-number (get m 0)) nil))
    nil))

(def xvfb (os/spawn ["Xvfb" disp "-screen" "0" "1280x900x24" "-nolisten" "tcp"]
                    :p {:out (nullf) :err (nullf)}))
(os/sleep 2)

(var fails 0)
(defn check [ok msg] (print (string (if ok "ok   " "FAIL ") msg)) (unless ok (++ fails)))

(defn drag-to [from-x to-x]
  # A real press-drag-release: the same gesture the owner makes. The press
  # lands just inside the divider band; the release is what writes.
  (sh [xd disp (string (math/floor from-x)) "500" (string (math/floor to-x)) "500"]))

# --- drag to the minimum -------------------------------------------------
(stage "# my words\ngtk-sidebar-width = 400\n")
(launch "min")
(def e0 (edge "min"))
(drag-to (- e0 2) (- e0 400))
(os/sleep 1)
(def wmin (recorded))
(stop)
(print (string "dragged to min: screen " e0 " -> config " wmin))
(check (= wmin 100) (string "a drag past the floor records the floor, got " wmin))
(launch "min-relaunch")
(def emin (edge "min-relaunch"))
(stop)
(check (and emin (>= emin 118) (<= emin 140))
       (string "relaunch opens at the minimum (screen " emin ")"))
(check (= (recorded) 100) (string "the minimum survives the relaunch, config " (recorded)))

# --- drag to the maximum -------------------------------------------------
(stage "# my words\ngtk-sidebar-width = 300\n")
(launch "max")
(def b0 (edge "max"))
(drag-to (- b0 2) (+ b0 600))
(os/sleep 1)
(def wmax (recorded))
(stop)
(print (string "dragged to max: screen " b0 " -> config " wmax))
(check (and wmax (> wmax 700)) (string "a drag past half the window records the dragged width, got " wmax))
(launch "max-relaunch")
(def emax (edge "max-relaunch"))
(stop)
(check (and emax (>= emax (- wmax 14)) (<= emax (+ wmax 4)))
       (string "relaunch opens at the dragged width (screen " emax " recorded " wmax ")"))
(check (= (recorded) wmax) (string "the brought-forward width survives the relaunch, config " (recorded)))

# --- drag past half the window ------------------------------------------
# The user's value is recorded as dragged; the screen shows what the window
# allows (the divider stops at the right edge). No cap is written back.
(stage "# my words\ngtk-sidebar-width = 300\n")
(launch "over")
(def c0 (edge "over"))
(drag-to (- c0 3) 1500)
(os/sleep 1)
(def wover (recorded))
(stop)
(print (string "dragged past the window: screen " c0 " -> config " wover))
(check (and wover (> wover 900)) (string "an over-wide drag is recorded as dragged, got " wover))
(launch "over-relaunch")
(def eover (edge "over-relaunch"))
(stop)
(check (= (recorded) wover) (string "the over-wide value survives the relaunch, config " (recorded)))
(print (string "warm: the screen showed " eover " for a recorded " wover))
(print (string "RESULT: " (if (= fails 0) "pass" (string "fail (" fails ")"))))
(os/proc-kill xvfb true)
(os/exit (if (= fails 0) 0 1))
