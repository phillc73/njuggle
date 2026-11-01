//! What the sidebar status indicator needs to know that the plain status
//! state does not say: which colour a state shows, and which of the three
//! loaded textures `syncStatus` puts on the widget.
//!
//! The image files are read here and not only their names because a
//! name-level mapping passes with any artwork swapped underneath: green
//! indexed as grey is still "green" by filename. The grey plane is what
//! separates the three owner-supplied sets.
const std = @import("std");
const tab_status = @import("tab_status.zig");

/// The colour a state shows. The one mapping; the config docs, the ledger and
/// the tests all read it from here.
pub fn colour(state: tab_status.State) []const u8 {
    return switch (state) {
        .idle => "grey",
        .running => "green",
        .needs_attention => "red",
    };
}

/// Which entry of the row's `status_states` texture list carries this state.
/// The list is loaded in its own order and only its order means anything to
/// the row, so the index is a search, not a switch with three cases to keep
/// in step by hand: a list that loses a state trips the assert instead of
/// silently showing the wrong colour for it.
pub fn textureIndex(comptime states: []const tab_status.State, state: tab_status.State) usize {
    for (states, 0..) |s, i| {
        if (s == state) return i;
    }
    @panic("textureIndex: the status texture list has no entry for a state it must show");
}

/// A 64x64 RGB PNG as 8-bit channels, rows top to bottom, no alpha.
pub const Pixels = struct {
    width: u32,
    height: u32,
    rgb: []const u8,
};

/// Decode the subset of PNG the status artwork uses: 8-bit, RGB or RGBA,
/// non-interlaced, all filters. Anything else is a load error, not a guess.
pub fn decodeRgb(alloc: std.mem.Allocator, bytes: []const u8) !Pixels {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.NotPng;

    var at: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var channels: usize = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(alloc);

    while (at + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
        const kind = bytes[at + 4 ..][0..4];
        const data = bytes[at + 8 ..][0..len];
        if (data.len != len) return error.Truncated;
        at += 12 + len;

        if (std.mem.eql(u8, kind, "IHDR")) {
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8) return error.UnsupportedBitDepth;
            channels = switch (data[9]) {
                2 => 3,
                6 => 4,
                else => return error.UnsupportedColourType,
            };
            if (data[12] != 0) return error.Interlaced;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(alloc, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }

    const stride = @as(usize, width) * channels;
    const raw = try alloc.alloc(u8, (stride + 1) * height);
    defer alloc.free(raw);

    // Inflate the zlib stream into a fixed writer sized from IHDR. The
    // decoder needs no window buffer of its own when the output is fixed.
    var in: std.Io.Reader = .fixed(idat.items);
    var writer: std.Io.Writer = .fixed(raw);
    var dec: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    _ = dec.reader.streamRemaining(&writer) catch return error.Truncated;

    return unfilterRgb(alloc, raw, width, height, channels);
}

/// Undo the per-row PNG filters and drop alpha. `raw` holds the inflated
/// zlib payload: one filter byte then `width * channels` bytes per row.
pub fn unfilterRgb(
    alloc: std.mem.Allocator,
    raw: []u8,
    width: u32,
    height: u32,
    channels: usize,
) !Pixels {
    const stride = @as(usize, width) * channels;
    if (raw.len != (stride + 1) * height) return error.Truncated;

    const rgb = try alloc.alloc(u8, @as(usize, width) * height * 3);
    errdefer alloc.free(rgb);

    const bpp: usize = channels;
    var prev: []u8 = &[_]u8{};
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const line = raw[row * (stride + 1) ..][0..(stride + 1)];
        const filter = line[0];
        const out = raw[row * (stride + 1) + 1 ..][0..stride];

        // The previous row's ALREADY FILTERED bytes, per the PNG spec.
        var i: usize = 0;
        while (i < stride) : (i += 1) {
            const a: u8 = if (i >= bpp) out[i - bpp] else 0;
            const b: u8 = if (prev.len != 0) prev[i] else 0;
            const c: u8 = if (i >= bpp and prev.len != 0) prev[i - bpp] else 0;
            out[i] = switch (filter & 7) {
                0 => out[i],
                1 => out[i] +% a,
                2 => out[i] +% b,
                3 => out[i] +% @as(u8, @truncate((@as(u16, a) + @as(u16, b)) / 2)),
                4 => out[i] +% paeth(a, b, c),
                else => return error.BadFilter,
            };
        }
        prev = out;

        var x: usize = 0;
        while (x < width) : (x += 1) {
            const src = x * channels;
            const dst = (row * width + x) * 3;
            rgb[dst] = out[src];
            rgb[dst + 1] = out[src + 1];
            rgb[dst + 2] = out[src + 2];
        }
    }

    return .{ .width = width, .height = height, .rgb = rgb };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + @as(i16, b) - @as(i16, c);
    const pa = @abs(p - @as(i16, a));
    const pb = @abs(p - @as(i16, b));
    const pc = @abs(p - @as(i16, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}


/// What an icon says about itself, measured rather than named. The owner's
/// artwork is one horse mark recoloured per state, so the colour is read from
/// which channel a large area of the image is made of, not from the filename
/// the image happens to be filed under.
pub const Fingerprint = struct {
    /// Pixels of a mostly-neutral colour that is not near black (the mark's
    /// linework, and the whole idle image).
    neutral: u32 = 0,
    /// Pixels saturated enough to carry a state colour, per dominant channel.
    red: u32 = 0,
    green: u32 = 0,
    blue: u32 = 0,
};

/// Saturated means max-min above this: the owner's red is (237,28,36), the
/// green (5,222,78), both far past it; linework and shading are within it.
const saturated_spread: u8 = 80;
/// "Not near black": the images carry a dark outline, and a near-black pixel
/// is neither linework nor colour.
const near_black: u8 = 40;

pub fn fingerprint(p: Pixels) Fingerprint {
    std.debug.assert(p.rgb.len == @as(usize, p.width) * p.height * 3);
    var f: Fingerprint = .{};
    var i: usize = 0;
    while (i < p.rgb.len) : (i += 3) {
        const r = p.rgb[i];
        const g = p.rgb[i + 1];
        const b = p.rgb[i + 2];
        const max = @max(r, @max(g, b));
        if (max <= near_black) continue;
        const spread = max - @min(r, @min(g, b));

        if (spread > saturated_spread) {
            // Ties (a colour exactly between two channels) count for neither:
            // no state colour is a tie.
            const winners = @as(u8, @intFromBool(r == max)) +
                @intFromBool(g == max) +
                @intFromBool(b == max);
            if (winners != 1) continue;
            if (r == max) f.red += 1;
            if (g == max) f.green += 1;
            if (b == max) f.blue += 1;
        } else {
            f.neutral += 1;
        }
    }
    return f;
}

/// The state an image's colours make it, or null when the image is
/// monochrome and has no state colour but idle's.
///
/// A state colour must hold at least one percent of the image: every pixel is
/// one classification or another, and the mark is a thin line drawing.
pub fn stateOf(f: Fingerprint) ?tab_status.State {
    const total: u64 = @as(u64, f.neutral) + f.red + f.green + f.blue;
    const floor = total / 100;

    if (f.red > floor and f.red > f.green and f.red > f.blue) return .needs_attention;
    if (f.green > floor and f.green > f.red and f.green > f.blue) return .running;
    // Blue is the idle mark as shipped (the neutral set is drawn in a blue
    // that is near-grey to the eye but not on the channels).
    if (f.blue > floor) return .idle;
    if (f.neutral > floor) return .idle;
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "colour: the state to colour mapping, named once" {
    try testing.expectEqualStrings("grey", colour(.idle));
    try testing.expectEqualStrings("green", colour(.running));
    try testing.expectEqualStrings("red", colour(.needs_attention));
}

const status_list = [_]tab_status.State{ .running, .needs_attention, .idle };

test "textureIndex: every state resolves to an entry carrying its own colour" {
    try testing.expectEqual(@as(usize, 0), textureIndex(&status_list, .running));
    try testing.expectEqual(@as(usize, 1), textureIndex(&status_list, .needs_attention));
    try testing.expectEqual(@as(usize, 2), textureIndex(&status_list, .idle));

    inline for (.{ .running, .needs_attention, .idle }) |state| {
        try testing.expectEqualStrings(colour(state), colour(status_list[textureIndex(&status_list, state)]));
    }
}

/// The artwork file for a colour, resolved from the source tree. Tests read
/// the repository, so they run with the repository root as the cwd.
fn statusIconPath(alloc: std.mem.Allocator, c: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "images/status/{s}/64.png", .{c});
}

/// Read an artwork file. The tests run both standalone (`zig test`) and under
/// the build's test runner, which owns the process's Io; this opens a
/// process-local one, so the read does not depend on which.
fn statusIconBytes(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    return r.interface.allocRemaining(alloc, .limited(1 << 20));
}

test "artwork: each icon decodes to its own state's colour" {
    const alloc = testing.allocator;
    inline for ([_]tab_status.State{ .running, .needs_attention, .idle }) |state| {
        const path = try statusIconPath(alloc, colour(state));
        defer alloc.free(path);
        const bytes = try statusIconBytes(alloc, path);
        defer alloc.free(bytes);

        const pixels = try decodeRgb(alloc, bytes);
        defer alloc.free(pixels.rgb);
        try testing.expectEqual(@as(u32, 64), pixels.width);
        try testing.expectEqual(@as(u32, 64), pixels.height);

        try testing.expectEqual(@as(?tab_status.State, state), stateOf(fingerprint(pixels)));
    }
}

test "artwork: the idle image is the mark's neutral rendering" {
    const alloc = testing.allocator;
    const bytes = try statusIconBytes(alloc, "images/status/grey/64.png");
    defer alloc.free(bytes);
    const pixels = try decodeRgb(alloc, bytes);
    defer alloc.free(pixels.rgb);
    const f = fingerprint(pixels);
    try testing.expectEqual(@as(?tab_status.State, .idle), stateOf(f));
    try testing.expect(f.neutral > pixels.width * pixels.height / 10);
    try testing.expectEqual(@as(u32, 0), f.red);
    try testing.expectEqual(@as(u32, 0), f.green);
    try testing.expectEqual(@as(u32, 0), f.blue);
}

test "artwork: the three images are different, so a swapped index is visible" {
    const alloc = testing.allocator;
    var prints: [3]Fingerprint = undefined;
    inline for ([_]tab_status.State{ .running, .needs_attention, .idle }, 0..) |state, i| {
        const path = try statusIconPath(alloc, colour(state));
        defer alloc.free(path);
        const bytes = try statusIconBytes(alloc, path);
        defer alloc.free(bytes);
        const pixels = try decodeRgb(alloc, bytes);
        defer alloc.free(pixels.rgb);
        prints[i] = fingerprint(pixels);
    }
    // Every pair differs in where its colour sits.
    try testing.expect(prints[0].green != prints[1].green);
    try testing.expect(prints[1].red != prints[0].red);
    try testing.expect(prints[2].neutral != prints[0].neutral);
}

test "fingerprint: a red-dominant pixel counts red, its reverse counts green" {
    const red = [_]u8{ 237, 28, 36 };
    const green = [_]u8{ 5, 222, 78 };
    const px: Pixels = .{ .width = 2, .height = 1, .rgb = &red ++ &green };
    const f = fingerprint(px);
    try testing.expectEqual(@as(u32, 1), f.red);
    try testing.expectEqual(@as(u32, 1), f.green);
    try testing.expectEqual(@as(u32, 0), f.blue);
}
