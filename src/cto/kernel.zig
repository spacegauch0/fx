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
const release_mod = @import("release.zig");
const candidate_mod = @import("candidate.zig");
const git = @import("git.zig");

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
    releases: std.ArrayList(release_mod.Release),
    next_task_id: u64 = 1,
    next_goal_id: u64 = 1,
    next_run_id: u64 = 1,
    next_release_version: u64 = 1,

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
        var releases: std.ArrayList(release_mod.Release) = .empty;
        errdefer releases.deinit(allocator);
        try releases.appendSlice(allocator, try store.loadReleases(allocator, cto_root));

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
        var next_release_version: u64 = 1;
        for (releases.items) |release| {
            if (release.version >= next_release_version) next_release_version = release.version + 1;
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
            .releases = releases,
            .next_release_version = next_release_version,
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
        self.releases.deinit(self.allocator);
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

    /// `reason` is recorded on the run and in the journal only for a
    /// non-`.succeeded` status (e.g. a crash's error name, "timeout", or
    /// "interrupted by operator"); pass `null` for `.succeeded`.
    pub fn finishRun(self: *Kernel, run_id: u64, status: run_mod.Status, reason: ?[]const u8) !void {
        for (self.runs.items) |*run| if (run.id == run_id) {
            run.status = status;
            run.finished_at_ms = io_mod.milliTimestamp();
            run.finished_reason = if (reason) |r| try self.allocator.dupe(u8, r) else null;
            _ = try self.journal.append(.run_finished, run.worker, reason orelse @tagName(status));
            return store.saveRuns(self.allocator, self.cto_root, self.runs.items);
        };
        return error.RunNotFound;
    }

    /// Audits an `fx cto interrupt <run-id>` request regardless of whether
    /// a running worker was actually found for it — the attempt itself is
    /// part of the trail, per "preserve an audit trail."
    pub fn recordInterruptRequest(self: *Kernel, run_id: u64, outcome: []const u8) !void {
        var buf: [32]u8 = undefined;
        const subject = std.fmt.bufPrint(&buf, "{d}", .{run_id}) catch "run";
        _ = try self.journal.append(.interrupt_requested, subject, outcome);
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

    pub const ActivationOutcome = union(enum) {
        /// The release is built, tested, and `.cto/current` points at it.
        activated: release_mod.Release,
        /// The human approval stands, but the release did not become live.
        /// The capability remains a candidate because it is not actually
        /// available, and `activate` can be retried.
        health_failed: []const u8,
    };

    /// Records a human approval, then materializes and activates the
    /// candidate.
    ///
    /// Approval and activation are one command because a capability that
    /// is not live is not available: flipping the registry without a
    /// working release would make `fx cto capabilities` lie. They remain
    /// separable underneath, so a failed activation can be retried without
    /// re-approving.
    pub fn approve(self: *Kernel, repository_path: []const u8, task_id: u64) !ActivationOutcome {
        const task = self.findTask(task_id) orelse return error.TaskNotFound;
        if (task.status != .approval_required) return error.ApprovalNotRequired;
        const candidate_ref = task.candidate_ref orelse return error.CandidateMissing;

        _ = try self.journal.append(.approval_granted, task.required_capability, candidate_ref);
        try self.persistTasks();
        return self.activate(repository_path, task_id);
    }

    /// Materializes an approved candidate as a versioned release,
    /// health-checks it, and only then moves the active pointer.
    ///
    /// Retryable: safe to call again after a `health_failed` outcome.
    pub fn activate(self: *Kernel, repository_path: []const u8, task_id: u64) !ActivationOutcome {
        const task = self.findTask(task_id) orelse return error.TaskNotFound;
        switch (task.status) {
            .approval_required, .activation_failed => {},
            else => return error.ApprovalNotRequired,
        }
        const candidate_ref = task.candidate_ref orelse return error.CandidateMissing;
        const worktree_path = task.worktree_path orelse return error.CandidateMissing;

        // Commit the candidate's boundary-allowed work to its own branch so
        // the release is pinned to an immutable commit. Only the CTO-created
        // candidate branch is ever written to; human history is untouched.
        const message = try std.fmt.allocPrint(
            self.allocator,
            "cto: candidate for {s} (task {d})",
            .{ task.required_capability, task.id },
        );
        defer self.allocator.free(message);
        const commit = git.commitCandidate(self.allocator, worktree_path, message) catch |err| {
            return self.recordActivationFailure(task, @errorName(err));
        };
        defer self.allocator.free(commit);

        const version = self.next_release_version;
        const release_path = try release_mod.releasePath(self.allocator, self.cto_root, version);
        errdefer self.allocator.free(release_path);

        git.addWorktreeDetached(self.allocator, repository_path, release_path, commit) catch |err| {
            const outcome = try self.recordActivationFailure(task, @errorName(err));
            self.allocator.free(release_path);
            return outcome;
        };
        _ = try self.journal.append(.release_materialized, task.required_capability, release_path);

        const health = candidate_mod.healthCheck(self.allocator, release_path) catch |err| {
            const outcome = try self.recordActivationFailure(task, @errorName(err));
            self.allocator.free(release_path);
            return outcome;
        };
        defer self.allocator.free(health.log);

        if (!health.healthy()) {
            const reason = try std.fmt.allocPrint(
                self.allocator,
                "release health check failed (build_ok={} test_ok={})",
                .{ health.build_ok, health.test_ok },
            );
            defer self.allocator.free(reason);
            const outcome = try self.recordActivationFailure(task, reason);
            self.allocator.free(release_path);
            return outcome;
        }

        // Everything below this line is the point of no return, and it is a
        // single atomic rename.
        try release_mod.pointCurrentAt(self.cto_root, release_path);

        const release = release_mod.Release{
            .version = version,
            .task_id = task.id,
            .capability = try self.allocator.dupe(u8, task.required_capability),
            .branch = try self.allocator.dupe(u8, candidate_ref),
            .commit = try self.allocator.dupe(u8, commit),
            .path = release_path,
            .build_ok = health.build_ok,
            .test_ok = health.test_ok,
            .activated_at_ms = io_mod.milliTimestamp(),
        };
        try self.releases.append(self.allocator, release);
        self.next_release_version = version + 1;

        try self.capabilities.activate(task.required_capability, candidate_ref);
        task.status = .completed;

        _ = try self.journal.append(.release_activated, task.required_capability, release_path);
        _ = try self.journal.append(.capability_activated, task.required_capability, candidate_ref);

        try store.saveReleases(self.allocator, self.cto_root, self.releases.items);
        try self.persistCapabilities();
        try self.persistTasks();
        try store.saveVersionRecord(self.allocator, self.cto_root, .{
            .task_id = task.id,
            .capability = task.required_capability,
            .candidate_ref = candidate_ref,
            .worktree_path = worktree_path,
            .build_ok = health.build_ok,
            .test_ok = health.test_ok,
            .summary = "candidate approved and activated",
            .created_at_ms = io_mod.milliTimestamp(),
            .approved = true,
            .approved_at_ms = io_mod.milliTimestamp(),
        });
        return .{ .activated = release };
    }

    fn recordActivationFailure(self: *Kernel, task: *task_mod.Task, reason: []const u8) !ActivationOutcome {
        task.status = .activation_failed;
        _ = try self.journal.append(.release_health_failed, task.required_capability, reason);
        try self.persistTasks();
        return .{ .health_failed = reason };
    }

    /// Points the active release back at the previous known-good version.
    /// The superseded release is left on disk so the move is reversible in
    /// both directions.
    pub fn rollback(self: *Kernel) !release_mod.Release {
        const current = try release_mod.activeRelease(self.allocator, self.cto_root, self.releases.items) orelse
            return error.NoActiveRelease;
        const previous = release_mod.previousRelease(self.releases.items, current.version) orelse
            return error.NoPreviousRelease;

        try release_mod.pointCurrentAt(self.cto_root, previous.path);
        _ = try self.journal.append(.release_rolled_back, previous.capability, previous.path);
        return previous;
    }

    pub fn findTask(self: *Kernel, task_id: u64) ?*task_mod.Task {
        for (self.tasks.items) |*task| {
            if (task.id == task_id) return task;
        }
        return null;
    }

    /// Returns an existing task for `capability` that has not reached a
    /// terminal outcome (`completed`/`rejected`/`failed`), if one exists.
    /// `Runtime.request` uses this so a defensively re-issued request —
    /// exactly what a context compaction or a retried tool call produces —
    /// finds the task already in flight instead of forking a second,
    /// parallel one that duplicates real worker/build compute. A `failed`
    /// task is deliberately treated as terminal here even though nothing
    /// retries it automatically: the human's next move is a fresh
    /// `request`, not being silently pointed back at a dead end.
    pub fn inFlightTaskForCapability(self: *Kernel, capability: []const u8) ?*task_mod.Task {
        for (self.tasks.items) |*task| {
            if (!std.mem.eql(u8, task.required_capability, capability)) continue;
            switch (task.status) {
                .completed, .rejected, .failed => continue,
                else => return task,
            }
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

    try std.testing.expectError(error.ApprovalNotRequired, kernel.approve(root, task_id));

    try kernel.markDelegated(task_id);
    try kernel.markCandidate(task_id, "candidate/task-1", "/tmp/worktree", true, true);
    try std.testing.expect(!kernel.capabilities.isAvailable("github.pull_request.merged"));
    try std.testing.expectEqual(capability_mod.Status.candidate, kernel.capabilities.status("github.pull_request.merged"));

    // `/tmp/worktree` is not a git worktree, so materialization fails. The
    // approval still stands, the task becomes retryable, and — the part
    // that matters — the capability is NOT reported available, because it
    // is not live.
    const outcome = try kernel.approve(root, task_id);
    try std.testing.expect(outcome == .health_failed);
    try std.testing.expectEqual(task_mod.TaskStatus.activation_failed, kernel.findTask(task_id).?.status);
    try std.testing.expect(!kernel.capabilities.isAvailable("github.pull_request.merged"));
    try std.testing.expectEqual(
        capability_mod.Status.candidate,
        kernel.capabilities.status("github.pull_request.merged"),
    );
}

test "rollback refuses when there is no active release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });

    var kernel = try Kernel.init(alloc, cto_root);
    try std.testing.expectError(error.NoActiveRelease, kernel.rollback());
}

test "releases survive process-like re-initialization and keep numbering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });

    {
        var kernel = try Kernel.init(alloc, cto_root);
        try kernel.releases.append(alloc, .{
            .version = 4,
            .task_id = 1,
            .capability = "github.pull_request.merged",
            .branch = "candidate/task-1",
            .commit = "abc123",
            .path = "/repo/.cto/releases/v4",
            .build_ok = true,
            .test_ok = true,
            .activated_at_ms = 99,
        });
        try store.saveReleases(alloc, cto_root, kernel.releases.items);
    }

    const reloaded = try Kernel.init(alloc, cto_root);
    try std.testing.expectEqual(@as(usize, 1), reloaded.releases.items.len);
    try std.testing.expectEqual(@as(u64, 4), reloaded.releases.items[0].version);
    try std.testing.expectEqualStrings("abc123", reloaded.releases.items[0].commit);
    // The next release must not reuse a version number.
    try std.testing.expectEqual(@as(u64, 5), reloaded.next_release_version);
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
