#!/bin/sh
# njuggle-install.sh - install a Njuggle release bundle into the user's XDG
# directories. Licence: AGPLv3 (njuggle).
#
# Run on the desktop, from the extracted bundle root: sh njuggle-install.sh
#
# The bundle layout this script expects (the release tarball and the owner
# delivery bundle both carry it):
#
#   bin/njuggle
#   share/applications/org.mimosadev.njuggle.desktop
#   share/icons/hicolor/{32x32,64x64,128x128,256x256,512x512}/apps/org.mimosadev.njuggle.png
#   share/icons/hicolor/scalable/actions/njuggle-divider.svg
#   share/njuggle/config.default
#   share/site-terminfo/{g/ghostty,x/xterm-ghostty}
#   njuggle-clean.sh
#
# What it does, in order: snapshot the current install and the user's config,
# install the binary, icons, terminfo and desktop entry (with the absolute
# binary path), write the matching D-Bus service file, seed the default
# config only when none exists, refresh the desktop caches, then verify that
# the entry, the service file and the installed binary agree.
#
# The user's config is never overwritten: this is a reinstall, not a reset.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP=org.mimosadev.njuggle
PREFIX=${PREFIX:-$HOME/.local/bin}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
EXE=$PREFIX/njuggle
APPS=$DATA/applications
SERVICES=$DATA/dbus-1/services
ICONS=$DATA/icons/hicolor
TERMDB=$DATA/terminfo
BIN_SRC=$HERE/bin/njuggle
ENTRY_SRC=$HERE/share/applications/$APP.desktop
CONFIG_SRC=$HERE/share/njuggle/config.default

die() {
    echo "njuggle-install: $1" >&2
    exit 1
}

[ -f "$BIN_SRC" ] || die "bundle has no bin/njuggle (run from the extracted bundle root)"
[ -f "$ENTRY_SRC" ] || die "bundle has no desktop entry at share/applications"
[ -f "$CONFIG_SRC" ] || die "bundle has no share/njuggle/config.default"

echo "== snapshot of the current install"
STAMP=$(date +%Y%m%d-%H%M%S)
SNAP=$HERE/snapshot-$STAMP
mkdir -p "$SNAP"
[ -f "$APPS/$APP.desktop" ] && cp -p "$APPS/$APP.desktop" "$SNAP/entry.desktop" || :
[ -f "$SERVICES/$APP.service" ] && cp -p "$SERVICES/$APP.service" "$SNAP/service" || :
[ -x "$EXE" ] && sha256sum "$EXE" > "$SNAP/binary.sha256" || :
if [ -d "$CONFIG_HOME/njuggle" ]; then
    cp -Rp "$CONFIG_HOME/njuggle" "$SNAP/config-backup"
fi
echo "   restore point: $SNAP"

echo "== installing the binary at $EXE"
install -Dm755 "$BIN_SRC" "$EXE"
sha256sum "$EXE"

echo "== installing icons"
for size in 32x32 64x64 128x128 256x256 512x512; do
    src=$HERE/share/icons/hicolor/$size/apps/$APP.png
    [ -f "$src" ] || die "bundle is missing the $size icon"
    install -Dm644 "$src" "$ICONS/$size/apps/$APP.png"
done
marker=$HERE/share/icons/hicolor/scalable/actions/njuggle-divider.svg
if [ -f "$marker" ]; then
    install -Dm644 "$marker" "$ICONS/scalable/actions/njuggle-divider.svg"
fi

echo "== installing the terminal description"
if [ -d "$HERE/share/site-terminfo/g" ]; then
    for src in "$HERE"/share/site-terminfo/g/*; do
        tic -x -o "$TERMDB" "$src" 2>/dev/null || \
            echo "   note: tic could not compile $src; the shell falls back to its own terminfo"
    done
fi

echo "== installing the desktop entry with the absolute binary path"
tmp=$HERE/.njuggle-entry.$$
: > "$tmp"
seen_group=false
placed=false
while IFS= read -r line; do
    case "$line" in
        '['*']')
            printf '%s\n' "$line" >> "$tmp"
            if [ "$seen_group" = false ]; then
                printf 'DBusActivatable=true\n' >> "$tmp"
                placed=true
                seen_group=true
            fi
            ;;
        DBusActivatable=*)
            : ;;
        Exec=*|TryExec=*)
            key=${line%%=*}
            rest=${line#*=}
            case "$rest" in
                *" "*) printf '%s=%s %s\n' "$key" "$EXE" "${rest#* }" >> "$tmp" ;;
                *) printf '%s=%s\n' "$key" "$EXE" >> "$tmp" ;;
            esac
            ;;
        *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
done < "$ENTRY_SRC"
if [ "$placed" = false ]; then
    printf 'DBusActivatable=true\n' >> "$tmp"
fi
install -Dm644 "$tmp" "$APPS/$APP.desktop"
rm -f "$tmp"

echo "== writing the D-Bus service file"
mkdir -p "$SERVICES"
{
    printf '[D-BUS Service]\n'
    printf 'Name=%s\n' "$APP"
    printf 'Exec=%s --gtk-single-instance=true\n' "$EXE"
} > "$SERVICES/$APP.service"

echo "== seeding the default config when none exists"
if [ -f "$CONFIG_HOME/njuggle/config" ]; then
    echo "   keeping the existing config at $CONFIG_HOME/njuggle/config"
else
    install -Dm644 "$CONFIG_SRC" "$CONFIG_HOME/njuggle/config"
    echo "   installed $CONFIG_HOME/njuggle/config"
fi

echo "== refreshing the desktop caches"
gtk-update-icon-cache -f -t "$ICONS" 2>/dev/null || :
update-desktop-database "$APPS" 2>/dev/null || :

echo "== verifying"
[ -x "$EXE" ] || die "the binary is not executable at $EXE"
[ "$(sha256sum "$BIN_SRC" | cut -d' ' -f1)" = "$(sha256sum "$EXE" | cut -d' ' -f1)" ] \
    || die "the installed binary does not match the bundle"

entry_exec=no
entry_try=no
entry_dbus=no
service_exec=no
in_action=false
while IFS= read -r line; do
    case "$line" in
        '['*']') [ "$line" = '[Desktop Action new-window]' ] && in_action=true || in_action=false ;;
        "Exec=$EXE --gtk-single-instance=true") [ "$in_action" = false ] && entry_exec=yes || : ;;
        "TryExec=$EXE") entry_try=yes ;;
        DBusActivatable=true) [ "$in_action" = false ] && entry_dbus=yes || : ;;
        Exec=njuggle*|Exec=ghostty*|TryExec=njuggle|TryExec=ghostty)
            die "the desktop entry still names a bare program: $line" ;;
    esac
done < "$APPS/$APP.desktop"
[ "$entry_exec" = yes ] || die "the desktop entry Exec does not name $EXE"
[ "$entry_try" = yes ] || die "the desktop entry TryExec does not name $EXE"
[ "$entry_dbus" = yes ] || die "the desktop entry is not DBusActivatable in [Desktop Entry]"

while IFS= read -r line; do
    [ "$line" = "Exec=$EXE --gtk-single-instance=true" ] && service_exec=yes || :
done < "$SERVICES/$APP.service"
[ "$service_exec" = yes ] || die "the D-Bus service Exec does not name $EXE"

[ -f "$CONFIG_HOME/njuggle/config" ] || die "no config at $CONFIG_HOME/njuggle/config"

"$EXE" +version | head -n 1
echo "RESULT: verify pass"
echo "Log out and back in once so the panel re-reads the desktop entry."
