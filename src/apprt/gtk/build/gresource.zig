//! This file contains a binary helper that builds our gresource XML
//! file that we can then use with `glib-compile-resources`.
//!
//! This binary is expected to be run from the Ghostty source root.
//! Litmus test: `src/apprt/gtk` should exist relative to the pwd.

const std = @import("std");

const build_info = @import("info.zig");

/// The path to the Blueprint files. The folder structure is expected to be
/// `{version}/{name}.blp` where `version` is the major and minor
/// minimum adwaita version.
pub const ui_path = "src/apprt/gtk/ui";

/// The path to the CSS files.
pub const css_path = "src/apprt/gtk/css";

/// The possible icon sizes we'll embed into the gresource file.
/// If any size doesn't exist then it will be an error. We could
/// infer this completely from available files but we wouldn't be
/// able to error when they don't exist that way.
pub const icon_sizes: []const comptime_int = &.{ 16, 32, 128, 256, 512, 1024 };

/// The oldest libadwaita Ghostty supports. Individual blueprints can
/// require newer than this, never older, so the build checks the headers
/// against whichever of the two is higher.
pub const minimum_adwaita: struct { major: u16, minor: u16 } = .{
    .major = 1,
    .minor = 7,
};

/// The blueprint files that we will embed into the gresource file.
/// We can't look these up at runtime [easily] because we require the
/// compiled UI files as input. We can refactor this lator to maybe do
/// all of this automatically and ensure we have the right dependencies
/// setup in the build system.
///
/// These will be asserted to exist at runtime.
pub const blueprints: []const Blueprint = &.{
    .{ .major = 1, .minor = 0, .name = "imgui-widget" },
    .{ .major = 1, .minor = 0, .name = "inspector-widget" },
    .{ .major = 1, .minor = 0, .name = "key-state-overlay" },
    .{ .major = 1, .minor = 0, .name = "resize-overlay" },
    .{ .major = 1, .minor = 0, .name = "search-overlay" },
    .{ .major = 1, .minor = 0, .name = "split-tree" },
    .{ .major = 1, .minor = 0, .name = "split-tree-split" },
    .{ .major = 1, .minor = 0, .name = "surface" },
    .{ .major = 1, .minor = 0, .name = "surface-scrolled-window" },
    .{ .major = 1, .minor = 0, .name = "tab" },
    .{ .major = 1, .minor = 3, .name = "debug-warning" },
    .{ .major = 1, .minor = 3, .name = "surface-child-exited" },
    .{ .major = 1, .minor = 4, .name = "inspector-window" },
    .{ .major = 1, .minor = 4, .name = "window" },
    .{ .major = 1, .minor = 5, .name = "clipboard-confirmation-dialog" },
    .{ .major = 1, .minor = 5, .name = "close-confirmation-dialog" },
    .{ .major = 1, .minor = 5, .name = "command-palette" },
    .{ .major = 1, .minor = 5, .name = "config-errors-dialog" },
    .{ .major = 1, .minor = 5, .name = "title-dialog" },
    .{ .major = 1, .minor = 4, .name = "sidebar" },
    .{ .major = 1, .minor = 4, .name = "sidebar-row" },
    .{ .major = 1, .minor = 4, .name = "sidebar-pane-row" },
};

/// The sidebar status indicator's images, compiled into the binary.
///
/// Owner-supplied artwork for the three states, staged at
/// `images/status/{green,red,grey}/`. The directory names are fixed by
/// tab_status.zig (`assetColour`); 64 is the icon size drawn on a 2x row.
pub const status_icons = [_]struct { colour: []const u8, file: []const u8 }{
    .{ .colour = "green", .file = "images/status/green/64.png" },
    .{ .colour = "red", .file = "images/status/red/64.png" },
    .{ .colour = "grey", .file = "images/status/grey/64.png" },
};

/// Njuggle's own chrome artwork, embedded so the window icon resolves without
/// the install tree. `setIconName(bundle_id)` asks the icon theme for the app
/// id; a theme that never saw the hicolor install (a `zig build run`, a
/// scratch prefix, a machine where only the binary was copied) answers with
/// the default image, so the white waterhorse is carried inside the binary at
/// the theme's own locations for an application icon.
///
/// The files are the same ones the install step copies into hicolor, derived
/// from the master by `scripts/make-chrome-icons.janet`.
pub const chrome_icons = [_]struct { size: []const u8, file: []const u8 }{
    .{ .size = "512x512", .file = "images/njuggle/512.png" },
    .{ .size = "256x256", .file = "images/njuggle/256.png" },
    .{ .size = "128x128", .file = "images/njuggle/128.png" },
    .{ .size = "64x64", .file = "images/njuggle/64.png" },
    .{ .size = "32x32", .file = "images/njuggle/32.png" },
    // The 32px file again as the 16x16 slot: the desktop asks for a 16 size
    // and the smallest master-derived file is 32; a downscale at draw time
    // beats a theme miss that draws the fallback letter.
    .{ .size = "16x16", .file = "images/njuggle/32.png" },
};

/// CSS files in css_path
pub const css = [_][]const u8{
    "style.css",
};

pub const Blueprint = struct {
    major: u16,
    minor: u16,
    name: []const u8,
};

/// The list of filepaths that we depend on. Used for the build
/// system to have proper caching.
pub const file_inputs = deps: {
    const total = (icon_sizes.len * 2) + status_icons.len + chrome_icons.len +
        blueprints.len + css.len;
    var deps: [total][]const u8 = undefined;
    var index: usize = 0;
    for (icon_sizes) |size| {
        deps[index] = std.fmt.comptimePrint("images/gnome/{d}.png", .{size});
        deps[index + 1] = std.fmt.comptimePrint("images/gnome/{d}.png", .{size * 2});
        index += 2;
    }
    for (chrome_icons) |icon| {
        deps[index] = icon.file;
        index += 1;
    }
    for (status_icons) |source| {
        deps[index] = source.file;
        index += 1;
    }
    for (blueprints) |bp| {
        deps[index] = std.fmt.comptimePrint("{s}/{d}.{d}/{s}.blp", .{
            ui_path,
            bp.major,
            bp.minor,
            bp.name,
        });
        index += 1;
    }
    for (css) |name| {
        deps[index] = std.fmt.comptimePrint("{s}/{s}", .{ css_path, name });
        index += 1;
    }
    break :deps deps;
};

/// Returns the matching blueprint resource path for the given blueprint
/// definition. This will fail at compile time if the blueprint is not
/// found.
///
/// Must be called at comptime.
pub fn blueprint(comptime bp: Blueprint) [:0]const u8 {
    // The comptime block around this whole thing forces an error if
    // the caller attempts to call this function at runtime.
    comptime {
        for (blueprints) |candidate| {
            if (candidate.major == bp.major and
                candidate.minor == bp.minor and
                std.mem.eql(u8, candidate.name, bp.name))
            {
                return std.fmt.comptimePrint("{s}/ui/{d}.{d}/{s}.ui", .{
                    build_info.resource_path,
                    candidate.major,
                    candidate.minor,
                    candidate.name,
                });
            }
        }

        @compileError("invalid blueprint");
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const writer = &stdout.interface;
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<gresources>
        \\
    );

    try genRoot(init.io, writer);
    try genIcons(init.io, writer);
    try genStatusIcons(init.io, writer);
    try genChromeIcons(init.io, writer);
    try genUi(init.io, writer);

    try writer.writeAll(
        \\</gresources>
        \\
    );

    try stdout.end();
}

/// Generate the icon resources. This works by looking up all the icons
/// specified by `icon_sizes` in `images/icons/`. They are asserted to exist
/// by trying to access the file.
fn genIcons(io: std.Io, writer: *std.Io.Writer) !void {
    try writer.print(
        \\  <gresource prefix="{s}/icons">
        \\
    , .{build_info.resource_path});

    const cwd: std.Io.Dir = .cwd();
    inline for (icon_sizes) |size| {
        // 1x
        {
            const alias = std.fmt.comptimePrint("{d}x{d}", .{ size, size });
            const source = std.fmt.comptimePrint("images/gnome/{d}.png", .{size});
            try cwd.access(io, source, .{});
            try writer.print(
                \\    <file alias="{s}/apps/{s}.png">{s}</file>
                \\
            ,
                .{ alias, build_info.base_application_id, source },
            );
        }

        // 2x
        {
            const alias = std.fmt.comptimePrint("{d}x{d}@2", .{ size, size });
            const source = std.fmt.comptimePrint("images/gnome/{d}.png", .{size * 2});
            try cwd.access(io, source, .{});
            try writer.print(
                \\    <file alias="{s}/apps/{s}.png">{s}</file>
                \\
            ,
                .{ alias, build_info.base_application_id, source },
            );
        }
    }

    try writer.writeAll(
        \\  </gresource>
        \\
    );
}

/// Generate the sidebar status indicator resources: one pair
/// (128px `@2`) per state, aliased under their state directory name so the
/// row asks for `status/green@2` and the lookup is a resource path.
fn genStatusIcons(io: std.Io, writer: *std.Io.Writer) !void {
    try writer.print(
        \\  <gresource prefix="{s}/status">
        \\
    , .{build_info.resource_path});

    const cwd: std.Io.Dir = .cwd();
    for (status_icons) |icon| {
        try cwd.access(io, icon.file, .{});
        try writer.print(
            \\    <file compressed="true" alias="{s}.png">{s}</file>
            \\
        , .{ icon.colour, icon.file });
    }

    try writer.writeAll(
        \\  </gresource>
        \\
    );
}

/// Generate the chrome artwork resources: Njuggle's own application icon at
/// the locations the icon theme resolves an app id from, under the app's own
/// path so the resources above cannot be confused with the upstream set.
fn genChromeIcons(io: std.Io, writer: *std.Io.Writer) !void {
    try writer.print(
        \\  <gresource prefix="{s}/icons/Apps">
        \\
    , .{build_info.resource_path});

    const cwd: std.Io.Dir = .cwd();
    for (chrome_icons) |icon| {
        try cwd.access(io, icon.file, .{});
        try writer.print(
            \\    <file compressed="true" alias="{s}/apps/{s}.png">{s}</file>
            \\
        ,
            .{ icon.size, build_info.base_application_id, icon.file },
        );
    }

    try writer.writeAll(
        \\  </gresource>
        \\
    );
}

/// Generate the resources at the root prefix.
fn genRoot(io: std.Io, writer: *std.Io.Writer) !void {
    try writer.print(
        \\  <gresource prefix="{s}">
        \\
    , .{build_info.resource_path});

    const cwd: std.Io.Dir = .cwd();
    inline for (css) |name| {
        const source = std.fmt.comptimePrint(
            "{s}/{s}",
            .{ css_path, name },
        );
        try cwd.access(io, source, .{});
        try writer.print(
            \\    <file compressed="true" alias="{s}">{s}</file>
            \\
        ,
            .{ name, source },
        );
    }

    try writer.writeAll(
        \\  </gresource>
        \\
    );
}

/// Generate all the UI resources.
///
/// Each file is written as a *relative* path, `{major}.{minor}/{name}.ui`,
/// which `glib-compile-resources` resolves against a `--sourcedir`. An
/// absolute path into the Zig cache would change whenever the step that
/// produced the `.ui` did, and this XML with it.
///
/// The compiled `.ui` files are not inputs here for the same reason. We
/// check that the blueprint *sources* exist instead, as `genRoot` and
/// `genIcons` do for the CSS and icons.
fn genUi(io: std.Io, writer: *std.Io.Writer) !void {
    // Two `comptimePrint` calls per blueprint exceed the default quota.
    @setEvalBranchQuota(100_000);

    try writer.print(
        \\  <gresource prefix="{s}/ui">
        \\
    , .{build_info.resource_path});

    const cwd: std.Io.Dir = .cwd();
    inline for (blueprints) |bp| {
        const source = std.fmt.comptimePrint("{s}/{d}.{d}/{s}.blp", .{
            ui_path,
            bp.major,
            bp.minor,
            bp.name,
        });
        try cwd.access(io, source, .{});

        const alias = std.fmt.comptimePrint("{d}.{d}/{s}.ui", .{
            bp.major,
            bp.minor,
            bp.name,
        });
        try writer.print(
            \\    <file compressed="true" preprocess="xml-stripblanks" alias="{s}">{s}</file>
            \\
        , .{ alias, alias });
    }

    try writer.writeAll(
        \\  </gresource>
        \\
    );
}
