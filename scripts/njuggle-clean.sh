#!/bin/sh
# njuggle-clean.sh - remove everything Njuggle from the LOCAL machine,
# matching the install layout (binary, desktop entry, the
# D-Bus service file, the five hicolor sizes, config and data trees), so the
# next install is genuinely fresh. Licence: AGPLv3 (njuggle).
# Run on the DESKTOP: sh njuggle-clean.sh
set -eu

echo "== removing binary"
rm -f "$HOME/.local/bin/njuggle"

echo "== removing desktop entry"
rm -f "$HOME/.local/share/applications/org.mimosadev.njuggle.desktop"
# A `zig build install` from a dev tree writes the -debug app id too; left
# behind it re-registers the app after a clean and the launcher still finds a
# binary that is gone.
rm -f "$HOME/.local/share/applications/org.mimosadev.njuggle-debug.desktop"

echo "== removing D-Bus service files"
# The entry is DBusActivatable when the service file exists, and a launcher
# asks the bus for the name rather than exec'ing the binary. A service file
# left behind after the binary is gone turns every menu launch into the
# "not provided by any .service files" refusal.
rm -f "$HOME/.local/share/dbus-1/services/org.mimosadev.njuggle.service"
rm -f "$HOME/.local/share/dbus-1/services/org.mimosadev.njuggle-debug.service"
rm -f "$HOME/.local/share/njuggle/dbus.service.default" 2>/dev/null || :
# A dev-tree `zig build install` as root writes the system directory instead.
rm -f /usr/share/dbus-1/services/org.mimosadev.njuggle.service 2>/dev/null || :
rm -f /usr/share/dbus-1/services/org.mimosadev.njuggle-debug.service 2>/dev/null || :

echo "== removing icons (all sizes + cache)"
for s in 32x32 64x64 128x128 256x256 512x512; do
    rm -f "$HOME/.local/share/icons/hicolor/$s/apps/org.mimosadev.njuggle.png"
    rm -f "$HOME/.local/share/icons/hicolor/$s/apps/org.mimosadev.njuggle-debug.png"
done
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || :

echo "== removing config + data"
rm -rf "$HOME/.config/njuggle"
rm -rf "$HOME/.local/share/njuggle"

echo "== removing caches/state if any"
rm -rf "$HOME/.cache/njuggle" 2>/dev/null || :
rm -rf "$HOME/.local/state/njuggle" 2>/dev/null || :

echo "== refresh desktop database"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || :

echo "== verify (no output above each = clean)"
which njuggle || true
ls "$HOME/.local/bin/njuggle" 2>/dev/null || true
ls "$HOME/.config/njuggle" 2>/dev/null || true
ls "$HOME/.local/share/njuggle" 2>/dev/null || true
ls "$HOME/.local/share/applications" 2>/dev/null | /usr/bin/grep -i njuggle || true
ls "$HOME/.local/share/dbus-1/services" 2>/dev/null | /usr/bin/grep -i njuggle || true
dbus-send --session --print-reply --dest=org.freedesktop.DBus \
    /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
    string:org.mimosadev.njuggle 2>/dev/null || true
/usr/bin/find "$HOME/.local/share/icons" -iname "*njuggle*" 2>/dev/null || true

echo "CLEAN. Log out/in to clear the panel's app-grid cache."
echo "Reinstall with: scp the bundle, then the install block"
echo "(or the njuggle-install.sh script)."
