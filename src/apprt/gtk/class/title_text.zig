//! The default title both title closures fall back to.
//!
//! A new tab's title is the shell's title once the shell sets one, so the
//! fallback is only ever visible for the moment before that - a flash on
//! every new tab. The choice of what that flash says lives here rather than
//! in two GTK closures so it is tested once and cannot drift between the tab
//! row and the window title bar.
//!
//! Precedence: `title` set by the user wins (a user who pins a title asked for
//! it to be shown), otherwise the app name. Blank is not a title: the user
//! who wants no title sets one or more spaces (see `Config.title`).

const std = @import("std");

/// The app name shown before the shell has set a title.
pub const app_name = "Njuggle";

/// The fallback: the user's pinned title, else the app name.
///
/// `title` is the config value, untrimmed. An empty or all-space value counts
/// as unset, because a window titled "   " reads as a rendering fault rather
/// than a choice; the documented way to hide a title is spaces, so the tab row
/// honours it by showing nothing, and this returns an empty slice for that.
pub fn computeTitle(title: ?[:0]const u8) []const u8 {
    const raw: []const u8 = if (title) |t| t else return app_name;
    if (raw.len == 0) return app_name;
    for (raw) |c| {
        if (c != ' ' and c != '\t') return raw;
    }
    return raw;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "no config title: the app name" {
    try testing.expectEqualStrings("Njuggle", computeTitle(null));
}

test "empty config title: the app name" {
    try testing.expectEqualStrings("Njuggle", computeTitle(""));
}

test "all-space config title is kept: hiding a title stays possible" {
    try testing.expectEqualStrings(" ", computeTitle(" "));
    try testing.expectEqualStrings("   ", computeTitle("   "));
}

test "a set config title wins" {
    try testing.expectEqualStrings("work", computeTitle("work"));
}

test "a title with surrounding spaces is kept as written" {
    try testing.expectEqualStrings(" work ", computeTitle(" work "));
}
