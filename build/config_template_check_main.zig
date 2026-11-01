//! Build-run entry point: fail the build when the config file Njuggle writes on
//! first run breaks its contract.
//!
//! Runs as a step the install depends on (see `build.zig`), so the check costs
//! nothing at run time and cannot be skipped by forgetting to run a test. The
//! rules live in `config_template.zig`; the files are read from the build root,
//! which is this process's cwd.

const std = @import("std");
const config_template = @import("config_template.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;
    const cwd: std.Io.Dir = .cwd();

    var buf: [4096]u8 = undefined;
    var locked = try io.lockStderr(&buf, null);
    defer io.unlockStderr();
    const w = &locked.file_writer.interface;

    const template = try cwd.readFileAlloc(io, config_template.template_path, alloc, .limited(1 << 20));
    defer alloc.free(template);
    const default_text = try cwd.readFileAlloc(io, config_template.default_path, alloc, .limited(1 << 20));
    defer alloc.free(default_text);
    const source = try cwd.readFileAlloc(io, config_template.config_path, alloc, .limited(1 << 22));
    defer alloc.free(source);

    const found = try config_template.check(alloc, template, default_text);
    defer alloc.free(found);

    // The key list is a copy of what `Config.zig` declares. A key added there
    // and forgotten here would go undocumented and unchecked.
    var undeclared: usize = 0;
    for (config_template.njuggle_keys) |key| {
        if (std.mem.indexOf(u8, source, key) == null) {
            undeclared += 1;
            try w.print(
                "error: {s}: {s} is not named in {s}; the template key list is stale\n",
                .{ config_template.template_path, key, config_template.config_path },
            );
        }
    }

    for (found) |p| {
        switch (p.kind) {
            .upstream_header => try w.print(
                "error: {s}: still carries upstream's header \"{s}\"; " ++
                    "first run would write another app's words\n",
                .{ config_template.template_path, config_template.upstream_header },
            ),
            .format_brace => try w.print(
                "error: {s}: `{{`, `[` or `}}` outside {s} is read as a format field " ++
                    "by writeConfigTemplate and fails at run time: {s}\n",
                .{ config_template.template_path, config_template.path_field, p.detail },
            ),
            .unexpected_set => try w.print(
                "error: {s}: sets '{s}'; only {d} option(s) may be set uncommented " ++
                    "(the rest are commented examples)\n",
                .{ config_template.template_path, p.detail, config_template.allowed_set_keys.len },
            ),
            .missing_key => try w.print(
                "error: {s}: Njuggle option '{s}' is not documented in the file first run writes\n",
                .{ config_template.template_path, p.detail },
            ),
            .missing_default => try w.print(
                "error: {s}: is empty; the template is generated from it\n",
                .{config_template.default_path},
            ),
            .drift => try w.print(
                "error: template and {s} disagree on '{s}': first run and install " ++
                    "would write different files\n",
                .{ config_template.default_path, p.detail },
            ),
        }
    }

    const failed = found.len + undeclared;
    if (failed > 0) {
        try w.print(
            "error: {d} config template problem(s)\n",
            .{failed},
        );
        try w.flush();
        std.process.exit(1);
    }
}
