#!/usr/bin/env janet
# The default-configuration early close:
#   ~/.local/bin/strict scripts/check-default-early-close.janet <repo-root> [runs]
#
# WHY THIS EXISTS. `quit-after-last-window-closed = true` is the upstream
# default. Closing the last window while the pane shell's spawn is still in
# flight tears the window down under a surface that has not started its child;
# the toolkit's destroy cascade segfaults (libadwaita's toast overlay unref
# into gtk_widget_unparent), exit 139. The reconciliation measured it 5/5 at
# the immediate close, 2/2 at 2s, one clean and one SIGSEGV at 4s, and clean
# from 8s, on both the delta artifact and the installed 0.1.0 line.
#
# WHAT THIS PROVES. One instance, one window, the default quit key, and a close
# at the rung's time after the map leaves the process with exit code 0 and no
# SIGSEGV. The rungs are different inputs (a close before the shell exists, one
# racing it, one after it), not retries of one input: 0, 2, 4 and 8 seconds
# after the first mapped window, `runs` trials each (default 5).
#
# The launch carries NO `-e`: `-e` forces `gtk-single-instance = false` and
# `quit-after-last-window-closed = true` (Config.zig:5136), which would make
# every rung a different configuration from the one this cell pins.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def runs (if (> (length args) 2) (scan-number (get args 2)) 5))
(def bin (string root "/zig-out/bin/njuggle"))
(def base "/tmp/njuggle-default-early-close")
(def fails @[])

(defn check [ok? msg]
  (if ok?
    (print "ok   " msg)
    (do (print "FAIL " msg) (array/push fails msg))))

(defn read-or-nil [p]
  (if (not (nil? (os/stat p :mode))) (string (slurp p)) nil))

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

(defn close-window []
  (string "gdbus call --session --dest org.mimosadev.njuggle "
          "--object-path /org/mimosadev/njuggle/window/1 "
          "--method org.gtk.Actions.Activate close '[]' '{}' 2>&1 | grep -v systemd1"))

(defn census []
  (string
    (string "xwininfo -root -tree > " base "/XW\n")
    (string "echo -n 'WINDOWS='; grep -E '  [0-9]+x[0-9]+\\+' " base "/XW | grep -vc ' 1x1+'\n")))

# `delay` is seconds of whole or fractional sleep; awk-free: `sleep` accepts
# fractions on this host (coreutils), and whole seconds are passed as-is.
(defn trial [pause]
  (os/execute ["/bin/rm" "-rf" base])
  (os/execute ["/bin/mkdir" "-p" (string base "/cfg/njuggle")])
  (os/execute ["/bin/mkdir" "-p" (string base "/data")])
  (spit (string base "/cfg/njuggle/config")
        (string "gtk-sidebar-tabs = left\n"
                "quit-after-last-window-closed = true\n"
                "confirm-close-surface = false\n"
                "shell-integration = none\n"))
  (in-session
    @[(string "timeout 30 " bin " --gtk-single-instance=true >" base "/log 2>&1 & APP=$!")
      "i=0; while [ $i -lt 300 ]; do "
      (string "xwininfo -root -tree > " base "/XW 2>/dev/null; "
              "W=$(grep -E '  [0-9]+x[0-9]+\\+' " base "/XW | grep -vc ' 1x1+'); ")
      "[ \"$W\" -ge 1 ] && break; sleep 0.1; i=$((i+1)); done"
      (census)
      (string "sleep " pause)
      (string "echo -n 'SPAWNED_BEFORE_CLOSE='; grep -c 'started subcommand' " base "/log || true")
      (string "(sleep 15; kill $APP 2>/dev/null) & WD=$!")
      (string "(" (close-window) ") >" base "/close.out 2>&1 & C=$!")
      "wait $C"
      "wait $APP; RC=$?"
      "kill $WD 2>/dev/null"
      (string "echo -n 'CLOSE_CALL='; cat " base "/close.out")
      "echo APP_EXIT=$RC"
      (string "echo -n 'SEGV_COUNT='; grep -c SIGSEGV " base "/log || true")
      "echo END-MARKER default-early-close"]))

(def rungs @[["0" "instant"] ["2" "2s"] ["4" "4s"] ["8" "8s"]])
(var bad 0)
(each [pause name] rungs
  (for i 0 runs
    (def out (trial pause))
    (def marker (not (nil? (string/find "END-MARKER default-early-close" out))))
    (def exit (field out "APP_EXIT"))
    (def windows (field out "WINDOWS"))
    (def spawned (field out "SPAWNED_BEFORE_CLOSE"))
    (def segv (field out "SEGV_COUNT"))
    (def close-call (field out "CLOSE_CALL"))
    (def ok (and marker (= exit "0") (= segv "0")))
    (unless ok (++ bad))
    (print (string "CELL rung=" name " run=" (+ i 1) " APP_EXIT=" (or exit "none")
                   " WINDOWS=" (or windows "none") " SPAWNED_BEFORE_CLOSE=" (or spawned "none")
                   " SEGV=" (or segv "none") " CLOSE_CALL=" (or close-call "none")
                   " marker=" (if marker "yes" "NO") " RESULT=" (if ok "pass" "fail")))
    (unless (= (or windows "") "1")
      (print (string "  note: expected one mapped window before the close, saw "
                     (or windows "none"))))))

(print "")
(check (= bad 0)
       (string "default early close: every run exited 0 with no SIGSEGV ("
               bad " failing runs of " (* runs 4) ")"))
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (os/exit 1)))
