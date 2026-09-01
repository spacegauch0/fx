const std = @import("std");
const event_mod = @import("event.zig");
const store = @import("store.zig");

/// Append-only event journal. Every meaningful state transition in the
/// kernel is recorded here before it takes effect, so `.cto/events.jsonl`
/// is the audit trail for everything CTO has ever done or asked for.
pub const Journal = struct {
    allocator: std.mem.Allocator,
    cto_root: []const u8,
    events: std.ArrayList(event_mod.Event),

    pub fn init(allocator: std.mem.Allocator, cto_root: []const u8) !Journal {
        var events: std.ArrayList(event_mod.Event) = .empty;
        errdefer events.deinit(allocator);
        const loaded = try store.loadEvents(allocator, cto_root);
        try events.appendSlice(allocator, loaded);

        return .{
            .allocator = allocator,
            .cto_root = cto_root,
            .events = events,
        };
    }

    pub fn deinit(self: *Journal) void {
        self.events.deinit(self.allocator);
    }

    pub fn append(
        self: *Journal,
        kind: event_mod.EventKind,
        subject: []const u8,
        detail: []const u8,
    ) !event_mod.Event {
        const event = event_mod.Event.init(
            @intCast(self.events.items.len + 1),
            kind,
            subject,
            detail,
        );
        try self.events.append(self.allocator, event);
        try store.appendEvent(self.allocator, self.cto_root, event);
        return event;
    }
};

test "append persists to disk and a fresh journal reloads the same history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_mod = @import("../core/shared/io.zig");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });
    try store.ensureRoot(alloc, cto_root);

    var journal = try Journal.init(alloc, cto_root);
    _ = try journal.append(.human_requested, "human", "watch merged pull requests");
    _ = try journal.append(.capability_missing, "github.pull_request.merged", "watch merged pull requests");
    try std.testing.expectEqual(@as(usize, 2), journal.events.items.len);

    var reloaded = try Journal.init(alloc, cto_root);
    try std.testing.expectEqual(@as(usize, 2), reloaded.events.items.len);
    try std.testing.expectEqual(event_mod.EventKind.human_requested, reloaded.events.items[0].kind);
    try std.testing.expectEqual(event_mod.EventKind.capability_missing, reloaded.events.items[1].kind);

    _ = try reloaded.append(.task_created, "github.pull_request.merged", "self-extension task");
    try std.testing.expectEqual(@as(u64, 3), reloaded.events.items[2].sequence);
}
