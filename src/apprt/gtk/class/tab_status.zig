//! The per-tab status indicator state machine.
//!
//! This file is pure data: no GTK, no widgets, no signals. The widget side
//! (sidebar_row.zig) feeds it events and reads `State` back; the tests here
//! exercise the rules the owner set without needing a display.
//!
//! Rules (the verified state machine is icon-machine.qnt; this file is its
//! Zig spelling):
//!   - every tab shows an indicator in one of four states, focused or not;
//!   - a command that starts turns the tab green (running);
//!   - a command still running past the long threshold turns it dim green
//!     (long_running) - tracked by wall-clock elapsed, never a demotion;
//!   - a command that ends while the tab is unfocused and ran past the
//!     threshold, or a bell, turns it red (needs-attention);
//!   - a command that starts clears the red mark: the red belongs to the
//!     command that finished unseen, and running a new one answers it;
//!   - red outranks dim green outranks green outranks grey when a tab's
//!     panes disagree.
//!
//! The clock is owned by the surface, which hands this file how long the
//! current command has run. Neither a timestamp nor a timer lives here, so
//! every rule below is testable without time.

const std = @import("std");

pub const State = enum(u2) {
    /// Nothing is happening: the grey icon.
    idle = 0,
    /// A command is running: the green icon.
    running = 1,
    /// A command has been running past the long threshold: dim green.
    long_running = 2,
    /// A command finished while the tab was not focused, or the bell rang:
    /// the red icon.
    needs_attention = 3,

    /// The aggregation order over states, stated once. It is a mapping and
    /// not the enum's declared order: an order read off the declaration
    /// silently changes when a state is inserted, and the display would then
    /// follow the declaration instead of the law.
    pub fn rank(self: State) u2 {
        return switch (self) {
            .idle => 0,
            .running => 1,
            .long_running => 2,
            .needs_attention => 3,
        };
    }

    /// Dominance order for merging panes into one tab state. Red outranks
    /// dim green outranks green outranks grey; that ordering IS the owner's
    /// rule, expressed once here so the widget never has to remember it.
    pub fn max(a: State, b: State) State {
        return if (a.rank() >= b.rank()) a else b;
    }
};

/// What one surface (pane) is doing.
pub const Tracker = struct {
    /// The pane is running a command, per OSC 133 C (command start).
    running: bool = false,
    /// The command has run past the long threshold. Monotone within one
    /// command: it never goes back to `running`, only to `idle` (a focused
    /// finish) or `needs_attention` (a bell, or an unfocused finish past the
    /// attention threshold), or it restarts with the next command.
    long_running: bool = false,
    /// The pane wants the user's eyes. Set by a bell, or by a command that
    /// finished unfocused and long enough. Cleared when the user looks.
    attention: bool = false,

    pub fn state(self: Tracker) State {
        // Red outranks the run state while it is set: a finished-but-unseen
        // command, or a bell, is the thing the indicator exists for. It is
        // set and cleared by events, never derived - a command start clears
        // it (see commandStarted).
        if (self.attention) return .needs_attention;
        if (self.long_running) return .long_running;
        if (self.running) return .running;
        return .idle;
    }

    /// A command started (OSC 133 C). A second command restarts the run
    /// clock and clears the dim state: a fresh command is bright green, with
    /// no dim leaking from the one before it. It clears the attention mark
    /// too: the red belongs to the command that finished unseen, and the new
    /// command is the user's answer to it. Without this a bell in a focused
    /// pane stayed red across every following command until focus left and
    /// came back.
    pub fn commandStarted(self: *Tracker) void {
        self.running = true;
        self.long_running = false;
        self.attention = false;
    }

    /// How long the current command has been running, in nanoseconds, from
    /// the surface's wall clock. The state is recomputed rather than
    /// advanced, so a late or coalesced timer cannot lose a promotion.
    ///
    /// The threshold is strictly passed: elapsed at exactly the threshold is
    /// still `running` (icon-machine.qnt `tickNext`: `elapsed + 1 > long`).
    /// A threshold of 0 therefore promotes on the first check past zero. The
    /// surface's timer fires one millisecond past the threshold, which is the
    /// first wall-clock instant that is strictly past it.
    pub fn commandElapsed(self: *Tracker, elapsed_ns: u64, threshold_ns: u64) void {
        if (!self.running) return;
        if (elapsed_ns <= threshold_ns) return;
        self.long_running = true;
    }

    /// A command ended (OSC 133 D).
    ///
    /// `focused` is whether the user was looking at this pane; `duration_ns`
    /// is how long the command ran; `threshold_ns` is
    /// `gtk-sidebar-status-after`. The threshold is strictly passed, matching
    /// the rule in `finishNext`: `p.elapsed > attSecs`.
    pub fn commandFinished(
        self: *Tracker,
        focused: bool,
        duration_ns: u64,
        threshold_ns: u64,
    ) void {
        self.running = false;
        self.long_running = false;
        if (focused) return;
        if (duration_ns <= threshold_ns) return;
        self.attention = true;
    }

    /// The bell rang (BEL, or a notification that rings the bell).
    ///
    /// A bell marks the pane regardless of focus: it is an explicit request
    /// for attention from the program, and Ghostty's own bell features
    /// (border, title marker) treat it the same way. During a long-running
    /// command it replaces dim green at once.
    pub fn bell(self: *Tracker) void {
        self.attention = true;
    }

    /// The user looked at this pane: clear the attention mark. The run state
    /// is untouched, because a command that is still running is still running
    /// after you glance at it - including a long-running one, which comes
    /// back dim rather than bright.
    pub fn looked(self: *Tracker) void {
        self.attention = false;
    }
};

/// Merge the panes of one tab into the tab's single indicator state.
pub fn aggregate(states: []const State) State {
    var result: State = .idle;
    for (states) |s| result = result.max(s);
    return result;
}

/// The asset directory name for a state, matching the staged tree
/// `images/status/{green,green-dim,red,grey}/`. This is the single place the
/// state to colour mapping lives.
pub fn assetColour(state: State) [:0]const u8 {
    return switch (state) {
        .idle => "grey",
        .running => "green",
        .long_running => "green-dim",
        .needs_attention => "red",
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const sec = std.time.ns_per_s;

test "tracker: idle by default" {
    const t: Tracker = .{};
    try testing.expectEqual(State.idle, t.state());
    try testing.expectEqualStrings("grey", assetColour(t.state()));
}

test "tracker: command start is running" {
    var t: Tracker = .{};
    t.commandStarted();
    try testing.expectEqual(State.running, t.state());
    try testing.expectEqualStrings("green", assetColour(t.state()));
}

test "tracker: focused finish returns to idle" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandFinished(true, 60 * sec, 5 * sec);
    try testing.expectEqual(State.idle, t.state());
}

test "tracker: unfocused finish past threshold needs attention" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandFinished(false, 6 * sec, 5 * sec);
    try testing.expectEqual(State.needs_attention, t.state());
    try testing.expectEqualStrings("red", assetColour(t.state()));
}

test "tracker: unfocused finish under threshold stays idle" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandFinished(false, 4 * sec, 5 * sec);
    try testing.expectEqual(State.idle, t.state());
}

// The boundary is strictly past the threshold: a run equal to it has not
// gone past it.
test "tracker: threshold is exclusive" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandFinished(false, 5 * sec, 5 * sec);
    try testing.expectEqual(State.idle, t.state());

    // One nanosecond past is attention.
    t.commandStarted();
    t.commandFinished(false, 5 * sec + 1, 5 * sec);
    try testing.expectEqual(State.needs_attention, t.state());
}

test "tracker: zero threshold counts a finish that ran" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandFinished(false, 0, 0);
    try testing.expectEqual(State.idle, t.state());

    t.commandStarted();
    t.commandFinished(false, 1, 0);
    try testing.expectEqual(State.needs_attention, t.state());
}

test "tracker: bell marks attention without focus or a command" {
    var t: Tracker = .{};
    t.bell();
    try testing.expectEqual(State.needs_attention, t.state());
}

test "tracker: looking clears attention but not running" {
    var t: Tracker = .{};
    t.bell();
    t.looked();
    try testing.expectEqual(State.idle, t.state());

    t.commandStarted();
    t.bell();
    try testing.expectEqual(State.needs_attention, t.state());
    t.looked();
    try testing.expectEqual(State.running, t.state());
}

test "tracker: a new command clears the attention mark" {
    var t: Tracker = .{};
    t.commandFinished(false, 30 * sec, 1 * sec);
    t.commandStarted();
    try testing.expectEqual(State.running, t.state());

    // The bell shape too: a pane that rang while focused is red, and the
    // command after it is the user's answer.
    var b: Tracker = .{};
    b.bell();
    b.commandStarted();
    try testing.expectEqual(State.running, b.state());

    // Nothing is re-armed by the start: the fresh command's own finish
    // decides the next mark.
    t.commandFinished(false, 30 * sec, 1 * sec);
    try testing.expectEqual(State.needs_attention, t.state());
}

// ---------------------------------------------------------------------------
// Long-running (dim green)

test "long: not promoted while the run has not passed the threshold" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandElapsed(30 * sec, 60 * sec);
    try testing.expectEqual(State.running, t.state());
    try testing.expectEqualStrings("green", assetColour(t.state()));
}

// icon-machine.qnt tickNext: `elapsed + 1 > long`, so the state AT the
// threshold is still running and the state past it is dim.
test "long: promotion happens strictly past the threshold" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandElapsed(60 * sec, 60 * sec);
    try testing.expectEqual(State.running, t.state());
    t.commandElapsed(60 * sec + 1, 60 * sec);
    try testing.expectEqual(State.long_running, t.state());
    try testing.expectEqualStrings("green-dim", assetColour(t.state()));
}

test "long: a zero threshold promotes on the first tick past zero" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandElapsed(0, 0);
    try testing.expectEqual(State.running, t.state());
    t.commandElapsed(1, 0);
    try testing.expectEqual(State.long_running, t.state());
}

test "long: never demotes back to running" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandElapsed(61 * sec, 60 * sec);
    // A late or coalesced call carrying a shorter elapsed cannot undo it.
    t.commandElapsed(5 * sec, 60 * sec);
    try testing.expectEqual(State.long_running, t.state());
}

test "long: dims while focused - focus is not an input" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandElapsed(61 * sec, 60 * sec);
    t.looked();
    try testing.expectEqual(State.long_running, t.state());
}

test "long: a bell replaces dim with red at once" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandElapsed(61 * sec, 60 * sec);
    t.bell();
    try testing.expectEqual(State.needs_attention, t.state());
}

test "long: an unfocused finish past attention replaces dim with red" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandElapsed(61 * sec, 60 * sec);
    t.commandFinished(false, 61 * sec, 5 * sec);
    try testing.expectEqual(State.needs_attention, t.state());
}

test "long: a focused finish resolves dim to idle" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandElapsed(61 * sec, 60 * sec);
    t.commandFinished(true, 61 * sec, 5 * sec);
    try testing.expectEqual(State.idle, t.state());
}

test "long: a second command clears the dim state and the clock" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandElapsed(61 * sec, 60 * sec);
    t.commandFinished(true, 61 * sec, 5 * sec);
    t.commandStarted();
    try testing.expectEqual(State.running, t.state());
    try testing.expectEqualStrings("green", assetColour(t.state()));
}

test "long: elapsed is ignored when no command runs" {
    var t: Tracker = .{};
    t.commandElapsed(1000 * sec, 60 * sec);
    try testing.expectEqual(State.idle, t.state());
}

// ---------------------------------------------------------------------------
// Aggregation

test "rank: the full mapping, pinned" {
    // A state inserted into the enum must not be able to reorder display.
    try testing.expectEqual(@as(u2, 0), State.idle.rank());
    try testing.expectEqual(@as(u2, 1), State.running.rank());
    try testing.expectEqual(@as(u2, 2), State.long_running.rank());
    try testing.expectEqual(@as(u2, 3), State.needs_attention.rank());
    // Idle < running < long_running < needs_attention, as one sentence.
    try testing.expect(State.idle.rank() < State.running.rank());
    try testing.expect(State.running.rank() < State.long_running.rank());
    try testing.expect(State.long_running.rank() < State.needs_attention.rank());
}

test "aggregate: empty tab is idle" {
    try testing.expectEqual(State.idle, aggregate(&.{}));
}

test "aggregate: any running beats idle" {
    try testing.expectEqual(
        State.running,
        aggregate(&.{ .idle, .running, .idle }),
    );
}

test "aggregate: attention beats running (red outranks green)" {
    try testing.expectEqual(
        State.needs_attention,
        aggregate(&.{ .running, .needs_attention, .idle }),
    );
    // Order must not matter.
    try testing.expectEqual(
        State.needs_attention,
        aggregate(&.{ .needs_attention, .running }),
    );
}

test "aggregate: dim green outranks bright green, in both orders" {
    try testing.expectEqual(
        State.long_running,
        aggregate(&.{ .running, .long_running, .idle }),
    );
    try testing.expectEqual(
        State.long_running,
        aggregate(&.{ .long_running, .running }),
    );
}

test "aggregate: red outranks dim green" {
    try testing.expectEqual(
        State.needs_attention,
        aggregate(&.{ .long_running, .needs_attention }),
    );
}

test "aggregate: grey only when every pane is idle" {
    try testing.expectEqual(State.idle, aggregate(&.{ .idle, .idle, .idle }));
}

test "aggregate: single pane is its own state" {
    for ([_]State{ .idle, .running, .long_running, .needs_attention }) |st| {
        try testing.expectEqual(st, aggregate(&.{st}));
    }
}

// The owner's cycle as one sequence, through the same entry points the GTK
// surface calls: a command starts (OSC 133 C), finishes while the user is in
// another tab, and the user comes back. Each step names the icon colour.
test "cycle: grey idle, green running, red away, grey after looking" {
    var t: Tracker = .{};
    const threshold = 5 * sec;
    try testing.expectEqualStrings("grey", assetColour(t.state()));

    t.commandStarted();
    try testing.expectEqualStrings("green", assetColour(t.state()));

    t.commandFinished(false, 30 * sec, threshold);
    try testing.expectEqualStrings("red", assetColour(t.state()));

    t.looked();
    try testing.expectEqualStrings("grey", assetColour(t.state()));
}

test "cycle: a command running past the threshold is dim until it finishes" {
    var t: Tracker = .{};
    t.commandStarted();
    try testing.expectEqualStrings("green", assetColour(t.state()));
    t.commandElapsed(61 * sec, 60 * sec);
    try testing.expectEqualStrings("green-dim", assetColour(t.state()));
    t.commandFinished(true, 61 * sec, 5 * sec);
    try testing.expectEqualStrings("grey", assetColour(t.state()));
}

test "cycle: a bell alone reaches red and looking clears it" {
    var t: Tracker = .{};
    try testing.expectEqualStrings("grey", assetColour(t.state()));
    t.bell();
    try testing.expectEqualStrings("red", assetColour(t.state()));
    t.looked();
    try testing.expectEqualStrings("grey", assetColour(t.state()));
}

test "cycle: a focused finish never leaves green behind" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandFinished(true, 30 * sec, 5 * sec);
    try testing.expectEqualStrings("grey", assetColour(t.state()));
}

test "assetColour: every state maps to a staged directory" {
    try testing.expectEqualStrings("grey", assetColour(.idle));
    try testing.expectEqualStrings("green", assetColour(.running));
    try testing.expectEqualStrings("green-dim", assetColour(.long_running));
    try testing.expectEqualStrings("red", assetColour(.needs_attention));
}
