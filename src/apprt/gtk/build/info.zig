//! Optional -debug identity suffix for the GTK app id.
//!
//! Licence: AGPLv3 (njuggle).
//!
//! The app id is what the session bus registers and what a desktop entry's
//! `Icon=`/D-Bus activation ask for, so it must not depend on optimise mode.
//! It used to: a Debug or ReleaseSafe build registered
//! `org.mimosadev.njuggle-debug` while the installed entry asked for the plain
//! name, and a second launch from the menu died at the bus lookup with "the
//! name … was not provided by any .service files".
//!
//! A developer who wants a dev build living beside an installed one asks for
//! the suffix explicitly with `-Dapp-id-suffix=debug`; every other build uses
//! the plain id.

const options = @import("app_id_options");

/// Base application ID.
pub const base_application_id = "org.mimosadev.njuggle";

/// The suffix a build was configured with, dash included (`-debug`), empty
/// by default.
pub const suffix: []const u8 = options.suffix;

/// GTK application ID. One value per configuration, never per optimise mode.
pub const application_id = base_application_id ++ suffix;

/// Resource path. Suffixed builds get their own path so a dev build and an
/// installed one cannot share (and overwrite) each other's resources.
pub const resource_path = "/org/mimosadev/njuggle";
pub const object_path = if (suffix.len == 0)
    resource_path
else
    resource_path ++ "_" ++ suffix;

/// True when this build asked for a non-default identity. Debug-mode extras
/// keyed to "is this a dev build" should read this, not `builtin.mode`.
pub const is_dev_identity = suffix.len != 0;

