//! Build-run entry point: fail the build on a template child that is not
//! bound, or a bound name the template does not declare.
//!
//! Runs as a step the install depends on (see `build.zig`), so the check costs
//! nothing at run time and cannot be skipped by forgetting to run a test. The
//! rules live in `template_bindings.zig`; the files are read from the build
//! root, which is this process's cwd.

const std = @import("std");
const bindings = @import("template_bindings.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;
    const cwd: std.Io.Dir = .cwd();

    var buf: [4096]u8 = undefined;
    var locked = try io.lockStderr(&buf, null);
    defer io.unlockStderr();
    const w = &locked.file_writer.interface;

    var failed: usize = 0;
    for (bindings.pairs) |pair| {
        const source = try cwd.readFileAlloc(io, pair.source, alloc, .limited(1 << 20));
        defer alloc.free(source);
        const template = try cwd.readFileAlloc(io, pair.template, alloc, .limited(1 << 20));
        defer alloc.free(template);

        const found = try bindings.check(alloc, source, template);
        defer alloc.free(found);
        if (found.len == 0) continue;
        failed += found.len;
        for (found) |m| try m.write(pair, w);
    }

    if (failed > 0) {
        try w.print(
            "error: {d} template binding mismatch(es): a widget a class quotes " ++
                "must be declared in its blueprint and bound in the class\n",
            .{failed},
        );
        try w.flush();
        std.process.exit(1);
    }
}
