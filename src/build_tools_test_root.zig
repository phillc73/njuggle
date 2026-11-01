//! Test root for the build tools' own tests.
//!
//! Same reason `config_test_root.zig` exists: `zig build test` compiles the
//! whole GTK-linked tree and exceeds this machine's memory. The module tested
//! here reaches nothing outside the standard library, so it tests in seconds.
//!
//! `build/` sits outside the `src/` module root, so the checker lives here and
//! `build/template_bindings.zig` is the same file through the test runner's
//! module map (see `build.zig`, `addImport`). Two paths to one file cannot
//! drift apart; the build step reads that same file by path.
const std = @import("std");
const bindings = @import("bindings");
const config_template = @import("config_template");

test {
    _ = bindings;
    _ = config_template;
}

test "config template check: the real files satisfy the contract" {
    // Same shape as the binding test below: repository paths, repository cwd,
    // so a file that moved fails here instead of passing quietly.
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const template = try std.Io.Dir.cwd().readFileAlloc(
        io,
        config_template.template_path,
        alloc,
        .limited(1 << 20),
    );
    defer alloc.free(template);
    const default_text = try std.Io.Dir.cwd().readFileAlloc(
        io,
        config_template.default_path,
        alloc,
        .limited(1 << 20),
    );
    defer alloc.free(default_text);
    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        config_template.config_path,
        alloc,
        .limited(1 << 22),
    );
    defer alloc.free(source);

    // Every key the template documents is a key the config surface declares.
    for (config_template.njuggle_keys) |key| {
        try std.testing.expect(std.mem.indexOf(u8, source, key) != null);
    }

    const found = try config_template.check(alloc, template, default_text);
    defer alloc.free(found);
    if (found.len != 0) {
        for (found) |p| std.debug.print("config template: {t} {s}\n", .{ p.kind, p.detail });
    }
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "template binding check: every pair reads both sides" {
    // A checker that cannot find a file must fail, not pass: the pairs are
    // repository paths, so the test runs with the repository as cwd.
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for (bindings.pairs) |pair| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, pair.source, alloc, .limited(1 << 20));
        defer alloc.free(source);
        const template = try std.Io.Dir.cwd().readFileAlloc(io, pair.template, alloc, .limited(1 << 20));
        defer alloc.free(template);

        const bound = try bindings.boundNames(alloc, source);
        defer alloc.free(bound);
        const declared = try bindings.declaredNames(alloc, template);
        defer alloc.free(declared);
        try std.testing.expect(bound.len > 0);
        try std.testing.expect(declared.len > 0);
    }
}
