//! The window's size as text: parsed from `window-size = WIDTHxHEIGHT`, and
//! formatted back. GTK-free and pure, so the parse is a unit test rather than
//! a launch (F-D9).
//!
//! Licence: AGPLv3 (njuggle).

const std = @import("std");
const sidebar_width = @import("sidebar_width.zig");

pub const key = "window-size";

pub const Size = struct { width: u16, height: u16 };

/// Parse `900x640`. Anything malformed is "no recorded size" (null), which
/// leaves the window at its own default rather than at a guessed size.
///
/// A trailing comment is not part of the value. The file's own writer keeps
/// such a comment (`window-size = 900x640 # last size`), so a config the app
/// itself has written can carry one back in; without this split the size
/// parsed as absent and the next launch opened at the default.
pub fn parse(text: []const u8) ?Size {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const value = std.mem.trimEnd(
        u8,
        t[0 .. std.mem.indexOfScalar(u8, t, '#') orelse t.len],
        " \t",
    );
    const x = std.mem.indexOfScalar(u8, value, 'x') orelse return null;
    const w = std.fmt.parseInt(u16, value[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u16, value[x + 1 ..], 10) catch return null;
    // A zero side is a degenerate window and a parse that half-worked.
    if (w == 0 or h == 0) return null;
    return .{ .width = w, .height = h };
}

pub fn format(buf: []u8, size: Size) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}x{d}", .{ size.width, size.height });
}

/// The size a window should open at, from the configured text: the recorded
/// size when it parses, and null when the key is absent or the text is
/// malformed. A bad value is never an error and never a guessed size - the
/// window keeps its own default, so a typo cannot brick a launch.
pub fn recorded(text: ?[]const u8) ?Size {
    return parse(text orelse return null);
}

/// The single-key edit: `text` with `window-size` set to `size`.
/// Caller owns the returned bytes.
pub fn upsert(
    alloc: std.mem.Allocator,
    text: []const u8,
    size: Size,
) ![]u8 {
    var buf: [24]u8 = undefined;
    const value = try format(&buf, size);
    return sidebar_width.upsertValue(alloc, text, key, value);
}

const testing = std.testing;

test "parse: a recorded size" {
    try testing.expectEqual(Size{ .width = 900, .height = 640 }, parse("900x640").?);
}

test "parse: surrounding blanks are not the value" {
    try testing.expectEqual(Size{ .width = 1200, .height = 800 }, parse(" 1200x800\n").?);
}

test "parse: malformed is no size, never a guessed one" {
    try testing.expect(parse("") == null);
    try testing.expect(parse("900") == null);
    try testing.expect(parse("axb") == null);
    try testing.expect(parse("0x640") == null);
    try testing.expect(parse("900x0") == null);
    try testing.expect(parse("900x640x2") == null);
}

test "parse: a trailing comment is not part of the value" {
    // The writer preserves a comment on the line (see the upsert test
    // below), so the parser has to read through it.
    try testing.expectEqual(Size{ .width = 900, .height = 640 }, parse("900x640 # comment").?);
    try testing.expectEqual(Size{ .width = 900, .height = 640 }, parse("900x640#comment").?);
    try testing.expectEqual(Size{ .width = 1200, .height = 800 }, parse("1200x800\t# tight\n").?);
    // A comment does not rescue a malformed value.
    try testing.expect(parse("900 # comment") == null);
    try testing.expect(parse("# 900x640") == null);
}

test "format: round-trips through parse" {
    var buf: [24]u8 = undefined;
    const s = try format(&buf, .{ .width = 1024, .height = 768 });
    try testing.expectEqualStrings("1024x768", s);
    try testing.expectEqual(Size{ .width = 1024, .height = 768 }, parse(s).?);
}

test "recorded: absent and malformed both mean the window's own default" {
    try testing.expect(recorded(null) == null);
    try testing.expect(recorded("") == null);
    for ([_][]const u8{ "900", "axb", "0x640", "900x", "x640" }) |bad| {
        try testing.expect(recorded(bad) == null);
    }
    try testing.expectEqual(Size{ .width = 900, .height = 640 }, recorded("900x640").?);
}

test "upsert: an absent key is inserted into the Njuggle block" {
    const alloc = testing.allocator;
    const t =
        \\# top
        \\theme = dark
        \\# --- Njuggle-only options: ON unless you turn them off ----------
        \\# gtk-sidebar-width = 200
        \\
        \\# --- Look and feel ------------------------------------------------------
        \\# font-size = 12
        \\
    ;
    const out = try upsert(alloc, t, .{ .width = 900, .height = 640 });
    defer alloc.free(out);
    try testing.expectEqualStrings(
        \\# top
        \\theme = dark
        \\# --- Njuggle-only options: ON unless you turn them off ----------
        \\# gtk-sidebar-width = 200
        \\window-size = 900x640
        \\
        \\# --- Look and feel ------------------------------------------------------
        \\# font-size = 12
        \\
    , out);
}

test "upsert: an existing key has only its value replaced" {
    const alloc = testing.allocator;
    const t = "font-size = 13\nwindow-size = 900x640 # last size\n";
    const out = try upsert(alloc, t, .{ .width = 1024, .height = 768 });
    defer alloc.free(out);
    try testing.expectEqualStrings("font-size = 13\nwindow-size = 1024x768 # last size\n", out);
}

test "upsert: a second run replaces its own line, it does not add another" {
    const alloc = testing.allocator;
    const once = try upsert(alloc, "# c\ntheme = dark\n", .{ .width = 900, .height = 640 });
    defer alloc.free(once);
    const twice = try upsert(alloc, once, .{ .width = 1000, .height = 700 });
    defer alloc.free(twice);
    try testing.expectEqualStrings(
        "# c\ntheme = dark\nwindow-size = 1000x700\n",
        twice,
    );
}

test "upsert: the written line parses back to the size written" {
    const alloc = testing.allocator;
    const size: Size = .{ .width = 1280, .height = 720 };
    const out = try upsert(alloc, "theme = dark\n", size);
    defer alloc.free(out);
    const span = sidebar_width.findValueOf(out, key).?;
    try testing.expectEqual(size, parse(out[span.start..span.end]).?);
}
