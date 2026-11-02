#!/bin/sh
# Assert this fork's promise: with `gtk-sidebar-tabs = none`, SIDEBAR BEHAVIOUR
# matches upstream Ghostty.
#
# The scope is sidebar behaviour plus Njuggle's own config path and borders.
# The old promise - "none mode is indistinguishable from upstream" - is no
# longer achievable and
# is no longer made: Njuggle reads its own config path
# ($XDG_CONFIG_HOME/njuggle/config, never Ghostty's) and carries its own
# application id, by design. Neither is a sidebar behaviour, and neither can be
# reverted without undoing the reasons this fork exists.
#
# What the gate still checks, and why it is still worth checking:
#
#   1. With `none`, the fork emits no GTK/GLib complaint that upstream does not
#      emit. The sidebar must be inert, not merely invisible.
#   2. Neither `left` nor `right` emits a CRITICAL.
#
# The history that made this a script rather than a sentence in a README still
# holds: two divergences were caught only by a human reading a launch log.
#
#   1. GtkSingleSelection autoselects on an empty model, reaching through
#      AdwTabPages into adw_tab_view_get_nth_page(0) on a tab view with no
#      pages — an Adwaita assertion at window construction.
#   2. AdwBreakpoint requires a window minimum size, and said so on every
#      launch, because the breakpoint was declared in the template rather than
#      installed only when the sidebar is on.
#
# `active-pane-border` and `inactive-pane-dim` are Njuggle-only and have no
# effect under `none`: they are read on paths `none` never reaches. The gate
# diffs the `none` output against upstream, so it never compares a
# Njuggle-only feature against itself - a behaviour that only exists on a
# sidebar path cannot be masked by it.
#
# Usage:  sh scripts/check-none-parity.sh [path-to-upstream-ghostty]
set -eu

# The fork's rebrand renames the installed artifact to `njuggle`. When that
# rename lands, pointing this at the old name silently tests a stale binary and
# the gate reports PASS for code that is not the code under test.
FORK="${FORK:-./zig-out/bin/njuggle}"
UPSTREAM="${1:-/usr/bin/ghostty}"

[ -x "$FORK" ] || { echo "no fork binary at $FORK — run zig build first" >&2; exit 2; }
[ -x "$UPSTREAM" ] || { echo "no upstream binary at $UPSTREAM (pass one as \$1)" >&2; exit 2; }

# Refuse to certify a binary older than the sources it claims to test. A stale
# artifact passes every check here while proving nothing about current code.
if [ -n "${FORK_FRESHNESS_FROM:-}" ]; then
    [ "$FORK" -nt "$FORK_FRESHNESS_FROM" ] || {
        echo "fork binary $FORK is older than $FORK_FRESHNESS_FROM — rebuild" >&2
        exit 2
    }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Keep only GTK/GLib complaints. Everything else — versions, paths, pids,
# renderer chatter — differs between two builds for reasons that say nothing
# about behaviour.
noise() {
    # grep exits 1 on no match; an empty result is the good case here.
    #
    # 'Otherwise, please rebuild in a release mode.' is the CONTINUATION line
    # of the debug-build warning ('debug build' is the first line, already
    # filtered). A fork binary built with `zig build` (Debug) compared
    # against upstream's Release package emits this every run — it says
    # nothing about the sidebar, so both lines of the same warning must be
    # filtered together or the pair silently reappears as a false parity
    # break the next time the wording shifts by a line.
    grep -iE 'CRITICAL|WARNING|assertion' "$1" 2>/dev/null |
        grep -viE 'debug build|rebuild in a release mode|performance will be|GDK_DEBUG|GDK_DISABLE|hsl\(' |
        sed 's/0x[0-9a-f]*//g' |
        sort -u || true
}

# run <binary> <logfile> [extra-arg]
#
# Captures the exit status in RUN_RC. An earlier version swallowed it with
# `|| true` and reported PASS on a binary that was aborting on exit with
# `munmap_chunk(): invalid pointer` — the guard was blind to the single worst
# thing it could have caught. 124 is timeout's own code and means the window
# stayed up for the whole run, which is the healthy case here.
RUN_RC=0
run() {
    # Each invocation gets its OWN fresh XDG_CONFIG_HOME. Ghostty writes a
    # placeholder config.ghostty on first launch as a side effect; four
    # invocations sharing one config dir (upstream, none, left, right) means
    # whichever runs first leaves that empty file behind for the next one to
    # trip over — upstream always runs first, so only the fork's runs ever
    # saw the leftover and only the fork's logs ever complained about it.
    # That's an ordering artifact of this script, not a caller's environment
    # to isolate — a caller-supplied XDG_CONFIG_HOME would have the same bug.
    xdg_home="$tmp/xdg-config-$(basename "$2" .log)"
    mkdir -p "$xdg_home"
    # `cmd && rc=0 || rc=$?` and not `cmd; rc=$?`: under `set -e` a failing
    # command aborts the script before the assignment ever runs.
    if [ -n "${3:-}" ]; then
        XDG_CONFIG_HOME="$xdg_home" timeout 12 "$1" --quit-after-last-window-closed=true "$3" >"$2" 2>&1 &&
            RUN_RC=0 || RUN_RC=$?
    else
        XDG_CONFIG_HOME="$xdg_home" timeout 12 "$1" --quit-after-last-window-closed=true >"$2" 2>&1 &&
            RUN_RC=0 || RUN_RC=$?
    fi
    return 0
}

# check_exit <label> <rc>
check_exit() {
    case "$2" in
        0|124) return 0 ;;
        13[0-9]|14[0-3])
            echo "FAIL — $1 died on a signal (exit $2). Last lines:"
            tail -5 "$3" | sed 's/^/  /'
            exit 1 ;;
        *)
            echo "FAIL — $1 exited $2, which is neither success nor timeout."
            tail -5 "$3" | sed 's/^/  /'
            exit 1 ;;
    esac
}

echo "fork:     $FORK"
echo "upstream: $UPSTREAM"
echo

run "$UPSTREAM" "$tmp/upstream.log"
check_exit "upstream" "$RUN_RC" "$tmp/upstream.log"
run "$FORK"     "$tmp/none.log" "--gtk-sidebar-tabs=none"
check_exit "none" "$RUN_RC" "$tmp/none.log"

noise "$tmp/upstream.log" > "$tmp/upstream.txt"
noise "$tmp/none.log"     > "$tmp/none.txt"

if diff -u "$tmp/upstream.txt" "$tmp/none.txt" > "$tmp/diff.txt"; then
    echo "PASS — gtk-sidebar-tabs=none emits the same GTK/GLib diagnostics as upstream."
    echo "       (Re-scoped 2026-10-30: identical config path and app id are no"
    echo "        longer required; sidebar behaviour is.)"
else
    echo "FAIL — none mode emits diagnostics upstream does not:"
    echo
    sed 's/^/  /' "$tmp/diff.txt"
    echo
    echo "The sidebar must be inert when disabled. Something is running on the"
    echo "none path that should be behind the config guard."
    exit 1
fi

# The sidebar modes are allowed to differ from upstream, but never by emitting
# a CRITICAL. Those are always bugs, not features.
for mode in left right; do
    run "$FORK" "$tmp/$mode.log" "--gtk-sidebar-tabs=$mode"
    check_exit "$mode" "$RUN_RC" "$tmp/$mode.log"
    n="$(grep -c 'CRITICAL' "$tmp/$mode.log" || true)"
    if [ "$n" -ne 0 ]; then
        echo "FAIL — $mode emitted $n CRITICAL line(s):"
        grep 'CRITICAL' "$tmp/$mode.log" | sed 's/^/  /'
        exit 1
    fi
    echo "PASS — $mode is CRITICAL-free and exited cleanly."
done
