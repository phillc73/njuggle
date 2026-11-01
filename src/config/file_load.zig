const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.config);

// Njuggle reads its own config file, never Ghostty's. The parser is
// Ghostty's (unchanged); only the location differs. One path per platform,
// no legacy fallback chain: Njuggle has no pre-rename history to honour, and
// silently reading ~/.config/ghostty would reintroduce the shared-config
// problem this fork exists to avoid. See README "Configuration".

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
pub fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try internal_os.xdg.config(
        global.io(),
        alloc,
        &environ_map,
        .{ .subdir = "njuggle/config" },
    );
}

/// Preferred default path for the XDG home configuration file. There is
/// no legacy fallback in Njuggle: this is simply the default path.
/// Returned value must be freed by the caller.
pub fn preferredXdgPath(alloc: Allocator) ![]const u8 {
    return defaultXdgPath(alloc);
}

/// Default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn defaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config");
}

/// Preferred default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn preferredAppSupportPath(alloc: Allocator) ![]const u8 {
    return defaultAppSupportPath(alloc);
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    switch (builtin.target.os.tag) {
        .macos => {
            // macOS prefers the Application Support directory
            // if it exists.
            const app_support_path = try preferredAppSupportPath(alloc);
            const app_support_file = open(global.io(), app_support_path) catch {
                // Try the XDG path if it exists
                const xdg_path = try preferredXdgPath(alloc);
                const xdg_file = open(global.io(), xdg_path) catch {
                    // If neither file exists, use app support
                    alloc.free(xdg_path);
                    return app_support_path;
                };
                xdg_file.close(global.io());
                alloc.free(app_support_path);
                return xdg_path;
            };
            app_support_file.close(global.io());
            return app_support_path;
        },

        // All other platforms use XDG only
        else => return try preferredXdgPath(alloc),
    }
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
pub fn open(io: std.Io, path: []const u8) OpenFileError!std.Io.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.Io.Dir.openFileAbsolute(
        io,
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close(io);

    const stat = file.stat(io) catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}

// R1: Njuggle reads its own config and never Ghostty's. The test asserts on
// the produced path rather than on the constants, because the failure this
// guards against is a silent fallback chain reappearing.
test "defaultXdgPath points at the njuggle config" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const path = try defaultXdgPath(alloc);
    defer alloc.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "/njuggle/config"));
    try testing.expect(std.mem.indexOf(u8, path, "ghostty") == null);
}

test "preferredXdgPath has no ghostty fallback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const path = try preferredXdgPath(alloc);
    defer alloc.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "/njuggle/config"));
    try testing.expect(std.mem.indexOf(u8, path, "ghostty") == null);
}
