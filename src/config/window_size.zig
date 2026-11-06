//! The window's size as text: parsed from `window-size = WIDTHxHEIGHT`, and
//! formatted back. GTK-free and pure, so the parse is a unit test rather than
//! a launch (F-D9).
//!
//! Licence: AGPLv3 (njuggle).

const std = @import("std");

pub const Size = struct { width: u16, height: u16 };

/// Parse `900x640`. Anything malformed is "no recorded size" (null), which
/// leaves the window at its own default rather than at a guessed size.
pub fn parse(text: []const u8) ?Size {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const x = std.mem.indexOfScalar(u8, t, 'x') orelse return null;
    const w = std.fmt.parseInt(u16, t[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u16, t[x + 1 ..], 10) catch return null;
    // A zero side is a degenerate window and a parse that half-worked.
    if (w == 0 or h == 0) return null;
    return .{ .width = w, .height = h };
}

pub fn format(buf: []u8, size: Size) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}x{d}", .{ size.width, size.height });
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

test "format: round-trips through parse" {
    var buf: [24]u8 = undefined;
    const s = try format(&buf, .{ .width = 1024, .height = 768 });
    try testing.expectEqualStrings("1024x768", s);
    try testing.expectEqual(Size{ .width = 1024, .height = 768 }, parse(s).?);
}
