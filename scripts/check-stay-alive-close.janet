#!/usr/bin/env janet
# The stay-alive last-window close:
#   ~/.local/bin/strict scripts/check-stay-alive-close.janet <repo-root>
#
# WHY THIS EXISTS. With `quit-after-last-window-closed = false` the
# application must outlive its last window. Destroying that window runs the
# toolkit's widget-destroy cascade, which segfaults on this GTK/libadwaita
# version (the crash is inside `adw_toast_overlay_set_child` and
# `g_object_unref`; it reproduces on the 0.1.0 line, so it is not a v0.1.1
# regression). The njuggle-side fix withdraws the last window instead of
# destroying it; an activation re-shows the same window, surfaces intact.
#
# WHAT THIS PROVES. Red-first on an unfixed tree: the close kills the
# application (SIGSEGV) and the ticks below stop. Green on the fixed tree:
# the close leaves the process alive and the bus name owned, both pane
# processes keep writing ticks while the window is hidden, and an activation
# restores a visible window whose panes are still writing.
#
# The launch carries NO `-e`: `-e` forces `gtk-single-instance = false` and
# `quit-after-last-window-closed = true` (Config.zig:5136), which is exactly
# the configuration this cell must not exercise.
#
# THE WAITS ARE EVENT-DRIVEN. The pane shell is spawned by the io
# thread and measured at ~2.1s after the map on an idle host and past 3s under
# load, so a fixed 2s sleep reads the pids before they exist on a loaded host.
# Both waits below poll for the state the next step needs (one pane pid, then
# two) with a bounded 30s ceiling, then let one tick land before the close.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def bin (string root "/zig-out/bin/njuggle"))
(def base "/tmp/njuggle-stay-alive")
(def cfg-dir (string base "/cfg/njuggle"))
(def data-dir (string base "/data"))
(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(defn read-or-nil [p]
  (if (not (nil? (os/stat p :mode))) (string (slurp p)) nil))

(defn run-sh [cmd]
  (def f (string base ".out"))
  (os/execute ["/bin/sh" "-c" (string "PATH=/usr/bin:/bin:$PATH " cmd " > " f " 2>&1")] :p)
  (def out (if (nil? (os/stat f :mode)) "" (string (slurp f))))
  (os/execute ["/bin/rm" "-f" f])
  out)

# One run inside a session bus and a throwaway display. Every line is a real
# shell line; no line carries an in-string newline.
(defn in-session [lines]
  (def f (string base ".sh"))
  (spit f (string "#!/bin/sh\n" (string/join lines "\n") "\n"))
  (os/execute ["/bin/cp" f (string base "-last.sh")])
  (def out (run-sh
             (string "env XDG_CONFIG_HOME=" base "/cfg XDG_STATE_HOME=" base "/st"
                     " XDG_CACHE_HOME=" base "/ca XDG_DATA_HOME=" data-dir
                     " GSETTINGS_BACKEND=memory NO_AT_BRIDGE=1 GTK_A11Y=none"
                     " dbus-run-session -- xvfb-run -a -s '-screen 0 1600x1000x24'"
                     " /bin/sh " f)))
  (os/execute ["/bin/rm" "-f" f])
  out)

(defn census []
  (string
    (string "xwininfo -root -tree > " base "/XW\n")
    (string "grep -E '  [0-9]+x[0-9]+\\+' " base "/XW > " base "/XWT\n")
    (string "echo -n 'WINDOWS='; grep -vc ' 1x1+' " base "/XWT\n")))

(defn activate []
  (string "gdbus call --session --dest org.mimosadev.njuggle "
          "--object-path /org/mimosadev/njuggle "
          "--method org.freedesktop.Application.Activate '{}' 2>&1 | grep -v systemd1"))

(defn window-action [name]
  (string "gdbus call --session --dest org.mimosadev.njuggle "
          "--object-path /org/mimosadev/njuggle/window/1 "
          "--method org.gtk.Actions.Activate " name " '[]' '{}' "
          "2>&1 | grep -v systemd1"))

(defn owner []
  (string "gdbus call --session --dest org.freedesktop.DBus "
          "--object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner "
          "org.mimosadev.njuggle 2>&1 | grep -v systemd1"))

(defn pid-line []
  (string "echo -n 'PIDS=" "'; sort -u " base "/pids | tr '\\n' ',' ; echo"))

(defn ticks-line []
  (string "echo -n 'TICKS=" "'; sort " base "/ticks | uniq -c |"
          " awk '{printf \"%s:%s,\", $2, $1}'; echo"))

(def session-lines
  @["mkdir -p /tmp/njuggle-stay-alive/cfg/njuggle"
    "rm -f /tmp/njuggle-stay-alive/pids /tmp/njuggle-stay-alive/ticks"
    (string "timeout 60 " bin " --gtk-single-instance=true >" base "/log 2>&1 & APP=$!")
    "alive() { [ -n \"$APP\" ] && [ -d /proc/$APP ] && ! ps -o stat= -p $APP 2>/dev/null | grep -q '^Z'; }"
    "mapstate() { ID=$(xwininfo -root -tree 2>/dev/null | grep -E '  [0-9]+x[0-9]+\\+' | grep -v ' 1x1+' | head -1 | awk '{print $1}'); [ -n \"$ID\" ] && xwininfo -id $ID 2>/dev/null | grep 'Map State' | awk '{print $3}'; }"
    "i=0; while [ $i -lt 400 ]; do "
    (string "xwininfo -root -tree > " base "/XW 2>/dev/null; "
            "W=$(grep -E '  [0-9]+x[0-9]+\\+' " base "/XW | grep -vc ' 1x1+'); ")
    "[ \"$W\" -ge 1 ] && break; sleep 0.1; i=$((i+1)); done"
    # Wait for the first pane shell, not for a clock: the spawn is the event
    # the UP block reads. 30s is the ceiling, not the expected wait.
    "i=0; while [ $i -lt 300 ]; do "
    (string "N=$(grep -c . " base "/pids 2>/dev/null); ")
    "[ -n \"$N\" ] && [ \"$N\" -ge 1 ] && break; sleep 0.1; i=$((i+1)); done"
    "sleep 0.6"
    "echo UP:"
    (census)
    (string "echo -n 'OWNER=" "'; " (owner))
    (pid-line)
    (ticks-line)
    (window-action "new-tab")
    # The second pane's spawn waits behind the first; wait for two pids, then
    # one tick, before the close reads the panes.
    "i=0; while [ $i -lt 300 ]; do "
    (string "N=$(sort -u " base "/pids 2>/dev/null | grep -c .); ")
    "[ -n \"$N\" ] && [ \"$N\" -ge 2 ] && break; sleep 0.1; i=$((i+1)); done"
    "sleep 1.1"
    "echo SECOND_TAB:"
    (census)
    (pid-line)
    (ticks-line)
    (string "(" (window-action "close") " >/dev/null 2>&1) &")
    "sleep 2"
    "if alive; then echo CLOSE_ALIVE=yes; else wait $APP; echo CLOSE_ALIVE=no; echo APP_EXIT=$?; fi"
    (string "echo -n 'OWNER_AFTER_CLOSE=" "'; " (owner))
    "echo -n 'MAP_STATE_AFTER_CLOSE='; mapstate"
    "echo AFTER_CLOSE:"
    (census)
    (pid-line)
    (ticks-line)
    "sleep 2"
    "echo TICKS_LATER:"
    (pid-line)
    (ticks-line)
    (activate)
    "sleep 3"
    "echo AFTER_RESHOW:"
    (census)
    (string "echo -n 'OWNER_AFTER_RESHOW=" "'; " (owner))
    "echo -n 'MAP_STATE_AFTER_RESHOW='; mapstate"
    (pid-line)
    (ticks-line)
    "echo -n 'ALIVE_AT_END='; if alive; then echo yes; else echo no; fi"
    "pkill -f 'njuggle --gtk-single-instance=true' || true"])

(os/execute ["/bin/rm" "-rf" base])
(os/execute ["/bin/mkdir" "-p" cfg-dir])
(os/execute ["/bin/mkdir" "-p" data-dir])
(spit (string cfg-dir "/config")
      (string "gtk-sidebar-tabs = left\n"
              "quit-after-last-window-closed = false\n"
              "confirm-close-surface = false\n"
              "shell-integration = none\n"
              "command = shell:echo $$ >> " base "/pids; while true; do echo $$ >> "
              base "/ticks; sleep 1; done\n"))

(def out (in-session session-lines))

# The value after the LAST occurrence of a marker line. A marker may repeat
# (the pid-count lines do), so each read is anchored to its own section.
(defn section [text mark]
  (var from 0)
  (var at nil)
  (while (not (nil? (string/find mark text from)))
    (set at (string/find mark text from))
    (set from (+ at 1)))
  (if (nil? at)
    nil
    (string/slice text (+ at (length mark)))))

(defn first-line [text mark]
  (var out nil)
  (var on true)
  (each l (string/split "\n" text)
    (when (and on (string/has-prefix? mark l))
      (set on false)
      (set out (string/slice l (length mark)))))
  out)

# `pid:count,pid:count,` -> table of pid -> count
(defn pairs [s]
  (def out @{})
  (each part (string/split "," (or s ""))
    (when (not (empty? part))
      (def kv (string/split ":" part))
      (when (= 2 (length kv))
        (put out (get kv 0) (scan-number (get kv 1))))))
  out)

# The first WINDOWS= line after a marker. Markers are unique section heads;
# the flag stops the capture at the next WINDOWS= line so a later section
# cannot overwrite this one.
(defn after-count [text mark]
  (var n nil)
  (var on false)
  (each l (string/split "\n" (or text ""))
    (when (not (nil? (string/find mark l))) (set on true))
    (when (and on (not (nil? (string/find "WINDOWS=" l))))
      (set on false)
      (set n (scan-number ((string/split "=" l) 1)))))
  n)

(def up-windows (after-count out "UP:"))
(def second-windows (after-count out "SECOND_TAB:"))
(def after-close-windows (after-count out "AFTER_CLOSE:"))
(def reshow-windows (after-count out "AFTER_RESHOW:"))

# The pid/tick block after a marker: the next PIDS= and TICKS= lines.
(defn block [mark]
  (def tail (or (section out mark) ""))
  [(first-line tail "PIDS=") (first-line tail "TICKS=")])

(def up-block (block "UP:"))
(def tab-block (block "SECOND_TAB:"))
(def close-block (block "AFTER_CLOSE:"))
(def later-block (block "TICKS_LATER:"))
(def reshow-block (block "AFTER_RESHOW:"))

(defn ids [s]
  (filter |(not (empty? $)) (string/split "," (or s ""))))

(def close-alive (first-line out "CLOSE_ALIVE="))
(def owner-close (first-line out "OWNER_AFTER_CLOSE="))
(def owner-reshow (first-line out "OWNER_AFTER_RESHOW="))
(def alive-end (first-line out "ALIVE_AT_END="))
(def map-close (first-line out "MAP_STATE_AFTER_CLOSE="))
(def map-reshow (first-line out "MAP_STATE_AFTER_RESHOW="))

(print (string "up windows=" up-windows " owner=" (first-line out "OWNER=")))
(print (string "second tab windows=" second-windows " pids=" (length (ids (get up-block 0)))
              " -> " (length (ids (get tab-block 0)))))
(print (string "after close alive=" close-alive " owner=" owner-close
              " windows=" after-close-windows))
(print (string "after reshow windows=" reshow-windows " alive=" alive-end
              " owner=" owner-reshow))

(check "stay-alive: the application comes up with one window and owns the bus name"
       (and (= up-windows 1) (= "(true,)" (first-line out "OWNER=")))
       (string "launch: windows=" up-windows " owner=" (first-line out "OWNER=")))

(check "stay-alive: a second tab starts a second pane process"
       (>= (length (ids (get tab-block 0))) 2)
       (string "distinct pane pids " (length (ids (get tab-block 0)))
               " after the new-tab action; two are expected"))

(check "stay-alive: closing the last window leaves the application alive"
       (= close-alive "yes")
       (string "CLOSE_ALIVE=" close-alive
               (if (nil? (string/find "APP_EXIT=" out))
                 ""
                 (string " APP_EXIT=" (first-line out "APP_EXIT=")))
               ": the last-window close tore the application down"))

(check "stay-alive: the bus name is still owned after the close"
       (= owner-close "(true,)")
       (string "OWNER_AFTER_CLOSE=" owner-close))

(check "stay-alive: the closed window is withdrawn, not destroyed"
       (= map-close "IsUnMapped")
       (string "MAP_STATE_AFTER_CLOSE=" map-close
               ": the last window was not hidden"))

(check "stay-alive: both panes keep writing while the window is hidden"
       (and (= 2 (length (ids (get close-block 0))))
            (let [later (pairs (get later-block 1))
                  at-close (pairs (get close-block 1))]
              (all true? (seq [p :in (ids (get close-block 0))]
                             (and (not (nil? (get later p)))
                                  (not (nil? (get at-close p)))
                                  (> (get later p) (get at-close p)))))))
       (string "tick counts at close " (get close-block 1)
               " then " (get later-block 1)
               ": a pane stopped while the window was hidden"))

(check "stay-alive: an activation re-shows the same window"
       (and (= reshow-windows 1) (= owner-reshow "(true,)") (= alive-end "yes")
            (= map-reshow "IsViewable"))
       (string "after Activate: windows=" reshow-windows " alive=" alive-end
               " owner=" owner-reshow " map=" map-reshow))

(check "stay-alive: both panes survived hide and re-show"
       (let [at-close (pairs (get close-block 1))
             reshow (pairs (get reshow-block 1))]
         (all true? (seq [p :in (ids (get close-block 0))]
                        (and (not (nil? (get reshow p)))
                             (> (get reshow p) (get at-close p))))))
       (string "tick counts at close " (get close-block 1)
               " then after re-show " (get reshow-block 1)))

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (print "--- run ---")
    (print out)
    (os/exit 1)))
