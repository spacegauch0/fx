const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const git = @import("git.zig");

/// Result of validating a candidate implementation inside its worktree.
///
/// This is the `self.build` / `self.test` capability in action: the kernel
/// proves a candidate compiles and passes its tests before it is ever
/// eligible for human approval.
pub const ValidationResult = struct {
    build_ok: bool,
    test_ok: bool,
    log: []const u8,
};

pub fn validate(alloc: std.mem.Allocator, worktree_path: []const u8) !ValidationResult {
    var log: std.ArrayList(u8) = .empty;
    errdefer log.deinit(alloc);

    const build_ok = try runStep(alloc, worktree_path, &.{ "zig", "build" }, "zig build", &log);
    const test_ok = if (build_ok)
        try runStep(alloc, worktree_path, &.{ "zig", "build", "test" }, "zig build test", &log)
    else
        false;

    return .{
        .build_ok = build_ok,
        .test_ok = test_ok,
        .log = try log.toOwnedSlice(alloc),
    };
}

fn runStep(
    alloc: std.mem.Allocator,
    worktree_path: []const u8,
    argv: []const []const u8,
    label: []const u8,
    log: *std.ArrayList(u8),
) !bool {
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = worktree_path },
    }) catch |err| {
        const message = try std.fmt.allocPrint(alloc, "== {s} ==\nfailed to spawn: {s}\n", .{ label, @errorName(err) });
        defer alloc.free(message);
        try log.appendSlice(alloc, message);
        return false;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const header = try std.fmt.allocPrint(alloc, "== {s} ==\n", .{label});
    defer alloc.free(header);
    try log.appendSlice(alloc, header);
    try log.appendSlice(alloc, result.stdout);
    try log.appendSlice(alloc, result.stderr);

    return git.termExitedZero(result.term);
}
