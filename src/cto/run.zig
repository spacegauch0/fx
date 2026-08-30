pub const Status = enum { started, succeeded, failed, interrupted };

pub const Run = struct {
    id: u64,
    task_id: u64,
    worker: []const u8,
    status: Status = .started,
    started_at_ms: i64 = 0,
    finished_at_ms: ?i64 = null,
};
