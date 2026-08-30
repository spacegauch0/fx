const std = @import("std");

pub const Status = enum {
    available,
    missing,
    candidate,
    disabled,
};

pub const Capability = struct {
    name: []const u8,
    status: Status,
    source: []const u8 = "kernel",
};

/// The capabilities the trusted kernel ships with on a fresh `.cto/` state.
///
/// `github.pull_request.merged` is deliberately absent: the PoC demonstrates
/// CTO noticing the gap and bootstrapping it, not shipping it pre-built.
pub const bootstrap_available = [_][]const u8{
    "filesystem.read",
    "filesystem.write",
    "git.worktree",
    "worker.fx",
    "self.build",
    "self.test",
};

pub const bootstrap_missing = [_][]const u8{
    "github.pull_request.merged",
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    items: std.StringHashMap(Capability),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .items = std.StringHashMap(Capability).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.items.deinit();
    }

    pub fn bootstrap(self: *Registry) !void {
        for (bootstrap_available) |name| try self.put(name, .available, "kernel");
        for (bootstrap_missing) |name| try self.put(name, .missing, "none");
    }

    pub fn put(
        self: *Registry,
        name: []const u8,
        new_status: Status,
        source: []const u8,
    ) !void {
        try self.items.put(name, .{
            .name = name,
            .status = new_status,
            .source = source,
        });
    }

    pub fn status(self: *const Registry, name: []const u8) Status {
        if (self.items.get(name)) |item| return item.status;
        return .missing;
    }

    pub fn isAvailable(self: *const Registry, name: []const u8) bool {
        return self.status(name) == .available;
    }

    pub fn markCandidate(self: *Registry, name: []const u8, source: []const u8) !void {
        try self.put(name, .candidate, source);
    }

    pub fn activate(self: *Registry, name: []const u8, source: []const u8) !void {
        try self.put(name, .available, source);
    }

    /// Returns a caller-owned, name-sorted snapshot of every capability.
    /// Used anywhere output needs to be deterministic: printing and
    /// persistence both go through this instead of iterating the hash map
    /// directly.
    pub fn sortedEntries(self: *const Registry, alloc: std.mem.Allocator) ![]Capability {
        var list: std.ArrayList(Capability) = .empty;
        defer list.deinit(alloc);
        var iterator = self.items.iterator();
        while (iterator.next()) |entry| try list.append(alloc, entry.value_ptr.*);
        const owned = try list.toOwnedSlice(alloc);
        std.mem.sort(Capability, owned, {}, lessByName);
        return owned;
    }

    fn lessByName(_: void, a: Capability, b: Capability) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }

    pub const Counts = struct {
        available: usize = 0,
        missing: usize = 0,
        other: usize = 0,
    };

    pub fn count(self: *const Registry) Counts {
        var result: Counts = .{};
        var iterator = self.items.iterator();
        while (iterator.next()) |entry| {
            switch (entry.value_ptr.status) {
                .available => result.available += 1,
                .missing => result.missing += 1,
                .candidate, .disabled => result.other += 1,
            }
        }
        return result;
    }
};

test "bootstrap seeds the fixed capability set with github merge awareness missing" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.bootstrap();

    try std.testing.expect(registry.isAvailable("filesystem.read"));
    try std.testing.expect(registry.isAvailable("filesystem.write"));
    try std.testing.expect(registry.isAvailable("git.worktree"));
    try std.testing.expect(registry.isAvailable("worker.fx"));
    try std.testing.expect(registry.isAvailable("self.build"));
    try std.testing.expect(registry.isAvailable("self.test"));
    try std.testing.expect(!registry.isAvailable("github.pull_request.merged"));
    try std.testing.expectEqual(Status.missing, registry.status("github.pull_request.merged"));

    const counts = registry.count();
    try std.testing.expectEqual(@as(usize, 6), counts.available);
    try std.testing.expectEqual(@as(usize, 1), counts.missing);
}

test "unknown capability names report missing rather than crashing" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.bootstrap();

    try std.testing.expectEqual(Status.missing, registry.status("slack.channel.watch"));
    try std.testing.expect(!registry.isAvailable("slack.channel.watch"));
}

test "sortedEntries returns every capability ordered by name" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.bootstrap();

    const entries = try registry.sortedEntries(std.testing.allocator);
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 7), entries.len);
    var previous: []const u8 = "";
    for (entries) |entry| {
        try std.testing.expect(std.mem.lessThan(u8, previous, entry.name));
        previous = entry.name;
    }
}

test "candidate then activate transitions a missing capability to available" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.bootstrap();

    try registry.markCandidate("github.pull_request.merged", "candidate/task-1");
    try std.testing.expectEqual(Status.candidate, registry.status("github.pull_request.merged"));
    try std.testing.expect(!registry.isAvailable("github.pull_request.merged"));

    try registry.activate("github.pull_request.merged", "candidate/task-1");
    try std.testing.expect(registry.isAvailable("github.pull_request.merged"));
}
