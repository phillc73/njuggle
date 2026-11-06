//! The activation-collapse decision for the single-window fix.
//! Licence: AGPLv3 (njuggle).
//!
//! Why this is a pure function and not a GTK call: the defect is that the
//! primary's `activate` handler queued a window unconditionally, so every
//! activation that arrived while the application was still settling - the
//! owner's close-and-relaunch handover - produced another surface. The rule
//! is a question about state the handler already has, and keeping it free of
//! GTK lets `zig build test-units` hold it to account.
//!
//! The two flags mirror the application's own: `requested_window` (a window
//! request is in flight or a window has been requested at some point) and
//! `window_count` (windows that exist right now). Neither is GTK state.

const std = @import("std");
const testing = std.testing;

/// What an activation should do.
pub const Action = enum {
    /// Open a window: nothing is showing and nothing is on its way.
    open,

    /// A window exists, or one is on its way. Present it; never open another.
    present,
};

/// The state the decision is made from.
pub const State = struct {
    /// A window of this application exists right now.
    window_exists: bool = false,

    /// A window request has been made and has not yet been seen to land in
    /// `window_exists`. This is the handover: the activation that opens the
    /// first window queues it on the mailbox, and a second activation
    /// arriving before the event loop creates the window must not queue
    /// another.
    window_pending: bool = false,
};

pub fn decide(state: State) Action {
    if (state.window_exists or state.window_pending) return .present;
    return .open;
}

/// The window requests one sequence of activations produces, modelled on the
/// handler. `settling` is the window between an activation and its window
/// appearing: the request is in flight and no window exists yet.
pub const Model = struct {
    /// Window requests pushed to the core application.
    requests: usize = 0,
    window_exists: bool = false,

    /// Whether a queued request is in flight. The base handler had no such
    /// flag; `track_pending = false` reproduces that handler exactly, which
    /// is what makes the handover test below a red-first cell.
    track_pending: bool = true,
    pending: bool = false,

    /// One activation reached the handler.
    pub fn activate(self: *Model) void {
        switch (decide(.{
            .window_exists = self.window_exists,
            // Without the flag a queued request is invisible to the next
            // activation, which is the defect.
            .window_pending = self.track_pending and self.pending,
        })) {
            .open => {
                self.requests += 1;
                self.pending = true;
            },
            .present => {},
        }
    }

    /// The event loop creates the window the core application was asked for.
    pub fn land(self: *Model) void {
        self.window_exists = true;
        self.pending = false;
    }

    /// The user closes the window; the application has none again.
    pub fn close(self: *Model) void {
        self.window_exists = false;
    }
};

test "no window and no request in flight: the activation opens one" {
    try testing.expectEqual(Action.open, decide(.{}));
}

test "a window exists: the activation presents it" {
    try testing.expectEqual(Action.present, decide(.{ .window_exists = true }));
}

test "a request is in flight: the activation presents, never opens" {
    try testing.expectEqual(Action.present, decide(.{ .window_pending = true }));
}

// The cells below run the model WITH the in-flight flag, which is the shipped
// handler after the fix. The base handler had no flag (`track_pending =
// false`), and running these same cells against it is what the build log
// records as the red-first evidence: 2 requests where 1 is expected.

test "two activations at the handover open exactly one window" {
    var m = Model{};
    m.activate();
    m.activate();
    try testing.expectEqual(@as(usize, 1), m.requests);
}

test "an activation after the window landed opens nothing" {
    var m = Model{};
    m.activate();
    m.land();
    m.activate();
    m.activate();
    try testing.expectEqual(@as(usize, 1), m.requests);
}

test "after the window closes the next activation opens one again" {
    var m = Model{};
    m.activate();
    m.land();
    m.close();
    m.activate();
    try testing.expectEqual(@as(usize, 2), m.requests);
}
