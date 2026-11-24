//! The runtime writes to the user's config, one key at a time: the sidebar's
//! width and the window's size.
//!
//! Njuggle reads `~/.config/njuggle/config` and rarely writes it, by rule:
//! a user resize gesture (a drag, or the `sidebar_resize` keybinding) stores
//! the chosen width, and closing a window stores its size, so both survive a
//! restart. This module is the whole of those writes, and it is a function
//! over bytes so it can be tested without a file:
//!
//!   - the file's every other byte is carried through untouched, comments
//!     and blank lines included;
//!   - an existing `key = value` line has only its value replaced, its
//!     indentation and comment kept;
//!   - an absent key is INSERTED as exactly one new line at the end of the
//!     Njuggle-key block when that block can be found (the block between the
//!     default-off and default-on headers of the shipped template), else at
//!     the end of the file;
//!   - a commented-out `# key = ...` line is not the key: it is left alone,
//!     and a real line is added beside it.
//!
//! A whole-file rewrite is what this exists to prevent: it loses the user's
//! comments, and neither key is worth that.
//!
//! Licence: AGPLv3 (njuggle).

const std = @import("std");

pub const key = "gtk-sidebar-width";

/// Where an insertion goes when the key is absent.
pub const InsertAt = struct {
    offset: usize,
    /// True when the offset is an end-of-file position and needs a
    /// terminating newline added before the new line.
    at_eof: bool,
};

/// The byte span of an assignment's value.
pub const Span = struct { start: usize, end: usize };

/// Find the one live (not commented) assignment of this module's key.
pub fn findValue(text: []const u8) ?Span {
    return findValueOf(text, key);
}

/// Find the one live (not commented) assignment of any key.
///
/// Returns the byte span of the VALUE (trimmed of trailing blanks and the
/// line ending). A line counts only when the first non-blank character is
/// the key, so `# gtk-sidebar-width = 200` and `foo-gtk-sidebar-width` are
/// not matches.
pub fn findValueOf(text: []const u8, name: []const u8) ?Span {
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_start: usize = 0;
    while (it.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        const lead = std.mem.indexOfNone(u8, line, " \t") orelse line.len;
        if (lead < line.len and line[lead] != '#') {
            if (std.mem.startsWith(u8, line[lead..], name)) {
                const rest = line[lead + name.len ..];
                const trimmed = std.mem.trimStart(u8, rest, " \t");
                if (trimmed.len > 0 and trimmed[0] == '=') {
                    const value_raw = trimmed[1..];
                    const value_off = value_raw.len - std.mem.trimStart(u8, value_raw, " \t").len;
                    var value = value_raw[value_off..];
                    // A trailing `# comment` is not part of the value.
                    if (std.mem.indexOfScalar(u8, value, '#')) |hash| {
                        value = std.mem.trimEnd(u8, value[0..hash], " \t");
                        if (value.len == 0) value = "";
                    } else {
                        value = std.mem.trimEnd(u8, value, " \t");
                    }
                    const value_start = line_start + lead + name.len + (rest.len - trimmed.len) + 1 + value_off;
                    return .{ .start = value_start, .end = value_start + value.len };
                }
            }
        }
        line_start += raw_line.len + 1;
    }
    return null;
}

/// Where a new line goes when the key is absent.
///
/// `block_marker` is the header line of the Njuggle-key block: the insert
/// lands after the last non-blank line of that block, which is the last line
/// before the next section header (a line starting `# ---`).
pub fn insertPoint(text: []const u8, marker: []const u8) InsertAt {
    if (std.mem.indexOf(u8, text, marker)) |marker_at| {
        // Find the next section header after the block's own; the block ends
        // at the last non-blank line before it.
        const after = text[marker_at + marker.len ..];
        const scan = std.mem.indexOfScalarPos(u8, after, 0, '\n') orelse return eofPoint(text);
        var end_of_block: usize = marker_at + marker.len + scan;
        var line_start = marker_at + marker.len + scan + 1;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            const line = std.mem.trimEnd(u8, text[line_start..line_end], " \t\r");
            if (std.mem.startsWith(u8, line, "# ---")) {
                // The block ended on the previous non-blank line.
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

/// The single-key edit: `text` with `gtk-sidebar-width` set to `width`.
/// Caller owns the returned bytes.
pub fn upsert(
    alloc: std.mem.Allocator,
    text: []const u8,
    width: u16,
) ![]u8 {
    var num_buf: [8]u8 = undefined;
    const num = try std.fmt.bufPrint(&num_buf, "{d}", .{width});
    return upsertValue(alloc, text, key, num);
}

/// The same edit for any key: `text` with `name` set to `value`. This is what
/// the window's size goes through; the file is only ever edited one key at a
/// time, so the rules above hold for every key alike.
pub fn upsertValue(
    alloc: std.mem.Allocator,
    text: []const u8,
    name: []const u8,
    value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    if (findValueOf(text, name)) |span| {
        try buf.appendSlice(alloc, text[0..span.start]);
        try buf.appendSlice(alloc, value);
        try buf.appendSlice(alloc, text[span.end..]);
        return buf.toOwnedSlice(alloc);
    }

    const point = insertPoint(text, block_marker);
    try buf.appendSlice(alloc, text[0..point.offset]);
    // The insert lands at the start of a line (or at end of file), so the
    // new line needs no leading separator unless the file needs a final
    // newline first.
    if (point.at_eof) try buf.append(alloc, '\n');
    try buf.appendSlice(alloc, name);
    try buf.appendSlice(alloc, " = ");
    try buf.appendSlice(alloc, value);
    try buf.append(alloc, '\n');
    try buf.appendSlice(alloc, text[point.offset..]);
    return buf.toOwnedSlice(alloc);
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

test "findValue: a longer key that ends with ours is not the key" {
    const t = "gtk-sidebar-width-px = 240\n";
    try testing.expect(findValue(t) == null);
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
    // Removing the inserted line must give back the original byte for byte.
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
