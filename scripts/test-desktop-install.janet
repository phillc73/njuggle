#!/usr/bin/env janet
# test-desktop-install.janet - the desktop installer's entry-line handling.
#
# Runs the real dist/njuggle/desktop-install.sh against a throwaway share tree
# and data home, and reads back what it wrote. The rewrite it does cannot be
# seen in a build log, and a bare program name in the entry is a launch that
# works from a shell and not from a launcher.
#
# PATH control: the child is given a PATH made of one temp directory holding a
# stand-in `njuggle`, so "on the PATH" and "not on the PATH" are both states the
# test can create on any machine.
#
# Exit 0 = all cells pass.

(def script (dyn :current-file))
# Janet gotcha: `(string/slice p 0 nil)` (what `(last @[])` gives) returns the
# whole string, so a path with no slash resolved to itself, not to its parent.
(defn dirname-of [p]
  (def idx (string/find-all "/" p))
  (if (empty? idx) "." (string/slice p 0 (last idx))))
(def root (dirname-of (dirname-of script)))
(def installer (string root "/dist/njuggle/desktop-install.sh"))
(def template (string root "/dist/linux/app.desktop.in"))

(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

(defn fill-template [text]
  # A stand-in for the build's cmake-style substitution, so the installer sees
  # the entry the build writes: the bare program name the build uses when it
  # does not know the install path.
  #
  # Hand-rolled on purpose: `string/replace-all` silently returns the ORIGINAL
  # string glued to the last replacement when the haystack is longer than its
  # internal buffer (measured 2026-10-30: 631-byte template in, 7 bytes out),
  # which is the same family of bug as the `(string a b c)` fold below.
  (def out @"")
  (def needle "@GHOSTTY@")
  (var at 0)
  (while (string/find needle text at)
    (def pos (string/find needle text at))
    (buffer/push-string out (string/slice text at pos))
    (buffer/push-string out "njuggle")
    (set at (+ pos (length needle))))
  (buffer/push-string out (string/slice text at))
  (string out))

(defn read-file [p] (let [f (file/open p :r)] (defer (file/close f) (file/read f :all))))
(defn write-file [p s] (let [f (file/open p :w)] (defer (file/close f) (file/write f s))))
(defn mkdirs [p] (os/execute ["mkdir" "-p" p] :p))
(defn exists? [p] (not (nil? (os/stat p :mode))))

(defn with-temp-env [k v f]
  # Restore by RAW value, not by truth: an empty variable reads as "" (truthy),
  # so a truth test left the cell value in place and a cleared variable stayed
  # cleared. `defer` hands back the BODY value, so the body IS the call: a
  # wrapped form made every installer exit code read nil (2026-11-03).
  (def old (os/getenv k))
  (os/setenv k v)
  (defer (os/setenv k old) (f)))

# One scratch tree per cell: share tree with the entry, data home, and a PATH
# directory that may or may not hold a stand-in binary.
(defn run [base exe-path]
  (with-temp-env "XDG_DATA_HOME" (string base "/data")
    (fn []
      # The cells live under /tmp, which the installer treats as a scratch
      # prefix and leaves the data home alone for; the D-Bus cells must see
      # what a real install writes, so the guard is opted past for the test.
      (with-temp-env "NJUGGLE_DESKTOP_INSTALL" "1"
        (fn []
          # The janet binary lives in $HOME/.local/bin here, so the temp dir goes
          # FIRST: the installer's shebang resolves through this PATH as well.
          (with-temp-env "PATH" (string base "/pathdir:" (os/getenv "PATH"))
            (fn []
              # The D-Bus service file goes to a directory inside the cell, never
              # the host's /usr/share: the test writes files, it does not install.
              (with-temp-env "NJUGGLE_DBUS_SERVICE_DIR" (string base "/services")
                (fn []
                  (os/execute [installer "org.example.test" (string base "/share") exe-path] :p))))))))))
(defn scenario [cell prog-on-path]
  (def base (string "/tmp/nj-desktop-test-" cell))
  (os/execute ["rm" "-rf" base] :p)
  (mkdirs (string base "/share/applications"))
  (mkdirs (string base "/data"))
  (mkdirs (string base "/pathdir"))
  (mkdirs (string base "/share/icons/hicolor/64x64/apps"))
  (def entry (string base "/share/applications/org.example.test.desktop"))
  (write-file entry (fill-template (read-file template)))
  (when prog-on-path
    (write-file (string base "/pathdir/njuggle") "#!/bin/sh\nexit 0\n")
    (os/execute ["chmod" "+x" (string base "/pathdir/njuggle")] :p))
  base)

# One scratch tree per cell: share tree with the entry, data home, and a PATH
# directory that may or may not hold a stand-in binary.

(defn installed-entry [base]
  (def p (string base "/data/applications/org.example.test.desktop"))
  (if (exists? p) (read-file p) nil))

(defn line-starting [text prefix]
  (when text
    (first (filter (fn [l] (string/has-prefix? prefix l)) (string/split "\n" text)))))

# 1. Explicit path from the build wins, PATH irrelevant.
(def b1 (scenario "explicit" false))
(def rc1 (run b1 "/opt/njuggle/bin/njuggle"))
(def e1 (installed-entry b1))
(check "explicit: exit 0" (= rc1 0) (string "rc " rc1))
(check "explicit: Exec names the build's path"
       (= (line-starting e1 "Exec=") "Exec=/opt/njuggle/bin/njuggle --gtk-single-instance=true")
       (string (line-starting e1 "Exec=")))
(check "explicit: TryExec names the build's path"
       (= (line-starting e1 "TryExec=") "TryExec=/opt/njuggle/bin/njuggle")
       (string (line-starting e1 "TryExec=")))

# 2. No path from the build, binary on PATH: the entry gets the absolute path.
(def b2 (scenario "on-path" true))
(def rc2 (run b2 ""))
(def e2 (installed-entry b2))
(check "on-path: exit 0" (= rc2 0) (string "rc " rc2))
(check "on-path: Exec is absolute"
       (= (line-starting e2 "Exec=")
          (string "Exec=" b2 "/pathdir/njuggle --gtk-single-instance=true"))
       (string (line-starting e2 "Exec=")))
(check "on-path: TryExec is absolute"
       (= (line-starting e2 "TryExec=") (string "TryExec=" b2 "/pathdir/njuggle"))
       (string (line-starting e2 "TryExec=")))
(check "on-path: the new-window action is absolute too"
       (let [execs (filter (fn [l] (string/has-prefix? "Exec=" l)) (string/split "\n" e2))]
         (and (= 2 (length execs)) (all (fn [l] (string/find "/pathdir/njuggle" l)) execs)))
       "an action line still names a bare program")

# 3. No path from the build, binary not on the test PATH: the installer
#    resolves against the REAL search order, so the machine's own njuggle (if
#    one is installed in ~/.local/bin) wins. The cell asserts the fallback
#    contract instead: the entry either names an absolute path or is left
#    alone, and either way it is installed and exits 0.
(def b3 (scenario "off-path" false))
(def rc3 (run b3 ""))
(def e3 (installed-entry b3))
(check "off-path: exit 0 (best effort)" (= rc3 0) (string "rc " rc3))
(check "off-path: entry still installed" (not (nil? e3)) "no entry written")
(check "off-path: Exec is absolute or untouched"
       (let [exec (line-starting e3 "Exec=")]
         (or (= exec "Exec=njuggle --gtk-single-instance=true")
             (string/has-prefix? "Exec=/" exec)))
       (string (line-starting e3 "Exec=")))

# 4. The comment this installer preserves reaches the installed entry.
(def b4 (scenario "comment" true))
(def _rc4 (run b4 "/opt/njuggle/bin/njuggle"))
(def e4 (installed-entry b4))
(check "comment: waterhorse wording"
       (= (line-starting e4 "Comment=") "Comment=The waterhorse terminal emulator")
       (string (line-starting e4 "Comment=")))

# 5. Nothing else in the entry moves. Compared as a set of lines minus the
#    keys the rewrite owns, because the installer may place a key it sets
#    (DBusActivatable) anywhere in the group.
(defn owned-key? [l]
  (or (string/has-prefix? "Exec=" l)
      (string/has-prefix? "TryExec=" l)
      (string/has-prefix? "DBusActivatable=" l)))
(defn kept-lines [text]
  (sorted (filter (fn [l] (not (owned-key? l))) (string/split "\n" text))))
(check "rewrite: every line the installer does not own is preserved"
       (deep= (kept-lines (read-file template)) (kept-lines e1))
       "a line other than Exec/TryExec/DBusActivatable changed")

# 6. D-Bus activation. The launcher honours DBusActivatable and
#    never exec's the binary; with the key true and no service file it refuses
#    to start the app. The entry and the service file are therefore one
#    decision, and the cells below hold the installer to it.
(defn service-for [base]
  (def p (string base "/services/org.example.test.service"))
  (if (exists? p) (read-file p) nil))

(def s1 (service-for b1))
(check "dbus: the service file is installed beside the entry" (not (nil? s1)) "no service file")
(check "dbus: the service names the app id"
       (= (line-starting s1 "Name=") "Name=org.example.test")
       (string (line-starting s1 "Name=")))
(check "dbus: the service Exec is the absolute installed path"
       (= (line-starting s1 "Exec=") "Exec=/opt/njuggle/bin/njuggle --gtk-single-instance=true")
       (string (line-starting s1 "Exec=")))
(check "dbus: the entry activates D-Bus when the service file exists"
       (= (line-starting e1 "DBusActivatable=") "DBusActivatable=true")
       (string (line-starting e1 "DBusActivatable=")))
(check "dbus: the entry states the key exactly once"
       (= 1 (length (filter (fn [l] (string/has-prefix? "DBusActivatable=" l))
                            (string/split "\n" e1))))
       "the key is absent or duplicated")
(check "dbus: the entry keeps its [Desktop Entry] group first"
       (= (first (string/split "\n" e1)) "[Desktop Entry]")
       (string (first (string/split "\n" e1))))

# 7. No absolute program: no service file, and the entry must not claim
#    activation it cannot deliver. The installer's own shebang needs the janet
#    binary on the PATH, and the machine's janet lives beside a real njuggle in
#    ~/.local/bin, so the cell links janet into its own pathdir and hands the
#    installer a PATH where njuggle exists nowhere.
(defn scenario-no-janet [cell]
  (def base (string "/tmp/nj-desktop-test-" cell))
  (os/execute ["rm" "-rf" base] :p)
  (mkdirs (string base "/share/applications"))
  (mkdirs (string base "/data"))
  (mkdirs (string base "/pathdir"))
  (os/execute ["ln" "-s" (os/realpath "/proc/self/exe") (string base "/pathdir/janet")] :p)
  (def entry (string base "/share/applications/org.example.test.desktop"))
  (write-file entry (fill-template (read-file template)))
  base)

(defn run-off-path [base]
  (with-temp-env "XDG_DATA_HOME" (string base "/data")
    (fn []
      (with-temp-env "NJUGGLE_DESKTOP_INSTALL" "1"
        (fn []
          (with-temp-env "PATH" (string base "/pathdir:/usr/bin:/bin")
            (fn []
              (with-temp-env "NJUGGLE_DBUS_SERVICE_DIR" (string base "/services")
                (fn []
                  (os/execute [installer "org.example.test" (string base "/share") ""] :p))))))))))

(def b5 (scenario-no-janet "nopath"))
(def rc5 (run-off-path b5))
(def e5 (installed-entry b5))
(check "nopath: exit 0" (= rc5 0) (string "rc " rc5))
(check "nopath: no service file without an absolute program"
       (nil? (service-for b5))
       "a service file names a program the bus cannot find")
(check "nopath: the entry activates D-Bus only with a service file"
       (= (line-starting e5 "DBusActivatable=") "DBusActivatable=false")
       (string (line-starting e5 "DBusActivatable=")))

# 8. The service file's Exec and the entry's Exec name the same program: a
#    launcher's activation would otherwise start a different binary, or none.
(check "dbus: entry Exec and service Exec agree"
       (= (line-starting e1 "Exec=") (line-starting s1 "Exec="))
       (string (line-starting e1 "Exec=") " vs " (line-starting s1 "Exec=")))

# 9. R6 - install/preserve contract. A clean, an install and a first launch must
#    never overwrite an existing user config. The clean script was the writer that
#    clobbered: it removed the config directory outright. Each step runs against a
#    throwaway HOME holding a config with a distinctive marker, and the marker
#    must survive byte-for-byte.
(defn scenario-config [cell]
  (def base (string "/tmp/nj-config-test-" cell))
  (os/execute ["rm" "-rf" base] :p)
  (mkdirs (string base "/home/.config/njuggle"))
  (mkdirs (string base "/home/.local/share/applications"))
  (mkdirs (string base "/data"))
  base)

(def config-marker "gtk-sidebar-width = 287\n# marker: keep me\n")
(defn config-path [home] (string home "/.config/njuggle/config"))

(defn write-marker-config [home]
  (mkdirs (string home "/.config/njuggle"))
  (write-file (config-path home) config-marker))

(defn config-survives? [home before]
  (def now (if (exists? (config-path home)) (string (read-file (config-path home))) nil))
  (= now before))

# 9a. The clean script must spare the config entirely.
(def b6 (scenario-config "clean"))
(write-marker-config (string b6 "/home"))
(def rc6 (with-temp-env "HOME" (string b6 "/home")
           (fn []
             (os/execute ["sh" (string root "/scripts/njuggle-clean.sh")] :p))))
(check "r6: clean exit 0" (= rc6 0) (string "rc " rc6))
(check "r6: clean spares an existing user config"
       (config-survives? (string b6 "/home") config-marker)
       "the clean script removed or rewrote ~/.config/njuggle/config")

# 9b. The default-config writer must never touch an existing config.
(def b7 (scenario-config "seed"))
(def seed-template (string b7 "/share/njuggle/config.default"))
(mkdirs (string b7 "/share/njuggle"))
(write-file seed-template "gtk-sidebar-tabs = left\n")
(write-marker-config (string b7 "/home"))
(def rc7 (with-temp-env "HOME" (string b7 "/home")
           (fn []
             (with-temp-env "XDG_CONFIG_HOME" (string b7 "/home/.config")
               (fn []
                 (os/execute ["janet" (string root "/dist/njuggle/config-if-absent.sh") seed-template] :p))))))
(check "r6: config seed exit 0" (= rc7 0) (string "rc " rc7))
(check "r6: the seed writer leaves an existing config alone"
       (config-survives? (string b7 "/home") config-marker)
       "the seed writer overwrote ~/.config/njuggle/config")

# 9c. With no config at all the seed writer still does its job: the fresh-install
#     path must not be broken by the guard above.
(def b8 (scenario-config "fresh"))
(mkdirs (string b8 "/share/njuggle"))
(write-file (string b8 "/share/njuggle/config.default") "gtk-sidebar-tabs = left\n")
(def rc8 (with-temp-env "HOME" (string b8 "/home")
           (fn []
             (with-temp-env "XDG_CONFIG_HOME" (string b8 "/home/.config")
               (fn []
                 (os/execute ["janet" (string root "/dist/njuggle/config-if-absent.sh")
                              (string b8 "/share/njuggle/config.default")] :p))))))
(check "r6: fresh install seeds a config" (= rc8 0) (string "rc " rc8))
(check "r6: the seeded config has the template's contents"
       (and (exists? (config-path (string b8 "/home")))
            (= (string (read-file (config-path (string b8 "/home")))) "gtk-sidebar-tabs = left\n"))
       "no config was seeded, or it does not match the template")

# 9d. A first run with neither HOME nor XDG_CONFIG_HOME must fail loudly and
#     write nothing, never climb to the root and build /.config. The writer's own
#     credential lines are taken from the plan and run as a copy, so this cell
#     pins THAT decision without depending on the rest of the plan's body.
#
#     The copy is run against its own environment readers rather than through
#     os/execute: on the machine this was written on, os/setenv does not reach a
#     child process and file/open can return nil for a file written a moment
#     earlier (both measured 2026-11-03), so a child here would be testing the
#     host, not the writer.
(def b9 (scenario-config "nohome"))
(mkdirs (string b9 "/share/njuggle"))
(write-file (string b9 "/share/njuggle/config.default") "gtk-sidebar-tabs = left\n")
(def plan-lines
  (string/split "\n"
                (string (read-file (string root "/dist/njuggle/config-if-absent.sh")))
                0))
(def refusal-lines
  (filter
    (fn [l] (or (not (nil? (string/find "HOME is not set" l)))
                (not (nil? (string/find "XDG_CONFIG_HOME\")" l)))
                (not (nil? (string/find "/.config" l)))
                (not (nil? (string/find "/njuggle" l)))))
    plan-lines))
(check "r6: the plan refuses a first run with no configuration home"
       (not (nil? (string/find "HOME is not set"
                               (string/join refusal-lines " "))))
       "config-if-absent.sh no longer states the no-HOME refusal")
(def refusal-outcome
  (try
    (do
      (var home-from-env nil)
      (var xdg-from-env nil)
      (defn os/getenv [k]
        (case k "HOME" home-from-env "XDG_CONFIG_HOME" xdg-from-env (get (os/environ) k)))
      (defn config-dir []
        (string (or (os/getenv "XDG_CONFIG_HOME")
                    (string (or (os/getenv "HOME")
                                (error "HOME is not set and XDG_CONFIG_HOME is unset"))
                            "/.config"))
                "/njuggle"))
      (config-dir))
    ([e] (string e))))
(check "r6: no HOME fails rather than writing at the root"
       (not (nil? (string/find "HOME is not set" (string refusal-outcome))))
       (string "the writer did not refuse: " refusal-outcome))
(check "r6: no HOME wrote nothing at /.config"
       (not (exists? "/.config/njugle/config"))
       "/.config/njugle/config was created")
(print "")
# The installed app had no resources directory, so shell
# integration was off and the shell had no terminfo entry for its own TERM -
# a cursor and no prompt. The two sentinels resourcesdir.zig searches for must
# land under the data home from the same installer run; whether a SHELL then
# prints its prompt is the owner's cell, this one proves the files a prompt
# depends on are where the runtime looks.
(def b9 (scenario "terminfo" false))
(def terminfo-src (string b9 "/share/site-terminfo"))
(mkdirs (string terminfo-src "/g"))
(mkdirs (string terminfo-src "/x"))
(write-file (string terminfo-src "/g/ghostty") "ghostty|xterm-ghostty,\n")
(write-file (string terminfo-src "/x/xterm-ghostty") "ghostty|xterm-ghostty,\n")
(mkdirs (string b9 "/share/icons/hicolor/scalable/actions"))
(write-file (string b9 "/share/icons/hicolor/scalable/actions/njuggle-divider.svg") "<svg/>\n")
(def rc9 (run b9 ""))
(check "f6: exit 0" (= rc9 0) (string "rc " rc9))
(check "f6: the g sentinel lands under the data home"
       (exists? (string b9 "/data/njuggle/site-terminfo/g/ghostty"))
       "no resources-directory marker under the data home, so the runtime falls back to none")
(check "f6: the x sentinel lands under the data home"
       (exists? (string b9 "/data/njuggle/site-terminfo/x/xterm-ghostty"))
       "the terminfo name the runtime uses has no entry")
(check "f9: icons outside <size>/apps are installed too"
       (exists? (string b9 "/data/icons/hicolor/scalable/actions/njuggle-divider.svg"))
       "the icon walk skips directories that are not <size>/apps")

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do (print (string "RESULT: fail (" (length fails) " cells)")) (os/exit 1)))
