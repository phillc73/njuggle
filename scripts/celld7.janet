# Cell D7 (F-D7): four presses give four distinct widths, each surviving a
# relaunch.   janet celld7.janet <bin-dir> <out> <scripts-dir>
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

(defn stage []
  (sh ["/usr/bin/rm" "-rf" out])
  (sh ["/usr/bin/mkdir" "-p" (string cfg-dir "/njuggle") (string out "/rt")])
  (def f (file/open cfg-path :w))
  (file/write f "# my words\ngtk-sidebar-width = 100\nkeybind = ctrl+shift+r=sidebar_resize\n")
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

(stage)
(launch "press")
(def widths @[])
(each i [1 2 3 4]
  (sh [xd disp "key" "Control_L" "Shift_L" "r"])
  (os/sleep 1.5)
  (def w (recorded))
  (array/push widths w)
  (print (string "press " i " records " w))
  (stop)
  (launch (string "relaunch" i))
  (def e (edge (string "relaunch" i)))
  (def re (recorded))
  (check (and e re (= re w)) (string "press " i " (" w ") survives relaunch (screen " e ", config " re ")")))
(def distinct (length (distinct widths)))
(check (= distinct 4) (string "four presses record four distinct widths: got " distinct " " (string/join (map string widths) ",")))
(print (string "RESULT: " (if (= fails 0) "pass" (string "fail (" fails ")"))))
(os/proc-kill xvfb true)
(os/exit (if (= fails 0) 0 1))
