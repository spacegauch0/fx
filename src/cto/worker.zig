const std = @import("std");

pub const WorkRequest = struct {
    task_id: u64,
    repository_path: []const u8,
    worktree_path: []const u8,
    prompt: []const u8,
};

pub const WorkResult = struct {
    success: bool,
    summary: []const u8,
};

/// Type-erased worker boundary so the kernel/runtime never depend on a
/// concrete worker implementation. `FxWorker` (fx_worker.zig) is the only
/// implementation today, but the seam keeps the kernel from hard-coding how
/// work gets done.
pub const Worker = struct {
    context: *anyopaque,
    runFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: WorkRequest,
    ) anyerror!WorkResult,

    pub fn run(
        self: Worker,
        allocator: std.mem.Allocator,
        request: WorkRequest,
    ) !WorkResult {
        return self.runFn(self.context, allocator, request);
    }
};
