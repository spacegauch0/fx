pub const TaskStatus = enum {
    created,
    delegated,
    working,
    approval_required,
    completed,
    rejected,
    failed,
};

/// A durable unit of work the kernel tracks across process invocations.
///
/// The worktree and candidate fields intentionally live on the task, not on
/// the worker that implemented it: the task owns its worktree so a task
/// survives the fx session that worked on it.
pub const Task = struct {
    id: u64,
    objective: []const u8,
    assignee: []const u8,
    required_capability: []const u8,
    status: TaskStatus,
    candidate_ref: ?[]const u8 = null,
    worktree_path: ?[]const u8 = null,
    build_ok: bool = false,
    test_ok: bool = false,
    created_at_ms: i64 = 0,
};
