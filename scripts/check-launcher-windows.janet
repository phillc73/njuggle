#!/usr/bin/env janet
# R3-A: the launcher window count, tested the way GNOME drives it (rule 5).
#   ~/.local/bin/strict scripts/check-launcher-windows.janet <njuggle-repo-root>
#
# WHY THIS EXISTS. Three rounds shipped with a cell that proved the `activate()`
# guard and never exercised the sequence a desktop menu performs. The owner's
# desktop opened two windows from the menu and one from the command line.
#
# WHAT IS MEASURED, AND FROM WHERE (the mechanism pin: outside the binary).
#   TIER 1, the display: `xwininfo -root -tree` lists every mapped toplevel. A
#   window counts when its WM_CLASS is the application's (org.mimosadev.njuggle
#   and its -debug variants) and it is not the toolkit's 1x1 leader. Same probe
#   on any binary, old or new.
# TIER 2, the log: `sidebar dbg which=launch` lines. They are printed on every
# sidebar apply, whatever the window could do with the width, so they cannot
# lie by omission about constructions - but they do not distinguish one
# window from several. Two such applies per launch were measured with the
# initial show and one pixel-apply, so the count is recorded, not asserted.
#
# TIER 0, and why lane 2 is the decisive one: because `initial-window` is read
# from the config file, lane 2 first boots with `gtk-sidebar-tabs = none`, where
# the sidebar code cannot open a window. That boot installs the first-launch
# config template from the executable's own config-if-absent step, so the file
# lane 2 actually writes is the one the application reads. (An earlier revision
# wrote `cfg/njugle` while the application read `cfg/njuggle`, found no
# file, wrote its template, and launched a window whatever the lanes asked for
# - lane 2's window was the template's, not the activation's.) With
# `initial-window = false` read for real, the application
# starts with NO window, and any window that exists afterwards was opened by
# the forwarded activation alone.
#
# THE LANES:
#   lane 0 - the config template boot. Writes NO config, launches with the
#     sidebar off, and asserts the template landed at <config home>/njuggle/
#     config. It is the setup gate for lane 2: without it lane 2's shutdown
#     step has nothing to shut down, and its "no window" reading is an artifact
#     of an app that would not have opened one anyway.
#   lane 1 - the menu ladder on a running app: application up with a window,
#     then the application's Activate twice, each the click of a menu entry.
#     Every click must leave the count where it was. This is the lane v0.1.0
#     fails (it opened 2, then 3).
#   lane 2 - an idle primary, the GNOME launch shape: the application is up with
#     `initial-window = false` and owns the bus name, then one Activate arrives.
#     Requirements rule 5's contract is "the application Activate the way the
#     desktop does it"; one forwarded activation on an idle application opens
#     one window, so the assertion is EXACTLY one, and the recorded fact is that
#     upstream v0.1.0 does the same. A second window here is the double.
#
# NOT PROVABLE HERE, stated rather than implied: this host launches the app
# in-process and the activation is addressed by the bus name the app itself
# owns. A DBus-activated child of a foreign session bus cannot be reached from
# this harness (the bus cannot see a .service file in a data dir it does not
# read, and a bus-activated child inherits no DISPLAY). The owner's desktop
# sequence - reinstall, log out, click the menu entry - is the owner's cell.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def bin (string root "/zig-out/bin/njuggle"))

(def base "/tmp/njuggle-launcher-work")
(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(defn run-sh [cmd]
  (def f (string base ".out"))
  (os/execute ["/bin/sh" "-c" (string "PATH=/usr/bin:/bin:$PATH " cmd " > " f " 2>&1")] :p)
  (def out (if (nil? (os/stat f :mode)) "" (string (slurp f))))
  (os/execute ["/bin/rm" "-f" f])
  out)

(os/execute ["/bin/rm" "-rf" base])
(def cfg-dir (string base "/cfg/njuggle"))
(os/execute ["/bin/mkdir" "-p" cfg-dir])

(defn write-config [extra]
  (spit (string cfg-dir "/config")
        (string "gtk-sidebar-tabs = left\n" extra)))

# One run inside a session bus and a throwaway display. `lines` are shell
# lines, run in order by /bin/sh. No line may carry an in-string newline: every
# line boundary in a lane is a real list element (an in-string "\n" splits a
# shell command in two, silently).
(defn in-session [lines]
  (def f (string base ".sh"))
  (spit f (string "#!/bin/sh\n" (string/join lines "\n") "\n"))
  (os/execute ["/bin/cp" f (string base "-last.sh")])
  (def out (run-sh (string "dbus-run-session -- xvfb-run -a -s '-screen 0 1600x1000x24' /bin/sh " f)))
  (os/execute ["/bin/rm" "-f" f])
  out)

# The same, but the DISPLAY comes up BEFORE the bus, so the bus carries it and
# a bus-activated child inherits it. That is the only ordering in which a real
# D-Bus activation (the menu's own route) can be exercised here: the launcher
# asks the bus for the name, the bus starts the service file's Exec, and the
# activation is forwarded to the process it just started.
(defn in-session-bus-activatable [lines]
  (def data (string base "/data"))
  (def svc (string data "/dbus-1/services"))
  (os/execute ["/bin/mkdir" "-p" svc])
  (spit (string svc "/org.mimosadev.njuggle.service")
        (string "[D-BUS Service]\nName=org.mimosadev.njuggle\nExec="
                bin " --gtk-single-instance=true\n"))
  (def f (string base ".sh"))
  (spit f (string "#!/bin/sh\n" (string/join lines "\n") "\n"))
  (os/execute ["/bin/cp" f (string base "-last.sh")])
  (def out (run-sh
             (string "env XDG_CONFIG_HOME=" base "/cfg XDG_STATE_HOME=" base "/st"
                     " XDG_CACHE_HOME=" base "/ca XDG_DATA_HOME=" data
                     " GSETTINGS_BACKEND=memory NO_AT_BRIDGE=1 GTK_A11Y=none"
                     " xvfb-run -a -s '-screen 0 1600x1000x24'"
                     " dbus-run-session -- /bin/sh " f)))
  (os/execute ["/bin/rm" "-f" f])
  out)

(def common-env
  @["export XDG_CONFIG_HOME=/tmp/njuggle-launcher-work/cfg"
    "export XDG_STATE_HOME=/tmp/njuggle-launcher-work/st"
    "export XDG_CACHE_HOME=/tmp/njuggle-launcher-work/ca"
    "export GSETTINGS_BACKEND=memory"
    "export NO_AT_BRIDGE=1"
    "export GTK_A11Y=none"])

# Tier 1: the display's toplevels owned by this application. GTK's 1x1 leader
# carries the same class, so the count is of real toplevels.
(defn census []
  (string
    (string "xwininfo -root -tree > " base "/XW\n")
    (string "grep -E '  [0-9]+x[0-9]+\\+' " base "/XW > " base "/XWT\n")
    (string "echo -n 'WINDOWS='; grep -vc ' 1x1+' " base "/XWT\n")
    (string "echo -n 'SIZES='; grep -v ' 1x1+' " base "/XWT | grep -o '[0-9]*x[0-9]*+0+0' | tr '\\n' ' '; echo\n")
    (string "echo -n 'LAUNCH_LINES='; grep -c 'sidebar dbg which=launch' " base "/log\n")))

# The map state of the first application toplevel. A window count cannot tell
# a shown window from a withdrawn one: a stay-alive close hides the window and
# `xwininfo -root -tree` still lists it. The activation's effect is the
# map state, so lane 5 reads it.
(defn mapstate []
  (string "ID=$(xwininfo -root -tree 2>/dev/null | grep -E '  [0-9]+x[0-9]+\\+' "
          "| grep -v ' 1x1+' | head -1 | awk '{print $1}'); "
          "if [ -n \"$ID\" ]; then xwininfo -id $ID 2>/dev/null | grep 'Map State' "
          "| awk '{print $3}'; else echo NONE; fi"))

(defn activate []
  (string "gdbus call --session --dest org.mimosadev.njuggle "
          "--object-path /org/mimosadev/njuggle "
          "--method org.freedesktop.Application.Activate '{}' 2>&1 | grep -v systemd1"))

(def lane1-lines
  @["mkdir -p /tmp/njuggle-launcher-work/cfg/njuggle"
    (string "timeout 40 " bin " --gtk-single-instance=true >" base "/log 2>&1 &")
    "sleep 8"
    "echo UP:"
    (census)
    (activate)
    "sleep 5"
    "echo CLICK1:"
    (census)
    (activate)
    "sleep 5"
    "echo CLICK2:"
    (census)])

(def lane2-lines
  @["mkdir -p /tmp/njuggle-launcher-work/cfg/njuggle"
    (string "timeout 30 " bin " --gtk-single-instance=true >" base "/log 2>&1 &")
    "sleep 8"
    "echo IDLE_PRIMARY:"
    (census)
    "echo -n 'OWNER='; gdbus call --session --dest org.freedesktop.DBus "
    "--object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner "
    "org.mimosadev.njuggle 2>&1 | grep -v systemd1"
    (activate)
    "sleep 6"
    "echo AFTER_ONE_MENU_ACTIVATION:"
    (census)])

# lane 3 - THE COLD MENU LAUNCH, which is what the owner's desktop does. The
# service file starts the process and the bus forwards the activation to it
# while the launch's own window is still being built. `initial-window` is the
# default (true) here, unlike lane 2: the startup activation and the forwarded
# one both arrive, and the contract is still exactly one window. A cold launch
# that opens two is the owner's report.
(def lane3-lines
  @["mkdir -p /tmp/njuggle-launcher-work/cfg/njuggle"
    (string "timeout 40 " bin " --gtk-single-instance=true >" base "/log 2>&1 &")
    "i=0; while [ $i -lt 400 ]; do "
    "if gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus "
    "--method org.freedesktop.DBus.NameHasOwner org.mimosadev.njuggle 2>/dev/null | grep -q true; "
    "then echo OWNED; break; fi; sleep 0.02; i=$((i+1)); done"
    (activate)
    "sleep 10"
    "echo AFTER_COLD_LAUNCH:"
    (census)])

# lane 4 - the real thing: nothing is running, the shell asks the session bus
# for the application's name, and the bus starts the service file's Exec and
# forwards the activation. This is the menu's route, not a simulation of it.
(def lane4-lines
  @["mkdir -p /tmp/njuggle-launcher-work/cfg/njuggle"
    (activate)
    "echo ACTIVATED"
    "sleep 12"
    "echo AFTER_BUS_ACTIVATION:"
    (census)
    "pkill -f 'njuggle --gtk-single-instance=true' || true"])

# lane 5 - the close race. The window's own close action
# and one forwarded Activate leave together, which is a launcher click that
# lands as the window closes. The window's close would leave the application
# with no shown window if the activation were swallowed, so the application
# must still hold a window two seconds later and eight seconds later, and that
# window must be SHOWN - a stay-alive close withdraws the window and the
# tree census still counts it, so the count alone passes with no activation at
# all. The map-state readings are the load-bearing cells; the counts
# stay as the stay-alive smoke test.
#
# The launch carries NO `-e`: `-e` forces `gtk-single-instance = false` and
# `quit-after-last-window-closed = true` (Config.zig:5136), so the D-Bus calls
# below reached nothing and the cell proved nothing. The default shell
# is the command here; the cell is about the single-instance close path.
(defn close-window []
  (string "gdbus call --session --dest org.mimosadev.njuggle "
          "--object-path /org/mimosadev/njuggle/window/1 "
          "--method org.gtk.Actions.Activate close '[]' '{}' 2>&1 | grep -v systemd1"))

(def lane5-lines
  @["mkdir -p /tmp/njuggle-launcher-work/cfg/njuggle"
    (string "timeout 60 " bin " --gtk-single-instance=true >"
            base "/log 2>&1 &")
    "i=0; while [ $i -lt 300 ]; do "
    (string "xwininfo -root -tree > " base "/XW 2>/dev/null; "
            "W=$(grep -E '  [0-9]+x[0-9]+\\+' " base "/XW | grep -vc ' 1x1+'); ")
    "[ \"$W\" -ge 1 ] && break; sleep 0.1; i=$((i+1)); done"
    "echo UP:"
    (census)
    (string "(" (close-window) " >/dev/null 2>&1) & P1=$!")
    (string "(" (activate) " >/dev/null 2>&1) & P2=$!")
    "wait $P1; wait $P2"
    "sleep 2"
    "echo AFTER_CLOSE_ACTIVATE:"
    (census)
    (string "echo -n 'MAP2='; " (mapstate))
    "sleep 6"
    "echo AFTER_EIGHT_SECONDS:"
    (census)
    (string "echo -n 'MAP8='; " (mapstate))
    "pkill -f 'njuggle --gtk-single-instance=true' || true"])

(defn launch-and-read [lines]
  (in-session (flatten @[common-env lines])))

# Lane 1's launch with NO config file: this is the template boot. The app
# creates `njugle`-suffixed nothing; it writes <config home>/njuggle/config
# from its own embedded template, which is the file every later lane reads.
(os/execute ["/bin/rm" "-f" (string cfg-dir "/config")])
(def lane0-out (launch-and-read lane1-lines))
(def template-ok?
  (try
    (string/find "gtk-sidebar-tabs" (string (slurp (string cfg-dir "/config"))))
    ([_] false)))

(write-config "quit-after-last-window-closed = false\n")
(def lane1-out (launch-and-read lane1-lines))
(write-config "quit-after-last-window-closed = false\ninitial-window = false\n")
(def lane2-out (in-session (flatten @[common-env lane2-lines])))
(write-config "quit-after-last-window-closed = false\n")
(def lane3-out (in-session (flatten @[common-env lane3-lines])))
(write-config "quit-after-last-window-closed = false\n")
(def lane4-out (in-session-bus-activatable lane4-lines))
(write-config "quit-after-last-window-closed = false\n")
(def lane5-out (launch-and-read lane5-lines))

# The count after one marker: the first WINDOWS= line that follows it.
(defn after-count [text mark]
  (var n nil)
  (var on false)
  (each l (string/split "\n" (or text ""))
    (when (not (nil? (string/find mark l))) (set on true))
    (when (and on (not (nil? (string/find "WINDOWS=" l))))
      (set on false)
      (set n (scan-number ((string/split "=" l) 1)))))
  n)

(def l1-up (after-count lane1-out "UP:"))
(def l1-c1 (after-count lane1-out "CLICK1:"))
(def l1-c2 (after-count lane1-out "CLICK2:"))
(def l2-idle (after-count lane2-out "IDLE_PRIMARY:"))
(def l2-after (after-count lane2-out "AFTER_ONE_MENU_ACTIVATION:"))
(def l3-after (after-count lane3-out "AFTER_COLD_LAUNCH:"))
(def l4-after (after-count lane4-out "AFTER_BUS_ACTIVATION:"))
(defn after-value [text mark key]
  (var v nil)
  (each l (string/split "\n" (or text ""))
    (when (not (nil? (string/find (string mark "=") l)))
      (each part (string/split " " l)
        (when (string/has-prefix? (string key "=") part)
          (set v (string/slice part (+ 1 (string/find "=" part))))))))
  v)

(def l5-up (after-count lane5-out "UP:"))
(def l5-t2 (after-count lane5-out "AFTER_CLOSE_ACTIVATE:"))
(def l5-t8 (after-count lane5-out "AFTER_EIGHT_SECONDS:"))
(def l5-map2 (after-value lane5-out "MAP2" "MAP2"))
(def l5-map8 (after-value lane5-out "MAP8" "MAP8"))

(print (string "lane0 template boot: config file is the executable's template = " template-ok?))
(print (string "lane1 ladder: up=" l1-up " click1=" l1-c1 " click2=" l1-c2))
(print (string "lane2 idle primary: before=" l2-idle " after_one_activation=" l2-after))
(print (string "lane3 cold launch: after_one_activation=" l3-after))
(print (string "lane4 bus activation: after_one_activation=" l4-after))
(print (string "lane5 close + activate: up=" l5-up " after_2s=" l5-t2 " after_8s=" l5-t8
               " map2=" l5-map2 " map8=" l5-map8))

# Lane 2 is the reason this file runs lane 0 first. Its reading is meaningless
# on an idle window as the boot's template: the template opens a window.
(check "launcher: the config lane 2 will read is the executable's own template"
       template-ok?
       (string "no template config at " cfg-dir "/config: lane 2 would launch with "
               "the app's own template and report a window whatever the key says"))

(check "launcher: the application comes up with exactly one window"
       (and l1-up (= l1-up 1))
       (string "expected one application toplevel at launch, saw " l1-up))

(check "launcher: a menu click on a running app opens no window"
       (and l1-up (= l1-up 1) l1-c1 (= l1-c1 1))
       (string "windows " l1-up " -> " l1-c1 " after the first menu activation"))

(check "launcher: a second menu click opens no window"
       (and l1-c1 (= l1-c1 1) l1-c2 (= l1-c2 1))
       (string "windows " l1-c1 " -> " l1-c2 " after the second menu activation"))

(check "launcher: an idle primary is up with no window of its own"
       (and l2-idle (= l2-idle 0))
       (string "initial-window = false but the application already shows " l2-idle " windows"))

(check "launcher: one forwarded activation on an idle primary opens exactly one window"
       (and l2-idle (= l2-idle 0) l2-after (= l2-after 1))
       (string "an idle primary went from " l2-idle " to " l2-after
               " windows on one activation: the forwarded activation opened a second window"))

(check "launcher: a cold menu launch opens exactly one window"
       (and l3-after (= l3-after 1))
       (string "a launch whose own window and the bus's activation overlap opened "
               l3-after " windows: the startup request and the forwarded one both ran"))

(check "launcher: a D-Bus-activated launch opens exactly one window"
       (and l4-after (= l4-after 1))
       (string "the bus started the application and forwarded the activation; it opened "
               l4-after " windows"))

(check "launcher: the activation after a window close leaves the window shown"
       (and l5-up (= l5-up 1) l5-t2 (= l5-t2 1) l5-t8 (= l5-t8 1)
            (= l5-map2 "IsViewable") (= l5-map8 "IsViewable"))
       (string "a window was up (" l5-up "), then the close and an activation left "
               l5-t2 " windows mapped " l5-map2 " at two seconds and " l5-t8
               " windows mapped " l5-map8 " at eight: a stay-alive close withdraws "
               "the window and the census still counts it, so an unmapped window "
               "here means the activation never re-showed it"))

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (print "--- lane0 ---")
    (print lane0-out)
    (print "--- lane1 ---")
    (print lane1-out)
    (print "--- lane2 ---")
    (print lane2-out)
    (print "--- lane3 ---")
    (print lane3-out)
    (print "--- lane4 ---")
    (print lane4-out)
    (print "--- lane5 ---")
    (print lane5-out)
    (os/exit 1)))
