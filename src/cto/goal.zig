pub const Status = enum { active, achieved, abandoned };

pub const Goal = struct {
    id: u64,
    objective: []const u8,
    status: Status = .active,
    created_at_ms: i64 = 0,
};
