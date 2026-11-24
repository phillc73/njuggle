#!/usr/bin/env janet
# The status long-runner timer's lifetime, headless:
#   ~/.local/bin/strict scripts/check-status-lifetime.janet <repo-root> [structural-only]
#
# WHY THIS EXISTS. `Surface.status_long_timer` is armed on every command start
# by `glib.timeoutAdd`, which holds the raw surface as user data with no
# destroy notification. Nothing cancelled it on the teardown path, so a tab
# closed while a command ran left a live source whose callback wrote the
# private struct and emitted a notify on a disposed object. The callback was
# seen firing into a live loop at 5s and 20s after the close, with no crash; the
# lifetime is unsafe by construction.
#
# WHAT THIS PROVES, AND WHAT IT CANNOT. The structural cells are the pin: the
# timer is armed by the command-start path and cancelled by the surface's own
# dispose, before the config and the children are taken down. The runtime lane
# is the empirical backstop: the application is
# started as the single instance it is in the field, its surface runs a command
# that emits OSC 133 C (which arms the timer), a second window is opened, and
# the armed window is closed over the application's own bus name. The lane
# asserts the window count DROPS (2 -> 1), not that a count reads 1 either way,
# so a close that reaches nothing fails it. The process must then be alive and
# windowless of that tab at 5s and 20s. The callback itself leaves no log line,
# so the lane cannot SEE a stray fire - that reading is the structural cell's,
# stated rather than implied.
#
# The launch carries NO `-e`: `-e` forces `gtk-single-instance = false` and
# `quit-after-last-window-closed = true` (Config.zig:5136), so the application
# would not own the bus name the close is addressed to and the lane would test
# neither the single-instance path nor the stay-alive configuration.
#
# `structural-only` runs the source cells alone; it is how the red-first
# reading is reproduced against a pre-fix tree (the cell fails there for want
# of both the cancel and the aim site).
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def structural-only (and (> (length args) 2) (= (get args 2) "structural-only")))

(def surface-zig (string root "/src/apprt/gtk/class/surface.zig"))
(def bin (string root "/zig-out/bin/njuggle"))
(def base "/tmp/njuggle-status-lifetime")
(def cfg-dir (string base "/cfg"))
(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(defn read-or-nil [p]
  (if (not (nil? (os/stat p :mode))) (string (slurp p)) nil))

# The body of a function, from its opening brace to the matching close. The
# cells below read the teardown path as a region, not as a bare string: a
# cancel that exists somewhere in the file is not a cancel on dispose.
(defn block-after [text marker]
  (def at (string/find marker text))
  (if (nil? at)
    nil
    (do
      (var depth 0)
      (var i at)
      (var done nil)
      (while (and (nil? done) (< i (length text)))
        (def c (get text i))
        (cond
          (= c 123) (++ depth)
          (= c 125) (do (-- depth) (when (= depth 0) (set done (string/slice text at (+ i 1))))))
        (++ i))
      done)))

(def zig (read-or-nil surface-zig))

(check "status lifetime: the surface source is present"
       (not (nil? zig))
       (string "no " surface-zig))

(def dispose (if zig
               (block-after zig "fn dispose(self: *Self) callconv(.c) void {")
               nil))

(check "status lifetime: the surface has a dispose path"
       (not (nil? dispose))
       "no dispose function in surface.zig")

(check "status lifetime: dispose cancels the long-run timer"
       (and dispose (not (nil? (string/find "statusLongTimerCancel();" dispose))))
       "the teardown path leaves glib.timeoutAdd's source alive with the surface as user data")

(check "status lifetime: dispose drops the command start"
       (and dispose (not (nil? (string/find "status_command_start = null" dispose))))
       "a fired callback after dispose still sees a start timestamp")

# The aim site: a cancel that is never armed proves nothing. The command-start
# handler arms it, and an OSC 133 C command start on that path fires it.
(def started (if zig
               (block-after zig "fn statusCommandStarted(self: *Self) void {")
               nil))
(check "status lifetime: the command-start path arms the timer"
       (and started (not (nil? (string/find "statusLongTimerArm();" started))))
       "the timer the dispose cancels is not the one a command start arms")

# --- the churn lane --------------------------------------------------------
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
  (def out (run-sh (string "env XDG_CONFIG_HOME=" base "/cfg"
                           " XDG_STATE_HOME=" base "/st"
                           " XDG_CACHE_HOME=" base "/ca"
                           " GSETTINGS_BACKEND=memory NO_AT_BRIDGE=1 GTK_A11Y=none"
                           " dbus-run-session -- xvfb-run -a -s '-screen 0 1600x1000x24'"
                           " /bin/sh " f)))
  (os/execute ["/bin/rm" "-f" f])
  out)

(defn after-value [text mark key]
  (var v nil)
  (each l (string/split "\n" (or text ""))
    (when (not (nil? (string/find mark l)))
      (each part (string/split " " l)
        (when (not (nil? (string/find (string key "=") part)))
          (set v (string/slice part (+ 1 (string/find "=" part))))))))
  v)

(def lane-out
  (if (and (not structural-only) (not (nil? (read-or-nil bin))))
    (do
      (os/execute ["/bin/rm" "-rf" base])
      (os/execute ["/bin/mkdir" "-p" (string cfg-dir "/njuggle")])
      (spit (string cfg-dir "/njuggle/config")
            (string "gtk-sidebar-tabs = left\n"
                    "gtk-sidebar-status-long-after = 20s\n"
                    "confirm-close-surface = false\n"
                    "quit-after-last-window-closed = false\n"
                    "command = shell:sh -c 'printf \"\\033]133;C\\a\"; sleep 300'\n"))
      (in-session
        @[(string "timeout 60 " bin " --gtk-single-instance=true >"
                  base "/log 2>&1 &")
          "APP=$!"
          "i=0; while [ $i -lt 200 ]; do "
          "W=$(xwininfo -root -tree 2>/dev/null | grep -E '  [0-9]+x[0-9]+\\+' | grep -vc ' 1x1+'); "
          "[ \"$W\" -ge 1 ] && break; sleep 0.05; i=$((i+1)); done"
          (string "echo W_UP=$W")
          (string "echo -n 'OWNER='; gdbus call --session --dest org.freedesktop.DBus "
                  "--object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner "
                  "org.mimosadev.njuggle 2>&1 | grep -v systemd1")
          # A second window so the application survives the close of the
          # window whose timer is armed. The count after the close must fall
          # from this one: that is what makes the close load-bearing. Each
          # gdbus call is ONE string: split across array elements it becomes
          # several shell lines and the call never runs (the defect this
          # script carried in an earlier revision).
          (string "gdbus call --session --dest org.mimosadev.njuggle "
                  "--object-path /org/mimosadev/njuggle "
                  "--method org.gtk.Actions.Activate new-window '[]' '{}' >/dev/null 2>&1")
          "sleep 4"
          "W=$(xwininfo -root -tree 2>/dev/null | grep -E '  [0-9]+x[0-9]+\\+' | grep -vc ' 1x1+'); "
          "echo W_AFTER_NEW=$W"
          (string "gdbus call --session --dest org.mimosadev.njuggle "
                  "--object-path /org/mimosadev/njuggle/window/1 "
                  "--method org.gtk.Actions.Activate close '[]' '{}' >/dev/null 2>&1")
          "sleep 1"
          "W=$(xwininfo -root -tree 2>/dev/null | grep -E '  [0-9]+x[0-9]+\\+' | grep -vc ' 1x1+'); "
          "echo W_CLOSED=$W"
          "echo T_FIRST_FIRE_AT=20s"
          "sleep 4"
          "kill -0 $APP 2>/dev/null && echo ALIVE5=yes || echo ALIVE5=no"
          "sleep 15"
          "kill -0 $APP 2>/dev/null && echo ALIVE20=yes || echo ALIVE20=no"
          "kill -0 $APP 2>/dev/null && kill -TERM $APP 2>/dev/null"
          "wait $APP 2>/dev/null"
          (string "echo -n 'SEGV='; grep -c SIGSEGV " base "/log || true")]))
    "skipped"))

(unless structural-only
  (def up (after-value lane-out "W_UP" "W_UP"))
  (def owner (after-value lane-out "OWNER" "OWNER"))
  (def after-new (after-value lane-out "W_AFTER_NEW" "W_AFTER_NEW"))
  (def closed (after-value lane-out "W_CLOSED" "W_CLOSED"))
  (def alive5 (after-value lane-out "ALIVE5" "ALIVE5"))
  (def alive20 (after-value lane-out "ALIVE20" "ALIVE20"))
  (def segv (after-value lane-out "SEGV" "SEGV"))
  (check "status churn: the command's window was up before it closed"
         (and up (>= (scan-number up) 1))
         (string "no window came up: " (string/format "%q" up)))
  (check "status churn: the launch owns the bus name it is closed over"
         (= owner "(true,)")
         (string "OWNER=" (string/format "%q" owner)
                 ": the close cannot reach a non-unique application"))
  (check "status churn: the second window is up before the close"
         (and after-new (>= (scan-number after-new) 2))
         (string "expected two windows after the new-window action, saw "
                 (string/format "%q" after-new)))
  (check "status churn: the close lands on the armed window"
         (and closed after-new (= (scan-number closed) (- (scan-number after-new) 1)))
         (string "windows " (string/format "%q" after-new) " -> "
                 (string/format "%q" closed)
                 ": the close reached nothing, so the lane proves nothing"))
  (check "status churn: the process is alive at the 5s mark"
         (= alive5 "yes")
         (string "the process was gone at 5s: " (string/format "%q" alive5)))
  (check "status churn: the process is alive past the 20s fire"
         (= alive20 "yes")
         (string "the process was gone at 20s: " (string/format "%q" alive20)))
  (check "status churn: no crash in the app log"
         (= (scan-number (or segv "0")) 0)
         (string "SIGSEGV in the run log: " (string/format "%q" segv)))
  (print "lane readings:"
        (string " W_UP=" up " OWNER=" owner " W_AFTER_NEW=" after-new
                " W_CLOSED=" closed " ALIVE5=" alive5
                " ALIVE20=" alive20 " SEGV=" segv)))

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (print "--- lane ---")
    (print lane-out)
    (os/exit 1)))
