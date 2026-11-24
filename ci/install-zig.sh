#!/bin/sh
# Install the pinned Zig toolchain into .ci-tools/zig, verified against the
# published sha256. Licence: AGPLv3 (njuggle).
set -eu

ROOT=${CI_PROJECT_DIR:-$(pwd)}
DEST=$ROOT/.ci-tools/zig

if [ -x "$DEST/zig" ] && [ "$("$DEST/zig" version)" = "$ZIG_VERSION" ]; then
    echo "zig $ZIG_VERSION already installed"
    exit 0
fi

mkdir -p "$ROOT/.ci-tools"
TMP=$ROOT/.ci-tools/zig.tar.xz
curl -fsSL -o "$TMP" "https://ziglang.org/download/$ZIG_VERSION/$ZIG_TARBALL"
printf '%s  %s\n' "$ZIG_SHA256" "$TMP" | sha256sum -c -

rm -rf "$ROOT/.ci-tools/zig-extract" "$DEST"
mkdir -p "$ROOT/.ci-tools/zig-extract"
tar -xJf "$TMP" -C "$ROOT/.ci-tools/zig-extract" --strip-components=1
mv "$ROOT/.ci-tools/zig-extract" "$DEST"
rm -f "$TMP"

echo "zig $("$DEST/zig" version) installed at $DEST"
