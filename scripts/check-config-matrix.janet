#!/usr/bin/env janet
# The config load matrix (regression set):
#   ~/.local/bin/strict scripts/check-config-matrix.janet <repo-root>
#
# WHY THIS EXISTS. A config value that fails validation bricks the whole load,
# so every key a user can write into `~/.config/njuggle/config` is a launch
# risk. This cell carries the 29 cases a load must accept: the window-size
# boundary values, the comment-split cases and the shipped keys. The matrix is
# a shipped instrument, not a working note.
#
# WHAT THIS PROVES. Each case is loaded through the binary's own validator
# (`+validate-config`), which is the path a launch takes. Exit 0 for all 29
# cases; any non-zero is a value that bricks the load.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def bin (string root "/zig-out/bin/njuggle"))
(def base "/tmp/njuggle-config-matrix")
(def fails @[])

(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(defn run-rc [cmd]
  (def f (string base ".out"))
  (def rc (os/execute ["/bin/sh" "-c" (string "PATH=/usr/bin:/bin:$PATH " cmd " > " f " 2>&1")] :p))
  (def out (if (nil? (os/stat f :mode)) "" (string (slurp f))))
  (os/execute ["/bin/rm" "-f" f])
  [rc out])

# 29 load cases: a baseline, the window-size boundary values (including the
# comment forms the parser splits), and one representative line per shipped
# key family. The last case is the shipped default file itself.
(def cases
  @[["baseline" "font-size = 13\n"]
    ["window-size plain" "window-size = 900x640\n"]
    ["window-size trailing comment" "window-size = 900x640 # comment\n"]
    ["window-size glued comment" "window-size = 900x640#comment\n"]
    ["window-size zero" "window-size = 0x0\n"]
    ["window-size non-numeric" "window-size = axb\n"]
    ["window-size one number" "window-size = 900\n"]
    ["window-size overflow" "window-size = 99999999999x10\n"]
    ["window-size small" "window-size = 300x200\n"]
    ["window-size maximum" "window-size = 65535x65535\n"]
    ["window-size commented out" "# window-size = 900x640\n"]
    ["sidebar left" "gtk-sidebar-tabs = left\n"]
    ["sidebar right" "gtk-sidebar-tabs = right\n"]
    ["sidebar none" "gtk-sidebar-tabs = none\n"]
    ["sidebar tab border colour" "gtk-sidebar-active-tab-border = #ff8800\n"]
    ["pane border colour" "active-pane-border = #112233\n"]
    ["inactive pane dim" "inactive-pane-dim = true\n"]
    ["quit after last window true" "quit-after-last-window-closed = true\n"]
    ["quit after last window false" "quit-after-last-window-closed = false\n"]
    ["sidebar width" "gtk-sidebar-width = 150\n"]
    ["window decoration none" "window-decoration = none\n"]
    ["font family" "font-size = 13\nfont-family = monospace\n"]
    ["background" "background = #000000\n"]
    ["foreground" "foreground = #ffffff\n"]
    ["cursor style" "cursor-style = block\n"]
    ["scrollback limit" "scrollback-limit = 10000\n"]
    ["mouse hide while typing" "mouse-hide-while-typing = true\n"]
    ["shell integration none" "shell-integration = none\n"]
    ["shipped default file" nil]])

(os/execute ["/bin/rm" "-rf" base])
(os/execute ["/bin/mkdir" "-p" base])

(defn validate [name text]
  (def f (string base "/" (string/replace-all " " "-" name) ".config"))
  (if text
    (spit f text)
    (os/execute ["/bin/cp" (string root "/dist/njuggle/config.default") f]))
  (run-rc (string bin " +validate-config --config-file=" f)))

(var n 0)
(each [name text] cases
  (++ n)
  (def [rc out] (validate name text))
  (check (string "config matrix " n "/" (length cases) ": " name)
         (= rc 0)
         (string "exit " rc ": " (string/trim out))))

(print (string "config matrix cases: " n))
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do
    (print (string "RESULT: fail (" (length fails) " cells)"))
    (os/exit 1)))
