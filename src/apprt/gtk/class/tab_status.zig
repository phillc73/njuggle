//! The per-tab status indicator state machine.
//!
//! This file is pure data: no GTK, no widgets, no signals. The widget side
//! (sidebar_row.zig) feeds it events and reads `State` back; the tests here
//! exercise the rules the owner set without needing a display.
//!
//! Rules (docs repo, projects/njuggle/roadmap.md NEXT VERSION section 2):
//!   - every tab shows an indicator in one of three states, focused or not;
//!   - a command that starts turns the tab green (running);
//!   - a command that ends while the tab is unfocused and ran past the
//!     threshold, or a bell, turns it red (needs-attention);
//!   - red outranks green when a tab's panes disagree.

const std = @import("std");

pub const State = enum(u2) {
    /// Nothing is happening: the grey icon.
    idle = 0,
    /// A command is running: the green icon.
    running = 1,
    /// A command finished while the tab was not focused, or the bell rang:
    /// the red icon.
    needs_attention = 2,

    /// Dominance order for merging panes into one tab state. Red outranks
    /// green outranks grey; that ordering IS the owner's rule, expressed once
    /// here so the widget never has to remember it.
    pub fn max(a: State, b: State) State {
        return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
    }

    pub fn rank(self: State) u2 {
        return @intFromEnum(self);
    }
};

/// What one surface (pane) is doing.
pub const Tracker = struct {
    /// The pane is running a command, per OSC 133 C (command start).
    running: bool = false,
    /// The pane wants the user's eyes. Set by a bell, or by a command that
    /// finished unfocused and long enough. Cleared when the user looks.
    attention: bool = false,

    pub fn state(self: Tracker) State {
        // Red outranks green: a finished-but-unseen command is the thing the
        // indicator exists for, so it is not masked by the next command.
        if (self.attention) return .needs_attention;
        if (self.running) return .running;
        return .idle;
    }

    /// A command started (OSC 133 C).
    pub fn commandStarted(self: *Tracker) void {
        self.running = true;
    }

    /// A command ended (OSC 133 D).
    ///
    /// `focused` is whether the user was looking at this pane; `duration_ns`
    /// is how long the command ran; `threshold_ns` is
    /// `gtk-sidebar-status-after`. The threshold is exclusive of zero: a
    /// threshold of 0 means every unfocused finish counts.
    pub fn commandFinished(
        self: *Tracker,
        focused: bool,
        duration_ns: u64,
        threshold_ns: u64,
    ) void {
        self.running = false;
        if (focused) return;
        if (duration_ns < threshold_ns) return;
        self.attention = true;
    }

    /// The bell rang (BEL, or a notification that rings the bell).
    ///
    /// A bell marks the pane regardless of focus: it is an explicit request
    /// for attention from the program, and Ghostty's own bell features
    /// (border, title marker) treat it the same way.
    pub fn bell(self: *Tracker) void {
        self.attention = true;
    }

    /// The user looked at this pane: clear the attention mark. Running state
    /// is untouched, because a command that is still running is still running
    /// after you glance at it.
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
/// `images/status/{green,red,grey}/`. This is the single place the state to
/// colour mapping lives.
pub fn assetColour(state: State) [:0]const u8 {
    return switch (state) {
        .idle => "grey",
        .running => "green",
        .needs_attention => "red",
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

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
    t.commandFinished(true, 60 * std.time.ns_per_s, 5 * std.time.ns_per_s);
    try testing.expectEqual(State.idle, t.state());
}

test "tracker: unfocused finish past threshold needs attention" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandFinished(false, 6 * std.time.ns_per_s, 5 * std.time.ns_per_s);
    try testing.expectEqual(State.needs_attention, t.state());
    try testing.expectEqualStrings("red", assetColour(t.state()));
}

test "tracker: unfocused finish under threshold stays idle" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandFinished(false, 4 * std.time.ns_per_s, 5 * std.time.ns_per_s);
    try testing.expectEqual(State.idle, t.state());
}

// The boundary belongs to the threshold: run time equal to it counts.
test "tracker: threshold is inclusive" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandFinished(false, 5 * std.time.ns_per_s, 5 * std.time.ns_per_s);
    try testing.expectEqual(State.needs_attention, t.state());
}

test "tracker: zero threshold counts every unfocused finish" {
    var t: Tracker = .{};
    t.commandStarted();
    t.commandFinished(false, 0, 0);
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

test "tracker: attention outranks a command started after it" {
    var t: Tracker = .{};
    t.commandFinished(false, 30 * std.time.ns_per_s, 1 * std.time.ns_per_s);
    t.commandStarted();
    try testing.expectEqual(State.needs_attention, t.state());
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

test "aggregate: single pane is its own state" {
    for ([_]State{ .idle, .running, .needs_attention }) |s| {
        try testing.expectEqual(s, aggregate(&.{s}));
    }
}

// The owner's cycle as one sequence, through the same entry points the GTK
// surface calls: a command starts (OSC 133 C), finishes while the user is in
// another tab, and the user comes back. Each step names the icon colour.
test "cycle: grey idle, green running, red away, grey after looking" {
    var t: Tracker = .{};
    const threshold = 5 * std.time.ns_per_s;
    try testing.expectEqualStrings("grey", assetColour(t.state()));

    t.commandStarted();
    try testing.expectEqualStrings("green", assetColour(t.state()));

    t.commandFinished(false, 30 * std.time.ns_per_s, threshold);
    try testing.expectEqualStrings("red", assetColour(t.state()));

    t.looked();
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
    t.commandFinished(true, 30 * std.time.ns_per_s, 5 * std.time.ns_per_s);
    try testing.expectEqualStrings("grey", assetColour(t.state()));
}

test "assetColour: every state maps to a staged directory" {
    try testing.expectEqualStrings("grey", assetColour(.idle));
    try testing.expectEqualStrings("green", assetColour(.running));
    try testing.expectEqualStrings("red", assetColour(.needs_attention));
}
