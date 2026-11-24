#!/bin/sh
# Build the pinned blueprint-compiler. Debian trixie ships 0.16.0, but this
# tree enforces 0.20.0 or newer (src/apprt/gtk/build/blueprint.zig), so the
# runner builds the version the dev host used. The install goes to
# /usr/local, whose bin precedes /usr/bin on Debian and whose
# dist-packages is on the interpreter's path. Licence: AGPLv3 (njuggle).
set -eu

if command -v blueprint-compiler >/dev/null 2>&1 &&
    [ "$(blueprint-compiler --version)" = "0.22.2" ]; then
    echo "blueprint-compiler 0.22.2 already installed"
    exit 0
fi

ROOT=${CI_PROJECT_DIR:-$(pwd)}
SRC=$ROOT/.ci-tools/blueprint-src
rm -rf "$SRC"
git clone --depth 1 --branch "$BLUEPRINT_VERSION" \
    https://gitlab.gnome.org/GNOME/blueprint-compiler.git "$SRC"
cd "$SRC"
meson setup _build \
    --prefix=/usr/local \
    -Dpython.platlibdir=lib/python3.13/dist-packages \
    -Dpython.purelibdir=lib/python3.13/dist-packages
meson compile -C _build
meson install -C _build
cd "$ROOT"

[ "$(blueprint-compiler --version)" = "0.22.2" ] || {
    echo "FAIL: blueprint-compiler did not install as 0.22.2" >&2
    exit 1
}
echo "blueprint-compiler 0.22.2 installed"
