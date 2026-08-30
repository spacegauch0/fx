const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

pub const EventKind = enum {
    human_requested,
    capability_missing,
    capability_candidate,
    capability_activated,
    task_created,
    task_delegated,
    worker_started,
    worker_completed,
    worker_failed,
    candidate_ready,
    approval_requested,
    approval_granted,
    approval_rejected,
    goal_created,
    policy_allowed,
    policy_approval_required,
    policy_denied,
    run_started,
    run_finished,
    observation_recorded,
    observation_duplicate,
};

pub const Event = struct {
    sequence: u64,
    kind: EventKind,
    subject: []const u8,
    detail: []const u8,
    timestamp_ms: i64,

    pub fn init(
        sequence: u64,
        kind: EventKind,
        subject: []const u8,
        detail: []const u8,
    ) Event {
        return .{
            .sequence = sequence,
            .kind = kind,
            .subject = subject,
            .detail = detail,
            .timestamp_ms = io_mod.milliTimestamp(),
        };
    }
};
