#!/usr/bin/env janet
# A finished pane must not leave a hidden, closing window behind (DB3 round 3):
#   ~/.local/bin/strict scripts/check-hidden-window-state.janet <repo-root>
#
# WHY THIS EXISTS. `closeWithTeardown` sets `closing = true` before the settle
# wait, and the old fallback hid a non-last window that never settled without
# clearing that flag. A hidden window that still reports `isClosing()` is not
# a stay-alive window: the application's `hiddenWindow` lookup skips closing
# windows, so an activation cannot re-show it and the window stays out of
# reach until the process dies.
#
# WHAT THIS PROVES. Two windows under `quit-after-last-window-closed = false`,
# each running a command that finishes at once (`wait-after-command = true`,
# `command = /bin/true`). Closing window 2 must recognize the finished pane,
# destroy that window, and leave one window and no withdrawn toplevel behind.
# An activation then shows the surviving window. On the unfixed tree the close
# waits the full fallback, withdraws window 2, and the withdrawn window is not
# re-shown by an activation.
#
# The launch carries NO `-e`, as in the other settle cells.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def bin (string root "/zig-out/bin/njuggle"))
(def base "/tmp/njuggle-hidden-window")
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

(defn activate []
  (string "gdbus call --session --dest org.mimosadev.njuggle "
          "--object-path /org/mimosadev/njuggle "
          "--method org.freedesktop.Application.Activate '{}' 2>&1 | grep -v systemd1"))

(defn wait-map [n]
  (string "i=0; while [ $i -lt 300 ]; do "
          "xwininfo -root -tree > " base "/XW 2>/dev/null; "
          "W=$(grep -E '  [0-9]+x[0-9]+\\+' " base "/XW | grep -vc ' 1x1+'); "
          "[ \"$W\" -ge " (string n) " ] && break; sleep 0.1; i=$((i+1)); done"))

# The X id of the one toplevel that is not viewable, or "none".
(defn hidden-id []
  (string "HID=none; for ID in $(xwininfo -root -tree 2>/dev/null | "
          "grep -E '  [0-9]+x[0-9]+\\+' | grep -v ' 1x1+' | awk '{print $1}'); do "
          "M=$(xwininfo -id $ID 2>/dev/null | grep 'Map State' | awk '{print $3}'); "
          "if [ \"$M\" = IsUnMapped ]; then HID=$ID; fi; done; "
          "echo -n 'HIDDEN_ID='; echo $HID"))

(defn census []
  (string "xwininfo -root -tree > " base "/XW2 2>/dev/null; "
          "echo -n 'WINDOWS='; "
          "grep -E '  [0-9]+x[0-9]+\\+' " base "/XW2 | grep -vc ' 1x1+'"))

(defn trial []
  (os/execute ["/bin/rm" "-rf" base])
  (os/execute ["/bin/mkdir" "-p" (string base "/cfg/njuggle")])
  (os/execute ["/bin/mkdir" "-p" (string base "/data")])
  (spit (string base "/cfg/njuggle/config")
        (string "gtk-sidebar-tabs = left\n"
                "quit-after-last-window-closed = false\n"
                "confirm-close-surface = false\n"
                "shell-integration = none\n"
                "cursor-style-blink = false\n"
                "wait-after-command = true\n"
                "command = /bin/true\n"))
  (in-session
    @[(string "timeout 60 " bin " --gtk-single-instance=true >" base "/log 2>&1 & APP=$!")
      (wait-map 1)
      "sleep 2"
      (string "(" (app-action "new-window") ") >/dev/null 2>&1 & N=$!")
      "wait $N"
      (wait-map 2)
      "sleep 2"
      "T0=$(date +%s%N)"
      (string "(" (window-action 2 "close") ") >/dev/null 2>&1 & C=$!")
      "wait $C"
      "sleep 11"
      "T1=$(date +%s%N)"
      "echo HIDE_MS=$(( (T1-T0)/1000000 ))"
      "echo -n 'ALIVE_AFTER_CLOSE='; if [ -d /proc/$APP ] && ! ps -o stat= -p $APP | grep -q '^Z'; then echo yes; else echo no; fi"
      (string "echo -n 'HIDE_WARN='; grep -c 'window closed before its startup settled, hiding it' " base "/log || true")
      (string "echo -n 'DEFERRED='; grep -c 'close waiting for the surface startup to settle' " base "/log || true")
      (census)
      (hidden-id)
      # Activation must show the window that is left, with no withdrawn
      # closing window parked out of reach.
      (activate)
      "sleep 2"
      (census)
      "echo -n 'ALIVE_AFTER_RESHOW='; if [ -d /proc/$APP ] && ! ps -o stat= -p $APP | grep -q '^Z'; then echo yes; else echo no; fi"
      (string "(" (app-action "quit") ") >/dev/null 2>&1 & Q=$!")
      "wait $Q"
      "wait $APP; RC=$?"
      "echo APP_EXIT=$RC"
      (string "echo -n 'SEGV_COUNT='; grep -c SIGSEGV " base "/log || true")
      "echo END-MARKER hidden-window"]))

(def out (trial))
(def marker (not (nil? (string/find "END-MARKER hidden-window" out))))
(def alive-close (field out "ALIVE_AFTER_CLOSE"))
(def hide-warn (field out "HIDE_WARN"))
(def deferred (field out "DEFERRED"))
(def hidden-id-v (field out "HIDDEN_ID"))
(def alive-reshow (field out "ALIVE_AFTER_RESHOW"))
(def exit-code (field out "APP_EXIT"))
(def segv (field out "SEGV_COUNT"))
(def windows (field out "WINDOWS"))

(print (string "CELL hidden-window APP_EXIT=" (or exit-code "none")
               " SEGV=" (or segv "none") " ALIVE_AFTER_CLOSE=" (or alive-close "none")
               " HIDE_WARN=" (or hide-warn "none") " DEFERRED=" (or deferred "none")
               " HIDDEN_ID=" (or hidden-id-v "none")
               " WINDOWS_AFTER_CLOSE=" (or windows "none")
               " marker=" (if marker "yes" "NO")))

(check (and marker (= alive-close "yes"))
       "the application survives the finished-pane close")
(check (and (not (nil? deferred)) (>= (scan-number (or deferred "0")) 1))
       "the close went through the settle wait")
(check (and (not (nil? hide-warn)) (= hide-warn "0"))
       "the finished pane never took the withdraw fallback")
(check (= windows "1")
       "the closed window was destroyed, not left as a second toplevel")
(check (= hidden-id-v "none")
       "no withdrawn toplevel is parked behind the application")
(check (= alive-reshow "yes") "the application is alive after the activation")
(check (and (= exit-code "0") (= segv "0"))
       "quit after the close exits 0 with no SIGSEGV")

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (print "--- run ---")
    (print out)
    (os/exit 1)))
