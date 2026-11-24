#!/bin/sh
# Build the release binary and the install tree once per pipeline.
# Licence: AGPLv3 (njuggle).
set -eu

# Keep the build's run steps out of the container's real home.
export NJUGGLE_NO_DESKTOP_INSTALL=1
export XDG_CONFIG_HOME=$PWD/.ci-xdg/config
export XDG_DATA_HOME=$PWD/.ci-xdg/data
rm -rf package .ci-xdg

zig build -Doptimize=ReleaseFast --prefix package install

[ -x package/bin/njuggle ] || {
    echo "FAIL: no binary at package/bin/njuggle" >&2
    exit 1
}
echo "binary: $(stat -c %s package/bin/njuggle) bytes"
file package/bin/njuggle
