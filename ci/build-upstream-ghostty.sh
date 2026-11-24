#!/bin/sh
# Build upstream Ghostty at the pinned base tag once per cache key, and hand
# the binary to the parity gate. The source carries the same glslang -O0
# split the fork carries: Zig 0.17's bundled clang aborts on SPIRV/doc.cpp
# above -O0, upstream included. Licence: AGPLv3 (njuggle).
set -eu

ROOT=${CI_PROJECT_DIR:-$(pwd)}
OUT=$ROOT/.ci-tools
BIN=$OUT/ghostty

if [ -x "$BIN" ]; then
    echo "using the cached upstream binary"
    "$BIN" +version | head -n 1
    exit 0
fi

rm -rf "$OUT/ghostty-src"
git clone --depth 1 --branch "$GHOSTTY_TAG" \
    https://github.com/ghostty-org/ghostty.git "$OUT/ghostty-src"
cd "$OUT/ghostty-src"
git apply "$ROOT/ci/ghostty-glslang-o0.patch"

# ReleaseFast, like the fork's own artifact: the gate compares release
# against release. No LTO option exists in this base; leave the default.
zig build -Doptimize=ReleaseFast

mkdir -p "$OUT"
cp zig-out/bin/ghostty "$BIN"
cd "$ROOT"
"$BIN" +version | head -n 1
