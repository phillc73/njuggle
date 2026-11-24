# Red-first check of the item 1 forward rule, runnable on its own:
#   ~/.local/bin/strict scripts/check-single-instance.janet <njuggle-repo-root>
#
# The report was a second window on a launcher click. GTK opens a window for
# every ACTIVATE, and the first-instance path activates unconditionally because
# `initial-window` asks for one ("no window on a background launch"). After
# registration we are always the primary instance, so the bare activate also
# runs on a launch the bus FORWARDED to the running app - one from the launcher
# (the entry's Exec), one from the activation - two windows.
#
# The rule this cell pins: the bare post-registration activate runs only when
# the process was launched itself, i.e. `g_application_get_dbus_object_path`
# was NULL before registration (GLib: "not NULL if and only if the application
# is registered"). A bus activation is a forwarded activation.
#
# Licence: AGPLv3 (njuggle).

(def args (dyn *args*))
(def root (if (> (length args) 1) (get args 1) "."))
(def app-zig (string root "/src/apprt/gtk/class/application.zig"))
(def text (if (not (nil? (os/stat app-zig :mode))) (string (slurp app-zig)) nil))

(def fails @[])
(defn check [cell ok? msg]
  (if ok?
    (print "ok   " cell)
    (do (print "FAIL " cell ": " msg) (array/push fails cell))))

# The decision must be consulted at the bare activate; a cell that only looked
# for a function name would pass on a fix that never runs.
(check "single-instance: the launch asks whether it is remote, after registering"
       (and text
            (not (nil? (string/find "getIsRemote" text))))
       "the launch path is not consulted, so a forwarded activation still activates")

(check "single-instance: the bare activate is guarded by the decision"
       (and text
            (not (nil? (string/find "if (self.as(gio.Application).getIsRemote() == 0 and" text))))
       "the bare post-registration activate is unconditional (two windows on a forwarded launch)")

# The dbus object path ASSERTS that the application is registered; asking for
# it before register() raised a CRITICAL on every launch, which the parity gate
# caught. The guard must not go back to it.
(check "single-instance: the guard does not probe the dbus path before registering"
       (and text
            (nil? (string/find "getDbusObjectPath" text)))
       "getDbusObjectPath before register() asserts and logs a CRITICAL on every launch")

# A desktop report: the command line opened one window and the menu
# opened two, one process. The service file spawns `njuggle --gtk-single-instance=true`;
# the bus then forwards the activation to the running primary, whose
# `activate()` handler is what ran - and it queued a window unconditionally.
# The cells below assert the route, not the window count: this box cannot count
# windows headlessly, and the owner's desktop pass is the certification.
(check "single-instance: the activate handler queues a window only when none exists"
       (and text
            (not (nil? (string/find "if (self.activeWindow() == null)" text)))
            (not (nil? (string/find "fn activate(self: *Self)" text))))
       "activate() queues a new window on every activation, so a forwarded menu launch opens a second one")

(check "single-instance: a running instance is found by the toolkit, not assumed absent"
       (and text
            (not (nil? (string/find "getActiveWindow()" text))))
       "activate() has no window lookup, so it cannot tell a forwarded activation from a launch")

# The startup path's own bare activate is what creates the FIRST window, and a
# forwarded launch must never reach it: the guard above it is the only thing
# between a launcher click and a second window.
(check "single-instance: the startup activate stays guarded by getIsRemote"
       (and text
            (not (nil? (string/find "if (self.as(gio.Application).getIsRemote() == 0 and" text))))
       "the startup activate runs for a forwarded launch too")

(print "")
(if (empty? fails)
  (do (print "RESULT: pass") (os/exit 0))
  (do (print (string "RESULT: fail (" (length fails) " cells)")) (os/exit 1)))
