const std = @import("std");
const action_mod = @import("action.zig");

pub const protocol_version: u32 = 1;

/// The daemon's wire vocabulary: every `Action` (the shared vocabulary
/// from action.zig, D8) plus two protocol-only liveness probes that never
/// touch the kernel.
pub const Command = enum {
    health,
    ready,
    status,
    capabilities,
    tasks,
    goals,
    runs,
    decisions,
    observations,
    events,
    releases,
    request,
    review,
    approve,
    activate,
    rollback,
    interrupt,
    ingest,
    brief,
    explain,

    pub fn toAction(self: Command) ?action_mod.Action {
        return switch (self) {
            .health, .ready => null,
            inline else => |tag| @field(action_mod.Action, @tagName(tag)),
        };
    }
};

pub const Request = struct {
    version: u32 = protocol_version,
    id: []const u8,
    command: Command,
    argument: ?[]const u8 = null,
};

pub const Response = struct {
    version: u32 = protocol_version,
    id: []const u8,
    ok: bool,
    exit_code: u8,
    output: []const u8,
    error_message: ?[]const u8 = null,
};

pub fn decodeRequest(alloc: std.mem.Allocator, line: []const u8) !std.json.Parsed(Request) {
    const parsed = try std.json.parseFromSlice(Request, alloc, line, .{});
    if (parsed.value.version != protocol_version) {
        parsed.deinit();
        return error.UnsupportedProtocolVersion;
    }
    if (parsed.value.id.len == 0) {
        parsed.deinit();
        return error.MissingRequestId;
    }
    return parsed;
}

pub fn encodeResponse(alloc: std.mem.Allocator, response: Response) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, response, .{});
}

test "protocol rejects a mismatched version" {
    const alloc = std.testing.allocator;
    const text =
        \\{"version":999,"id":"x","command":"status"}
    ;
    try std.testing.expectError(error.UnsupportedProtocolVersion, decodeRequest(alloc, text));
}

test "protocol round-trips a request with an argument" {
    const alloc = std.testing.allocator;
    const parsed = try decodeRequest(alloc,
        \\{"version":1,"id":"abc","command":"request","argument":"watch merged pull requests"}
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abc", parsed.value.id);
    try std.testing.expectEqual(Command.request, parsed.value.command);
    try std.testing.expectEqualStrings("watch merged pull requests", parsed.value.argument.?);
}

test "every non-probe command maps onto the shared Action vocabulary" {
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        const command: Command = @enumFromInt(field.value);
        switch (command) {
            .health, .ready => try std.testing.expectEqual(@as(?action_mod.Action, null), command.toAction()),
            else => try std.testing.expect(command.toAction() != null),
        }
    }
}

test "encodeResponse produces parseable JSON" {
    const alloc = std.testing.allocator;
    const encoded = try encodeResponse(alloc, .{
        .id = "abc",
        .ok = true,
        .exit_code = 0,
        .output = "hello\n",
    });
    defer alloc.free(encoded);
    const parsed = try std.json.parseFromSlice(Response, alloc, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello\n", parsed.value.output);
}
