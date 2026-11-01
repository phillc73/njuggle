//! Test root for the config parser's own tests.
//!
//! Why this file exists: `zig build test` compiles the whole GTK-linked tree,
//! which exceeds this machine's memory (SIGKILL, record in the build ledger).
//! A test root that reaches only the config parser keeps `src/` as the module
//! root, so the parser's `..` imports resolve, and links nothing from
//! apprt/gtk. Test with:
//!
//!     zig test -Mconfig_test_root=src/config_test_root.zig
//!
//! This is a test-only entry point, not compiled into the binary.

/// Imported for their place in the module graph, not their contents: the
/// parser and the terminal tree behind it reach both, and the build supplies
/// them as dep edges. Referencing them from the test keeps the reference live.
const build_options = @import("build_options");
const terminal_options = @import("terminal_options");

test {
    try @import("std").testing.expect(@TypeOf(build_options) != void);
    try @import("std").testing.expect(@TypeOf(terminal_options) != void);
    _ = @import("config/Config.zig");
}
