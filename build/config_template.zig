//! Contract checks for the config file Njuggle writes on first run.
//!
//! `src/config/config-template` is embedded by `Config.writeConfigTemplate` and
//! written to `$XDG_CONFIG_HOME/njuggle/config` whenever no config file exists,
//! on any route (a bare `zig-out/bin/njugle` run included). Build 4 shipped
//! upstream's template there, so the first thing a new user read was "This is
//! the configuration file for Ghostty." Every check below is a way that file
//! has been or could be wrong, read as text: standard library only.
//!
//! The write itself is `std.fmt.print` over the embedded bytes with one
//! argument, so the template must contain no other `{`, `[` or `}` outside a
//! brace-delimited field or the print fails at run time, not build time.
//!
//! A source of truth moves: a new Njuggle config key must appear in
//! `Config.zig` and in `dist/njuggle/config.default`, and the template is
//! generated from that file. The checks run in `test-units` and as the
//! build-run tool `njuggle-config-template-check`, a dependency of the install
//! step.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The template Njuggle writes. Embedded by `Config.zig` as
/// `@embedFile("./config-template")`.
pub const template_path = "src/config/config-template";

/// The shipped default config, installed when the user has none.
pub const default_path = "dist/njuggle/config.default";

/// The config surface that owns every key the template may set.
pub const config_path = "src/config/Config.zig";

/// The single field the template may interpolate (the path it was written to).
pub const path_field = "{[path]s}";

/// Option names the template is allowed to set, uncommented. Comments are
/// free text; this list is about what the file actually changes.
pub const allowed_set_keys = [_][]const u8{"gtk-sidebar-tabs"};

/// Every Njuggle-only key, as declared in `Config.zig`. The template and the
/// shipped default must both mention all of them: an option a user cannot
/// discover from the file they were given does not exist for them.
pub const njuggle_keys = [_][]const u8{
    "gtk-sidebar-tabs",
    "gtk-sidebar-active-tab-border",
    "active-pane-border",
    "inactive-pane-dim",
    "gtk-sidebar-width",
    "gtk-sidebar-status-icon",
    "gtk-sidebar-status-after",
};

/// Upstream's template opens with this line. It must never be what Njuggle
/// writes.
pub const upstream_header = "# This is the configuration file for Ghostty.";

pub const Problem = struct {
    kind: Kind,
    /// The offending line (trimmed) or the key name, whichever names the fault
    /// more usefully; empty when the whole file is at fault.
    detail: []const u8,

    pub const Kind = enum {
        /// The file still carries upstream's "configuration file for Ghostty"
        /// header: first run would write another app's words.
        upstream_header,
        /// A brace or bracket that `std.fmt.print` would read as the start of
        /// a field. Only `{[path]s}` may appear.
        format_brace,
        /// A line that sets an option commented out, or a template that sets
        /// an option outside `allowed_set_keys`.
        unexpected_set,
        /// A Njuggle key is missing from the file, so a user reading it cannot
        /// learn the option exists.
        missing_key,
        /// The shipped default is missing (the template is generated from it).
        missing_default,
        /// The template and the shipped default disagree about a Njuggle key,
        /// so the file a first run writes is not the file an install writes.
        drift,
    };
};

/// Check one file's text against the contract. `default_text` is the shipped
/// default, required for the drift check and ignored for the other two files.
pub fn check(
    alloc: Allocator,
    template: []const u8,
    default_text: ?[]const u8,
) Allocator.Error![]const Problem {
    var out: std.ArrayList(Problem) = .empty;
    errdefer out.deinit(alloc);

    if (std.mem.indexOf(u8, template, upstream_header) != null) {
        try out.append(alloc, .{ .kind = .upstream_header, .detail = "" });
    }

    var lines = std.mem.splitScalar(u8, template, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");

        // Format braces: every `{`, `[` and `}` in the file must belong to
        // `{[path]s}`. Copy the file without that field and the remainder must
        // contain none of the three.
        if (std.mem.indexOfAny(u8, line, "{[}") != null) {
            const stripped = try replaceAll(alloc, line, path_field, "");
            defer alloc.free(stripped);
            if (std.mem.indexOfAny(u8, stripped, "{[}") != null) {
                try out.append(alloc, .{ .kind = .format_brace, .detail = line });
            }
        }

        // What the file sets: a line that is not a comment and carries `=`
        // before any `#`. A commented example is not a set.
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        if (!contains(&allowed_set_keys, key)) {
            try out.append(alloc, .{ .kind = .unexpected_set, .detail = key });
        }
    }

    // Every Njuggle key must be named somewhere in the file, set or commented.
    for (njuggle_keys) |key| {
        if (!mentionsKey(template, key)) {
            try out.append(alloc, .{ .kind = .missing_key, .detail = key });
        }
    }

    if (default_text) |default| {
        if (std.mem.trim(u8, default, " \t\r\n").len == 0) {
            try out.append(alloc, .{ .kind = .missing_default, .detail = "" });
        } else {
            for (njuggle_keys) |key| {
                if (mentionsKey(template, key) and !mentionsKey(default, key)) {
                    try out.append(alloc, .{ .kind = .drift, .detail = key });
                }
            }
        }
    }

    return out.toOwnedSlice(alloc);
}

/// True when `text` mentions `key` as an option name: at the start of a line
/// after optional `# ` and spaces, followed by `=`. A key name inside prose
/// ("longer than gtk-sidebar-status-after") is a reference, not documentation
/// of that option.
pub fn mentionsKey(text: []const u8, key: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, key)) |pos| {
        at = pos + 1;
        // Walk back over spaces and at most one '#'.
        var back = pos;
        while (back > 0 and (text[back - 1] == ' ' or text[back - 1] == '\t')) back -= 1;
        if (back > 0 and text[back - 1] == '#') back -= 1;
        const starts_line = back == 0 or text[back - 1] == '\n';
        // Walk forward over spaces to the '='.
        var fwd = pos + key.len;
        // The key must not be a prefix of a longer name (gtk-sidebar-width-px).
        if (fwd < text.len and (std.ascii.isAlphanumeric(text[fwd]) or text[fwd] == '-')) continue;
        while (fwd < text.len and (text[fwd] == ' ' or text[fwd] == '\t')) fwd += 1;
        if (!starts_line) continue;
        if (fwd < text.len and text[fwd] == '=') return true;
    }
    return false;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn replaceAll(
    alloc: Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |pos| {
        try out.appendSlice(alloc, haystack[at..pos]);
        try out.appendSlice(alloc, replacement);
        at = pos + needle.len;
    }
    try out.appendSlice(alloc, haystack[at..]);
    return out.toOwnedSlice(alloc);
}

// Tests

const testing = std.testing;

test "mentionsKey: set, commented and prose forms" {
    try testing.expect(mentionsKey("gtk-sidebar-tabs = left\n", "gtk-sidebar-tabs"));
    try testing.expect(mentionsKey("# gtk-sidebar-width = 0\n", "gtk-sidebar-width"));
    try testing.expect(mentionsKey("#   gtk-sidebar-width = 0\n", "gtk-sidebar-width"));
    try testing.expect(mentionsKey("key=value\n", "key"));
    // Prose references are not documentation.
    try testing.expect(!mentionsKey("# longer than gtk-sidebar-status-after, or so\n", "gtk-sidebar-status-after"));
    // A prefix of a longer option name is a different option.
    try testing.expect(!mentionsKey("# gtk-sidebar-width-px = 0\n", "gtk-sidebar-width"));
    // Only the first column of the line counts.
    try testing.expect(!mentionsKey("font-size = 12 # gtk-sidebar-width = 0\n", "gtk-sidebar-width"));
}

test "check: upstream's header is caught" {
    const alloc = testing.allocator;
    const found = try check(alloc, "# This is the configuration file for Ghostty.\n", null);
    defer alloc.free(found);
    try testing.expect(found.len >= 1);
    try testing.expectEqual(Problem.Kind.upstream_header, found[0].kind);
}

test "check: a format brace outside the path field fails" {
    const alloc = testing.allocator;
    const found = try check(alloc, "#   {[path]s}\n# set = {x}\n", null);
    defer alloc.free(found);
    var saw = false;
    for (found) |p| if (p.kind == .format_brace) {
        saw = true;
    };
    try testing.expect(saw);
}

test "check: setting an option outside the allowed list" {
    const alloc = testing.allocator;
    const found = try check(alloc, "gtk-sidebar-tabs = left\nfont-size = 12\n", null);
    defer alloc.free(found);
    var saw = false;
    for (found) |p| {
        if (p.kind == .unexpected_set) {
            saw = true;
            try testing.expectEqualStrings("font-size", p.detail);
        }
    }
    try testing.expect(saw);
}

test "check: a commented example is not a set" {
    const alloc = testing.allocator;
    const found = try check(alloc, "gtk-sidebar-tabs = left\n# font-size = 12\n", null);
    defer alloc.free(found);
    for (found) |p| try testing.expect(p.kind != .unexpected_set);
}

test "check: every Njuggle key must be documented" {
    const alloc = testing.allocator;
    const found = try check(alloc, "", null);
    defer alloc.free(found);
    var missing: usize = 0;
    for (found) |p| if (p.kind == .missing_key) {
        missing += 1;
    };
    try testing.expectEqual(njuggle_keys.len, missing);
}

test "check: template and shipped default agree on every key" {
    const alloc = testing.allocator;
    const template = "gtk-sidebar-tabs = left\n# gtk-sidebar-width = 0\n";
    const default_text = "# gtk-sidebar-width = 0\n";
    const found = try check(alloc, template, default_text);
    defer alloc.free(found);
    // gtk-sidebar-tabs is in the template and not in the default: drift.
    var saw = false;
    for (found) |p| {
        if (p.kind == .drift) {
            saw = true;
            try testing.expectEqualStrings("gtk-sidebar-tabs", p.detail);
        }
    }
    try testing.expect(saw);
}

test "check: an empty shipped default is reported" {
    const alloc = testing.allocator;
    const found = try check(alloc, "gtk-sidebar-tabs = left\n", "  \n");
    defer alloc.free(found);
    var saw = false;
    for (found) |p| if (p.kind == .missing_default) {
        saw = true;
    };
    try testing.expect(saw);
}
