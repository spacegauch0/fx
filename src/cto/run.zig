pub const Status = enum { started, succeeded, failed, interrupted };

pub const Run = struct {
    id: u64,
    task_id: u64,
    worker: []const u8,
    status: Status = .started,
    started_at_ms: i64 = 0,
    finished_at_ms: ?i64 = null,
    /// Set only for `.failed`/`.interrupted` outcomes: why, in a form
    /// suitable for `fx cto runs` and the journal (e.g. "timeout",
    /// "interrupted by operator", or a crash's error name). Never set for
    /// `.succeeded`, where the run summary already says enough.
    finished_reason: ?[]const u8 = null,
};
