#!/bin/sh
# Fast gate 2: the none-mode parity gate, invoked exactly as shipped, in the
# runner's plain environment (no PATH shims exist here). The gate launches
# real windows, so it runs under Xvfb.
set -eu

# The fork binary comes from build-binary's artifact tree (--prefix package).
# FORK is exported: check-none-parity.sh honours it over its own default.
[ -x .ci-tools/ghostty ] || { echo "FAIL: no upstream binary" >&2; exit 1; }
[ -x package/bin/njuggle ] || { echo "FAIL: no fork binary" >&2; exit 1; }
export FORK=package/bin/njuggle

LOG=$PWD/.ci-parity.log
xvfb-run -a sh scripts/check-none-parity.sh .ci-tools/ghostty 2>&1 | tee "$LOG"

passes=$(awk '/^PASS/{c++} END{print c+0}' "$LOG")
echo "parity gate: $passes PASS lines"
[ "$passes" -ge 3 ] || {
    echo "FAIL: expected 3 PASS lines (none, left, right)" >&2
    exit 1
}
