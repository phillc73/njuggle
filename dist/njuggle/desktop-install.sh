#!/usr/bin/env janet
# desktop-install.sh - install the app's icon and desktop entry into a data
# prefix and refresh the caches the desktop reads.
#
# The .sh suffix and shebang follow the upstream build's convention for
# run-step helpers; the body is Janet (house rule: utility scripts are
# Janet).
#
# Why this exists: `zig build install -p DIR` writes the desktop entry and the
# icons into DIR/share, where no desktop looks. A user who runs the installed
# binary then gets a fallback letter for an icon and no launcher entry. This
# step copies both into the XDG data home and refreshes the icon cache and the
# desktop database, so one install command leaves a working launcher.
#
# Contract:
#   argv[1] = the app id (e.g. org.mimosadev.njuggle)
#   argv[2] = the install prefix's share directory (passed by the build)
#   argv[3] = the absolute path the binary is installed at, if known; empty
#             leaves the entry naming the binary alone (PATH lookup)
#   env XDG_DATA_HOME (optional, defaults to $HOME/.local/share)
#   env NJUGGLE_DBUS_SERVICE_DIR (optional): where the D-Bus service file is
#             written. Defaults to the system-wide directory the bus reads
#             (/usr/share/dbus-1/services) when it is writable, otherwise the
#             data home's services directory ($XDG_DATA_HOME/dbus-1/services),
#             which the same bus session merges. Only a run as root can reach
#             the system directory; a user install lands in the data home.
#
# The icon cache is rebuilt from the copied tree, never copied: its entries
# are relative to the tree it was built in. A failed cache refresh is
# reported, not fatal - the files are still correct.
#
# Set NJUGGLE_NO_DESKTOP_INSTALL=1 to install into DIR only (packagers, CI).

(def args (slice (dyn *args*) 1))

(unless (= (length args) 3)
  (eprint "usage: desktop-install.sh <app-id> <prefix>/share <exe-path|''>")
  (os/exit 2))

(def app-id (get args 0))
(def share (get args 1))
(def exe-path (get args 2))

(when (os/getenv "NJUGGLE_NO_DESKTOP_INSTALL")
  (print "njuggle: NJUGGLE_NO_DESKTOP_INSTALL set, leaving the data home alone")
  (os/exit 0))

(defn mode-of [path]
  (try (os/stat path :mode) ([_] nil)))

(defn exists? [path]
  (not (nil? (mode-of path))))

(defn parent-of [path]
  (string/slice path 0 (last (string/find-all "/" path))))

# os/mkdir is not recursive: walk up to the first existing ancestor, then
# rebuild the chain down.
(defn mkdir-chain [path]
  (var missing @[])
  (var p path)
  (while (not (exists? p))
    (array/push missing p)
    (set p (parent-of p)))
  (loop [d :in (reverse missing)] (os/mkdir d)))

(defn copy [from to]
  (mkdir-chain (parent-of to))
  (spit to (slurp from)))

(def data-home
  (or (os/getenv "XDG_DATA_HOME")
      (string (or (os/getenv "HOME") "") "/.local/share")))

# A build into a scratch prefix must not register itself with the desktop.
# `zig build install -p DIR` used to write the user's data home anyway (the
# run step always read zig-out/share), so a test or containerised install
# silently replaced the session's launcher entry and icons. Only the obvious
# scratch locations count: the temp dir. The plain `zig build` tree
# (`./zig-out`) is NOT scratch - that is how the owner installs for real.
(defn scratch-prefix? [share]
  (or (string/has-prefix? "/tmp/" share)
      (string/has-prefix? "/var/tmp/" share)))

(when (scratch-prefix? share)
  (when (nil? (os/getenv "NJUGGLE_DESKTOP_INSTALL"))
    (print (string "njuggle: installing into a scratch prefix (" share "); "
                   "leaving the desktop data home alone. Set "
                   "NJUGGLE_DESKTOP_INSTALL=1 to register it anyway."))
    (os/exit 0)))

# A build that installed no share tree (lib-only builds) has nothing to
# install; say so rather than failing the build.
(unless (= (mode-of share) :directory)
  (eprint "njuggle: no installed share tree at " share ", nothing to install")
  (os/exit 0))

# Icons: every size the build wrote, under the app id.
(def icons-src (string share "/icons/hicolor"))
(def icons-dst (string data-home "/icons/hicolor"))
(var copied 0)
(when (= (mode-of icons-src) :directory)
  (each size (os/dir icons-src)
    (def apps (string icons-src "/" size "/apps"))
    (when (= (mode-of apps) :directory)
      (each file (os/dir apps)
        (when (string/has-suffix? ".png" file)
          (copy (string apps "/" file) (string icons-dst "/" size "/apps/" file))
          (++ copied))))))

(print (string "njuggle: installed " copied " icon files into " icons-dst))

# Desktop entry. The build writes it under the (possibly -debug suffixed) app
# id; install whichever one exists. The Exec line names the binary by PATH
# unless the build knows the absolute path it goes to, because a data-home
# entry that names a path only true of the build tree launches nothing.
#
# When the build does not know the path (a plain `zig build install`, which
# also installs the binary in <prefix>/bin), the program named by the entry's
# first Exec line is resolved here instead: if the installed binary is on the
# searching shell's PATH, the entry gets its absolute path. A launcher runs
# with a different PATH from a shell - a desktop opened from a file manager
# carries none of the shell's additions - so a bare name is a launch that works
# in one place and not another. Resolution happens once, here, where a shell's
# PATH is the one the user built the binary with.
(def desktop-src (string share "/applications/" app-id ".desktop"))
(defn entry-program
  "The absolute path `prog` resolves to on this process's PATH, or nil.
  A PATH entry is on disk or it is not; the search is the same one a shell
  does, left to right, and it stops at the first regular file.
  A `var` accumulator, not `filter` or `return`: `(filter f coll)` keeps the
  ELEMENTS the callable passes (so `first` answered with a DIRECTORY) and
  `(return)` inside `each` signals the fiber."
  [prog]
  (if (and prog (not (empty? prog)))
    (do
      (var found nil)
      (each dir (string/split ":" (or (os/getenv "PATH") ""))
        (def full (string dir "/" prog))
        (when (and (nil? found) (exists? full))
          (set found full)))
      found)
    nil))

(defn rewrite-menu-entry
  "One desktop-entry line with its Exec/TryExec program replaced by `owner`.
  Built in steps rather than as one `(string a b c)` call: the single call
  folds at compile time when its arguments are constant and has been seen
  duplicating the tail, so each piece is concatenated at run time."
  [line owner]
  (def sep (string/find "=" line))
  (def key (string/slice line 0 (+ 1 sep)))
  (def rest (string/slice line (+ 1 sep)))
  (def words (string/split " " rest))
  (def args (string/join (slice words 1) " "))
  (def owner-prog (string owner))
  (def head (string key owner-prog))
  (if (empty? args) head (string head " " args)))

(defn entry-program-name [lines]
  (var found nil)
  (each line lines (when (and (nil? found) (string/has-prefix? "Exec=" line)) (set found line)))
  found)

(defn exec-program
  "The program `Exec=`/`TryExec=` line `line` names, or nil. The part after
  the first `=` is the program and its arguments, separated by spaces."
  [line]
  (def eq (string/find "=" line))
  (when eq
    (get (string/split " " (string/slice line (+ 1 eq))) 0)))

(def desktop-owner
  (if (not (empty? exe-path))
    exe-path
    (if (exists? desktop-src)
      (entry-program (exec-program (entry-program-name (string/split "\n" (slurp desktop-src)))))
      nil)))

(def desktop-dst (string data-home "/applications/" app-id ".desktop"))
(when (exists? desktop-src)
  (if (nil? desktop-owner)
    (do
      (copy desktop-src desktop-dst)
      (eprint (string "njuggle: the desktop entry names the binary alone; "
                      "the launcher resolves it against the panel's PATH. "
                      "Put the binary on your PATH, or install with "
                      "-Dinstalled-exe-path=/absolute/path/to/njuggle.")))
    (do
      (def lines (string/split "\n" (slurp desktop-src)))
      (def rewritten
        (seq [line :in lines]
          (if (or (string/has-prefix? "Exec=" line)
                  (string/has-prefix? "TryExec=" line))
            (rewrite-menu-entry line desktop-owner)
            line)))
      (mkdir-chain (string data-home "/applications"))
      (spit desktop-dst (string/join rewritten "\n"))))
  (print (string "njuggle: installed desktop entry " desktop-dst)))

# D-Bus activation. The shipped entry asks the bus to start Njuggle by name
# (`DBusActivatable=true`), and a launcher that honours it never exec's the
# binary: it asks the session bus for org.mimosadev.njuggle, the bus looks for a
# `<name>.service` file to spawn the app from, and with none shipped the
# launcher refuses with "The name ... was not provided by any .service files".
# The app is then installed and unlaunchable from the menu.
#
# So the entry claims D-Bus activation only when a service file naming the same
# absolute program exists. The two are decided together, here, because this is
# the only place that decides the entry's program: a service file naming a
# different binary would activate something else.
(defn set-dbus-activatable
  "The entry `text` with its DBusActivatable key set to `value`. The key is
  always written, so the entry states its value instead of relying on a
  default another entry may have moved."
  [text value]
  (def lines (string/split "\n" text))
  (def wanted (string "DBusActivatable=" value))
  (var replaced false)
  (var in-body false)
  (def mapped
    (seq [line :in lines]
      (cond
        (string/has-prefix? "DBusActivatable=" line)
        (do (set replaced true) wanted)

        (string/has-prefix? "[" line)
        # The first header opens the group the key belongs to; a later header
        # starts a new one, which would drop the key, so it is written first.
        (if in-body
          (if replaced line (do (set replaced true) (string wanted "\n" line)))
          (do (set in-body true) line))

        line)))
  (string/join (if replaced mapped [;mapped wanted]) "\n"))

(defn dir-writable? [dir]
  (and (= (mode-of dir) :directory)
       (try (do
              (def probe (string dir "/.njuggle-write-probe"))
              (spit probe "")
              (os/rm probe)
              true)
            ([_] false))))

# The system directory is the one every bus session reads; a user install can
# only be root there. The data home's services directory is the documented
# per-user equivalent and is merged by the same session bus.
(def service-dir
  (or (os/getenv "NJUGGLE_DBUS_SERVICE_DIR")
      (if (dir-writable? "/usr/share/dbus-1/services")
        "/usr/share/dbus-1/services"
        (string data-home "/dbus-1/services"))))

(defn write-service-file
  "Write the D-Bus service file for the app id into `service-dir`, naming
  `owner` with the single-instance flags the entry uses. Returns its path, or
  nil when the file could not be written."
  [owner]
  (try
    (do
      (mkdir-chain service-dir)
      (def path (string service-dir "/" app-id ".service"))
      (spit path (string "[D-BUS Service]\nName=" app-id "\nExec=" owner
                         " --gtk-single-instance=true\n"))
      path)
    ([err]
      (eprint (string "njuggle: could not write the D-Bus service file: " err))
      nil)))

(defn entry-set-dbus [value]
  (when (exists? desktop-dst)
    (spit desktop-dst (set-dbus-activatable (slurp desktop-dst) value))))

(def service-path
  (if (nil? desktop-owner)
    # Without an absolute program the bus would spawn a PATH lookup from its
    # own environment, which is the failure this fix removes.
    (do
      (eprint (string "njuggle: no absolute path to the binary, so no D-Bus "
                      "service file is installed and the entry is marked "
                      "DBusActivatable=false"))
      (entry-set-dbus "false")
      nil)
    (write-service-file desktop-owner)))

(if service-path
  (do
    (print (string "njuggle: installed D-Bus service file " service-path))
    (entry-set-dbus "true"))
  (entry-set-dbus "false"))

# Cache refresh. Both tools are best-effort: a desktop that does not ship one
# still finds the files, it just scans instead of looking up.
(def gtk-update-icon-cache
  (or (os/getenv "GTK_UPDATE_ICON_CACHE") "gtk-update-icon-cache"))
(when (= (mode-of icons-dst) :directory)
  (def rc (os/execute [gtk-update-icon-cache "-f" "-t" icons-dst] :p))
  (unless (= rc 0)
    (eprint (string "njuggle: " gtk-update-icon-cache
                    " failed (exit " rc "); icons are installed, cache left to the desktop"))))

(def update-desktop-database
  (or (os/getenv "UPDATE_DESKTOP_DATABASE") "update-desktop-database"))
(when (= (mode-of (string data-home "/applications")) :directory)
  (def rc
    (try (os/execute [update-desktop-database (string data-home "/applications")] :p)
         ([_] -1)))
  (unless (= rc 0)
    (eprint (string "njuggle: " update-desktop-database
                    " failed (exit " rc "); the entry is installed, the database is left to the desktop"))))
