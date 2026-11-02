//! Njuggle's own version, and the Ghostty release it is rebased on.
//!
//! Licence: AGPLv3 (njuggle).
//!
//! Why both, and why separate: Njuggle versions Njuggle. The Ghostty base is
//! metadata about the rebase, not part of Njuggle's version digits, so it
//! cannot drift the product version on every rebase. It still has to be
//! visible, because the built sitting on a 1.4.0 base is a different thing
//! from one on a later base. `+version` therefore reports
//! `0.1.0+ghostty.1.4.0`.
//!
//! See README "Lineage and attribution" and the version section of
//! the project documentation.
//!
//! The product version lives in `build.zig.zon`; the base lives in
//! `build.zig` (`ghostty_base_version`).

const std = @import("std");
const testing = std.testing;

/// What a build knows about its own version and its base.
pub const Identity = struct {
    /// Njuggle's version, from `build.zig.zon`.
    app: std.SemanticVersion,

    /// The Ghostty release this tree is rebased on, e.g. `1.4.0`.
    base: []const u8,

    /// The branch, or the tag's suffix, carried as the prerelease on a
    /// non-release build.
    pre: ?[]const u8 = null,

    /// Short commit hash, when git was available.
    build: ?[]const u8 = null,
};

/// The version Njuggle reports, in semver: `M.m.p[-pre][+build]`.
///
/// The base is deliberately absent. Folding `ghostty.1.4.0` into the build
/// metadata here would put the rebase cadence into the version semver
/// exposes to tooling; the base travels in `describe` instead, which is what
/// humans read.
pub fn appVersion(alloc: std.mem.Allocator, id: Identity) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.print("{d}.{d}.{d}", .{ id.app.major, id.app.minor, id.app.patch });
    if (id.pre) |pre| if (pre.len > 0) {
        try out.writer.print("-{s}", .{pre});
    };
    if (id.build) |build| if (build.len > 0) {
        try out.writer.print("+{s}", .{build});
    };

    return out.toOwnedSlice();
}

/// The full identity string, for `+version` and logs:
/// `0.1.0+ghostty.1.4.0`, or with the pre-release on a non-release build
/// `0.1.0-fix-build7-findings+ghostty.1.4.0.<commit>`.
///
/// The base is carried as build metadata after `ghostty.`, so it names
/// itself rather than looking like a second product version.
pub fn describe(alloc: std.mem.Allocator, id: Identity) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.print("{d}.{d}.{d}", .{ id.app.major, id.app.minor, id.app.patch });
    if (id.pre) |pre| if (pre.len > 0) {
        try out.writer.print("-{s}", .{pre});
    };

    try out.writer.print("+ghostty.{s}", .{id.base});
    if (id.build) |build| if (build.len > 0) {
        try out.writer.print(".{s}", .{build});
    };

    return out.toOwnedSlice();
}

/// The tag a release of this version carries: `v0.1.0`.
pub fn releaseTag(alloc: std.mem.Allocator, app: std.SemanticVersion) ![]const u8 {
    return std.fmt.allocPrint(alloc, "v{d}.{d}.{d}", .{ app.major, app.minor, app.patch });
}

test "appVersion: release carries no base" {
    const alloc = testing.allocator;
    const v = try appVersion(alloc, .{
        .app = .{ .major = 0, .minor = 1, .patch = 0 },
        .base = "1.4.0",
    });
    defer alloc.free(v);
    try testing.expectEqualStrings("0.1.0", v);
}

test "describe: release names the base" {
    const alloc = testing.allocator;
    const v = try describe(alloc, .{
        .app = .{ .major = 0, .minor = 1, .patch = 0 },
        .base = "1.4.0",
    });
    defer alloc.free(v);
    try testing.expectEqualStrings("0.1.0+ghostty.1.4.0", v);
}

test "describe: branch build keeps pre and commit after the base" {
    const alloc = testing.allocator;
    const id: Identity = .{
        .app = .{ .major = 0, .minor = 1, .patch = 0 },
        .base = "1.4.0",
        .pre = "fix-build7-findings",
        .build = "abc1234",
    };
    const v = try describe(alloc, id);
    defer alloc.free(v);
    try testing.expectEqualStrings("0.1.0-fix-build7-findings+ghostty.1.4.0.abc1234", v);

    const plain = try appVersion(alloc, id);
    defer alloc.free(plain);
    try testing.expectEqualStrings("0.1.0-fix-build7-findings+abc1234", plain);
}

test "describe: the base never becomes the version digits" {
    const alloc = testing.allocator;
    const v = try describe(alloc, .{
        .app = .{ .major = 0, .minor = 1, .patch = 0 },
        .base = "1.4.0",
    });
    defer alloc.free(v);
    try testing.expect(!std.mem.startsWith(u8, v, "1.4.0"));
    try testing.expect(std.mem.startsWith(u8, v, "0.1.0"));
}

test "describe: a later base does not move the version" {    var a_buf: [64]u8 = undefined;
    var b_buf: [64]u8 = undefined;

    const a = try std.fmt.bufPrint(&a_buf, "{s}+{s}", .{ "0.1.0", "ghostty.1.4.0" });
    const b = try std.fmt.bufPrint(&b_buf, "{s}+{s}", .{ "0.1.0", "ghostty.1.5.0" });

    const alloc = testing.allocator;
    const va = try describe(alloc, .{ .app = .{ .major = 0, .minor = 1, .patch = 0 }, .base = "1.4.0" });
    defer alloc.free(va);
    const vb = try describe(alloc, .{ .app = .{ .major = 0, .minor = 1, .patch = 0 }, .base = "1.5.0" });
    defer alloc.free(vb);

    try testing.expectEqualStrings(a, va);
    try testing.expectEqualStrings(b, vb);
    // The product version is the common prefix; only the base moved.
    try testing.expectEqualStrings("0.1.0", va[0..5]);
    try testing.expectEqualStrings("0.1.0", vb[0..5]);
}

test "appVersion: output parses as a semantic version" {
    const alloc = testing.allocator;
    const v = try appVersion(alloc, .{
        .app = .{ .major = 0, .minor = 1, .patch = 0 },
        .base = "1.4.0",
        .pre = "rc.1",
        .build = "abc1234",
    });
    defer alloc.free(v);
    const parsed = try std.SemanticVersion.parse(v);
    try testing.expectEqual(@as(usize, 0), parsed.major);
    try testing.expectEqual(@as(usize, 1), parsed.minor);
}

test "appVersion: pre without build, build without pre" {
    const alloc = testing.allocator;

    const pre_only = try appVersion(alloc, .{
        .app = .{ .major = 0, .minor = 1, .patch = 0 },
        .base = "1.4.0",
        .pre = "dev",
    });
    defer alloc.free(pre_only);
    try testing.expectEqualStrings("0.1.0-dev", pre_only);

    const build_only = try appVersion(alloc, .{
        .app = .{ .major = 0, .minor = 1, .patch = 0 },
        .base = "1.4.0",
        .build = "abc1234",
    });
    defer alloc.free(build_only);
    try testing.expectEqualStrings("0.1.0+abc1234", build_only);

    const empty = try appVersion(alloc, .{
        .app = .{ .major = 0, .minor = 1, .patch = 0 },
        .base = "1.4.0",
        .pre = "",
        .build = "",
    });
    defer alloc.free(empty);
    try testing.expectEqualStrings("0.1.0", empty);
}

test "releaseTag: the product version decides the tag" {
    const alloc = testing.allocator;
    const t = try releaseTag(alloc, .{ .major = 0, .minor = 1, .patch = 0 });
    defer alloc.free(t);
    try testing.expectEqualStrings("v0.1.0", t);
}

test "describe: exactly one build-metadata clause" {
    // Caught in the first build: the commit was appended after the base with
    // its own `+`, producing `0.1.0-x+abc+ghostty.1.4.0`. Semver allows one
    // `+`, and that string does not parse, so every consumer of the version
    // as a version would have broken.
    const alloc = testing.allocator;
    const v = try describe(alloc, .{
        .app = .{ .major = 0, .minor = 1, .patch = 0 },
        .base = "1.4.0",
        .pre = "fix-build7-findings",
        .build = "d6497c592",
    });
    defer alloc.free(v);

    var plus: usize = 0;
    for (v) |c| if (c == '+') {
        plus += 1;
    };
    try testing.expectEqual(@as(usize, 1), plus);

    // And it parses as a semantic version, with the base inside the
    // build metadata rather than in the digits.
    var buf: [128]u8 = undefined;
    const padded = try std.fmt.bufPrint(&buf, "{s}", .{v});
    const parsed = try std.SemanticVersion.parse(padded);
    try testing.expectEqual(@as(usize, 0), parsed.major);
    try testing.expectEqual(@as(usize, 1), parsed.minor);
    try testing.expectEqualStrings("fix-build7-findings", parsed.pre.?);
    try testing.expect(std.mem.indexOf(u8, parsed.build.?, "ghostty.1.4.0") != null);
}

test "describe: no trailing dot when there is no commit" {
    const alloc = testing.allocator;
    const v = try describe(alloc, .{
        .app = .{ .major = 0, .minor = 1, .patch = 0 },
        .base = "1.4.0",
    });
    defer alloc.free(v);
    try testing.expect(!std.mem.endsWith(u8, v, "."));
    try testing.expectEqualStrings("0.1.0+ghostty.1.4.0", v);
}
