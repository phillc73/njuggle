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

(defn with-env [k v f]
  (def old (os/getenv k))
  (os/setenv k v)
  (defer (if old (os/setenv k old) (os/setenv k nil)) (f)))

# One scratch tree per cell: share tree with the entry, data home, and a PATH
# directory that may or may not hold a stand-in binary.
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

(defn run [base exe-path]
  (with-env "XDG_DATA_HOME" (string base "/data")
    (fn []
      # The cells live under /tmp, which the installer treats as a scratch
      # prefix and leaves the data home alone for; the D-Bus cells must see
      # what a real install writes, so the guard is opted past for the test.
      (with-env "NJUGGLE_DESKTOP_INSTALL" "1"
        (fn []
          # The janet binary lives in $HOME/.local/bin here, so the temp dir goes
          # FIRST: the installer's shebang resolves through this PATH as well.
          (with-env "PATH" (string base "/pathdir:" (os/getenv "PATH"))
            (fn []
              # The D-Bus service file goes to a directory inside the cell, never
              # the host's /usr/share: the test writes files, it does not install.
              (with-env "NJUGGLE_DBUS_SERVICE_DIR" (string base "/services")
                (fn []
                  (os/execute [installer "org.example.test" (string base "/share") exe-path] :p))))))))))

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
  (os/execute ["ln" "-s" (os/realpath (dyn :executable)) (string base "/pathdir/janet")] :p)
  (def entry (string base "/share/applications/org.example.test.desktop"))
  (write-file entry (fill-template (read-file template)))
  base)

(defn run-off-path [base]
  (with-env "XDG_DATA_HOME" (string base "/data")
    (fn []
      (with-env "NJUGGLE_DESKTOP_INSTALL" "1"
        (fn []
          (with-env "PATH" (string base "/pathdir:/usr/bin:/bin")
            (fn []
              (with-env "NJUGGLE_DBUS_SERVICE_DIR" (string base "/services")
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

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do (print (string "RESULT: fail (" (length fails) " cells)")) (os/exit 1)))
