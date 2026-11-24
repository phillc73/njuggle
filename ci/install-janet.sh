#!/bin/sh
# Install the pinned Janet into .ci-tools/janet, verified against the
# published sha256. Licence: AGPLv3 (njuggle).
set -eu

ROOT=${CI_PROJECT_DIR:-$(pwd)}
DEST=$ROOT/.ci-tools/janet

if [ -x "$DEST/bin/janet" ] && [ "$("$DEST/bin/janet" -v)" = "$JANET_DIST_VERSION" ]; then
    echo "janet $JANET_DIST_VERSION already installed"
    exit 0
fi

mkdir -p "$ROOT/.ci-tools"
TMP=$ROOT/.ci-tools/janet.tar.gz
curl -fsSL -o "$TMP" "https://github.com/janet-lang/janet/releases/download/v$JANET_VERSION/$JANET_TARBALL"
printf '%s  %s\n' "$JANET_SHA256" "$TMP" | sha256sum -c -

# The dist tarball's top directory is janet-v<VERSION>-linux; extract whole
# and move it into place (no --strip-components: GNU tar counts the "./"
# prefix tar stores, which would leave the binary one level too deep).
rm -rf "$ROOT/.ci-tools/janet-extract" "$DEST"
mkdir -p "$ROOT/.ci-tools/janet-extract"
tar -xzf "$TMP" -C "$ROOT/.ci-tools/janet-extract"
mv "$ROOT/.ci-tools/janet-extract/janet-v$JANET_VERSION-linux" "$DEST"
rm -rf "$ROOT/.ci-tools/janet-extract"
rm -f "$TMP"

if [ ! -x "$DEST/bin/janet" ]; then
    echo "FAIL: janet not at $DEST/bin/janet after install" >&2
    exit 1
fi

echo "janet $("$DEST/bin/janet" -v) installed at $DEST"
