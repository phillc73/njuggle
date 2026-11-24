#!/bin/sh
# Tag job: package the built tree as the release tarball, measure its
# sha256, and fail loudly when the version, size or strip state is wrong.
# Licence: AGPLv3 (njuggle).
set -eu

TAG=${CI_COMMIT_TAG:?the artifact job runs on a tag only}
VER=${TAG#v}
BIN=package/bin/njuggle
NAME=njuggle-$TAG-x86_64-linux
STAGE=dist/$NAME

[ -x "$BIN" ] || { echo "FAIL: no binary at $BIN" >&2; exit 1; }

# The base is read from the tree, never assumed: the provenance clause is
# re-measured at the tagged tree.
BASE=$(while IFS= read -r line; do
    case "$line" in
        *'const ghostty_base_version = "'*)
            rest=${line#*const ghostty_base_version = \"}
            printf '%s\n' "${rest%%\"*}"
            break
            ;;
    esac
done < build.zig)
[ -n "$BASE" ] || { echo "FAIL: no ghostty_base_version in build.zig" >&2; exit 1; }

VERSION_LINE=$("$BIN" +version | head -n 1)
EXPECT="Njuggle $VER+ghostty.$BASE"
echo "version: $VERSION_LINE"
[ "$VERSION_LINE" = "$EXPECT" ] || {
    echo "FAIL: expected '$EXPECT'" >&2
    exit 1
}

SIZE=$(stat -c %s "$BIN")
echo "binary: $SIZE bytes"
{ [ "$SIZE" -ge 31457280 ] && [ "$SIZE" -le 37748736 ]; } || {
    echo "FAIL: $SIZE bytes is outside the 30-36 MiB band" >&2
    exit 1
}

file "$BIN" | grep -q 'stripped' || {
    echo "FAIL: the binary is not stripped" >&2
    file "$BIN" >&2
    exit 1
}

rm -rf "$STAGE" "dist/$NAME.tar.gz" "dist/$NAME.tar.gz.sha256"
mkdir -p "$STAGE/bin" "$STAGE/dist/njuggle"
cp "$BIN" "$STAGE/bin/njuggle"
cp -R package/share "$STAGE/share"
cp scripts/njuggle-install.sh scripts/njuggle-clean.sh "$STAGE/"
cp dist/njuggle/config.default dist/njuggle/config-if-absent.sh \
    dist/njuggle/desktop-install.sh dist/njuggle/dbus.service.default \
    "$STAGE/dist/njuggle/"
cp README.md "$STAGE/README"

tar -czf "dist/$NAME.tar.gz" -C dist "$NAME"
(
    cd dist
    sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
)
echo "tarball: $(stat -c %s "dist/$NAME.tar.gz") bytes"
cat "dist/$NAME.tar.gz.sha256"
