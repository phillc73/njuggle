//! Template child binding check for the sidebar rows.
//!
//! A row class reaches its widgets through `priv.<name>`, and a scaffolded but
//! unbound widget gives that pointer to whatever occupies the slot. The
//! inverse is a class that binds a name its template no longer declares. The
//! first case renders nothing; a row that shipped that way had its
//! `status_image` declared, used in `syncStatus`, and never bound.
//!
//! Both sides are read as text, standard library only: the self-hosted Zig
//! build cannot depend on a module from `zig-pkg/` from a build-run tool, and
//! the table here is small enough that a parser buys nothing.
//!
//! Widget names are quoted string literals on both sides, so keyword
//! properties, signals, CSS classes and bindings are all invisible to this
//! check and cannot report as misses.
//!
//! A source of truth moves: when a row class is written, add it to `pairs`.
//! When a pair stops resolving, the test in `src/build_tools_test_root.zig`
//! fails, so the check cannot rot into a no-op.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pair = struct {
    /// The class source, e.g. `src/apprt/gtk/class/sidebar_row.zig`.
    source: []const u8,
    /// The blueprint compiled into that class, e.g.
    /// `src/apprt/gtk/ui/1.4/sidebar-row.blp`.
    template: []const u8,
};

/// Every class that binds template children privately.
pub const pairs = [_]Pair{
    .{
        .source = "src/apprt/gtk/class/sidebar_row.zig",
        .template = "src/apprt/gtk/ui/1.4/sidebar-row.blp",
    },
};

/// The widget names bound by `bindTemplateChildPrivate("name", ...)`.
pub fn boundNames(
    alloc: Allocator,
    source: []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);

    const marker = "bindTemplateChildPrivate(";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, marker)) |m| {
        const open = m + marker.len;
        at = open;
        if (open >= source.len or source[open] != '"') continue;
        const close = std.mem.indexOfScalarPos(u8, source, open + 1, '"') orelse break;
        if (close == open + 1) {
            at = close + 1;
            continue;
        }
        try out.append(alloc, source[open + 1 .. close]);
        at = close + 1;
    }
    return out.toOwnedSlice(alloc);
}

/// The widget names declared with an id in the template body (`Gtk.Image foo
/// {`).
///
/// Template kid ids are bare words in the widget name slot, the token before
/// the node's opening brace; every class the templates use (Gtk, Adw, Ghostty
/// templates) is qualified with dots. A comment line is skipped whole.
///
/// Top-level `menu name {` and `boxed-struct` declarations are NOT widget
/// kids: they are named resources handed to `menu-model:` or set as values,
/// so a class never binds them and they never carry `priv.` fields.
pub fn declaredNames(
    alloc: Allocator,
    template: []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);

    var lines = std.mem.splitScalar(u8, template, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        const brace = std.mem.indexOfScalar(u8, line, '{') orelse continue;
        const head = std.mem.trim(u8, line[0..brace], " \t");
        var tokens = std.mem.tokenizeAny(u8, head, " \t");
        const kind = tokens.next() orelse continue;
        if (std.mem.eql(u8, kind, "menu") or std.mem.eql(u8, kind, "boxed-struct")) continue;
        const name = tokens.next() orelse continue;
        if (tokens.next() != null) continue;
        if (!isIdentifier(name)) continue;
        try out.append(alloc, name);
    }
    return out.toOwnedSlice(alloc);
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const ok = switch (c) {
            'a'...'z', 'A'...'Z', '_' => true,
            '0'...'9' => i != 0,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

pub const Result = enum { ok, unbound, dangling };

/// For one widget name: does it exist on both sides?
pub fn check(
    alloc: Allocator,
    source: []const u8,
    template: []const u8,
) Allocator.Error![]const Mismatch {
    const bound = try boundNames(alloc, source);
    defer alloc.free(bound);
    const declared = try declaredNames(alloc, template);
    defer alloc.free(declared);

    var out: std.ArrayList(Mismatch) = .empty;
    errdefer out.deinit(alloc);

    for (declared) |name| {
        if (!contains(bound, name)) try out.append(alloc, .{ .name = name, .kind = .unbound });
    }
    for (bound) |name| {
        if (!contains(declared, name)) try out.append(alloc, .{ .name = name, .kind = .dangling });
    }
    return out.toOwnedSlice(alloc);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub const Mismatch = struct {
    name: []const u8,
    kind: Result,

    /// The build failure text: the name, which way it is wrong, and the file.
    pub fn write(self: Mismatch, pair: Pair, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .unbound => try w.print(
                "error: {s}: '{s}' is declared in {s} and never bound with " ++
                    "bindTemplateChildPrivate - the class's priv.{s} reads " ++
                    "whatever occupies that slot",
                .{ pair.source, self.name, pair.template, self.name },
            ),
            .dangling => try w.print(
                "error: {s}: '{s}' is bound with bindTemplateChildPrivate and " ++
                    "{s} no longer declares it",
                .{ pair.source, self.name, pair.template },
            ),
            .ok => unreachable,
        }
        try w.writeAll("\n");
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "declared names: widget ids, not classes or properties" {
    const alloc = testing.allocator;
    const blp =
        \\template $GhosttySidebarRow: Adw.Bin {
        \\  Gtk.Box {
        \\    orientation: vertical;
        \\    Gtk.Image status_image {
        \\      pixel-size: 12;
        \\    }
        \\    // Gtk.Image commented_out {
        \\    Gtk.DragSource drag_source {
        \\      actions: move;
        \\    }
        \\  }
        \\}
        \\menu row_menu {
        \\  item {
        \\    label: "x";
        \\  }
        \\}
    ;
    const names = try declaredNames(alloc, blp);
    defer alloc.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("status_image", names[0]);
    try testing.expectEqualStrings("drag_source", names[1]);
}

test "bound names: the quoted first argument only" {
    const alloc = testing.allocator;
    const src =
        \\class.bindTemplateChildPrivate("menu", .{});
        \\class.bindTemplateChildPrivate("status_image", .{});
        \\class.bindTemplateCallback("close_clicked", &closeClicked);
    ;
    const names = try boundNames(alloc, src);
    defer alloc.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("menu", names[0]);
    try testing.expectEqualStrings("status_image", names[1]);
}

test "check: an unbound declared widget is an unbound mismatch" {
    const alloc = testing.allocator;
    const found = try check(
        alloc,
        \\class.bindTemplateChildPrivate("menu", .{});
        ,
        \\template $X: Adw.Bin {
        \\  Gtk.PopoverMenu menu {
        \\    Gtk.Image status_image {
        \\  }
        \\}
        ,
    );
    defer alloc.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("status_image", found[0].name);
    try testing.expectEqual(Result.unbound, found[0].kind);
}

test "check: a bound name the template dropped is dangling" {
    const alloc = testing.allocator;
    const found = try check(
        alloc,
        \\class.bindTemplateChildPrivate("gone", .{});
        ,
        \\template $X: Adw.Bin {
        \\  Gtk.Box some_other_name {
        \\  }
        \\}
    );
    defer alloc.free(found);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("some_other_name", found[0].name);
    try testing.expectEqual(Result.unbound, found[0].kind);
    try testing.expectEqualStrings("gone", found[1].name);
    try testing.expectEqual(Result.dangling, found[1].kind);
}

test "check: every declared id bound is clean" {
    const alloc = testing.allocator;
    const found = try check(
        alloc,
        \\class.bindTemplateChildPrivate("menu", .{});
        ,
        \\template $X: Adw.Bin {
        \\  Gtk.PopoverMenu menu {
        \\    menu-model: row_menu;
        \\    halign: start;
        \\  }
        \\}
    );
    defer alloc.free(found);
    try testing.expectEqual(@as(usize, 0), found.len);
}
