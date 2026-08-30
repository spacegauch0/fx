const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

const capability_mod = @import("capability.zig");
const event_mod = @import("event.zig");
const journal_mod = @import("journal.zig");
const task_mod = @import("task.zig");
const store = @import("store.zig");
const policy = @import("policy.zig");
const goal_mod = @import("goal.zig");
const run_mod = @import("run.zig");
const observation_mod = @import("observation.zig");

/// The trusted CTO kernel: task lifecycle, capability registry, event
/// journal, and the approval boundary. Everything here is meant to stay
/// small and boring; self-generated code lives in worktrees the kernel
/// creates and validates, never inside this module.
pub const Kernel = struct {
    allocator: std.mem.Allocator,
    cto_root: []const u8,
    capabilities: capability_mod.Registry,
    journal: journal_mod.Journal,
    tasks: std.ArrayList(task_mod.Task),
    goals: std.ArrayList(goal_mod.Goal),
    runs: std.ArrayList(run_mod.Run),
    observations: std.ArrayList(observation_mod.Observation),
    next_task_id: u64 = 1,
    next_goal_id: u64 = 1,
    next_run_id: u64 = 1,

    /// `cto_root` may be relative (the default is ".cto"); it is resolved
    /// to an absolute path once, up front, since every durable write below
    /// this point needs one.
    pub fn init(allocator: std.mem.Allocator, cto_root_input: []const u8) !Kernel {
        const cto_root = try store.resolveAbsolute(allocator, cto_root_input);
        try store.ensureRoot(allocator, cto_root);

        var capabilities = capability_mod.Registry.init(allocator);
        errdefer capabilities.deinit();
        const capabilities_existed = try store.loadCapabilities(allocator, cto_root, &capabilities);
        if (!capabilities_existed) {
            try capabilities.bootstrap();
            try store.saveCapabilities(allocator, cto_root, &capabilities);
        }

        var journal = try journal_mod.Journal.init(allocator, cto_root);
        errdefer journal.deinit();

        var tasks: std.ArrayList(task_mod.Task) = .empty;
        errdefer tasks.deinit(allocator);
        const loaded_tasks = try store.loadTasks(allocator, cto_root);
        try tasks.appendSlice(allocator, loaded_tasks);
        var goals: std.ArrayList(goal_mod.Goal) = .empty;
        errdefer goals.deinit(allocator);
        try goals.appendSlice(allocator, try store.loadGoals(allocator, cto_root));
        var runs: std.ArrayList(run_mod.Run) = .empty;
        errdefer runs.deinit(allocator);
        try runs.appendSlice(allocator, try store.loadRuns(allocator, cto_root));
        var observations: std.ArrayList(observation_mod.Observation) = .empty;
        errdefer observations.deinit(allocator);
        try observations.appendSlice(allocator, try store.loadObservations(allocator, cto_root));

        var next_task_id: u64 = 1;
        for (tasks.items) |task| {
            if (task.id >= next_task_id) next_task_id = task.id + 1;
        }
        var next_goal_id: u64 = 1;
        for (goals.items) |goal| {
            if (goal.id >= next_goal_id) next_goal_id = goal.id + 1;
        }
        var next_run_id: u64 = 1;
        for (runs.items) |run| {
            if (run.id >= next_run_id) next_run_id = run.id + 1;
        }

        return .{
            .allocator = allocator,
            .cto_root = cto_root,
            .capabilities = capabilities,
            .journal = journal,
            .tasks = tasks,
            .goals = goals,
            .runs = runs,
            .observations = observations,
            .next_task_id = next_task_id,
            .next_goal_id = next_goal_id,
            .next_run_id = next_run_id,
        };
    }

    pub fn deinit(self: *Kernel) void {
        self.tasks.deinit(self.allocator);
        self.goals.deinit(self.allocator);
        self.runs.deinit(self.allocator);
        self.observations.deinit(self.allocator);
        self.journal.deinit();
        self.capabilities.deinit();
    }

    pub fn createGoal(self: *Kernel, objective: []const u8) !u64 {
        const id = self.next_goal_id;
        self.next_goal_id += 1;
        try self.goals.append(self.allocator, .{ .id = id, .objective = try self.allocator.dupe(u8, objective), .created_at_ms = io_mod.milliTimestamp() });
        _ = try self.journal.append(.goal_created, "goal", objective);
        try store.saveGoals(self.allocator, self.cto_root, self.goals.items);
        return id;
    }

    pub fn startRun(self: *Kernel, task_id: u64, worker: []const u8) !u64 {
        const id = self.next_run_id;
        self.next_run_id += 1;
        try self.runs.append(self.allocator, .{ .id = id, .task_id = task_id, .worker = try self.allocator.dupe(u8, worker), .started_at_ms = io_mod.milliTimestamp() });
        _ = try self.journal.append(.run_started, worker, "worker run started");
        try store.saveRuns(self.allocator, self.cto_root, self.runs.items);
        return id;
    }

    pub fn finishRun(self: *Kernel, run_id: u64, succeeded: bool) !void {
        for (self.runs.items) |*run| if (run.id == run_id) {
            run.status = if (succeeded) .succeeded else .failed;
            run.finished_at_ms = io_mod.milliTimestamp();
            _ = try self.journal.append(.run_finished, run.worker, if (succeeded) "succeeded" else "failed");
            return store.saveRuns(self.allocator, self.cto_root, self.runs.items);
        };
        return error.RunNotFound;
    }

    /// Records a normalized observation unless one with the same
    /// (provider, delivery_id) is already stored. Returns `true` when this
    /// call actually recorded it, `false` when it was a duplicate delivery
    /// (still journaled either way, so a retried delivery is auditable).
    ///
    /// Takes ownership of `observation`'s heap-allocated fields: callers
    /// must normalize with `self.allocator` and must not free the result
    /// themselves, duplicate or not.
    pub fn recordObservation(self: *Kernel, observation: observation_mod.Observation) !bool {
        for (self.observations.items) |existing| {
            if (std.mem.eql(u8, existing.provenance.provider, observation.provenance.provider) and
                std.mem.eql(u8, existing.provenance.delivery_id, observation.provenance.delivery_id))
            {
                _ = try self.journal.append(
                    .observation_duplicate,
                    observation.provenance.provider,
                    observation.provenance.delivery_id,
                );
                return false;
            }
        }
        try self.observations.append(self.allocator, observation);
        _ = try self.journal.append(
            .observation_recorded,
            observation.provenance.provider,
            observation.provenance.delivery_id,
        );
        try store.appendObservation(self.allocator, self.cto_root, observation);
        return true;
    }

    /// Audits a raw event the trusted admission layer refused. The reason
    /// is the operator-facing `Verdict.reason()` text, which never carries
    /// any part of the body, signature, or secret.
    pub fn recordIngestRejection(self: *Kernel, event_name: []const u8, reason: []const u8) !void {
        _ = try self.journal.append(.ingest_rejected, event_name, reason);
    }

    fn persistCapabilities(self: *Kernel) !void {
        try store.saveCapabilities(self.allocator, self.cto_root, &self.capabilities);
    }

    fn persistTasks(self: *Kernel) !void {
        try store.saveTasks(self.allocator, self.cto_root, self.tasks.items);
    }

    pub fn createCapabilityTask(
        self: *Kernel,
        objective: []const u8,
        capability: []const u8,
    ) !u64 {
        const id = self.next_task_id;
        self.next_task_id += 1;

        try self.tasks.append(self.allocator, .{
            .id = id,
            .objective = objective,
            .assignee = "cto-dev",
            .required_capability = capability,
            .status = .created,
            .created_at_ms = io_mod.milliTimestamp(),
        });

        _ = try self.journal.append(.task_created, capability, objective);
        try self.persistTasks();

        return id;
    }

    pub fn markDelegated(self: *Kernel, task_id: u64) !void {
        const task = self.findTask(task_id) orelse return error.TaskNotFound;
        task.status = .delegated;
        _ = try self.journal.append(.task_delegated, task.required_capability, task.assignee);
        try self.persistTasks();
    }

    /// Audit and enforce a policy decision before an effect is dispatched.
    /// `deny` is returned as an error so callers cannot accidentally ignore it.
    pub fn authorize(self: *Kernel, action: []const u8, path: ?[]const u8) !policy.Decision {
        const decision = policy.classify(action, path);
        const kind: event_mod.EventKind = switch (decision) {
            .allow => .policy_allowed,
            .approval_required => .policy_approval_required,
            .deny => .policy_denied,
        };
        _ = try self.journal.append(kind, action, path orelse "");
        if (decision == .deny) return error.PolicyDenied;
        return decision;
    }

    /// Records that a worker attempt failed. The task and its worktree (if
    /// any) are left in place for a human to inspect; the kernel never
    /// deletes evidence of a failed self-extension attempt.
    pub fn markFailed(self: *Kernel, task_id: u64, reason: []const u8) !void {
        const task = self.findTask(task_id) orelse return error.TaskNotFound;
        task.status = .failed;
        _ = try self.journal.append(.worker_failed, task.required_capability, reason);
        try self.persistTasks();
    }

    pub fn markCandidate(
        self: *Kernel,
        task_id: u64,
        candidate_ref: []const u8,
        worktree_path: []const u8,
        build_ok: bool,
        test_ok: bool,
    ) !void {
        const task = self.findTask(task_id) orelse return error.TaskNotFound;
        task.status = .approval_required;
        task.candidate_ref = try self.allocator.dupe(u8, candidate_ref);
        task.worktree_path = try self.allocator.dupe(u8, worktree_path);
        task.build_ok = build_ok;
        task.test_ok = test_ok;

        try self.capabilities.markCandidate(task.required_capability, task.candidate_ref.?);

        _ = try self.journal.append(.candidate_ready, task.required_capability, candidate_ref);
        _ = try self.journal.append(.approval_requested, task.required_capability, candidate_ref);

        try self.persistCapabilities();
        try self.persistTasks();
        try store.saveVersionRecord(self.allocator, self.cto_root, .{
            .task_id = task.id,
            .capability = task.required_capability,
            .candidate_ref = task.candidate_ref.?,
            .worktree_path = task.worktree_path.?,
            .build_ok = build_ok,
            .test_ok = test_ok,
            .summary = "candidate ready for approval",
            .created_at_ms = io_mod.milliTimestamp(),
            .approved = false,
            .approved_at_ms = null,
        });
    }

    pub fn approve(self: *Kernel, task_id: u64) !void {
        const task = self.findTask(task_id) orelse return error.TaskNotFound;
        if (task.status != .approval_required) return error.ApprovalNotRequired;

        const candidate_ref = task.candidate_ref orelse return error.CandidateMissing;

        _ = try self.journal.append(.approval_granted, task.required_capability, candidate_ref);

        try self.capabilities.activate(task.required_capability, candidate_ref);

        task.status = .completed;

        _ = try self.journal.append(.capability_activated, task.required_capability, candidate_ref);

        try self.persistCapabilities();
        try self.persistTasks();
        try store.saveVersionRecord(self.allocator, self.cto_root, .{
            .task_id = task.id,
            .capability = task.required_capability,
            .candidate_ref = candidate_ref,
            .worktree_path = task.worktree_path orelse "",
            .build_ok = task.build_ok,
            .test_ok = task.test_ok,
            .summary = "candidate approved and activated",
            .created_at_ms = io_mod.milliTimestamp(),
            .approved = true,
            .approved_at_ms = io_mod.milliTimestamp(),
        });
    }

    pub fn findTask(self: *Kernel, task_id: u64) ?*task_mod.Task {
        for (self.tasks.items) |*task| {
            if (task.id == task_id) return task;
        }
        return null;
    }
};

test "createCapabilityTask assigns cto-dev and records a task_created event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });

    var kernel = try Kernel.init(alloc, cto_root);
    const task_id = try kernel.createCapabilityTask(
        "watch merged pull requests",
        "github.pull_request.merged",
    );

    try std.testing.expectEqual(@as(u64, 1), task_id);
    const task = kernel.findTask(task_id).?;
    try std.testing.expectEqualStrings("cto-dev", task.assignee);
    try std.testing.expectEqual(task_mod.TaskStatus.created, task.status);
    try std.testing.expectEqual(@as(usize, 1), kernel.journal.events.items.len);
    try std.testing.expectEqual(event_mod.EventKind.task_created, kernel.journal.events.items[0].kind);
}

test "approve requires a candidate to be ready first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });

    var kernel = try Kernel.init(alloc, cto_root);
    const task_id = try kernel.createCapabilityTask("watch merged pull requests", "github.pull_request.merged");

    try std.testing.expectError(error.ApprovalNotRequired, kernel.approve(task_id));

    try kernel.markDelegated(task_id);
    try kernel.markCandidate(task_id, "candidate/task-1", "/tmp/worktree", true, true);
    try std.testing.expect(!kernel.capabilities.isAvailable("github.pull_request.merged"));
    try std.testing.expectEqual(capability_mod.Status.candidate, kernel.capabilities.status("github.pull_request.merged"));

    try kernel.approve(task_id);
    try std.testing.expect(kernel.capabilities.isAvailable("github.pull_request.merged"));
    try std.testing.expectEqual(task_mod.TaskStatus.completed, kernel.findTask(task_id).?.status);
}

fn testObservation(alloc: std.mem.Allocator, delivery_id: []const u8) !observation_mod.Observation {
    return .{
        .occurred_at_ms = 1700000000000,
        .provenance = .{
            .provider = try alloc.dupe(u8, "github"),
            .delivery_id = try alloc.dupe(u8, delivery_id),
            .repository = try alloc.dupe(u8, "spacegauch0/fx"),
            .url = try alloc.dupe(u8, "https://github.com/spacegauch0/fx/pull/1"),
        },
        .payload = .{ .pull_request_merged = .{
            .number = 1,
            .title = try alloc.dupe(u8, "CTO"),
            .author = try alloc.dupe(u8, "diego"),
            .merged_by = try alloc.dupe(u8, "reviewer"),
            .head_sha = try alloc.dupe(u8, "abc"),
            .base_branch = try alloc.dupe(u8, "main"),
        } },
    };
}

test "recordObservation deduplicates by provider and delivery id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });
    var kernel = try Kernel.init(alloc, cto_root);

    const first = try kernel.recordObservation(try testObservation(alloc, "delivery-1"));
    try std.testing.expect(first);
    try std.testing.expectEqual(@as(usize, 1), kernel.observations.items.len);

    const duplicate = try kernel.recordObservation(try testObservation(alloc, "delivery-1"));
    try std.testing.expect(!duplicate);
    try std.testing.expectEqual(@as(usize, 1), kernel.observations.items.len);

    const different = try kernel.recordObservation(try testObservation(alloc, "delivery-2"));
    try std.testing.expect(different);
    try std.testing.expectEqual(@as(usize, 2), kernel.observations.items.len);

    const reloaded = try Kernel.init(alloc, cto_root);
    try std.testing.expectEqual(@as(usize, 2), reloaded.observations.items.len);
}

test "kernel audits policy decisions and blocks escaped paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });
    var kernel = try Kernel.init(alloc, cto_root);
    try std.testing.expectEqual(policy.Decision.allow, try kernel.authorize("worker.run", "src/cto/extensions/a.zig"));
    try std.testing.expectError(error.PolicyDenied, kernel.authorize("filesystem.write", "../escape"));
    try std.testing.expectEqual(event_mod.EventKind.policy_denied, kernel.journal.events.items[1].kind);
}

test "kernel state survives across process-like re-initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });

    {
        var kernel = try Kernel.init(alloc, cto_root);
        _ = try kernel.createCapabilityTask("watch merged pull requests", "github.pull_request.merged");
    }

    var reloaded = try Kernel.init(alloc, cto_root);
    try std.testing.expectEqual(@as(usize, 1), reloaded.tasks.items.len);
    try std.testing.expectEqual(@as(u64, 2), reloaded.next_task_id);
    try std.testing.expect(reloaded.capabilities.isAvailable("filesystem.read"));
    try std.testing.expectEqual(@as(usize, 1), reloaded.journal.events.items.len);
}
