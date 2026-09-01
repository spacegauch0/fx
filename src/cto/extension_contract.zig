const std = @import("std");
const observation_mod = @import("observation.zig");

pub const RawEvent = struct {
    event_name: []const u8,
    delivery_id: []const u8,
    body: []const u8,
};

/// Type-erased contract implemented by self-generated connectors.
///
/// Returning null means the provider event is valid but irrelevant to this
/// connector. A returned observation is caller-owned.
pub const Connector = struct {
    id: []const u8,
    capability: []const u8,
    context: *anyopaque,
    normalize_fn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        event: RawEvent,
    ) anyerror!?observation_mod.Observation,

    pub fn normalize(
        self: Connector,
        allocator: std.mem.Allocator,
        event: RawEvent,
    ) !?observation_mod.Observation {
        return self.normalize_fn(self.context, allocator, event);
    }
};

test "connector contract preserves identity and delegates normalization" {
    const Probe = struct {
        called: bool = false,

        fn normalize(raw: *anyopaque, _: std.mem.Allocator, event: RawEvent) !?observation_mod.Observation {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.called = true;
            try std.testing.expectEqualStrings("pull_request", event.event_name);
            return null;
        }
    };

    var probe: Probe = .{};
    const connector: Connector = .{
        .id = "fixture",
        .capability = "github.pull_request.merged",
        .context = &probe,
        .normalize_fn = Probe.normalize,
    };
    const result = try connector.normalize(std.testing.allocator, .{
        .event_name = "pull_request",
        .delivery_id = "delivery-1",
        .body = "{}",
    });

    try std.testing.expect(result == null);
    try std.testing.expect(probe.called);
}
