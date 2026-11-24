#!/bin/sh
# Fast gate 1: the GTK-free unit suite. The test run steps carry
# has_side_effects in build.zig, so a cached step still executes. The job
# also asserts the summary reports a non-trivial pass count: a run that did
# nothing cannot print one, which is the green-by-nothing trap.
#
# The build's own exit status is checked directly: piping into tee would
# report tee's status and hide a failed build.
set -eu

LOG=$PWD/.ci-test-units.log
if ! zig build test-units --summary all > "$LOG" 2>&1; then
    echo "FAIL: zig build test-units failed" >&2
    cat "$LOG" >&2
    exit 1
fi
cat "$LOG"

grep -q 'Build Summary' "$LOG" || {
    echo "FAIL: the build printed no summary" >&2
    exit 1
}

summary=$(grep 'Build Summary' "$LOG" | head -n 1)
echo "$summary"
passed=$(printf '%s\n' "$summary" | awk '{for (i=1; i<=NF; i++) if ($i == "tests" && $(i+1) == "passed") { split($(i-1), a, "/"); print a[2]; exit }}')
echo "test units: ${passed:-0} test cases reported by the summary"
[ "${passed:-0}" -ge 4000 ] || {
    echo "FAIL: ${passed:-0} test cases is below the 4000 floor; the suite did not run" >&2
    exit 1
}
