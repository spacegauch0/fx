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
///
/// Returns an empty diff, rather than erroring, when the worktree has no
/// `src/cto/extensions/` directory at all: `git add -N` requires the
/// pathspec to match something on disk, and a dry-run or otherwise
/// unchanged candidate never creates that directory.
pub fn extensionDiff(alloc: std.mem.Allocator, worktree_path: []const u8) ![]u8 {
    const extensions_path = try std.fs.path.join(alloc, &.{ worktree_path, "src", "cto", "extensions" });
    defer alloc.free(extensions_path);
    if (!try dirExists(extensions_path)) return alloc.alloc(u8, 0);

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

/// Paths a candidate commit is allowed to contain. Committing an explicit
/// pathspec rather than `-A` means build artifacts (`.zig-cache/`,
/// `zig-out/`) can never enter a release commit even in a worktree with no
/// gitignore, and enforces the extension boundary a second time at the
/// moment work becomes immutable.
pub const candidate_commit_paths = [_][]const u8{
    "src/cto/extensions",
    ".cto-task-prompt.md",
};

/// Commits the candidate's boundary-allowed work to its own branch and
/// returns the resulting commit SHA (caller-owned).
///
/// Identity is supplied per-invocation so this never depends on, or
/// mutates, the repository's configured `user.name`/`user.email`. When
/// there is nothing to commit the existing HEAD is returned, which is the
/// honest result for an approved candidate that changed nothing.
pub fn commitCandidate(
    alloc: std.mem.Allocator,
    worktree_path: []const u8,
    message: []const u8,
) ![]u8 {
    // Each path is staged independently and only when it exists on disk.
    // `git add -- a b` fails wholesale when *any* pathspec matches nothing
    // and then stages neither, so a single batched add would silently
    // produce an empty release commit whenever a candidate wrote only one
    // of these.
    var staged_any = false;
    for (candidate_commit_paths) |candidate_path| {
        if (try stagePathIfPresent(alloc, worktree_path, candidate_path)) staged_any = true;
    }
    if (!staged_any) return headSha(alloc, worktree_path);

    const commit_result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{
            "git",                         "-C",
            worktree_path,                 "-c",
            "user.name=cto-dev",           "-c",
            "user.email=cto-dev@fx.local", "commit",
            "--quiet",                     "--no-verify",
            "-m",                          message,
        },
    });
    alloc.free(commit_result.stdout);
    alloc.free(commit_result.stderr);
    // A non-zero exit means nothing was actually different from HEAD, which
    // is a legitimate outcome; HEAD below then reports the unchanged commit.

    return headSha(alloc, worktree_path);
}

/// Stages one path when it exists, reporting whether anything was staged.
fn stagePathIfPresent(
    alloc: std.mem.Allocator,
    worktree_path: []const u8,
    sub_path: []const u8,
) !bool {
    const full = try std.fs.path.join(alloc, &.{ worktree_path, sub_path });
    defer alloc.free(full);
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), full, .{}) catch return false;
    _ = stat;

    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "git", "-C", worktree_path, "add", "--", sub_path },
    }) catch |err| return switch (err) {
        error.FileNotFound => error.GitUnavailable,
        else => err,
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return termExitedZero(result.term);
}

/// Returns the caller-owned commit SHA at a worktree's HEAD.
pub fn headSha(alloc: std.mem.Allocator, worktree_path: []const u8) ![]u8 {
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "git", "-C", worktree_path, "rev-parse", "HEAD" },
    }) catch |err| return switch (err) {
        error.FileNotFound => error.GitUnavailable,
        else => err,
    };
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);
    if (!termExitedZero(result.term)) return error.GitCommandFailed;

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.GitCommandFailed;
    const sha = try alloc.dupe(u8, trimmed);
    alloc.free(result.stdout);
    return sha;
}

/// Materializes a worktree pinned to an exact commit.
///
/// Detached on purpose: a release is an immutable snapshot, and git
/// refuses to check the same branch out in two worktrees at once, so a
/// branch-based release would collide with the candidate worktree that
/// still holds it.
pub fn addWorktreeDetached(
    alloc: std.mem.Allocator,
    repository_path: []const u8,
    worktree_path: []const u8,
    commit: []const u8,
) !void {
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{
            "git", "-C", repository_path, "worktree", "add", "--detach", worktree_path, commit,
        },
    }) catch |err| return switch (err) {
        error.FileNotFound => error.GitUnavailable,
        else => err,
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!termExitedZero(result.term)) return error.GitWorktreeFailed;
}

fn dirExists(path: []const u8) !bool {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    dir.close(io_mod.getIo());
    return true;
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

test "extensionDiff returns empty rather than erroring when extensions/ was never created" {
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

    // No src/cto/extensions/ directory anywhere in this worktree: this is
    // the common case for a dry-run task (fx cto review must not crash).
    const diff = try extensionDiff(alloc, root);
    defer alloc.free(diff);
    try std.testing.expectEqual(@as(usize, 0), diff.len);
}

test "commitCandidate captures extension work and excludes build artifacts" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "init", "--quiet" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "config", "user.email", "seed@example.com" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "config", "user.name", "seed" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "README.md", .data = "seed\n" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "add", "README.md" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "commit", "--quiet", "-m", "seed" });
    const before = try headSha(alloc, root);
    defer alloc.free(before);

    // A candidate that wrote a connector, the durable prompt, and the build
    // artifacts a `zig build` leaves behind.
    try tmp.dir.createDirPath(std.testing.io, "src/cto/extensions");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/cto/extensions/gen.zig",
        .data = "pub const id = \"gen\";\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".cto-task-prompt.md", .data = "prompt\n" });
    try tmp.dir.createDirPath(std.testing.io, ".zig-cache");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zig-cache/junk.o", .data = "binary\n" });

    const sha = try commitCandidate(alloc, root, "cto: candidate");
    defer alloc.free(sha);
    try std.testing.expect(!std.mem.eql(u8, before, sha));

    const listing = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "git", "-C", root, "show", "--name-only", "--format=", sha },
    });
    defer alloc.free(listing.stdout);
    defer alloc.free(listing.stderr);

    try std.testing.expect(std.mem.find(u8, listing.stdout, "src/cto/extensions/gen.zig") != null);
    try std.testing.expect(std.mem.find(u8, listing.stdout, ".cto-task-prompt.md") != null);
    // The whole point: build output never enters a release commit, even
    // with no gitignore covering it.
    try std.testing.expect(std.mem.find(u8, listing.stdout, ".zig-cache") == null);
}

test "commitCandidate stages the prompt even when no extensions directory exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "init", "--quiet" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "config", "user.email", "seed@example.com" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "config", "user.name", "seed" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "README.md", .data = "seed\n" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "add", "README.md" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "commit", "--quiet", "-m", "seed" });
    const before = try headSha(alloc, root);
    defer alloc.free(before);

    // Only the prompt exists. A batched `git add -- src/cto/extensions
    // .cto-task-prompt.md` would fail on the missing directory and stage
    // nothing at all, silently losing this file.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".cto-task-prompt.md", .data = "prompt\n" });

    const sha = try commitCandidate(alloc, root, "cto: prompt only");
    defer alloc.free(sha);
    try std.testing.expect(!std.mem.eql(u8, before, sha));

    const listing = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "git", "-C", root, "show", "--name-only", "--format=", sha },
    });
    defer alloc.free(listing.stdout);
    defer alloc.free(listing.stderr);
    try std.testing.expect(std.mem.find(u8, listing.stdout, ".cto-task-prompt.md") != null);
}

test "commitCandidate on an unchanged worktree keeps HEAD rather than failing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "init", "--quiet" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "config", "user.email", "seed@example.com" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "config", "user.name", "seed" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "README.md", .data = "seed\n" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "add", "README.md" });
    try runGitOrSkip(alloc, &.{ "git", "-C", root, "commit", "--quiet", "-m", "seed" });

    const before = try headSha(alloc, root);
    defer alloc.free(before);
    const sha = try commitCandidate(alloc, root, "cto: nothing to do");
    defer alloc.free(sha);
    try std.testing.expectEqualStrings(before, sha);
}

fn runGitOrSkip(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.run(alloc, io_mod.getIo(), .{ .argv = argv }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!termExitedZero(result.term)) return error.SkipZigTest;
}
