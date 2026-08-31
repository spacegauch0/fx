//! Renders read-only kernel state to a `std.Io.Writer`. Deliberately the
//! only place these views are formatted: `main.zig`'s CLI printers and
//! `daemon.zig`'s control-socket read-command handler both call these same
//! functions rather than keeping two independently-formatted copies of
//! "what does `tasks` look like" that could silently drift apart (the
//! class of problem docs/CTO_ROADMAP.md's D8/D9 exist to close).

const std = @import("std");
const id_mod = @import("id.zig");
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

pub fn renderEvents(writer: *std.Io.Writer, kernel: *kernel_mod.Kernel) !void {
    if (kernel.journal.events.items.len == 0) {
        try writer.print("no events yet\n", .{});
        return;
    }
    for (kernel.journal.events.items) |event| {
        try writer.print(
            "{d} {s} {s}: {s}\n",
            .{ event.sequence, @tagName(event.kind), event.subject, event.detail },
        );
    }
}

test "renderTasks reports the empty case and the same shape for a real task" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io_mod = @import("../core/shared/io.zig");

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
