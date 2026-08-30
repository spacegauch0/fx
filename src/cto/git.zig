const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

/// Creates a git worktree for a task's implementation work.
///
/// The task owns this worktree, not the worker: the kernel/runtime creates
/// it before a worker ever runs, and the worker is only ever handed a path
/// that already exists.
pub fn addWorktree(
    alloc: std.mem.Allocator,
    repository_path: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
) !void {
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{
            "git",
            "-C",
            repository_path,
            "worktree",
            "add",
            "-b",
            branch,
            worktree_path,
            "HEAD",
        },
    }) catch |err| return switch (err) {
        error.FileNotFound => error.GitUnavailable,
        else => err,
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (!termExitedZero(result.term)) return error.GitWorktreeFailed;
}

pub fn termExitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Returns a caller-owned diff for the self-generated extension boundary.
/// Intent-to-add makes new untracked connector files visible in the diff
/// without staging their contents or creating a commit.
pub fn extensionDiff(alloc: std.mem.Allocator, worktree_path: []const u8) ![]u8 {
    try runOk(alloc, &.{
        "git", "-C", worktree_path, "add", "-N", "--", "src/cto/extensions",
    });
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{
            "git", "-C", worktree_path, "diff", "--no-ext-diff", "--", "src/cto/extensions",
        },
    });
    defer alloc.free(result.stderr);
    if (!termExitedZero(result.term)) {
        alloc.free(result.stdout);
        return error.GitDiffFailed;
    }
    return result.stdout;
}

fn runOk(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.run(alloc, io_mod.getIo(), .{ .argv = argv }) catch |err| return switch (err) {
        error.FileNotFound => error.GitUnavailable,
        else => err,
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!termExitedZero(result.term)) return error.GitCommandFailed;
}

test "addWorktree creates an isolated checkout on its own branch" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    try runGitOrSkip(alloc, &.{ "git", "-C", root, "init", "--quiet" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "config", "user.email", "cto@example.com" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "config", "user.name", "cto" });

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "README.md", .data = "seed\n" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "add", "README.md" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "commit", "--quiet", "-m", "seed" });

    const worktree_path = try std.fs.path.join(alloc, &.{ root, "worktree-task-1" });
    defer alloc.free(worktree_path);

    try addWorktree(alloc, root, worktree_path, "cto/task-1");

    var worktree_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), worktree_path, .{});
    defer worktree_dir.close(io_mod.getIo());
    const stat = try worktree_dir.statFile(io_mod.getIo(), "README.md", .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
}

test "extensionDiff includes a new untracked connector" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "init", "--quiet" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "config", "user.email", "cto@example.com" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "config", "user.name", "cto" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "README.md", .data = "seed\n" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "add", "README.md" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "commit", "--quiet", "-m", "seed" });

    try tmp.dir.createDirPath(std.testing.io, "src/cto/extensions");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/cto/extensions/github_events.zig",
        .data = "pub const id = \"github\";\n",
    });

    const diff = try extensionDiff(alloc, root);
    defer alloc.free(diff);
    try std.testing.expect(std.mem.find(u8, diff, "github_events.zig") != null);
    try std.testing.expect(std.mem.find(u8, diff, "+pub const id = \"github\";") != null);
}

fn runGitOrSkip(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.run(alloc, io_mod.getIo(), .{ .argv = argv }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!termExitedZero(result.term)) return error.SkipZigTest;
}
