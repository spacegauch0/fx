const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const git = @import("git.zig");

/// Result of validating a candidate implementation inside its worktree.
///
/// This is the `self.build` / `self.test` capability in action: the kernel
/// proves a candidate compiles and passes its tests before it is ever
/// eligible for human approval.
pub const ValidationResult = struct {
    boundary_ok: bool,
    build_ok: bool,
    test_ok: bool,
    log: []const u8,
};

/// Build and test outcome with no boundary component. A materialized
/// release is already-approved, already-committed code, so re-running the
/// working-tree boundary check against it would be meaningless (it is
/// clean by construction) — the question there is only whether it builds
/// and passes.
pub const HealthResult = struct {
    build_ok: bool,
    test_ok: bool,
    log: []const u8,

    pub fn healthy(self: HealthResult) bool {
        return self.build_ok and self.test_ok;
    }
};

pub fn validate(alloc: std.mem.Allocator, worktree_path: []const u8) !ValidationResult {
    var log: std.ArrayList(u8) = .empty;
    errdefer log.deinit(alloc);

    const boundary_ok = try validateExtensionBoundary(alloc, worktree_path, &log);
    var build_ok = false;
    var test_ok = false;
    if (boundary_ok) {
        build_ok = try runStep(alloc, worktree_path, &.{ "zig", "build" }, "zig build", &log);
        if (build_ok) {
            test_ok = try runStep(alloc, worktree_path, &.{ "zig", "build", "test" }, "zig build test", &log);
        }
    }

    return .{
        .boundary_ok = boundary_ok,
        .build_ok = build_ok,
        .test_ok = test_ok,
        .log = try log.toOwnedSlice(alloc),
    };
}

/// Runs the release health check inside a materialized release worktree.
/// Called before the active pointer moves, so a release that cannot build
/// never becomes current.
pub fn healthCheck(alloc: std.mem.Allocator, release_path: []const u8) !HealthResult {
    var log: std.ArrayList(u8) = .empty;
    errdefer log.deinit(alloc);

    const build_ok = try runStep(alloc, release_path, &.{ "zig", "build" }, "zig build", &log);
    const test_ok = if (build_ok)
        try runStep(alloc, release_path, &.{ "zig", "build", "test" }, "zig build test", &log)
    else
        false;

    return .{
        .build_ok = build_ok,
        .test_ok = test_ok,
        .log = try log.toOwnedSlice(alloc),
    };
}

fn validateExtensionBoundary(
    alloc: std.mem.Allocator,
    worktree_path: []const u8,
    log: *std.ArrayList(u8),
) !bool {
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{
            "git", "-C", worktree_path, "status", "--porcelain=v1", "-z", "--untracked-files=all",
        },
    }) catch |err| {
        const message = try std.fmt.allocPrint(alloc, "== extension boundary ==\nfailed to inspect changes: {s}\n", .{@errorName(err)});
        defer alloc.free(message);
        try log.appendSlice(alloc, message);
        return false;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!git.termExitedZero(result.term)) return false;

    var valid = true;
    var records = std.mem.splitScalar(u8, result.stdout, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        if (record.len < 4 or record[2] != ' ') {
            valid = false;
            try log.appendSlice(alloc, "extension boundary rejected malformed git status record\n");
            continue;
        }
        const path = record[3..];
        const allowed = isAllowedChangedPath(path);
        if (!allowed) {
            valid = false;
            const message = try std.fmt.allocPrint(alloc, "extension boundary rejected: {s}\n", .{path});
            defer alloc.free(message);
            try log.appendSlice(alloc, message);
        }
    }
    if (valid) try log.appendSlice(alloc, "extension boundary: ok\n");
    return valid;
}

fn isAllowedChangedPath(path: []const u8) bool {
    return std.mem.eql(u8, path, ".cto-task-prompt.md") or
        std.mem.startsWith(u8, path, "src/cto/extensions/");
}

test "extension boundary accepts connector files and rejects kernel changes" {
    try std.testing.expect(isAllowedChangedPath(".cto-task-prompt.md"));
    try std.testing.expect(isAllowedChangedPath("src/cto/extensions/github_events.zig"));
    try std.testing.expect(isAllowedChangedPath("src/cto/extensions/fixtures/pull_request_merged.json"));
    try std.testing.expect(!isAllowedChangedPath("src/cto/kernel.zig"));
    try std.testing.expect(!isAllowedChangedPath("src/cto/extensions-escape.zig"));
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
