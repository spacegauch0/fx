const std = @import("std");

/// The four independently-numbered `u64` counters this system hands out
/// (`Kernel.next_task_id`, `next_run_id`, `next_release_version`,
/// `next_goal_id`), each starting at 1. Displayed and parsed as
/// `<prefix>-<id>` (`task-7`, `run-12`) everywhere, per
/// docs/CTO_ROADMAP.md D7: four counters that all start at 1 and print as
/// a bare `#7` is a standing invitation to conflate one with another —
/// exactly the ambiguity M4 had to design around by hand when scoping
/// `fx cto interrupt` to run ids specifically.
pub const Kind = enum {
    task,
    run,
    release,
    goal,

    pub fn prefix(self: Kind) []const u8 {
        return switch (self) {
            .task => "task",
            .run => "run",
            .release => "release",
            .goal => "goal",
        };
    }
};

pub fn format(alloc: std.mem.Allocator, kind: Kind, value: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}-{d}", .{ kind.prefix(), value });
}

/// Formats into a caller-supplied buffer — for the common case (a
/// `std.debug.print`/`writer.print` call site) where an allocation would
/// be pure overhead. 32 bytes comfortably fits the longest prefix
/// (`release-`) plus a full `u64` in decimal.
pub fn formatBuf(buf: []u8, kind: Kind, value: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}-{d}", .{ kind.prefix(), value }) catch buf;
}

/// Accepts a bare integer or a *correctly*-prefixed id (`task-7` for
/// `.task`, never `run-7`). Used where the surrounding command already
/// scopes the entity kind unambiguously (`approve`, `activate`, `review`,
/// and `rollback` only ever mean a task) — a bare integer stays accepted
/// there for scripts and muscle memory, but a wrongly-prefixed one is
/// rejected rather than silently reinterpreted, since typing `run-7` for
/// `fx cto approve` is far more likely a mistake than a request to
/// approve task 7.
pub fn parse(kind: Kind, text: []const u8) ?u64 {
    if (std.mem.indexOfScalar(u8, text, '-')) |dash| {
        if (!std.mem.eql(u8, text[0..dash], kind.prefix())) return null;
        return std.fmt.parseInt(u64, text[dash + 1 ..], 10) catch null;
    }
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// Requires the exact `<kind>-<id>` form; a bare integer is refused. Used
/// exactly where a bare integer would be genuinely ambiguous between two
/// different counters that are both small integers starting at 1 — a task
/// id and a run id in particular — so `interrupt` and `logs` use this
/// instead of `parse`.
pub fn parseStrict(kind: Kind, text: []const u8) ?u64 {
    const dash = std.mem.indexOfScalar(u8, text, '-') orelse return null;
    if (!std.mem.eql(u8, text[0..dash], kind.prefix())) return null;
    return std.fmt.parseInt(u64, text[dash + 1 ..], 10) catch null;
}

test "format produces the canonical prefixed form" {
    const alloc = std.testing.allocator;
    const text = try format(alloc, .task, 7);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("task-7", text);
}

test "formatBuf matches format without allocating" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("run-12", formatBuf(&buf, .run, 12));
    try std.testing.expectEqualStrings("release-3", formatBuf(&buf, .release, 3));
    try std.testing.expectEqualStrings("goal-2", formatBuf(&buf, .goal, 2));
}

test "parse accepts a bare integer or the correctly-prefixed form" {
    try std.testing.expectEqual(@as(?u64, 7), parse(.task, "7"));
    try std.testing.expectEqual(@as(?u64, 7), parse(.task, "task-7"));
}

test "parse rejects a wrongly-prefixed id rather than silently reinterpreting it" {
    try std.testing.expectEqual(@as(?u64, null), parse(.task, "run-7"));
    try std.testing.expectEqual(@as(?u64, null), parse(.task, "not-a-number"));
    try std.testing.expectEqual(@as(?u64, null), parse(.task, ""));
}

test "parseStrict refuses a bare integer, unlike parse" {
    try std.testing.expectEqual(@as(?u64, null), parseStrict(.run, "12"));
    try std.testing.expectEqual(@as(?u64, 12), parseStrict(.run, "run-12"));
    try std.testing.expectEqual(@as(?u64, null), parseStrict(.run, "task-12"));
}
