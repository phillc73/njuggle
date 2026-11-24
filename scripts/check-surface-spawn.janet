#!/usr/bin/env janet
# The terminal-spawn cell, runnable on its own:
#   ~/.local/bin/strict scripts/check-surface-spawn.janet <njuggle-repo-root>
#
# WHY THIS EXISTS. Round 2 shipped a binary whose window opened with a sidebar
# and NEVER started a terminal: no surface, no shell. Every cell in that round
# tested layout, install and single-instance; none asserted that a terminal
# actually exists. The owner found it within minutes of installing. This cell
# is the permanent guard, and it asserts the OUTCOME (a surface initialises and
# a PTY child is spawned), not the structure that is supposed to produce it.
#
# It launches the real binary under a throwaway X display, with a clean config
# that turns the sidebar on, and reads the launch log:
#   - "surface content scale"  - the core surface initialised
#   - "started subcommand"     - the shell child was spawned (the PTY exists)
# Both are `info` level, so no debug logging is needed.
#
# Limits, stated rather than implied: this proves a surface and a shell come
# up on THIS host under Xvfb. It does not prove the terminal renders, that the
# prompt is drawn, or that the GPU path works on the owner's desktop - those
# remain the owner's cells. It DOES catch the class of regression that shipped,
# where the surface never initialised at all.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def bin (string root "/zig-out/bin/njuggle"))

(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(defn slurp-string [p]
  (if (nil? (os/stat p :mode)) nil (string (slurp p))))

(def log-path "/tmp/njuggle-surface-spawn.log")
(os/execute ["/bin/rm" "-f" log-path])

# A clean config with the sidebar on: the same shape the owner launched, and
# the shape that failed.
(def config-dir "/tmp/njuggle-surface-spawn-cfg")
(os/execute ["/bin/rm" "-rf" config-dir])
(os/execute ["/bin/mkdir" "-p" config-dir])
(spit (string config-dir "/config") "gtk-sidebar-tabs = left\n")

# The launch. `timeout` ends it after the window has had time to come up; the
# exit status is not the assertion (a GUI that stays up exits on the timeout),
# the LOG is.
(def rc (os/execute ["/bin/sh" "-c"
                     (string "timeout 12 xvfb-run -a env XDG_CONFIG_HOME="
                             config-dir " " bin " > " log-path " 2>&1")]))
(def log (or (slurp-string log-path) ""))
(def lines (if (empty? log) @[] (string/split "\n" log)))

(defn has? [needle] (not (nil? (string/find needle log))))

(check "surface: the binary exists and ran"
       (not (empty? log))
       "no launch log at all: the binary did not start")

(check "surface: a core surface initialised"
       (has? "surface content scale")
       "no 'surface content scale' line: the terminal surface never initialised - the window opened with no terminal")

(check "surface: a shell child was spawned"
       (has? "started subcommand")
       "no 'started subcommand' line: the PTY child never spawned, so there is no prompt")

(check "surface: the sidebar was on"
       (has? "sidebar dbg")
       "no sidebar line: the cell did not exercise the sidebar path")

(print "")
(if (empty? fails)
  (print (string "RESULT: pass (" (length lines) " log lines)"))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (print "--- launch log ---")
    (each l lines (print l))))
(os/exit (if (empty? fails) 0 1))
