const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const store = @import("store.zig");

/// Decision D4: whoever holds this lock is the single writer of `.cto/`.
/// The daemon (when running) holds it for its whole lifetime; a direct CLI
/// mutation acquires it only for the duration of one command. Either way,
/// a second writer is refused rather than racing whole-file JSON
/// read-modify-write cycles.
pub const Guard = struct {
    verified_root: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn release(self: *Guard) void {
        self.lock.release();
        self.verified_root.close();
        self.* = undefined;
    }
};

/// Acquires the one writer lock used by both direct CLI mutation and the
/// daemon. `cto_root` is verified as a private `0700` directory before the
/// lock file inside it is trusted, reusing fx's hardened durable-state
/// primitives (`io_mod.openOrCreateVerifiedPrivateDirFromDir`,
/// `io_mod.acquireTimedAdvisoryLock`) rather than new file-locking code.
///
/// `cto_root_input` may be relative; it is resolved the same way
/// `Kernel.init` resolves it, so the lock always lands next to the state
/// it protects regardless of the caller's current directory.
pub fn acquire(
    alloc: std.mem.Allocator,
    cto_root_input: []const u8,
    deadline_ms: u64,
) !Guard {
    const root = try store.resolveAbsolute(alloc, cto_root_input);
    defer alloc.free(root);
    const parent_path = std.fs.path.dirname(root) orelse return error.InvalidCtoRoot;
    const leaf = std.fs.path.basename(root);

    var parent = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent_path, .{ .iterate = true });
    defer parent.close(io_mod.getIo());

    var verified_root = try io_mod.openOrCreateVerifiedPrivateDirFromDir(parent, leaf);
    errdefer verified_root.close();
    const lock = try io_mod.acquireTimedAdvisoryLock(&verified_root, "writer.lock", deadline_ms);
    return .{ .verified_root = verified_root, .lock = lock };
}

test "a second writer is refused while the first holds the lock" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });
    defer alloc.free(cto_root);
    try io_mod.makeDirRecursive(cto_root);

    var first = try acquire(alloc, cto_root, 50);
    defer first.release();

    try std.testing.expectError(error.LockBusy, acquire(alloc, cto_root, 50));
}

test "the lock releases cleanly so a later acquire succeeds" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });
    defer alloc.free(cto_root);
    try io_mod.makeDirRecursive(cto_root);

    var first = try acquire(alloc, cto_root, 50);
    first.release();

    var second = try acquire(alloc, cto_root, 50);
    second.release();
}
