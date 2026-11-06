//! The runtime writes to the user's config: the sidebar's width and the
//! window's size.
//!
//! Njuggle reads `~/.config/njuggle/config` and never writes it, with one
//! rule-amended exception: a user gesture (a drag, the `sidebar_resize`
//! keybinding, or simply closing a window) stores what the user chose so it
//! survives a restart. This module is the whole of those writes, and it is a
//! function over bytes so it can be tested without a file:
//!
//!   - the file's every other byte is carried through untouched, comments
//!     and blank lines included;
//!   - an existing key line has only its value replaced, its indentation and
//!     comment kept;
//!   - an absent key is INSERTED as exactly one new line at the end of the
//!     Njuggle-key block when that block can be found (the block between the
//!     default-off and default-on headers of the shipped template), else at
//!     the end of the file;
//!   - a commented-out `# gtk-sidebar-width = ...` line is not the key: it is
//!     left alone, and a real line is added beside it.
//!
//! A whole-file rewrite is what this exists to prevent: it loses the user's
//! comments, and a width or a window size is not worth that.
//!
//! Licence: AGPLv3 (njuggle).

const std = @import("std");

pub const key = "gtk-sidebar-width";

/// The key holding the window's last size, as `WIDTHxHEIGHT`.
pub const window_key = "window-size";

/// Where an insertion goes when the key is absent.
pub const InsertAt = struct {
    offset: usize,
    /// True when the offset is an end-of-file position and needs a
    /// terminating newline added before the new line.
    at_eof: bool,
};

/// The byte span of a key's value.
pub const Span = struct { start: usize, end: usize };

/// Find the one live (not commented) assignment of `k`.
///
/// Returns the byte span of the VALUE (trimmed of trailing blanks and the
/// line ending). A line counts only when the first non-blank character is
/// the key, so `# gtk-sidebar-width = 200` and `foo-gtk-sidebar-width` are
/// not matches, and neither is a longer key that merely starts with ours.
pub fn findKeyValue(text: []const u8, k: []const u8) ?Span {
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_start: usize = 0;
    while (it.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        const lead = std.mem.indexOfNone(u8, line, " \t") orelse line.len;
        if (lead < line.len and line[lead] != '#') {
            if (std.mem.startsWith(u8, line[lead..], k)) {
                const rest = line[lead + k.len ..];
                // A longer key that merely starts with ours is not ours.
                const longer = rest.len > 0 and (rest[0] == '-' or rest[0] == '_' or std.ascii.isAlphanumeric(rest[0]));
                if (!longer) {
                    const trimmed = std.mem.trimStart(u8, rest, " \t");
                    if (trimmed.len > 0 and trimmed[0] == '=') {
                        const value_raw = trimmed[1..];
                        const value_off = value_raw.len - std.mem.trimStart(u8, value_raw, " \t").len;
                        var value = value_raw[value_off..];
                        // A trailing `# comment` is not part of the value.
                        if (std.mem.indexOfScalar(u8, value, '#')) |hash| {
                            value = std.mem.trimEnd(u8, value[0..hash], " \t");
                        } else {
                            value = std.mem.trimEnd(u8, value, " \t");
                        }
                        const value_start = line_start + lead + k.len + (rest.len - trimmed.len) + 1 + value_off;
                        return .{ .start = value_start, .end = value_start + value.len };
                    }
                }
            }
        }
        line_start += raw_line.len + 1;
    }
    return null;
}

/// `gtk-sidebar-width`'s value span.
pub fn findValue(text: []const u8) ?Span {
    return findKeyValue(text, key);
}

/// Where a new line goes when the key is absent.
///
/// `block_marker` is the header line of the Njuggle-key block: the insert
/// lands after the last non-blank line of that block, which is the last line
/// before the next section header (a line starting `# ---`).
pub fn insertPoint(text: []const u8, marker: []const u8) InsertAt {
    if (std.mem.indexOf(u8, text, marker)) |marker_at| {
        const after = text[marker_at + marker.len ..];
        const scan = std.mem.indexOfScalarPos(u8, after, 0, '\n') orelse return eofPoint(text);
        var end_of_block: usize = marker_at + marker.len + scan;
        var line_start = marker_at + marker.len + scan + 1;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            const line = std.mem.trimEnd(u8, text[line_start..line_end], " \t\r");
            if (std.mem.startsWith(u8, line, "# ---")) {
                return .{ .offset = end_of_block + 1, .at_eof = false };
            }
            if (line.len > 0) end_of_block = line_end;
            if (line_end >= text.len) break;
            line_start = line_end + 1;
        }
        return .{ .offset = end_of_block + 1, .at_eof = end_of_block + 1 > text.len };
    }
    return eofPoint(text);
}

fn eofPoint(text: []const u8) InsertAt {
    return .{ .offset = text.len, .at_eof = text.len != 0 and text[text.len - 1] != '\n' };
}

/// The single-key edit: `text` with `k` set to `value`. Caller owns the
/// returned bytes.
pub fn setKey(
    alloc: std.mem.Allocator,
    text: []const u8,
    k: []const u8,
    value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    if (findKeyValue(text, k)) |span| {
        try buf.appendSlice(alloc, text[0..span.start]);
        try buf.appendSlice(alloc, value);
        try buf.appendSlice(alloc, text[span.end..]);
        return buf.toOwnedSlice(alloc);
    }

    const point = insertPoint(text, block_marker);
    try buf.appendSlice(alloc, text[0..point.offset]);
    if (point.at_eof) try buf.append(alloc, '\n');
    try buf.appendSlice(alloc, k);
    try buf.appendSlice(alloc, " = ");
    try buf.appendSlice(alloc, value);
    try buf.append(alloc, '\n');
    try buf.appendSlice(alloc, text[point.offset..]);
    return buf.toOwnedSlice(alloc);
}

/// The single-key edit for `gtk-sidebar-width`.
pub fn upsert(
    alloc: std.mem.Allocator,
    text: []const u8,
    width: u16,
) ![]u8 {
    var num_buf: [8]u8 = undefined;
    const num = try std.fmt.bufPrint(&num_buf, "{d}", .{width});
    return setKey(alloc, text, key, num);
}

/// The window size edit, as `window-size = WIDTHxHEIGHT`.
pub fn upsertWindowSize(
    alloc: std.mem.Allocator,
    text: []const u8,
    width: u16,
    height: u16,
) ![]u8 {
    var num_buf: [24]u8 = undefined;
    const value = try std.fmt.bufPrint(&num_buf, "{d}x{d}", .{ width, height });
    return setKey(alloc, text, window_key, value);
}

/// The header line the shipped template opens its default-on block with.
pub const block_marker = "# --- Njuggle-only options";

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "findValue: a live assignment, with spaces around the equals" {
    const t = "theme = dark\ngtk-sidebar-width = 240\n";
    const span = findValue(t).?;
    try testing.expectEqualStrings("240", t[span.start..span.end]);
}

test "findValue: a commented line is not the key" {
    const t = "# gtk-sidebar-width = 240\n";
    try testing.expect(findValue(t) == null);
}

test "findValue: a longer key that starts with ours is not the key" {
    const t = "gtk-sidebar-width-px = 240\n";
    try testing.expect(findValue(t) == null);
}

test "findValue: a real key after a longer one is still found" {
    const t = "gtk-sidebar-width-px = 240\ngtk-sidebar-width = 180\n";
    const span = findValue(t).?;
    try testing.expectEqualStrings("180", t[span.start..span.end]);
}

test "findValue: a trailing comment is not part of the value" {
    const t = "gtk-sidebar-width = 240 # narrow\n";
    const span = findValue(t).?;
    try testing.expectEqualStrings("240", t[span.start..span.end]);
}

test "findValue: CRLF files are read the same way" {
    const t = "gtk-sidebar-width = 180\r\n";
    const span = findValue(t).?;
    try testing.expectEqualStrings("180", t[span.start..span.end]);
}

test "upsert: an existing key has only its value replaced" {
    const alloc = testing.allocator;
    const t =
        \\# my config
        \\theme = catppuccin-mocha
        \\
        \\gtk-sidebar-width = 200   # tuned by hand
        \\font-size = 13
        \\
    ;
    const out = try upsert(alloc, t, 260);
    defer alloc.free(out);
    try testing.expectEqualStrings(
        \\# my config
        \\theme = catppuccin-mocha
        \\
        \\gtk-sidebar-width = 260   # tuned by hand
        \\font-size = 13
        \\
    , out);
}

test "upsert: an absent key is inserted into the Njuggle block" {
    const alloc = testing.allocator;
    const t =
        \\# top
        \\theme = dark
        \\# --- Njuggle-only options: ON unless you turn them off ----------
        \\# gtk-sidebar-status-icon = true
        \\# gtk-sidebar-status-after = 5s
        \\
        \\# --- Look and feel ------------------------------------------------------
        \\# font-size = 12
        \\
    ;
    const out = try upsert(alloc, t, 220);
    defer alloc.free(out);
    try testing.expectEqualStrings(
        \\# top
        \\theme = dark
        \\# --- Njuggle-only options: ON unless you turn them off ----------
        \\# gtk-sidebar-status-icon = true
        \\# gtk-sidebar-status-after = 5s
        \\gtk-sidebar-width = 220
        \\
        \\# --- Look and feel ------------------------------------------------------
        \\# font-size = 12
        \\
    , out);
}

test "upsert: the FLOOR value is written like any other (F-D6)" {
    const alloc = testing.allocator;
    const t = "gtk-sidebar-width = 300\n";
    const out = try upsert(alloc, t, 100);
    defer alloc.free(out);
    try testing.expectEqualStrings("gtk-sidebar-width = 100\n", out);
}

test "upsert: the MAXIMUM value is written like any other (F-D6)" {
    const alloc = testing.allocator;
    const t = "gtk-sidebar-width = 300\n";
    const out = try upsert(alloc, t, 1000);
    defer alloc.free(out);
    try testing.expectEqualStrings("gtk-sidebar-width = 1000\n", out);
}

test "upsert: no block, no trailing newline: one line appended" {
    const alloc = testing.allocator;
    const t = "theme = dark";
    const out = try upsert(alloc, t, 150);
    defer alloc.free(out);
    try testing.expectEqualStrings("theme = dark\ngtk-sidebar-width = 150\n", out);
}

test "upsert: an empty file gains exactly one line" {
    const alloc = testing.allocator;
    const out = try upsert(alloc, "", 200);
    defer alloc.free(out);
    try testing.expectEqualStrings("gtk-sidebar-width = 200\n", out);
}

test "upsert: every other byte survives, measured" {
    const alloc = testing.allocator;
    const t =
        \\# comment one
        \\
        \\keybind = ctrl+shift+t=new_tab
        \\#gtk-sidebar-width=1
        \\window-theme = ghostty
        \\
    ;
    const out = try upsert(alloc, t, 333);
    defer alloc.free(out);
    const inserted = "gtk-sidebar-width = 333\n";
    const at = std.mem.indexOf(u8, out, inserted).?;
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(alloc);
    try stripped.appendSlice(alloc, out[0..at]);
    try stripped.appendSlice(alloc, out[at + inserted.len ..]);
    try testing.expectEqualStrings(t, stripped.items);
}

test "upsert: a second run replaces its own line, it does not add another" {
    const alloc = testing.allocator;
    const once = try upsert(alloc, "# c\ntheme = dark\n", 210);
    defer alloc.free(once);
    const twice = try upsert(alloc, once, 250);
    defer alloc.free(twice);
    try testing.expectEqualStrings("# c\ntheme = dark\ngtk-sidebar-width = 250\n", twice);
}

test "window size: a new key lands beside the width, comments intact" {
    const alloc = testing.allocator;
    const t = "# mine\ngtk-sidebar-width = 300\n";
    const out = try upsertWindowSize(alloc, t, 900, 640);
    defer alloc.free(out);
    try testing.expectEqualStrings("# mine\ngtk-sidebar-width = 300\nwindow-size = 900x640\n", out);
}

test "window size: a second save replaces the first" {
    const alloc = testing.allocator;
    const once = try upsertWindowSize(alloc, "# mine\n", 900, 640);
    defer alloc.free(once);
    const twice = try upsertWindowSize(alloc, once, 1024, 768);
    defer alloc.free(twice);
    try testing.expectEqualStrings("# mine\nwindow-size = 1024x768\n", twice);
}

test "window size: the key does not match a longer name" {
    const t = "window-size-hint = 5\n";
    try testing.expect(findKeyValue(t, window_key) == null);
}
