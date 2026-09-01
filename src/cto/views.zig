//! Renders read-only kernel state to a `std.Io.Writer`. Deliberately the
//! only place these views are formatted: `main.zig`'s CLI printers and
//! `daemon.zig`'s control-socket read-command handler both call these same
//! functions rather than keeping two independently-formatted copies of
//! "what does `tasks` look like" that could silently drift apart (the
//! class of problem docs/CTO_ROADMAP.md's D8/D9 exist to close).

const std = @import("std");
const id_mod = @import("id.zig");
const io_mod = @import("../core/shared/io.zig");
const kernel_mod = @import("kernel.zig");
const release_mod = @import("release.zig");

pub fn renderStatus(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel) !void {
    const counts = kernel.capabilities.count();
    var pending: usize = 0;
    for (kernel.tasks.items) |task| {
        switch (task.status) {
            .completed, .rejected, .failed => {},
            else => pending += 1,
        }
    }
    try writer.print(
        \\CTO runtime: ready
        \\counterpart: cto-dev
        \\worker: fx
        \\capabilities: {d} available, {d} missing
        \\pending tasks: {d}
        \\
    ,
        .{ counts.available, counts.missing, pending },
    );
}

pub fn renderCapabilities(writer: *std.Io.Writer, alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel) !void {
    const entries = try kernel.capabilities.sortedEntries(alloc);
    defer alloc.free(entries);
    for (entries) |capability| {
        try writer.print("{s}: {s} ({s})\n", .{ capability.name, @tagName(capability.status), capability.source });
    }
}

pub fn renderTasks(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel) !void {
    if (kernel.tasks.items.len == 0) {
        try writer.print("no tasks yet\n", .{});
        return;
    }
    var id_buf: [32]u8 = undefined;
    for (kernel.tasks.items) |task| {
        try writer.print(
            "{s} [{s}] {s} -> {s}\n",
            .{ id_mod.formatBuf(&id_buf, .task, task.id), @tagName(task.status), task.required_capability, task.assignee },
        );
    }
}

pub fn renderGoals(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel) !void {
    if (kernel.goals.items.len == 0) {
        try writer.print("no goals yet\n", .{});
        return;
    }
    var id_buf: [32]u8 = undefined;
    for (kernel.goals.items) |goal| {
        try writer.print("{s} [{s}] {s}\n", .{ id_mod.formatBuf(&id_buf, .goal, goal.id), @tagName(goal.status), goal.objective });
    }
}

pub fn renderRuns(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel) !void {
    if (kernel.runs.items.len == 0) {
        try writer.print("no runs yet\n", .{});
        return;
    }
    var run_id_buf: [32]u8 = undefined;
    var task_id_buf: [32]u8 = undefined;
    for (kernel.runs.items) |worker_run| {
        const run_id = id_mod.formatBuf(&run_id_buf, .run, worker_run.id);
        const task_id = id_mod.formatBuf(&task_id_buf, .task, worker_run.task_id);
        if (worker_run.finished_reason) |reason| {
            try writer.print(
                "{s} {s} [{s}] {s} ({s})\n",
                .{ run_id, task_id, @tagName(worker_run.status), worker_run.worker, reason },
            );
        } else {
            try writer.print(
                "{s} {s} [{s}] {s}\n",
                .{ run_id, task_id, @tagName(worker_run.status), worker_run.worker },
            );
        }
    }
}

pub fn renderReleases(writer: *std.Io.Writer, alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel) !void {
    if (kernel.releases.items.len == 0) {
        try writer.print("no releases yet\n", .{});
        return;
    }
    // The symlink, not the metadata file, decides which release is live.
    const current = try release_mod.readCurrent(alloc, kernel.cto_root);
    defer if (current) |value| alloc.free(value);

    var task_id_buf: [32]u8 = undefined;
    for (kernel.releases.items) |release| {
        const active = if (current) |value| std.mem.eql(u8, value, release.path) else false;
        try writer.print("v{d}{s} {s} {s} {s}\n", .{
            release.version,
            if (active) " (active)" else "",
            id_mod.formatBuf(&task_id_buf, .task, release.task_id),
            release.capability,
            release.commit,
        });
    }
}

pub fn renderObservations(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel) !void {
    if (kernel.observations.items.len == 0) {
        try writer.print("no observations yet\n", .{});
        return;
    }
    for (kernel.observations.items) |observation| {
        switch (observation.payload) {
            .pull_request_merged => |value| try writer.print(
                "[{s}] {s}#{d} \"{s}\" merged by {s} ({s})\n",
                .{
                    observation.provenance.provider,
                    observation.provenance.repository,
                    value.number,
                    value.title,
                    value.merged_by,
                    observation.provenance.delivery_id,
                },
            ),
        }
    }
}

pub fn renderDecisions(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel) !void {
    var found = false;
    for (kernel.journal.events.items) |event| {
        switch (event.kind) {
            .policy_allowed, .policy_approval_required, .policy_denied => {
                found = true;
                try writer.print(
                    "#{d} [{s}] {s} {s}\n",
                    .{ event.sequence, @tagName(event.kind), event.subject, event.detail },
                );
            },
            else => {},
        }
    }
    if (!found) try writer.print("no policy decisions yet\n", .{});
}

/// `since` filters to events with `sequence > since`; pass 0 for the full
/// history (sequences start at 1, so 0 excludes nothing). Lets an agent
/// check "what happened since I last looked" in O(new), not by rereading
/// the whole append-only journal on every check-in (D7).
pub fn renderEvents(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel, since: u64) !void {
    var found = false;
    for (kernel.journal.events.items) |event| {
        if (event.sequence <= since) continue;
        found = true;
        try writer.print(
            "{d} {s} {s}: {s}\n",
            .{ event.sequence, @tagName(event.kind), event.subject, event.detail },
        );
    }
    if (!found) {
        if (since == 0) {
            try writer.print("no events yet\n", .{});
        } else {
            try writer.print("no events since {d}\n", .{since});
        }
    }
}

/// Formats a duration (in ms) as a short relative form ("45s", "3m",
/// "2h", "5d"). Coarse on purpose: `renderBrief` uses this to answer "is
/// this overdue" at a glance, not to replace the exact `*_at_ms`
/// timestamp every entity still carries in its raw form.
fn formatElapsed(buf: []u8, elapsed_ms: i64) []const u8 {
    const ms = @max(elapsed_ms, 0);
    const total_s = @divTrunc(ms, 1000);
    if (total_s < 60) return std.fmt.bufPrint(buf, "{d}s", .{total_s}) catch buf;
    const total_m = @divTrunc(total_s, 60);
    if (total_m < 60) return std.fmt.bufPrint(buf, "{d}m", .{total_m}) catch buf;
    const total_h = @divTrunc(total_m, 60);
    if (total_h < 24) return std.fmt.bufPrint(buf, "{d}h", .{total_h}) catch buf;
    const total_d = @divTrunc(total_h, 24);
    return std.fmt.bufPrint(buf, "{d}d", .{total_d}) catch buf;
}

/// The full causal narrative for one entity, cross-referenced across
/// tasks, runs, releases, and (best-effort — see below) the journal, so
/// tracing "why is task-3 stuck" is one lookup instead of manually
/// joining `tasks`/`runs`/`events` by hand, which is what every session
/// building this milestone had to do before this existed (D7).
///
/// Honest limitation: `Event.subject` is a capability or worker name, not
/// a task id — the journal was never given a task-id field to filter on.
/// The "journal entries mentioning `<capability>`" section below is
/// therefore a same-capability match, not a guaranteed same-task match;
/// it is exact only when at most one task exists per capability, which
/// `Runtime.request`'s idempotency check makes the common case but not a
/// guarantee for tasks that reached a terminal state and were re-created.
/// `runs` (which do carry an exact `task_id`) are the part of this view
/// that is always precise.
pub fn renderExplain(
    writer: *std.Io.Writer,
    kernel: *kernel_mod.Kernel,
    kind: id_mod.Kind,
    entity_id: u64,
) !void {
    var id_buf: [32]u8 = undefined;
    const label = id_mod.formatBuf(&id_buf, kind, entity_id);
    switch (kind) {
        .task => try explainTask(writer, kernel, entity_id, label),
        .run => try explainRun(writer, kernel, entity_id, label),
        .release => try explainRelease(writer, kernel, entity_id, label),
        .goal => try explainGoal(writer, kernel, entity_id, label),
    }
}

fn explainTask(
    writer: *std.Io.Writer,
    kernel: *kernel_mod.Kernel,
    task_id: u64,
    label: []const u8,
) !void {
    const task = kernel.findTask(task_id) orelse {
        try writer.print("{s} was not found\n", .{label});
        return;
    };
    const now_ms = io_mod.milliTimestamp();
    var elapsed_buf: [16]u8 = undefined;
    try writer.print(
        "{s} [{s}] {s}\n  objective: {s}\n  assignee: {s}\n  created: {s} ago\n",
        .{
            label,
            @tagName(task.status),
            task.required_capability,
            task.objective,
            task.assignee,
            formatElapsed(&elapsed_buf, now_ms - task.created_at_ms),
        },
    );
    if (task.candidate_ref) |ref| {
        try writer.print("  candidate: {s} (build_ok={} test_ok={})\n", .{ ref, task.build_ok, task.test_ok });
    }
    if (task.worktree_path) |path| try writer.print("  worktree: {s}\n", .{path});

    var found_run = false;
    var run_id_buf: [32]u8 = undefined;
    for (kernel.runs.items) |worker_run| {
        if (worker_run.task_id != task_id) continue;
        if (!found_run) {
            try writer.print("\nruns:\n", .{});
            found_run = true;
        }
        const run_label = id_mod.formatBuf(&run_id_buf, .run, worker_run.id);
        if (worker_run.finished_reason) |reason| {
            try writer.print("  {s} [{s}] {s} ({s})\n", .{ run_label, @tagName(worker_run.status), worker_run.worker, reason });
        } else {
            try writer.print("  {s} [{s}] {s}\n", .{ run_label, @tagName(worker_run.status), worker_run.worker });
        }
    }
    if (!found_run) try writer.print("\nno runs recorded yet\n", .{});

    var found_release = false;
    for (kernel.releases.items) |release| {
        if (release.task_id != task_id) continue;
        if (!found_release) {
            try writer.print("\nreleases:\n", .{});
            found_release = true;
        }
        try writer.print("  v{d} {s} (build_ok={} test_ok={})\n", .{ release.version, release.commit, release.build_ok, release.test_ok });
    }

    var found_event = false;
    for (kernel.journal.events.items) |event| {
        if (!std.mem.eql(u8, event.subject, task.required_capability)) continue;
        if (!found_event) {
            try writer.print("\njournal entries mentioning `{s}` (see the caveat above):\n", .{task.required_capability});
            found_event = true;
        }
        try writer.print("  {d} {s}: {s}\n", .{ event.sequence, @tagName(event.kind), event.detail });
    }

    try writer.print("\nnext:\n", .{});
    switch (task.status) {
        .approval_required => try writer.print("  fx cto review {s}  (see the candidate diff)\n  fx cto approve {s}\n", .{ label, label }),
        .activation_failed => try writer.print("  fx cto activate {s}  (retry activation)\n", .{label}),
        .failed => try writer.print("  nothing automatic — a fresh `fx cto request` starts over for this capability\n", .{}),
        else => try writer.print("  nothing to do yet; still in progress\n", .{}),
    }
}

fn explainRun(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel, run_id: u64, label: []const u8) !void {
    for (kernel.runs.items) |worker_run| {
        if (worker_run.id != run_id) continue;
        var task_id_buf: [32]u8 = undefined;
        const task_label = id_mod.formatBuf(&task_id_buf, .task, worker_run.task_id);
        try writer.print("{s} [{s}] {s} for {s}\n", .{ label, @tagName(worker_run.status), worker_run.worker, task_label });
        if (worker_run.finished_reason) |reason| try writer.print("  reason: {s}\n", .{reason});
        try writer.print(
            "\nnext:\n  fx cto logs {s}  (captured stdout/stderr, if it dispatched out-of-process)\n  fx cto explain {s}  (the task this run belongs to)\n",
            .{ label, task_label },
        );
        return;
    }
    try writer.print("{s} was not found\n", .{label});
}

fn explainRelease(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel, version: u64, label: []const u8) !void {
    for (kernel.releases.items) |release| {
        if (release.version != version) continue;
        var task_id_buf: [32]u8 = undefined;
        try writer.print(
            "{s} {s} (build_ok={} test_ok={})\n  branch: {s}\n  path: {s}\n  task: {s}\n\nnext:\n  fx cto releases  (see which release is active)\n  fx cto rollback  (point at the previous release)\n",
            .{
                label,
                release.commit,
                release.build_ok,
                release.test_ok,
                release.branch,
                release.path,
                id_mod.formatBuf(&task_id_buf, .task, release.task_id),
            },
        );
        return;
    }
    try writer.print("{s} was not found\n", .{label});
}

fn explainGoal(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel, goal_id: u64, label: []const u8) !void {
    for (kernel.goals.items) |goal| {
        if (goal.id != goal_id) continue;
        try writer.print("{s} [{s}] {s}\n", .{ label, @tagName(goal.status), goal.objective });
        return;
    }
    try writer.print("{s} was not found\n", .{label});
}

/// One call, the whole current situation: what needs a decision, what's
/// running right now, what recently failed, and what capability is still
/// missing — the thing an agent runs first in a session and on every
/// check-in (D7), instead of manually joining `tasks`/`runs`/`events`.
///
/// Deliberately does not try to explain *why* something failed — that
/// requires cross-referencing the journal per task, which is exactly
/// `fx cto explain <task-id>`'s job. `brief` stays a dense pointer to
/// what deserves attention, not the causal story itself.
pub fn renderBrief(writer: *std.Io.Writer, alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel) !void {
    const now_ms = io_mod.milliTimestamp();
    var id_buf: [32]u8 = undefined;
    var elapsed_buf: [16]u8 = undefined;

    const counts = kernel.capabilities.count();
    try writer.print("capabilities: {d} available, {d} missing\n", .{ counts.available, counts.missing });
    if (counts.missing > 0) {
        const entries = try kernel.capabilities.sortedEntries(alloc);
        defer alloc.free(entries);
        for (entries) |capability| {
            if (capability.status == .missing) try writer.print("  missing: {s}\n", .{capability.name});
        }
    }

    var needs_decision = false;
    for (kernel.tasks.items) |task| {
        switch (task.status) {
            .approval_required, .activation_failed => {
                if (!needs_decision) {
                    try writer.print("\nneeds your decision:\n", .{});
                    needs_decision = true;
                }
                const label = id_mod.formatBuf(&id_buf, .task, task.id);
                try writer.print(
                    "  {s} [{s}] {s} (created {s} ago)\n",
                    .{ label, @tagName(task.status), task.required_capability, formatElapsed(&elapsed_buf, now_ms - task.created_at_ms) },
                );
                if (task.status == .approval_required) {
                    try writer.print("    -> fx cto approve {s}\n", .{label});
                } else {
                    try writer.print("    -> fx cto activate {s} (retry), or fx cto explain {s} (why it didn't go live)\n", .{ label, label });
                }
            },
            else => {},
        }
    }
    if (!needs_decision) try writer.print("\nnothing needs your decision right now.\n", .{});

    var in_flight = false;
    for (kernel.runs.items) |worker_run| {
        if (worker_run.status != .started) continue;
        if (!in_flight) {
            try writer.print("\nin flight:\n", .{});
            in_flight = true;
        }
        var task_id_buf: [32]u8 = undefined;
        try writer.print(
            "  {s} {s} [{s}] running {s} ago\n",
            .{
                id_mod.formatBuf(&id_buf, .run, worker_run.id),
                id_mod.formatBuf(&task_id_buf, .task, worker_run.task_id),
                worker_run.worker,
                formatElapsed(&elapsed_buf, now_ms - worker_run.started_at_ms),
            },
        );
    }

    var failed_shown: usize = 0;
    var i = kernel.tasks.items.len;
    while (i > 0) {
        i -= 1;
        const task = kernel.tasks.items[i];
        if (task.status != .failed) continue;
        if (failed_shown == 0) try writer.print("\nrecently failed (see `fx cto explain <id>` for why):\n", .{});
        if (failed_shown >= 5) {
            try writer.print("  ... and more; see `fx cto tasks`\n", .{});
            break;
        }
        try writer.print(
            "  {s} {s} ({s} ago)\n",
            .{ id_mod.formatBuf(&id_buf, .task, task.id), task.required_capability, formatElapsed(&elapsed_buf, now_ms - task.created_at_ms) },
        );
        failed_shown += 1;
    }
}

test "renderTasks reports the empty case and the same shape for a real task" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });

    var kernel = try kernel_mod.Kernel.init(alloc, cto_root);
    var accumulating = std.Io.Writer.Allocating.init(alloc);
    defer accumulating.deinit();

    try renderTasks(&accumulating.writer, &kernel);
    try std.testing.expectEqualStrings("no tasks yet\n", accumulating.writer.buffered());

    _ = try kernel.createCapabilityTask("watch merged pull requests", "github.pull_request.merged");
    accumulating.writer.end = 0;
    try renderTasks(&accumulating.writer, &kernel);
    try std.testing.expectEqualStrings(
        "task-1 [created] github.pull_request.merged -> cto-dev\n",
        accumulating.writer.buffered(),
    );
}

test "renderEvents --since filters to what's new without rereading the whole journal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });

    var kernel = try kernel_mod.Kernel.init(alloc, cto_root);
    _ = try kernel.createCapabilityTask("watch merged pull requests", "github.pull_request.merged");
    _ = try kernel.createCapabilityTask("watch merged pull requests again", "github.pull_request.merged2");
    // Two tasks, two events each (task_created plus whatever the create
    // path also journals) — enough sequence numbers to filter on.
    const total = kernel.journal.events.items.len;
    try std.testing.expect(total >= 2);

    var accumulating = std.Io.Writer.Allocating.init(alloc);
    defer accumulating.deinit();

    try renderEvents(&accumulating.writer, &kernel, 0);
    const full = accumulating.writer.buffered();
    try std.testing.expect(std.mem.count(u8, full, "\n") == total);

    accumulating.writer.end = 0;
    try renderEvents(&accumulating.writer, &kernel, @intCast(total - 1));
    const tail = accumulating.writer.buffered();
    try std.testing.expect(std.mem.count(u8, tail, "\n") == 1);

    accumulating.writer.end = 0;
    try renderEvents(&accumulating.writer, &kernel, @intCast(total));
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(alloc, "no events since {d}\n", .{total}),
        accumulating.writer.buffered(),
    );
}
