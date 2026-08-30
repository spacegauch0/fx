//! Versioned releases and the active-version pointer.
//!
//! An approved candidate is materialized as an immutable, detached
//! worktree under `.cto/releases/v<n>/`, health-checked there, and only
//! then does `.cto/current` start pointing at it.
//!
//! The symlink is the single source of truth for which release is active.
//! `releases.json` carries history and metadata *about* releases but never
//! decides which one is live, so the two cannot disagree.
//!
//! Note what this does and does not do: activation switches a validated
//! pointer, it does not replace the running `fx` binary. An operator
//! builds or installs from `.cto/current`. Hot-swapping a live process is
//! deliberately out of scope (docs/CTO_POC.md).

const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

pub const releases_dir_name = "releases";
pub const current_link_name = "current";

pub const Release = struct {
    version: u64,
    task_id: u64,
    capability: []const u8,
    /// Branch the candidate work was committed to. Never a human branch.
    branch: []const u8,
    /// Exact commit the release worktree is pinned to.
    commit: []const u8,
    path: []const u8,
    build_ok: bool,
    test_ok: bool,
    activated_at_ms: i64,
};

pub fn releasesDir(alloc: std.mem.Allocator, cto_root: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ cto_root, releases_dir_name });
}

pub fn releasePath(alloc: std.mem.Allocator, cto_root: []const u8, version: u64) ![]u8 {
    const name = try std.fmt.allocPrint(alloc, "v{d}", .{version});
    defer alloc.free(name);
    return std.fs.path.join(alloc, &.{ cto_root, releases_dir_name, name });
}

pub fn currentLinkPath(alloc: std.mem.Allocator, cto_root: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ cto_root, current_link_name });
}

/// Points `.cto/current` at `target_path` atomically.
///
/// `symLinkAtomic` writes a uniquely-named temporary link in the same
/// directory and renames it over the destination, so a reader either sees
/// the old release or the new one and never a missing or partial link.
pub fn pointCurrentAt(cto_root: []const u8, target_path: []const u8) !void {
    const zio = io_mod.getIo();
    var dir = try std.Io.Dir.openDirAbsolute(zio, cto_root, .{});
    defer dir.close(zio);
    try dir.symLinkAtomic(zio, target_path, current_link_name, .{ .is_directory = true });
}

/// Returns the caller-owned path `.cto/current` resolves to, or null when
/// no release has ever been activated.
pub fn readCurrent(alloc: std.mem.Allocator, cto_root: []const u8) !?[]u8 {
    const link_path = try currentLinkPath(alloc, cto_root);
    defer alloc.free(link_path);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(io_mod.getIo(), link_path, &buffer) catch |err| switch (err) {
        error.FileNotFound, error.NotLink => return null,
        else => return err,
    };
    return try alloc.dupe(u8, buffer[0..len]);
}

/// The release `.cto/current` currently points at, if any.
pub fn activeRelease(alloc: std.mem.Allocator, cto_root: []const u8, releases: []const Release) !?Release {
    const current = try readCurrent(alloc, cto_root) orelse return null;
    defer alloc.free(current);
    for (releases) |release| {
        if (std.mem.eql(u8, release.path, current)) return release;
    }
    return null;
}

/// The newest release older than `version`, which is what a rollback
/// returns to. Null when there is nothing to roll back to.
pub fn previousRelease(releases: []const Release, version: u64) ?Release {
    var best: ?Release = null;
    for (releases) |release| {
        if (release.version >= version) continue;
        if (best == null or release.version > best.?.version) best = release;
    }
    return best;
}

test "release paths are versioned under the releases directory" {
    const alloc = std.testing.allocator;
    const path = try releasePath(alloc, "/repo/.cto", 3);
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/repo/.cto/releases/v3", path);

    const link = try currentLinkPath(alloc, "/repo/.cto");
    defer alloc.free(link);
    try std.testing.expectEqualStrings("/repo/.cto/current", link);
}

test "previousRelease picks the newest strictly older version" {
    const releases = [_]Release{
        .{ .version = 1, .task_id = 1, .capability = "a", .branch = "b", .commit = "c", .path = "/p1", .build_ok = true, .test_ok = true, .activated_at_ms = 1 },
        .{ .version = 2, .task_id = 2, .capability = "a", .branch = "b", .commit = "c", .path = "/p2", .build_ok = true, .test_ok = true, .activated_at_ms = 2 },
        .{ .version = 3, .task_id = 3, .capability = "a", .branch = "b", .commit = "c", .path = "/p3", .build_ok = true, .test_ok = true, .activated_at_ms = 3 },
    };
    try std.testing.expectEqual(@as(u64, 2), previousRelease(&releases, 3).?.version);
    try std.testing.expectEqual(@as(u64, 1), previousRelease(&releases, 2).?.version);
    // Nothing precedes the first release, so there is nothing to roll back to.
    try std.testing.expect(previousRelease(&releases, 1) == null);
    try std.testing.expect(previousRelease(&.{}, 5) == null);
}

test "current pointer swaps atomically and resolves to the newest target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cto_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(cto_root);

    try std.testing.expect((try readCurrent(alloc, cto_root)) == null);

    const first = try std.fs.path.join(alloc, &.{ cto_root, "v1" });
    defer alloc.free(first);
    const second = try std.fs.path.join(alloc, &.{ cto_root, "v2" });
    defer alloc.free(second);
    try io_mod.makeDirRecursive(first);
    try io_mod.makeDirRecursive(second);

    try pointCurrentAt(cto_root, first);
    {
        const resolved = (try readCurrent(alloc, cto_root)).?;
        defer alloc.free(resolved);
        try std.testing.expectEqualStrings(first, resolved);
    }

    // Repointing over an existing link must succeed rather than fail with
    // PathAlreadyExists, which is the whole point of the atomic swap.
    try pointCurrentAt(cto_root, second);
    {
        const resolved = (try readCurrent(alloc, cto_root)).?;
        defer alloc.free(resolved);
        try std.testing.expectEqualStrings(second, resolved);
    }

    // Rolling back is the same operation in the other direction.
    try pointCurrentAt(cto_root, first);
    const rolled_back = (try readCurrent(alloc, cto_root)).?;
    defer alloc.free(rolled_back);
    try std.testing.expectEqualStrings(first, rolled_back);
}

test "activeRelease matches the pointer against recorded releases" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cto_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(cto_root);

    const v1 = try std.fs.path.join(alloc, &.{ cto_root, "v1" });
    defer alloc.free(v1);
    try io_mod.makeDirRecursive(v1);

    const releases = [_]Release{
        .{ .version = 1, .task_id = 7, .capability = "cap", .branch = "candidate/task-7", .commit = "abc", .path = v1, .build_ok = true, .test_ok = true, .activated_at_ms = 1 },
    };

    try std.testing.expect((try activeRelease(alloc, cto_root, &releases)) == null);
    try pointCurrentAt(cto_root, v1);
    try std.testing.expectEqual(@as(u64, 1), (try activeRelease(alloc, cto_root, &releases)).?.version);
}
