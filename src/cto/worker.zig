const std = @import("std");

/// Default wall-clock budget for one worker attempt: generous enough for a
/// real build-and-test cycle, bounded so a wedged or looping agent cannot
/// run forever. Only enforced by a worker that actually runs
/// out-of-process (`process_worker.zig`); an in-process call cannot be
/// preempted and ignores this.
pub const default_timeout_ms: i64 = 30 * 60 * 1000;

pub const Outcome = enum {
    succeeded,
    failed,
    timed_out,
    interrupted,
};

pub const WorkRequest = struct {
    task_id: u64,
    /// The kernel-assigned run id for this attempt. Out-of-process workers
    /// key their pid file, log, and interrupt marker off this so a
    /// concurrent `fx cto interrupt <run-id>` can find and cancel exactly
    /// this attempt, even across separate CLI invocations.
    run_id: u64,
    repository_path: []const u8,
    worktree_path: []const u8,
    /// Absolute `.cto` root (`Kernel.cto_root`). Passed explicitly rather
    /// than re-derived from `repository_path` so a worker's bookkeeping
    /// always lands next to the rest of this task's audit trail even when
    /// `cto_root` is configured somewhere other than `<repo>/.cto`.
    cto_root: []const u8,
    prompt: []const u8,
    timeout_ms: i64 = default_timeout_ms,
};

pub const WorkResult = struct {
    outcome: Outcome,
    summary: []const u8,

    pub fn success(self: WorkResult) bool {
        return self.outcome == .succeeded;
    }
};

/// Type-erased worker boundary so the kernel/runtime never depend on a
/// concrete worker implementation. `FxWorker` (fx_worker.zig, in-process)
/// and `ProcessWorker` (process_worker.zig, out-of-process) both implement
/// this; the seam keeps the kernel from hard-coding how work gets done.
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
