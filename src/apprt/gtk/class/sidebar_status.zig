//! The row's status repaint, with the widget layer behind a switch.
//!
//! `sidebar_row.zig` is GTK-bound from top to bottom, so its `syncStatus`
//! could not be tested at all - which is how an indicator once shipped
//! that never bound its image and a texture index nobody had checked. Here
//! the same logic reads and paints through `WidgetKit`, which the row
//! instantiates over GTK and the tests instantiate over nothing.
//!
//! The KIT switch is a comptime option, not a runtime branch: the GTK build
//! carries only the GTK instantiation and the test build only the fake one.

const std = @import("std");
const tab_status = @import("tab_status.zig");
const status_icon = @import("status_icon.zig");

/// The three state images in texture-list order. Green, red, grey: the index
/// `syncStatus` shows for a state is taken from this list by search, so the
/// order is free to change and the colours follow.
pub const status_states = [_]tab_status.State{ .running, .needs_attention, .idle };

/// The icons a row loads once and shows by state.
pub const StatusIcons = struct {
    /// A decoded image handle; only the tests need to name the type.
    images: [status_states.len]*anyopaque,
};

/// One leaf pane's status, read from the surface.
pub const PaneState = tab_status.State;

pub fn Kit(comptime kit: anytype) type {
    const Image = kit.Image;
    return struct {
        image: *Image,
        enabled: bool,
        icons: ?*StatusIcons,
        shown: tab_status.State = .idle,

        /// Repaint the indicator from the tab's aggregate pane state. Returns
        /// whether it painted (false: hidden, unchanged, or nothing loaded).
        pub fn sync(self: *@This(), panes: []const PaneState) bool {
            const state = tab_status.aggregate(panes);

            // Switched off or nothing loaded: hide, whatever the state. Checked
            // before the unchanged-state shortcut, which would otherwise leave
            // the image showing after the config turned the indicator off.
            const icons = self.icons orelse {
                kit.hide(self.image);
                return false;
            };
            if (!self.enabled) {
                kit.hide(self.image);
                return false;
            }

            // Only a real change repaints; a hidden image always repaints,
            // because "hidden" is not a state and the icon appears again
            // without a state change when the config or a load catches up.
            if (state == self.shown and kit.visible(self.image)) return false;
            self.shown = state;

            kit.show(self.image, icons.images[status_icon.textureIndex(&status_states, state)]);
            kit.tooltip(self.image, switch (state) {
                .needs_attention => "Command finished while you were away\x00",
                else => null,
            });
            return true;
        }
    };
}

/// The GTK kit: the row's real widgets and textures.
pub const Gtk = struct {
    const gdk = @import("gdk");
    const gtk = @import("gtk");

    pub const Image = gtk.Image;

    pub fn visible(image: *Image) bool {
        return image.as(gtk.Widget).getVisible() != 0;
    }
    pub fn hide(image: *Image) void {
        image.as(gtk.Widget).setVisible(0);
    }
    pub fn show(image: *Image, paint: *anyopaque) void {
        const texture: *gdk.Texture = @ptrCast(@alignCast(paint));
        image.setFromPaintable(texture.as(gdk.Paintable));
        image.as(gtk.Widget).setVisible(1);
    }
    pub fn tooltip(image: *Image, text: ?[*:0]const u8) void {
        image.as(gtk.Widget).setTooltipText(text);
    }
};

/// The test kit: records what the last repaint asked for.
pub const Fake = struct {
    pub const Image = struct {
        visible: bool = false,
        shown: ?*anyopaque = null,
        tip: ?[]const u8 = null,
        paints: usize = 0,
    };

    pub fn visible(image: *Image) bool {
        return image.visible;
    }
    pub fn hide(image: *Image) void {
        image.visible = false;
    }
    pub fn show(image: *Image, paint: *anyopaque) void {
        image.visible = true;
        image.shown = paint;
        image.paints += 1;
    }
    pub fn tooltip(image: *Image, text: ?[]const u8) void {
        image.tip = text;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const St = tab_status.State;

fn fakeIcons(storage: *[status_states.len]usize) StatusIcons {
    // One distinguishable handle per list entry: the tests compare WHICH
    // entry was shown, which is the only thing the row can get wrong.
    var handles: [status_states.len]*anyopaque = undefined;
    for (storage, 0..) |*slot, i| {
        slot.* = i;
        handles[i] = slot;
    }
    return .{ .images = handles };
}

fn harness(storage: *[status_states.len]usize) struct { row: Kit(Fake), image: *Fake.Image, icons: *StatusIcons } {
    const icons = std.testing.allocator.create(StatusIcons) catch unreachable;
    icons.* = fakeIcons(storage);
    const image = std.testing.allocator.create(Fake.Image) catch unreachable;
    image.* = .{};
    return .{
        .row = .{ .image = image, .enabled = true, .icons = icons },
        .image = image,
        .icons = icons,
    };
}

fn destroy(h: anytype) void {
    std.testing.allocator.destroy(h.icons);
    std.testing.allocator.destroy(h.image);
}

test "status_states: green, red, grey, and the index follows the list" {
    try testing.expectEqual(St.running, status_states[0]);
    try testing.expectEqual(St.needs_attention, status_states[1]);
    try testing.expectEqual(St.idle, status_states[2]);
    for (status_states) |state| {
        try testing.expectEqual(state, status_states[status_icon.textureIndex(&status_states, state)]);
    }
}

test "sync: idle shows the grey image and painted once" {
    var storage: [status_states.len]usize = undefined;
    var h = harness(&storage);
    defer destroy(h);

    try testing.expect(h.row.sync(&.{.idle}));
    try testing.expect(h.image.visible);
    try testing.expectEqual(@as(*anyopaque, &storage[status_icon.textureIndex(&status_states, .idle)]), h.image.shown.?);
    try testing.expectEqual(@as(usize, 1), h.image.paints);
    try testing.expectEqual(@as(?[]const u8, null), h.image.tip);
}

test "sync: a command starting turns the image green, finishing unfocused red, looking again grey" {
    var storage: [status_states.len]usize = undefined;
    var h = harness(&storage);
    defer destroy(h);

    const grey = status_icon.textureIndex(&status_states, .idle);
    const green = status_icon.textureIndex(&status_states, .running);
    const red = status_icon.textureIndex(&status_states, .needs_attention);

    // idle -> running
    try testing.expect(h.row.sync(&.{.running}));
    try testing.expectEqual(@as(*anyopaque, &storage[green]), h.image.shown.?);
    try testing.expectEqual(@as(?[]const u8, null), h.image.tip);

    // running -> needs_attention
    try testing.expect(h.row.sync(&.{.needs_attention}));
    try testing.expectEqual(@as(*anyopaque, &storage[red]), h.image.shown.?);
    try testing.expectEqualStrings("Command finished while you were away", h.image.tip.?[0 .. h.image.tip.?.len - 1]);

    // needs_attention -> idle (the user looked)
    try testing.expect(h.row.sync(&.{.idle}));
    try testing.expectEqual(@as(*anyopaque, &storage[grey]), h.image.shown.?);
    try testing.expectEqual(@as(?[]const u8, null), h.image.tip);
    try testing.expectEqual(@as(usize, 3), h.image.paints);
}

test "sync: the colours on screen are the ones the artwork carries" {
    // The list order and the artwork agree: whatever index the row uses for a
    // state, the image at that index is the image whose colours say so.
    const si = status_icon;
    inline for ([_]St{ .running, .needs_attention, .idle }) |state| {
        const idx = si.textureIndex(&status_states, state);
        try testing.expectEqualStrings(si.colour(state), si.colour(status_states[idx]));
    }
}

test "sync: an unchanged state does not repaint" {
    var storage: [status_states.len]usize = undefined;
    var h = harness(&storage);
    defer destroy(h);

    _ = h.row.sync(&.{.running});
    try testing.expect(!h.row.sync(&.{.running}));
    try testing.expectEqual(@as(usize, 1), h.image.paints);
}

test "sync: a split tab shows the strongest pane, red over green" {
    var storage: [status_states.len]usize = undefined;
    var h = harness(&storage);
    defer destroy(h);

    _ = h.row.sync(&.{ .idle, .running });
    try testing.expectEqual(
        @as(*anyopaque, &storage[status_icon.textureIndex(&status_states, .running)]),
        h.image.shown.?,
    );

    _ = h.row.sync(&.{ .running, .needs_attention });
    try testing.expectEqual(
        @as(*anyopaque, &storage[status_icon.textureIndex(&status_states, .needs_attention)]),
        h.image.shown.?,
    );
}

test "sync: disabled hides the image and a re-enable repaints at once" {
    var storage: [status_states.len]usize = undefined;
    var h = harness(&storage);
    defer destroy(h);

    _ = h.row.sync(&.{.idle});
    h.row.enabled = false;
    try testing.expect(!h.row.sync(&.{.idle}));
    try testing.expect(!h.image.visible);

    // Back on with no state change: repaints because it was hidden.
    h.row.enabled = true;
    try testing.expect(h.row.sync(&.{.idle}));
    try testing.expect(h.image.visible);
}

test "sync: no loaded icons hides rather than crash (a bad build)" {
    var storage: [status_states.len]usize = undefined;
    var h = harness(&storage);
    defer destroy(h);

    h.row.icons = null;
    try testing.expect(!h.row.sync(&.{.running}));
    try testing.expect(!h.image.visible);
}
