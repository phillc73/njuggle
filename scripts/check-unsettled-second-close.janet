#!/usr/bin/env janet
# Closing a non-last window while its own startup is in flight:
#   ~/.local/bin/strict scripts/check-unsettled-second-close.janet <repo-root> [runs]
#
# WHY THIS EXISTS. The settle wait was keyed on the window count
# (`windowCount() <= 1`), so a second window closed while its surface was
# still starting up skipped the wait and destroyed the unsettled surface
# inline: libadwaita's toast overlay unref runs gtk_widget_unparent against a
# surface with no drawn frame, exit 139. The settle rule belongs to the
# surface's state, not the window's index in the count.
#
# WHAT THIS PROVES. One instance, the default quit key, two windows; the
# second is closed 0.3s after its new-window action (before its shell can
# spawn). The process must stay alive with window 1 intact, exit 0 once
# window 1 closes, and log no SIGSEGV. `runs` trials (default 3).
#
# The launch carries NO `-e`: `-e` forces `gtk-single-instance = false` and
# `quit-after-last-window-closed = true` (Config.zig:5136), which would make
# every trial a different configuration from the one this cell pins.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def runs (if (> (length args) 2) (scan-number (get args 2)) 3))
(def bin (string root "/zig-out/bin/njuggle"))
(def base "/tmp/njuggle-unsettled-second-close")
(def fails @[])

(defn check [ok? msg]
  (if ok?
    (print "ok   " msg)
    (do (print "FAIL " msg) (array/push fails msg))))

(defn run-sh [cmd]
  (def f (string base ".out"))
  (os/execute ["/bin/sh" "-c" (string "PATH=/usr/bin:/bin:$PATH " cmd " > " f " 2>&1")] :p)
  (def out (if (nil? (os/stat f :mode)) "" (string (slurp f))))
  (os/execute ["/bin/rm" "-f" f])
  out)

# One trial inside a session bus and a throwaway display: the shell lines are
# real line boundaries (no in-string newline, which the shell would split).
(defn in-session [lines]
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

(defn wait-map [n]
  (string "i=0; while [ $i -lt 300 ]; do "
          "xwininfo -root -tree > " base "/XW 2>/dev/null; "
          "W=$(grep -E '  [0-9]+x[0-9]+\\+' " base "/XW | grep -vc ' 1x1+'); "
          "[ \"$W\" -ge " (string n) " ] && break; sleep 0.1; i=$((i+1)); done; "
          "echo -n 'WINDOWS='; echo $W"))

(defn census [tag]
  (string "xwininfo -root -tree > " base "/XW2 2>/dev/null; "
          "echo -n '" tag "='; "
          "grep -E '  [0-9]+x[0-9]+\\+' " base "/XW2 | grep -vc ' 1x1+'"))

# Wait for the second window's action object to appear, then close at once:
# the object exists from window construction, before the map and the spawn,
# so the close lands inside the startup window by construction.
(defn wait-window-object [n]
  (string "i=0; while [ $i -lt 1000 ]; do "
          "gdbus introspect --session --dest org.mimosadev.njuggle "
          "--object-path /org/mimosadev/njuggle/window/" (string n) " "
          ">/dev/null 2>&1 && break; sleep 0.02; i=$((i+1)); done"))

(defn trial []
  (os/execute ["/bin/rm" "-rf" base])
  (os/execute ["/bin/mkdir" "-p" (string base "/cfg/njuggle")])
  (os/execute ["/bin/mkdir" "-p" (string base "/data")])
  (spit (string base "/cfg/njuggle/config")
        (string "gtk-sidebar-tabs = left\n"
                "quit-after-last-window-closed = true\n"
                "confirm-close-surface = false\n"
                "shell-integration = none\n"))
  (in-session
    @[(string "timeout 60 " bin " --gtk-single-instance=true >" base "/log 2>&1 & APP=$!")
      (wait-map 1)
      (string "(" (app-action "new-window") ") >/dev/null 2>&1 & N=$!")
      "wait $N"
      (wait-window-object 2)
      (census "WINDOWS_AT_CLOSE")
      (string "echo -n 'SPAWN_COUNT_AT_CLOSE='; grep -c 'started subcommand' " base "/log || true")
      (string "(" (window-action 2 "close") ") >" base "/close.out 2>&1 & C=$!")
      "wait $C"
      "sleep 6"
      "echo -n 'ALIVE_AFTER_W2CLOSE='; if [ -d /proc/$APP ] && ! ps -o stat= -p $APP | grep -q '^Z'; then echo yes; else echo no; fi"
      (string "(" (window-action 1 "close") ") >/dev/null 2>&1 & C2=$!")
      "wait $C2"
      "wait $APP; RC=$?"
      "echo APP_EXIT=$RC"
      (string "echo -n 'SEGV_COUNT='; grep -c SIGSEGV " base "/log || true")
      (string "echo -n 'DEFERRED='; grep -c 'close waiting for the surface startup to settle' " base "/log || true")
      (string "echo -n 'CLOSE_CALL='; cat " base "/close.out")
      "echo END-MARKER unsettled-second-close"]))

(var bad 0)
(for i 0 runs
  (def out (trial))
  (def marker (not (nil? (string/find "END-MARKER unsettled-second-close" out))))
  (def exit (field out "APP_EXIT"))
  (def segv (field out "SEGV_COUNT"))
  (def alive (field out "ALIVE_AFTER_W2CLOSE"))
  (def windows (field out "WINDOWS_AT_CLOSE"))
  (def spawned (field out "SPAWN_COUNT_AT_CLOSE"))
  (def deferred (field out "DEFERRED"))
  (def close-call (field out "CLOSE_CALL"))
  (def ok (and marker (= exit "0") (= segv "0") (= alive "yes")
              (= windows "2") (= spawned "0")
              (not (nil? deferred)) (>= (scan-number (or deferred "0")) 1)))
  (unless ok (++ bad))
  (print (string "CELL run=" (+ i 1) " APP_EXIT=" (or exit "none")
                 " SEGV=" (or segv "none") " ALIVE_AFTER_W2CLOSE=" (or alive "none")
                 " WINDOWS_AT_CLOSE=" (or windows "none")
                 " SPAWN_COUNT_AT_CLOSE=" (or spawned "none")
                 " DEFERRED=" (or deferred "none")
                 " CLOSE_CALL=" (or close-call "none")
                 " marker=" (if marker "yes" "NO") " RESULT=" (if ok "pass" "fail"))))

(print "")
(check (= bad 0)
       (string "unsettled second close: every run closed before the spawn through "
               "the deferred teardown, stayed alive, and exited 0 ("
               bad " failing runs of " runs ")"))
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (os/exit 1)))
