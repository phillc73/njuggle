const GhosttyResources = @This();

const std = @import("std");
const assert = std.debug.assert;
const Config = @import("Config.zig");
const RunStep = std.Build.Step.Run;
const SharedDeps = @import("SharedDeps.zig");
const build_config = @import("../build_config.zig");

steps: []*std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !GhosttyResources {
    var steps: std.ArrayList(*std.Build.Step) = .empty;
    errdefer steps.deinit(b.allocator);

    // This is the exe used to generate some build data.
    const build_data_exe = b.addExecutable(.{
        .name = "ghostty-build-data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_build_data.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
            .link_libc = true,
        }),
    });

    deps.help_strings.addImport(build_data_exe);

    // Terminfo
    terminfo: {
        const os_tag = cfg.target.result.os.tag;
        const terminfo_share_dir = if (os_tag == .freebsd)
            "site-terminfo"
        else
            "terminfo";

        // Encode our terminfo
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+terminfo");
        const wf = b.addWriteFiles();
        const source = wf.addCopyFile(run.captureStdOut(.{}), "ghostty.terminfo");

        if (cfg.emit_terminfo) {
            const source_install = b.addInstallFile(
                source,
                if (os_tag == .freebsd)
                    "share/site-terminfo/ghostty.terminfo"
                else
                    "share/terminfo/ghostty.terminfo",
            );

            try steps.append(b.allocator, &source_install.step);
        }

        // Windows doesn't have the binaries below.
        if (os_tag == .windows) break :terminfo;

        // Convert to termcap source format if thats helpful to people and
        // install it. The resulting value here is the termcap source in case
        // that is used for other commands.
        if (cfg.emit_termcap) {
            const run_step = RunStep.create(b, "infotocap");
            run_step.addArg("infotocap");
            run_step.addFileArg(source);
            const out_source = run_step.captureStdOut(.{});
            _ = run_step.captureStdErr(.{}); // so we don't see stderr

            const cap_install = b.addInstallFile(
                out_source,
                if (os_tag == .freebsd)
                    "share/site-terminfo/ghostty.termcap"
                else
                    "share/terminfo/ghostty.termcap",
            );

            try steps.append(b.allocator, &cap_install.step);
        }

        // Compile the terminfo source into a terminfo database
        {
            const run_step = RunStep.create(b, "tic");
            run_step.addArgs(&.{ "tic", "-x", "-o" });
            const path = run_step.addOutputFileArg(terminfo_share_dir);

            run_step.addFileArg(source);
            _ = run_step.captureStdErr(.{}); // so we don't see stderr

            const install_step = b.addInstallDirectory(.{
                .source_dir = path,
                .install_dir = .{ .custom = "share" },
                .install_subdir = terminfo_share_dir,
            });
            try steps.append(b.allocator, &install_step.step);

            // `tic` files an entry under the first letter of its name, so
            // this database holds x/xterm-ghostty and nothing under g/.
            // src/os/resourcesdir.zig searches terminfo/g/ghostty first and
            // uses the result as its "this is the resources dir" marker, so
            // a database without that path makes the lookup fall through to
            // a system Ghostty (or fail). Fill in the second name.
            //
            // The entry is the same bytes as x/xterm-ghostty, which is the
            // terminfo source this build generated, so install that source
            // under both names. Nothing reads tic's output directory: a
            // step that read it would be treated as depending on a cache
            // directory, and zig refuses to regenerate a cache directory
            // that something reads.
            const sentinel_install = b.addInstallFile(
                source,
                b.pathJoin(&.{ "share", terminfo_share_dir, "g", "ghostty" }),
            );
            try steps.append(b.allocator, &sentinel_install.step);
        }
    }

    // Shell-integration
    {
        const install_step = b.addInstallDirectory(.{
            .source_dir = b.path("src/shell-integration"),
            .install_dir = .{ .custom = "share" },
            .install_subdir = b.pathJoin(&.{ "ghostty", "shell-integration" }),
            .exclude_extensions = &.{".md"},
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // Themes
    if (cfg.emit_themes) {
        if (b.lazyDependency("iterm2_themes", .{})) |upstream| {
            const install_step = b.addInstallDirectory(.{
                .source_dir = upstream.path(""),
                .install_dir = .{ .custom = "share" },
                .install_subdir = b.pathJoin(&.{ "ghostty", "themes" }),
                .exclude_extensions = &.{".md"},
            });
            try steps.append(b.allocator, &install_step.step);
        }
    }

    // Fish shell completions
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+fish");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(.{}), "ghostty.fish");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/fish/vendor_completions.d",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // zsh shell completions
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+zsh");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(.{}), "_ghostty");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/zsh/site-functions",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // bash shell completions
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+bash");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(.{}), "ghostty.bash");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/bash-completion/completions",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // Vim and Neovim plugin
    {
        const wf = b.addWriteFiles();

        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-syntax");
            _ = wf.addCopyFile(run.captureStdOut(.{}), "syntax/ghostty.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-ftdetect");
            _ = wf.addCopyFile(run.captureStdOut(.{}), "ftdetect/ghostty.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-ftplugin");
            _ = wf.addCopyFile(run.captureStdOut(.{}), "ftplugin/ghostty.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-compiler");
            _ = wf.addCopyFile(run.captureStdOut(.{}), "compiler/ghostty.vim");
        }

        const vim_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/vim/vimfiles",
        });
        try steps.append(b.allocator, &vim_step.step);

        const neovim_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/nvim/site",
        });
        try steps.append(b.allocator, &neovim_step.step);
    }

    // Sublime syntax highlighting for bat cli tool
    // NOTE: The current implementation requires symlinking the generated
    // 'ghostty.sublime-syntax' file from zig-out to the '~.config/bat/syntaxes'
    // directory. The syntax then needs to be mapped to the correct language in
    // the config file within the '~.config/bat' directory
    // (ex: --map-syntax "/Users/user/.config/ghostty/config.ghostty:Ghostty Config").
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+sublime");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(.{}), "ghostty.sublime-syntax");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/bat/syntaxes",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // App (Linux)
    if (cfg.target.result.os.tag == .linux) try addLinuxAppResources(
        b,
        cfg,
        &steps,
    );

    return .{ .steps = steps.items };
}

/// Add the resource files needed to make Ghostty a proper
/// Linux desktop application (for various desktop environments).
fn addLinuxAppResources(
    b: *std.Build,
    cfg: *const Config,
    steps: *std.ArrayList(*std.Build.Step),
) !void {
    assert(cfg.target.result.os.tag == .linux);

    // Background:
    // https://developer.gnome.org/documentation/guidelines/maintainer/integrating.html

    // R6: identity comes from one place. `bundle_id` is the same string the
    // runtime uses for the GTK application id (build/info.zig), so the
    // desktop entry, the DBus name and the WM_CLASS agree and the app cannot
    // group with an installed Ghostty.
    const name = b.fmt("Njuggle{s}", .{
        if (cfg.app_id_suffix.len == 0) "" else " (Debug)",
    });

    // The same suffix the runtime applies to its app id (build/info.zig),
    // from the same build option: entry, D-Bus name and WM_CLASS cannot
    // diverge from the binary whatever the optimize mode.
    const app_id = b.fmt("{s}{s}", .{ build_config.bundle_id, cfg.app_id_suffix });

    // How the files below launch Njuggle. See -Dinstalled-exe-path.
    const exe = cfg.installed_exe_path orelse "njuggle";

    // Variables used by the templates.
    // Fields are nullable since unused fields trigger a build failure.
    const Variables = struct {
        NAME: ?[]const u8 = null,
        APPID: ?[]const u8 = null,
        GHOSTTY: ?[]const u8 = null,
    };

    // The templates that we will process. The templates are in
    // cmake format and will be processed and saved to the
    // second element of the tuple.
    const Template = struct { std.Build.LazyPath, []const u8, Variables };
    const templates: []const Template = templates: {
        var ts: std.ArrayList(Template) = .empty;
        defer ts.deinit(b.allocator);

        // Desktop file so that we have an icon and other metadata
        try ts.append(b.allocator, .{
            b.path("dist/linux/app.desktop.in"),
            b.fmt("share/applications/{s}.desktop", .{app_id}),
            .{ .NAME = name, .APPID = app_id, .GHOSTTY = exe },
        });

        // Service for DBus activation.
        try ts.append(b.allocator, .{
            if (cfg.flatpak)
                b.path("dist/linux/dbus.service.flatpak.in")
            else
                b.path("dist/linux/dbus.service.in"),
            b.fmt("share/dbus-1/services/{s}.service", .{app_id}),
            .{ .APPID = app_id, .GHOSTTY = exe },
        });

        // `systemd` user service. This is kind of nasty but `systemd` looks for
        // user services in different paths depending on if we are installed
        // as a system package or not (lib vs. share) so we have to handle that
        // here. We might be able to get away with always installing to both
        // because it only ever searches in one... but I don't want to do that
        // hack until we have to.
        //
        // The XDG Freedesktop Portal has a major undocumented requirement
        // for programs that are launched/controlled by `systemd` to interact
        // with the Portal. The unit must be named `app-<appid>.service`. The
        // Portal uses the `systemd` unit name figure out what the program's
        // application ID is and it will only look at unit names that begin with
        // `app-`. I can find no place that this is documented other than by
        // inspecting the code or the issue and PR that introduced this feature.
        // See the following code:
        //
        // https://github.com/flatpak/xdg-desktop-portal/blob/7d4d48cf079147c8887da17ec6c3954acd5a285c/src/xdp-utils.c#L152-L220
        if (!cfg.flatpak) try ts.append(b.allocator, .{
            b.path("dist/linux/systemd.service.in"),
            b.fmt(
                "{s}/systemd/user/app-{s}.service",
                .{
                    if (b.graph.system_package_mode) "lib" else "share",
                    app_id,
                },
            ),
            .{ .NAME = name, .APPID = app_id, .GHOSTTY = exe },
        });

        // AppStream metainfo so that application has rich metadata
        // within app stores
        try ts.append(b.allocator, .{
            b.path("dist/linux/com.mitchellh.ghostty.metainfo.xml.in"),
            b.fmt("share/metainfo/{s}.metainfo.xml", .{app_id}),
            .{ .NAME = name, .APPID = app_id },
        });

        break :templates try ts.toOwnedSlice(b.allocator);
    };

    // Process all our templates
    for (templates) |template| {
        const tpl = b.addConfigHeader(
            .{ .style = .{ .cmake = template[0] } },
            .{},
        );
        inline for (@typeInfo(Variables).@"struct".field_names) |field| {
            if (@field(template[2], field)) |v| {
                tpl.addValue(field, @FieldType(Variables, field), v);
            }
        }

        // Template output has a single header line we want to remove.
        // We use `tail` to do it since its part of the POSIX standard.
        const tail = b.addSystemCommand(&.{ "tail", "-n", "+2" });
        tail.setStdIn(.{ .lazy_path = tpl.getOutputFile() });

        const copy = b.addInstallFile(
            tail.captureStdOut(.{}),
            template[1],
        );

        try steps.append(b.allocator, &copy.step);
    }

    // Right click menu action for Plasma desktop
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("dist/linux/ghostty_dolphin.desktop"),
        b.fmt("share/kio/servicemenus/{s}.desktop", .{app_id}),
    ).step);

    // Right click menu action for Nautilus. Note that this _must_ be named
    // `ghostty.py`. Using the full app id causes problems (see #5468) - the
    // file NAME is the module name, not the app id, so it stays.
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("dist/linux/ghostty_nautilus.py"),
        "share/nautilus-python/extensions/ghostty.py",
    ).step);

    // The D-Bus service file's own template, shipped because the desktop
    // installer is what writes the placeable copy: the template above carries
    // the build-time program name, while the launcher needs the installed
    // path (-Dinstalled-exe-path), which only the install step knows.
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("dist/njuggle/dbus.service.default"),
        "share/njuggle/dbus.service.default",
    ).step);

    // R6: Njuggle's own artwork, at the hicolor sizes the desktop reads.
    // 32/64/128 are generated from the 512 master rather than shipped as
    // three hand-made files, so there is one source of truth for the mark.
    const hicolor = .{
        .{ "512", "512x512" },
        .{ "256", "256x256" },
        .{ "128", "128x128" },
        .{ "64", "64x64" },
        .{ "32", "32x32" },
    };
    inline for (hicolor) |pair| {
        const size, const dir = pair;
        try steps.append(b.allocator, &b.addInstallFile(
            b.path(b.fmt("images/njuggle/{s}.png", .{size})),
            b.fmt("share/icons/hicolor/{s}/apps/{s}.png", .{ dir, app_id }),
        ).step);
    }

    // The install tree is not on any icon-theme or desktop search path, so
    // `zig build install` alone gives the window nothing to resolve
    // `setIconName(bundle_id)` against and the desktop no launcher: the
    // titlebar and the taskbar draw a fallback letter. This run step copies
    // the installed desktop entry and icons into the XDG data home and
    // refreshes both caches, so one install command leaves a working app.
    // It is best-effort (never fails the build), honours $XDG_DATA_HOME, and
    // NJUGGLE_NO_DESKTOP_INSTALL=1 turns it off for packagers and CI.
    const install_desktop = RunStep.create(b, "install desktop entry and icons");
    install_desktop.addFileArg(b.path("dist/njuggle/desktop-install.sh"));
    install_desktop.addArg(app_id);
    // The run step receives the install prefix as a directory argument. The
    // path must be built from `.install_prefix`, not a literal `zig-out`: a
    // literal resolves inside the BUILD root whatever `-p` says, so a
    // scratch-prefix install read the zig-out tree and wrote that tree's
    // entry and service file into the real data home (a `-p /tmp/...`
    // build replaced the launcher entry with a /tmp path).
    install_desktop.addDirectoryArg(b.graph.path(.install_prefix, "share"));
    // Empty unless the build was told where the binary lands: the entry then
    // keeps naming the binary alone, which is what a PATH lookup needs.
    install_desktop.addArg(cfg.installed_exe_path orelse "");
    install_desktop.has_side_effects = true;
    for (steps.items) |dep| install_desktop.step.dependOn(dep);
    try steps.append(b.allocator, &install_desktop.step);

    // R2: ship a default config, installed only when the user has none.
    // A plain install-file would overwrite the user's edited config on
    // every `zig build install`, so this is a run step with a test -f
    // guard. The template is written to the install prefix so the file the
    // guard copies is the one that shipped with this build.
    const config_template = b.addInstallFile(
        b.path("dist/njuggle/config.default"),
        "share/njuggle/config.default",
    );
    try steps.append(b.allocator, &config_template.step);

    const config_guard = RunStep.create(b, "install default config if absent");
    config_guard.addFileArg(b.path("dist/njuggle/config-if-absent.sh"));
    // The guard needs the template path; without it it prints usage and
    // exits 2, which fails the build.
    config_guard.addFileArg(b.path("dist/njuggle/config.default"));
    config_guard.has_side_effects = true;
    // The user's config is written in exactly one place: the guard script,
    // which refuses to touch an existing file.
    config_guard.step.dependOn(&config_template.step);
    try steps.append(b.allocator, &config_guard.step);
}

pub fn install(self: *const GhosttyResources) void {
    const b = self.steps[0].owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyResources,
    other_step: *std.Build.Step,
) void {
    for (self.steps) |step| other_step.dependOn(step);
}
