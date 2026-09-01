//! Build-time registry for human-approved CTO extensions.
//!
//! A generated candidate may add its connector import and tests here because
//! this file is inside the self-modification boundary. The trusted kernel
//! never imports a candidate directly.

pub const github_events = @import("github_events.zig");
pub const connectors = .{github_events.connector};
