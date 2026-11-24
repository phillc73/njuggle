#!/bin/sh
# R3-B cell driver: the sidebar tab model, read from OUTSIDE the binary.
#   scripts/check-sidebar-model.sh <njuggle-repo-root> [work-dir]
#
# Launches <root>/zig-out/bin/njuggle under Xvfb in its own session bus, lets
# it settle, dumps the accessibility tree (scripts/check-sidebar-model-a11y.py)
# and asserts three things (scripts/check-sidebar-model-a11y-check.py):
#   WINDOWS  exactly one realized window
#   TABS     the sidebar's tab model is non-empty at launch
#   SURFACE  the terminal is the split view's content child
#
# COVERAGE BRACKET. The cell also launches once with gtk-sidebar-tabs = none
# and requires the title bar's tab list to appear in THAT tree. Without the
# bracket, a blind instrument and an empty sidebar read the same, so a cell
# whose bracket fails reports BRACKET and never PASS.
#
# Environment is a11y-ON on purpose: GTK_A11Y=none or NO_AT_BRIDGE keeps the
# app off the accessibility bus and makes every reading vacuous; GTK_DEBUG
# would add a window of its own to the frame count.
#
# Licence: AGPLv3 (njuggle).

set -u
PATH=/usr/bin:/bin
export PATH

ROOT=${1:-.}
WORK=${2:-/tmp/njuggle-sidebar-model}
BIN="$ROOT/zig-out/bin/njuggle"
HERE=$(dirname "$0")

if [ ! -x "$BIN" ]; then
  echo "FAIL: no binary at $BIN"
  echo "RESULT: fail (BINARY)"
  exit 1
fi

run_mode() {
  mode=$1
  out=$2
  w="$WORK/$mode"
  rm -rf "$w"
  mkdir -p "$w/cfg/njuggle"
  printf 'gtk-sidebar-tabs = %s\nquit-after-last-window-closed = false\n' \
    "$mode" > "$w/cfg/njuggle/config"
  if [ "$mode" = none ]; then
    # The bracket needs a tab list on screen to look at. The shipped default
    # is `window-show-tab-bar = never` (the fork's belt), so with the sidebar
    # off there would be no tab widget at all and the bracket would fail for
    # a reason that has nothing to do with the instrument.
    printf 'window-show-tab-bar = always\n' >> "$w/cfg/njuggle/config"
  fi
  XDG_CONFIG_HOME="$w/cfg" XDG_STATE_HOME="$w/st" XDG_CACHE_HOME="$w/ca" \
    GSETTINGS_BACKEND=memory W="$w" BIN="$BIN" PROBE_DIR="$HERE" OUT="$out" \
    dbus-run-session -- /bin/sh -c '
      Xvfb :73 -screen 0 1600x1000x24 > "$W/xvfb.log" 2>&1 &
      sleep 2
      DISPLAY=:73
      export DISPLAY
      flock "$W/lock" timeout 50 "$BIN" --gtk-single-instance=true > "$W/log" 2>&1 &
      sleep 9
      python3 "$PROBE_DIR/check-sidebar-model-a11y.py" "$OUT" 20 > "$W/probe.err" 2>&1
      echo "probe-rc=$? lines=$(wc -l < "$OUT" 2>/dev/null || echo 0)"
      kill %1 2>/dev/null
      kill %2 2>/dev/null
    '
}

mkdir -p "$WORK"
run_mode left "$WORK/a11y-left.txt"
run_mode none "$WORK/a11y-none.txt"

echo "binary: $(sha256sum "$BIN" | cut -d' ' -f1)"
echo "provenance: $(grep -o "version=[^ ]*" "$WORK/left/log" | head -1)"
echo "tier 2 (reported, never asserted): surface=$(grep -c "surface content scale" "$WORK/left/log") shell=$(grep -c "started subcommand" "$WORK/left/log")"

bracket=0
if [ -f "$WORK/a11y-none.txt" ]; then
  bracket=$(grep -c '|page tab list|' "$WORK/a11y-none.txt")
fi
if [ "${bracket:-0}" -gt 0 ] 2>/dev/null; then
  echo "BRACKET  ok     sidebar off: $bracket title-bar tab list(s) visible to a11y"
else
  echo "BRACKET  FAIL   sidebar off: the dump sees no tab list at all"
  echo ""
  echo "RESULT: fail (BRACKET: the a11y dump cannot see tabs even with the sidebar off)"
  exit 1
fi

python3 "$HERE/check-sidebar-model-a11y-check.py" "$WORK/a11y-left.txt"
