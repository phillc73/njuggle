# Cell C1 (F-D6): two sequential drags on ONE instance both take.
#   janet cellc1.janet <bin-dir> <out> <scripts-dir>
#
# Owner UAT path: drag, drag again. The defects this guards:
#   - the press latch must hand a non-divider press back, so the user's own
#     press on the list is not swallowed;
#   - the latch must not leak past its press into the next gesture;
#   - the second drag must start from where the first one LEFT the width,
#     not from the stored launch width (the sidebar never followed alone).
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

(defn launch []
  (def script (string out "/launch.sh"))
  (def f (file/open script :w))
  (file/write f (string "#!/bin/sh\nexec env DISPLAY=" disp " GDK_BACKEND=x11 XDG_CONFIG_HOME=" cfg-dir
                        " XDG_RUNTIME_DIR=" out "/rt " bin " > " out "/run.log 2>&1\n"))
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

(defn drag [from-x to-x]
  (sh [xd disp (string (math/floor from-x)) "500" (string (math/floor to-x)) "500"])
  (os/sleep 1))

# 400 in a 1200-wide window: the first drag goes left into open space, the
# second one further left onto the floor.
(stage "# my words\ngtk-sidebar-width = 400\nwindow-width = 1200\n")
(launch)
(def e0 (edge "start"))
(drag (- e0 3) (- e0 100))
(def e1 (edge "first"))
(def w1 (recorded))
(print (string "first drag: " e0 " -> " e1 " config " w1))
(check (and e0 e1 (< e1 (- e0 60))) (string "the first drag moves the sidebar (screen " e1 ")"))
(check (and w1 (<= (math/abs (- w1 e1)) 8)) (string "the first release writes the width (" w1 ")"))

(drag (- e1 3) -400)
(def e2 (edge "second"))
(def w2 (recorded))
(print (string "second drag: " e1 " -> " e2 " config " w2))
(check (and e2 (< e2 (- e1 40))) (string "the second drag moves it again (screen " e2 ")"))
(check (= w2 100) (string "the second release records the floor (" w2 ")"))

# A press away from the divider is the list's: the width must not follow the
# pointer, so the user's own click and drag inside the list still work.
(def e3 (edge "before-list"))
(drag 60 (+ e3 200))
(def e4 (edge "after-list"))
(stop)
(print (string "list press: " e3 " -> " e4 " config " (recorded)))
(check (and e3 e4 (<= (math/abs (- e3 e4)) 4)) "a press away from the divider does not move the sidebar")
(check (= (recorded) 100) "the list press leaves the config alone")
(print (string "RESULT: " (if (= fails 0) "pass" (string "fail (" fails ")"))))
(os/proc-kill xvfb true)
(os/exit (if (= fails 0) 0 1))
