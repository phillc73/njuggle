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

rm -rf "$ROOT/.ci-tools/janet-extract" "$DEST"
mkdir -p "$ROOT/.ci-tools/janet-extract"
tar -xzf "$TMP" -C "$ROOT/.ci-tools/janet-extract" --strip-components=1
mv "$ROOT/.ci-tools/janet-extract" "$DEST"
rm -f "$TMP"

echo "janet $("$DEST/bin/janet" -v) installed at $DEST"
