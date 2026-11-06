//! The divider drag's state machine: latch -> follow -> release, and the three
//! other ways a drag ends. GTK-free and pure, so every transition is a unit
//! test - the release path in particular: a drag whose latch never cleared
//! kept following the pointer after button-up (owner UAT, 2026-11-05), and
//! that is a state bug, not a widget bug.
//!
//! Licence: AGPLv3 (njuggle).

const std = @import("std");

/// How a drag ended. Only the release writes the config: a grab broken by the
/// window system or the pointer leaving the window ends the gesture where it
/// stands, with nothing saved.
pub const End = enum {
    release,
    grab_broken,
    pointer_leave,
    drag_end,

    pub fn writes(self: End) bool {
        return self == .release;
    }
};

pub const State = union(enum) {
    idle,
    active: Active,

    pub const Active = struct {
        /// Pointer x where the press landed.
        press_x: f64,
        /// Sidebar width on screen when the press landed.
        start_width: i64,
        /// The last motion seen, so the write uses what the user last saw.
        last_x: f64,
        /// The width the NOISE THRESHOLD is measured from: the pointer at the
        /// press, and later wherever the drag last began or resumed.
        anchor_x: f64,
        anchor_width: i64,
    };

    pub fn release() State {
        return .idle;
    }

    /// A press on the divider lands within a pixel or two of the edge it is
    /// hit-testing, so the first motion almost always points AWAY from the
    /// user's gesture: the pointer is set down, walks a few pixels back to
    /// the edge, and only then starts moving. Under a plain delta that first
    /// step moved the edge by 4px, and the next compare - against the hit
    /// band - ended the drag (F-D6, found by the cells: press at 404, edge
    /// jumped to 400, every following motion left the band). Below the
    /// threshold the drag holds the anchor width and reports null.
    pub const noise: f64 = 10.0;

    /// The press latch. `start_width` is the width on screen, not the stored
    /// one: the split view may hold a smaller fraction than the config.
    pub fn press(x: f64, start_width: c_int) State {
        const w: i64 = @max(start_width, 0);
        return .{ .active = .{ .press_x = x, .start_width = w, .last_x = x, .anchor_x = x, .anchor_width = w } };
    }

    pub fn isActive(self: State) bool {
        return switch (self) {
            .idle => false,
            .active => true,
        };
    }

    pub fn lastX(self: State) ?f64 {
        return switch (self) {
            .idle => null,
            .active => |a| a.last_x,
        };
    }

    /// The width the pointer position asks for while latched, or null when
    /// there is no drag to follow.
    pub fn widthAt(self: State, x: f64) ?i64 {
        return switch (self) {
            .idle => null,
            .active => |a| a.anchor_width + @as(i64, @intFromFloat(x - a.anchor_x)),
        };
    }

    /// A motion while latched: records the pointer and returns the width.
    /// `self` is updated so the release can write what was last seen. Null
    /// while the pointer is still inside the noise threshold of the anchor.
    pub fn follow(self: *State, x: f64) ?i64 {
        return switch (self.*) {
            .idle => null,
            .active => |*a| blk: {
                a.last_x = x;
                if (@abs(x - a.anchor_x) < noise) break :blk null;
                break :blk a.anchor_width + @as(i64, @intFromFloat(x - a.anchor_x));
            },
        };
    }

    /// Whether the drag has moved the edge at all: past the threshold, and
    /// then the base for the rest of the gesture is where it last stood.
    pub fn began(self: State) bool {
        return switch (self) {
            .idle => false,
            .active => |a| a.anchor_width != a.start_width or @abs(a.last_x - a.anchor_x) >= noise,
        };
    }

    /// Re-anchor the noise threshold at the current pointer and width: the
    /// window stops following once a motion leaves the divider's hit band,
    /// and follows again when the pointer comes back onto it.
    pub fn reanchor(self: *State) void {
        switch (self.*) {
            .idle => {},
            .active => |*a| {
                const w = a.anchor_width + @as(i64, @intFromFloat(a.last_x - a.anchor_x));
                a.anchor_x = a.last_x;
                a.anchor_width = w;
            },
        }
    }

    /// Ends the drag. Any end clears the latch; only the release reports a
    /// width for the write, and only when a drag was actually active.
    pub fn end(self: State, how: End) struct { state: State, persist: ?i64 } {
        const w = self.widthAt(self.lastX() orelse return .{ .state = .idle, .persist = null });
        return .{ .state = .idle, .persist = if (how.writes()) w else null };
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "drag: a release before any press clears nothing and writes nothing" {
    const s: State = .release();
    try testing.expect(!s.isActive());
    try testing.expect(s.widthAt(10) == null);
    const r = s.end(.release);
    try testing.expect(!r.state.isActive());
    try testing.expect(r.persist == null);
}

test "drag: press latches at the width on screen, not the stored width" {
    const s: State = .press(300, 197);
    try testing.expect(s.isActive());
    try testing.expectEqual(@as(?i64, 197), s.widthAt(300));
}

test "drag: follow moves the width by the pointer delta" {
    var s: State = .press(300, 200);
    try testing.expectEqual(@as(?i64, 230), s.follow(330));
    try testing.expectEqual(@as(?i64, 170), s.follow(270));
}

test "drag: RELEASE clears the latch and reports the last width" {
    var s: State = .press(300, 200);
    _ = s.follow(340);
    const r = s.end(.release);
    try testing.expect(!r.state.isActive());
    try testing.expectEqual(@as(?i64, 240), r.persist);
    // After the release the pointer no longer moves the width: the owner's
    // UAT defect was exactly this line failing.
    try testing.expect(r.state.widthAt(500) == null);
    var after = r.state;
    try testing.expect(after.follow(500) == null);
    try testing.expect(!after.isActive());
}

test "drag: grab-broken clears the latch and writes nothing" {
    var s: State = .press(300, 200);
    _ = s.follow(340);
    const r = s.end(.grab_broken);
    try testing.expect(!r.state.isActive());
    try testing.expect(r.persist == null);
    try testing.expect(r.state.widthAt(500) == null);
}

test "drag: pointer-leave clears the latch and writes nothing" {
    var s: State = .press(300, 200);
    _ = s.follow(100);
    const r = s.end(.pointer_leave);
    try testing.expect(!r.state.isActive());
    try testing.expect(r.persist == null);
}

test "drag: drag-end (the gesture's own end) clears and writes nothing" {
    var s: State = .press(300, 200);
    const r = s.end(.drag_end);
    try testing.expect(!r.state.isActive());
    try testing.expect(r.persist == null);
}

test "drag: a second press re-latches from the new width" {
    var s: State = .press(300, 200);
    _ = s.follow(350);
    s = .press(350, 250);
    try testing.expectEqual(@as(?i64, 260), s.widthAt(360));
}

test "drag: a motion inside the noise threshold does not move the edge" {
    var s: State = .press(404, 400);
    try testing.expect(s.follow(400) == null);
    try testing.expect(!s.began());
    try testing.expectEqual(@as(?i64, 390), s.follow(390));
}

test "drag: the width follows from the anchor, which moves with the edge" {
    var s: State = .press(404, 400);
    _ = s.follow(390);
    // The anchor follows the edge to where the width was set (390, width
    // 400). A motion to 390 asks for no change; another 60px left asks for
    // 340 - exactly the pointer's travel, not the press pixel's.
    var s2 = s;
    s2.reanchor();
    try testing.expectEqual(@as(?i64, 400), s2.widthAt(390));
    try testing.expectEqual(@as(?i64, 330), s2.widthAt(320));
    try testing.expect(s2.follow(340) == null);
    try testing.expect(s2.began());
}

test "drag: leaving the hit band stops the follow until the pointer returns" {
    var s: State = .press(100, 100);
    try testing.expectEqual(@as(?i64, 40), s.follow(40));
    // 90px away, back outside the band: the edge stays at 40.
    try testing.expectEqual(@as(?i64, 40), s.widthAt(130));
    s.reanchor();
    try testing.expect(s.follow(131) == null);
    try testing.expectEqual(@as(?i64, 50), s.follow(141));
}

test "drag: only release writes" {
    try testing.expect(End.release.writes());
    try testing.expect(!End.grab_broken.writes());
    try testing.expect(!End.pointer_leave.writes());
    try testing.expect(!End.drag_end.writes());
}
