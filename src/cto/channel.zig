const std = @import("std");

/// Provider-neutral human command. Telegram, a local socket, or a future UI
/// can all normalize into this value before the trusted control plane acts.
pub const Command = union(enum) {
    status,
    goals,
    runs,
    decisions,
    approve: u64,
    interrupt: u64,
    invalid: []const u8,
};

pub fn parse(text: []const u8) Command {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "/status")) return .status;
    if (std.mem.eql(u8, trimmed, "/goals")) return .goals;
    if (std.mem.eql(u8, trimmed, "/runs")) return .runs;
    if (std.mem.eql(u8, trimmed, "/decisions")) return .decisions;
    if (std.mem.startsWith(u8, trimmed, "/approve ")) {
        const id = std.fmt.parseInt(u64, trimmed[9..], 10) catch return .{ .invalid = trimmed };
        return .{ .approve = id };
    }
    if (std.mem.startsWith(u8, trimmed, "/interrupt ")) {
        const id = std.fmt.parseInt(u64, trimmed[11..], 10) catch return .{ .invalid = trimmed };
        return .{ .interrupt = id };
    }
    return .{ .invalid = trimmed };
}

test "telegram-compatible commands are parsed without executing them" {
    try std.testing.expectEqual(@as(u64, 7), parse("/approve 7").approve);
    try std.testing.expectEqual(Command.status, parse(" /status "));
    try std.testing.expectEqualStrings("/approve nope", parse("/approve nope").invalid);
}
