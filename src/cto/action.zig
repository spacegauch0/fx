const std = @import("std");

/// The canonical vocabulary of "what this system can be asked to do,"
/// shared by every transport: the CLI (`main.zig`), the human-channel
/// text bridge (`channel.zig`), and the daemon's control socket
/// (`daemon.zig`/`control_protocol.zig`). Before this existed, the CLI and
/// `channel.zig` each maintained their own notion of the action surface
/// independently and had already drifted — `channel.Command` covers only
/// `status/goals/runs/decisions/approve/interrupt`, missing `request`,
/// `activate`, `rollback`, `review`, and `ingest` entirely, none of which
/// were deliberately excluded. A daemon adds a third transport; giving it
/// a third independent enum would make that drift worse, not better
/// (docs/CTO_ROADMAP.md, D8).
///
/// `health` and `ready` are deliberately absent: they never touch the
/// kernel and exist only as a liveness/readiness probe for whatever is
/// listening on the other end of a transport, so they live in the
/// transport's own protocol type instead (`control_protocol.Command`).
pub const Action = enum {
    status,
    capabilities,
    tasks,
    goals,
    runs,
    decisions,
    observations,
    events,
    releases,
    request,
    review,
    approve,
    activate,
    rollback,
    interrupt,
    ingest,
    brief,
    explain,

    /// Actions that mutate `.cto/` state and therefore need the writer
    /// lock (D4) when no daemon owns it, and are refused rather than
    /// silently raced when one does.
    pub fn isMutating(self: Action) bool {
        return switch (self) {
            .request, .approve, .activate, .rollback, .interrupt, .ingest => true,
            .status, .capabilities, .tasks, .goals, .runs, .decisions, .observations, .events, .releases, .review, .brief, .explain => false,
        };
    }
};

test "every action self-reports whether it mutates state" {
    try std.testing.expect(Action.request.isMutating());
    try std.testing.expect(Action.approve.isMutating());
    try std.testing.expect(!Action.status.isMutating());
    try std.testing.expect(!Action.review.isMutating());
}
