const std = @import("std");

/// The trusted, deliberately small authorization boundary. Extensions may
/// propose actions, but only the kernel classifies whether they can run.
pub const Decision = enum { allow, approval_required, deny };

pub fn classify(action: []const u8, path: ?[]const u8) Decision {
    if (std.mem.startsWith(u8, action, "delete") or
        std.mem.startsWith(u8, action, "deploy") or
        std.mem.startsWith(u8, action, "merge") or
        std.mem.startsWith(u8, action, "spend") or
        std.mem.startsWith(u8, action, "message")) return .approval_required;
    if (path) |value| {
        if (std.mem.indexOf(u8, value, "..") != null or std.fs.path.isAbsolute(value)) return .deny;
    }
    return .allow;
}

test "sensitive effects require approval and escaped paths are denied" {
    try std.testing.expectEqual(Decision.allow, classify("worker.run", "src/cto/extensions/a.zig"));
    try std.testing.expectEqual(Decision.approval_required, classify("merge.pull_request", null));
    try std.testing.expectEqual(Decision.deny, classify("filesystem.write", "../outside"));
}
