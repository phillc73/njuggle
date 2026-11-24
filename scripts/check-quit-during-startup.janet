#!/usr/bin/env janet
# Quitting the application while a surface is still starting up:
#   ~/.local/bin/strict scripts/check-quit-during-startup.janet <repo-root> [runs]
#
# WHY THIS EXISTS. The quit action reaches `Application.quitNow`, which
# destroys every toplevel directly. That path never enters `closeWithTeardown`,
# so the settle wait is bypassed and an unsettled surface walks the
# toolkit destroy cascade (libadwaita's toast overlay unref into
# gtk_widget_unparent), exit 139. The quit belongs on the same settle-before-
# destroy path as a close.
#
# WHAT THIS PROVES. One instance, the default quit key; the quit action fires
# the moment the first window maps, with its surface still starting up. The
# process must wait for the startup to settle, tear the window down, exit 0,
# and log no SIGSEGV. `runs` trials (default 3).
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
(def base "/tmp/njuggle-quit-during-startup")
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

(defn wait-map [n]
  (string "i=0; while [ $i -lt 300 ]; do "
          "xwininfo -root -tree > " base "/XW 2>/dev/null; "
          "W=$(grep -E '  [0-9]+x[0-9]+\\+' " base "/XW | grep -vc ' 1x1+'); "
          "[ \"$W\" -ge " (string n) " ] && break; sleep 0.1; i=$((i+1)); done; "
          "echo -n 'WINDOWS='; echo $W"))

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
    @[(string "timeout 40 " bin " --gtk-single-instance=true >" base "/log 2>&1 & APP=$!")
      (wait-map 1)
      (string "echo -n 'SPAWN_COUNT_AT_QUIT='; grep -c 'started subcommand' " base "/log || true")
      (string "(" (app-action "quit") ") >" base "/quit.out 2>&1 & Q=$!")
      "wait $Q"
      "wait $APP; RC=$?"
      "echo APP_EXIT=$RC"
      (string "echo -n 'SEGV_COUNT='; grep -c SIGSEGV " base "/log || true")
      (string "echo -n 'DEFERRED='; grep -c 'close waiting for the surface startup to settle' " base "/log || true")
      (string "echo -n 'QUIT_CALL='; cat " base "/quit.out")
      "echo END-MARKER quit-during-startup"]))

(var bad 0)
(for i 0 runs
  (def out (trial))
  (def marker (not (nil? (string/find "END-MARKER quit-during-startup" out))))
  (def exit (field out "APP_EXIT"))
  (def segv (field out "SEGV_COUNT"))
  (def spawned (field out "SPAWN_COUNT_AT_QUIT"))
  (def deferred (field out "DEFERRED"))
  (def quit-call (field out "QUIT_CALL"))
  (def ok (and marker (= exit "0") (= segv "0")
              (not (nil? deferred)) (>= (scan-number (or deferred "0")) 1)))
  (unless ok (++ bad))
  (print (string "CELL run=" (+ i 1) " APP_EXIT=" (or exit "none")
                 " SEGV=" (or segv "none")
                 " SPAWN_COUNT_AT_QUIT=" (or spawned "none")
                 " DEFERRED=" (or deferred "none")
                 " QUIT_CALL=" (or quit-call "none")
                 " marker=" (if marker "yes" "NO") " RESULT=" (if ok "pass" "fail"))))

(print "")
(check (= bad 0)
       (string "quit during startup: every run exercised the deferred teardown "
               "and exited 0 with no SIGSEGV (" bad " failing runs of " runs ")"))
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (os/exit 1)))
