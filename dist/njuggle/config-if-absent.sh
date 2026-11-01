#!/usr/bin/env janet
# config-if-absent.sh - install Njuggle's default config only when the user
# has none.
#
# The .sh suffix and shebang follow the upstream build's convention for
# run-step helpers; the body is Janet (house rule: utility scripts are
# Janet).
#
# Why this exists at all: `zig build install` must give a fresh install the
# shipped config (gtk-sidebar-tabs = left) without ever overwriting a config
# the user has edited. A plain install-file step cannot express "only if
# absent", so this guard runs after the template is installed.
#
# Contract:
#   argv[1] = path to the shipped template (share/njuggle/config.default,
#             passed by the build as a file arg)
#   env XDG_CONFIG_HOME (optional, defaults to $HOME/.config)
#
# Exit 0 whenever the user's config is left in a valid state, including
# "template missing" and "user already has one".

(def args (slice (dyn *args*) 1))

(unless (= (length args) 1)
  (eprint "usage: config-if-absent.sh <template>")
  (os/exit 2))

(def template (first args))

(defn config-dir []
  (string (or (os/getenv "XDG_CONFIG_HOME") (string (or (os/getenv "HOME") "") "/.config"))
          "/njuggle"))

(defn file-exists? [path]
  (not (nil? (os/stat path :mode))))

(def target (string (config-dir) "/config"))

# A missing template is a packaging error, not a user state: say so and leave.
# It must not create an empty config, which would then look like a user config
# and block the real one for ever.
(unless (file-exists? template)
  (eprint "njuggle: config template missing: " template)
  (os/exit 0))

# Already present: never touch it.
(when (file-exists? target)
  (print "njuggle: keeping existing config " target)
  (os/exit 0))

# A first run can arrive with no config home at all, and os/mkdir takes
# one argument (there is no recursive flag). Create each missing ancestor
# in turn: walk up until a component exists, then rebuild the chain down.
# The previous form assumed the parent already existed and failed on a
# fresh account.
(defn parent-of [path]
  (string/slice path 0 (last (string/find-all "/" path))))

(defn exists-dir? [path]
  (not (nil? (os/stat path :mode))))

(do
  (var missing @[])
  (var p (config-dir))
  (while (not (exists-dir? p))
    (array/push missing p)
    (set p (parent-of p)))
  (loop [d :in (reverse missing)] (os/mkdir d)))

(let [contents (slurp template)]
  (spit target contents)
  (print "njuggle: installed default config " target))
