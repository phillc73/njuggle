#!/usr/bin/env janet
# Closing a window whose command finished without drawing:
#   ~/.local/bin/strict scripts/check-silent-pane-close.janet <repo-root> [runs]
#
# WHY THIS EXISTS. The settle wait requires the render widget to have
# drawn two frames. A pane whose command exits without producing output never
# draws them, so the wait runs to its 10s bound. With one window that bound
# ends the process directly; with two windows the old fallback hid both and
# the application never quit under `quit-after-last-window-closed = true`.
#
# WHAT THIS PROVES.
#   single: one silent-pane window is closed; the settle recognizes the
#           finished command, the close completes well below the 10s
#           fallback, and the process exits 0 with no SIGSEGV.
#   multi:  two silent-pane windows are closed in sequence under
#           `quit-after-last-window-closed = true`; the process exits 0
#           inside the fallback bound and the bus name is released. The old
#           tree hung to the outer timeout with two hidden windows.
#
# Both shapes assert the deferred-branch log line, so a fast host that
# settles inline cannot pass the cell by accident.
#
# The launch carries NO `-e`: `-e` forces `gtk-single-instance = false` and
# `quit-after-last-window-closed = true` (Config.zig:5136), a different
# configuration from the one this cell pins.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def runs (if (> (length args) 2) (scan-number (get args 2)) 1))
(def bin (string root "/zig-out/bin/njuggle"))
(def fails @[])

(defn check [ok? msg]
  (if ok?
    (print "ok   " msg)
    (do (print "FAIL " msg) (array/push fails msg))))

(defn run-sh [cmd]
  (def f "/tmp/njuggle-silent-out.txt")
  (os/execute ["/bin/sh" "-c" (string "PATH=/usr/bin:/bin:$PATH " cmd " > " f " 2>&1")] :p)
  (def out (if (nil? (os/stat f :mode)) "" (string (slurp f))))
  (os/execute ["/bin/rm" "-f" f])
  out)

# One trial inside a session bus and a throwaway display. Every line is a
# real shell line; no line carries an in-string newline.
(defn in-session [base lines]
  (def f (string base ".sh"))
  (spit f (string "#!/bin/sh\n" (string/join lines "\n") "\n"))
  (os/execute ["/bin/cp" f (string base "-last.sh")])
  (def out (run-sh
             (string "env XDG_CONFIG_HOME=" base "/cfg XDG_STATE_HOME=" base "/st"
                     " XDG_CACHE_HOME=" base "/ca XDG_DATA_HOME=" base "/data"
                     " GSETTINGS_BACKEND=memory NO_AT_BRIDGE=1 GTK_A11Y=none"
                     " dbus-run-session -- xvfb-run -a -s '-screen 0 1600x1000x24'"
                     " /bin/sh " f)))
  (os/execute ["/bin/rm" "-f" f])
  out)

(defn field [text key]
  (var v nil)
  (each l (string/split "\n" (or text ""))
    (when (and (nil? v) (string/has-prefix? (string key "=") l))
      (set v (string/slice l (+ 1 (length key))))))
  v)

(defn app-action [name]
  (string "gdbus call --session --dest org.mimosadev.njuggle "
          "--object-path /org/mimosadev/njuggle "
          "--method org.gtk.Actions.Activate " name " '[]' '{}' "
          "2>&1 | grep -v systemd1"))

(defn window-action [n name]
  (string "gdbus call --session --dest org.mimosadev.njuggle "
          "--object-path /org/mimosadev/njuggle/window/" n " "
          "--method org.gtk.Actions.Activate " name " '[]' '{}' "
          "2>&1 | grep -v systemd1"))

(defn owner []
  (string "gdbus call --session --dest org.freedesktop.DBus "
          "--object-path /org/freedesktop/DBus "
          "--method org.freedesktop.DBus.NameHasOwner "
          "org.mimosadev.njuggle 2>&1 | grep -v systemd1"))

(defn wait-map [base n]
  (string "i=0; while [ $i -lt 300 ]; do "
          "xwininfo -root -tree > " base "/XW 2>/dev/null; "
          "W=$(grep -E '  [0-9]+x[0-9]+\\+' " base "/XW | grep -vc ' 1x1+'); "
          "[ \"$W\" -ge " (string n) " ] && break; sleep 0.1; i=$((i+1)); done"))

(defn deferred-count [base]
  (string "echo -n 'DEFERRED='; grep -c 'close waiting for the surface startup to settle' "
          base "/log || true"))

(defn prepare [base]
  (os/execute ["/bin/rm" "-rf" base])
  (os/execute ["/bin/mkdir" "-p" (string base "/cfg/njuggle")])
  (os/execute ["/bin/mkdir" "-p" (string base "/data")])
  (spit (string base "/cfg/njuggle/config")
        (string "gtk-sidebar-tabs = left\n"
                "quit-after-last-window-closed = true\n"
                "confirm-close-surface = false\n"
                "shell-integration = none\n"
                "wait-after-command = true\n"
                "command = /bin/true\n")))

(defn single-trial []
  (def base "/tmp/njuggle-silent-single")
  (prepare base)
  (in-session base
    @[(string "timeout 60 " bin " --gtk-single-instance=true >" base "/log 2>&1 & APP=$!")
      (wait-map base 1)
      "sleep 2"
      "T0=$(date +%s%N)"
      (string "(" (window-action 1 "close") ") >/dev/null 2>&1 & C=$!")
      "wait $C"
      "wait $APP; RC=$?"
      "T1=$(date +%s%N)"
      "echo SILENT_CLOSE_MS=$(( (T1-T0)/1000000 ))"
      "echo APP_EXIT=$RC"
      (string "echo -n 'SEGV_COUNT='; grep -c SIGSEGV " base "/log || true")
      (deferred-count base)
      "echo END-MARKER silent-single"]))

(defn multi-trial []
  (def base "/tmp/njuggle-silent-multi")
  (prepare base)
  (in-session base
    @[(string "timeout 60 " bin " --gtk-single-instance=true >" base "/log 2>&1 & APP=$!")
      (wait-map base 1)
      "sleep 2"
      (string "(" (app-action "new-window") ") >/dev/null 2>&1 & N=$!")
      "wait $N"
      (wait-map base 2)
      "sleep 2"
      "T0=$(date +%s%N)"
      (string "(" (window-action 2 "close") ") >/dev/null 2>&1 & C2=$!")
      "wait $C2"
      (string "(" (window-action 1 "close") ") >/dev/null 2>&1 & C1=$!")
      "wait $C1"
      "wait $APP; RC=$?"
      "T1=$(date +%s%N)"
      "echo MULTI_CLOSE_MS=$(( (T1-T0)/1000000 ))"
      "echo APP_EXIT=$RC"
      (string "echo -n 'SEGV_COUNT='; grep -c SIGSEGV " base "/log || true")
      (string "echo -n 'OWNER_AFTER='; " (owner))
      (string "echo -n 'HIDE_WARN='; grep -c 'window closed before its startup settled, hiding it' " base "/log || true")
      (deferred-count base)
      "echo END-MARKER silent-multi"]))

(defn number-or [v fallback]
  (if (and (not (nil? v)) (scan-number v) (> (length v) 0))
    (scan-number v)
    fallback))

(var bad 0)
(for i 0 runs
  (def out (single-trial))
  (def marker (not (nil? (string/find "END-MARKER silent-single" out))))
  (def exit (field out "APP_EXIT"))
  (def segv (field out "SEGV_COUNT"))
  (def ms (field out "SILENT_CLOSE_MS"))
  (def deferred (field out "DEFERRED"))
  (def ms-n (number-or ms 1000000000))
  (def ok (and marker (= exit "0") (= segv "0") (<= ms-n 4000)
               (not (nil? deferred)) (>= (number-or deferred -1) 1)))
  (unless ok (++ bad))
  (print (string "CELL single run=" (+ i 1) " APP_EXIT=" (or exit "none")
                 " SEGV=" (or segv "none") " CLOSE_MS=" (or ms "none")
                 " DEFERRED=" (or deferred "none")
                 " marker=" (if marker "yes" "NO") " RESULT=" (if ok "pass" "fail"))))

(for i 0 runs
  (def out (multi-trial))
  (def marker (not (nil? (string/find "END-MARKER silent-multi" out))))
  (def exit (field out "APP_EXIT"))
  (def segv (field out "SEGV_COUNT"))
  (def owner-after (field out "OWNER_AFTER"))
  (def hide-warn (field out "HIDE_WARN"))
  (def ms (field out "MULTI_CLOSE_MS"))
  (def deferred (field out "DEFERRED"))
  (def ms-n (number-or ms 1000000000))
  (def ok (and marker (= exit "0") (= segv "0") (= owner-after "(false,)")
               (= hide-warn "0")
               (<= ms-n 20000) (not (nil? deferred))
               (>= (number-or deferred -1) 1)))
  (unless ok (++ bad))
  (print (string "CELL multi run=" (+ i 1) " APP_EXIT=" (or exit "none")
                 " SEGV=" (or segv "none") " CLOSE_MS=" (or ms "none")
                 " OWNER_AFTER=" (or owner-after "none")
                 " HIDE_WARN=" (or hide-warn "none")
                 " DEFERRED=" (or deferred "none")
                 " marker=" (if marker "yes" "NO") " RESULT=" (if ok "pass" "fail"))))

(print "")
(check (= bad 0)
       (string "silent-pane close: every run exited 0 with no SIGSEGV and the "
               "close stayed inside the bound (" bad " failing runs of "
               (* 2 runs) ")"))
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (os/exit 1)))
