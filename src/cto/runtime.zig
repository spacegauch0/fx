const std = @import("std");

const candidate_mod = @import("candidate.zig");
const counterpart_mod = @import("counterpart.zig");
const fx_worker_mod = @import("fx_worker.zig");
const git = @import("git.zig");
const io_mod = @import("../core/shared/io.zig");
const kernel_mod = @import("kernel.zig");
const run_mod = @import("run.zig");
const worker_mod = @import("worker.zig");
const workspace_mod = @import("workspace.zig");

/// Accepts a human request, decides whether it needs a capability CTO does
/// not have, and if so runs the whole self-extension loop: create a task,
/// delegate it to cto-dev, create an isolated worktree (the task owns the
/// worktree, not the worker), run the fx worker inside it, validate the
/// result with a real build and test, and leave the task awaiting approval.
///
/// Everything below `request` degrades to a recorded failure on the task
/// rather than propagating an error out of the CLI: an environment missing
/// `git` or `zig`, or a worktree collision, should not crash `fx cto`.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    kernel: *kernel_mod.Kernel,
    counterpart: counterpart_mod.Counterpart,
    workspace: workspace_mod.Workspace,
    fx_worker: fx_worker_mod.FxWorker,
    /// Set by `initWithWorker`; when present, dispatch uses this worker
    /// instead of `fx_worker`. This is how the daemon (M6) injects
    /// `ProcessWorker` (M4) as the live dispatch mechanism without
    /// disturbing the CLI's `FxWorker`/`LiveRunner` composition-root seam
    /// (D3) at all: the CLI never sets this field, so `init` below is
    /// unchanged and every existing caller is unaffected.
    worker_override: ?worker_mod.Worker = null,

    /// `repository_path` must already be absolute; the worktree paths this
    /// runtime hands to the worker are joined against it verbatim.
    /// `cto_root` is taken from `kernel.cto_root` (already resolved during
    /// `Kernel.init`) rather than re-derived here, so the worktree root the
    /// runtime writes into always matches the root the kernel persists to.
    pub fn init(
        allocator: std.mem.Allocator,
        kernel: *kernel_mod.Kernel,
        repository_path: []const u8,
        dispatch: fx_worker_mod.DispatchMode,
        live_runner: ?fx_worker_mod.LiveRunner,
    ) Runtime {
        return .{
            .allocator = allocator,
            .kernel = kernel,
            .counterpart = counterpart_mod.Counterpart.ctoDev(repository_path),
            .workspace = workspace_mod.Workspace.init(allocator, repository_path, kernel.cto_root),
            .fx_worker = .{ .dispatch = dispatch, .live_runner = live_runner },
        };
    }

    /// Daemon constructor (M6): the daemon supervises workers
    /// out-of-process (`ProcessWorker`, M4) rather than in-process, per
    /// D3. `fx_worker` is left at its harmless `dry_run`/no-runner default
    /// and never consulted — `worker_override` always wins when set.
    pub fn initWithWorker(
        allocator: std.mem.Allocator,
        kernel: *kernel_mod.Kernel,
        repository_path: []const u8,
        worker: worker_mod.Worker,
    ) Runtime {
        return .{
            .allocator = allocator,
            .kernel = kernel,
            .counterpart = counterpart_mod.Counterpart.ctoDev(repository_path),
            .workspace = workspace_mod.Workspace.init(allocator, repository_path, kernel.cto_root),
            .fx_worker = .{ .dispatch = .dry_run, .live_runner = null },
            .worker_override = worker,
        };
    }

    pub fn request(self: *Runtime, objective: []const u8) !?u64 {
        _ = try self.kernel.journal.append(.human_requested, "human", objective);
        _ = try self.kernel.createGoal(objective);

        if (requiresGithubMergeAwareness(objective) and
            !self.kernel.capabilities.isAvailable("github.pull_request.merged"))
        {
            _ = try self.kernel.journal.append(
                .capability_missing,
                "github.pull_request.merged",
                objective,
            );

            const task_id = try self.kernel.createCapabilityTask(
                objective,
                "github.pull_request.merged",
            );

            try self.delegateSelfExtension(task_id);
            return task_id;
        }

        return null;
    }

    fn delegateSelfExtension(self: *Runtime, task_id: u64) !void {
        const decision = self.kernel.authorize("worker.run", "src/cto/extensions/") catch |err| {
            try self.kernel.markFailed(task_id, @errorName(err));
            return;
        };
        if (decision != .allow) {
            try self.kernel.markFailed(task_id, "worker dispatch requires human approval");
            return;
        }
        try self.kernel.markDelegated(task_id);

        const worktree_path = try self.workspace.worktreePath(task_id);
        defer self.allocator.free(worktree_path);
        const branch = try self.workspace.candidateBranch(task_id);
        defer self.allocator.free(branch);

        git.addWorktree(self.allocator, self.counterpart.repository_path, worktree_path, branch) catch |err| {
            const reason = try std.fmt.allocPrint(
                self.allocator,
                "could not create worktree {s}: {s}",
                .{ worktree_path, @errorName(err) },
            );
            defer self.allocator.free(reason);
            try self.kernel.markFailed(task_id, reason);
            return;
        };

        const prompt = try std.fmt.allocPrint(
            self.allocator,
            \\You are cto-dev, the fixed engineer counterpart responsible for the CTO runtime.
            \\
            \\Implement the missing capability `github.pull_request.merged`.
            \\The implementation must:
            \\- live behind the CTO extension/connector boundary (src/cto/extensions/)
            \\- export an `extension_contract.Connector`
            \\- accept `extension_contract.RawEvent` and return a provider-neutral `observation.Observation`
            \\- handle only the GitHub `pull_request` event with action `closed` and merged=true
            \\- preserve delivery id, repository, PR URL, author, merger, head SHA, base branch, title, number, and merge time
            \\- include deterministic JSON fixtures and co-located tests under src/cto/extensions/
            \\- register the connector in src/cto/extensions/registry.zig so its tests enter the build graph
            \\- avoid modifying the trusted kernel's audit, policy, or activation code
            \\- avoid activating itself
            \\- return a candidate for human approval
            \\
            \\Repository: {s}
            \\Worktree: {s}
        ,
            .{ self.counterpart.repository_path, worktree_path },
        );
        defer self.allocator.free(prompt);

        const result = try self.dispatchWithRetry(task_id, worktree_path, prompt) orelse return;

        switch (result.outcome) {
            .succeeded => _ = try self.kernel.journal.append(.worker_completed, "cto-dev", result.summary),
            .failed, .timed_out, .interrupted => {
                try self.kernel.markFailed(task_id, result.summary);
                return;
            },
        }

        const validation = candidate_mod.validate(self.allocator, worktree_path) catch |err| {
            const reason = try std.fmt.allocPrint(
                self.allocator,
                "candidate validation crashed: {s}",
                .{@errorName(err)},
            );
            defer self.allocator.free(reason);
            try self.kernel.markFailed(task_id, reason);
            return;
        };
        defer self.allocator.free(validation.log);

        if (!validation.boundary_ok or !validation.build_ok or !validation.test_ok) {
            const reason = try std.fmt.allocPrint(
                self.allocator,
                "candidate failed validation (boundary_ok={} build_ok={} test_ok={}) in {s}",
                .{ validation.boundary_ok, validation.build_ok, validation.test_ok, worktree_path },
            );
            defer self.allocator.free(reason);
            try self.kernel.markFailed(task_id, reason);
            return;
        }

        try self.kernel.markCandidate(task_id, branch, worktree_path, validation.build_ok, validation.test_ok);
    }

    /// Dispatches one worker attempt, retrying only a crash of the dispatch
    /// mechanism itself (`adapter.run` returning a Zig error: a failed
    /// spawn, a wait4 failure, a filesystem hiccup) — never a semantic
    /// outcome the worker actually reported (`.failed`, `.timed_out`,
    /// `.interrupted`). Retrying those would mean silently re-running a
    /// model attempt, which is spending without the approval that requires
    /// — "Act narrowly" — so a real attempt's result is always surfaced to
    /// the human once, not looped on.
    ///
    /// Returns `null` (with the task already marked failed) once attempts
    /// are exhausted; otherwise returns the terminal `WorkResult`.
    fn dispatchWithRetry(
        self: *Runtime,
        task_id: u64,
        worktree_path: []const u8,
        prompt: []const u8,
    ) !?worker_mod.WorkResult {
        const max_dispatch_attempts: u32 = 3;
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            const detail = if (attempt == 1)
                try self.allocator.dupe(u8, "fx")
            else
                try std.fmt.allocPrint(self.allocator, "fx (attempt {d})", .{attempt});
            defer self.allocator.free(detail);
            _ = try self.kernel.journal.append(.worker_started, "cto-dev", detail);

            const run_id = try self.kernel.startRun(task_id, "fx");
            const fallback = self.fx_worker.asWorker();
            var adapter = self.worker_override orelse fallback;
            const attempt_result = adapter.run(self.allocator, .{
                .task_id = task_id,
                .run_id = run_id,
                .repository_path = self.counterpart.repository_path,
                .worktree_path = worktree_path,
                .cto_root = self.kernel.cto_root,
                .prompt = prompt,
            });

            if (attempt_result) |ok| {
                const status: run_mod.Status = switch (ok.outcome) {
                    .succeeded => .succeeded,
                    .failed => .failed,
                    .timed_out, .interrupted => .interrupted,
                };
                const reason: ?[]const u8 = switch (ok.outcome) {
                    .succeeded => null,
                    .failed => "worker reported failure",
                    .timed_out => "timeout",
                    .interrupted => "interrupted by operator",
                };
                try self.kernel.finishRun(run_id, status, reason);
                return ok;
            } else |err| {
                try self.kernel.finishRun(run_id, .failed, @errorName(err));
                if (attempt >= max_dispatch_attempts) {
                    const reason = try std.fmt.allocPrint(
                        self.allocator,
                        "worker crashed after {d} attempt(s): {s}",
                        .{ attempt, @errorName(err) },
                    );
                    defer self.allocator.free(reason);
                    try self.kernel.markFailed(task_id, reason);
                    return null;
                }
                io_mod.sleep(dispatchBackoffMs(attempt) * std.time.ns_per_ms);
            }
        }
    }
};

/// Exponential backoff between dispatch-crash retries: 2s, 4s, ... This is
/// real wall-clock time by design — it only ever runs after the dispatch
/// mechanism itself has crashed, which existing tests never trigger.
fn dispatchBackoffMs(completed_attempt: u32) u64 {
    return @as(u64, 2000) << @intCast(completed_attempt - 1);
}

fn requiresGithubMergeAwareness(objective: []const u8) bool {
    const haystack = objective;

    const mentions_github =
        std.mem.indexOf(u8, haystack, "GitHub") != null or
        std.mem.indexOf(u8, haystack, "github") != null or
        std.mem.indexOf(u8, haystack, "PR") != null or
        std.mem.indexOf(u8, haystack, "pull request") != null;

    const mentions_observation =
        std.mem.indexOf(u8, haystack, "watch") != null or
        std.mem.indexOf(u8, haystack, "monitor") != null or
        std.mem.indexOf(u8, haystack, "merged") != null or
        std.mem.indexOf(u8, haystack, "merge") != null;

    return mentions_github and mentions_observation;
}

test "detects github merge-awareness objective" {
    try std.testing.expect(requiresGithubMergeAwareness(
        "watch merged pull requests on GitHub",
    ));
    try std.testing.expect(requiresGithubMergeAwareness(
        "monitor PR merges",
    ));
    try std.testing.expect(!requiresGithubMergeAwareness(
        "refactor the billing service",
    ));
}

test "request returns null and does not create a task when nothing is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });

    var kernel = try kernel_mod.Kernel.init(alloc, cto_root);
    var runtime = Runtime.init(alloc, &kernel, root, .dry_run, null);

    const task_id = try runtime.request("refactor the billing service");
    try std.testing.expect(task_id == null);
    try std.testing.expectEqual(@as(usize, 0), kernel.tasks.items.len);
    try std.testing.expectEqual(@as(usize, 2), kernel.journal.events.items.len);
}

test "request records a failed task rather than crashing when the worktree cannot be created" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });

    // Give the tmp dir its own git repo so `git worktree add` cannot walk
    // upward and mistake the real fx checkout for the test's repository.
    try initTestRepo(alloc, root);
    // Task ids start at 1 for a fresh kernel, so this is exactly the branch
    // name `delegateSelfExtension` will try to create, forcing a
    // deterministic `git worktree add` failure without touching zig/build.
    try runGitOrFail(alloc, &.{ "git", "-C", root, "branch", "candidate/task-1" });

    var kernel = try kernel_mod.Kernel.init(alloc, cto_root);
    var runtime = Runtime.init(alloc, &kernel, root, .dry_run, null);

    const task_id = try runtime.request("watch merged pull requests");
    try std.testing.expect(task_id != null);
    const task = kernel.findTask(task_id.?).?;
    try std.testing.expectEqual(@import("task.zig").TaskStatus.failed, task.status);
}

fn initTestRepo(alloc: std.mem.Allocator, root: []const u8) !void {
    try runGitOrFail(alloc, &.{ "git", "-C", root, "init", "--quiet" });
    try runGitOrFail(alloc, &.{ "git", "-C", root, "config", "user.email", "cto@example.com" });
    try runGitOrFail(alloc, &.{ "git", "-C", root, "config", "user.name", "cto" });

    const readme_path = try std.fs.path.join(alloc, &.{ root, "README.md" });
    defer alloc.free(readme_path);
    var readme = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), readme_path, .{ .truncate = true });
    try readme.writeStreamingAll(io_mod.getIo(), "seed\n");
    readme.close(io_mod.getIo());

    try runGitOrFail(alloc, &.{ "git", "-C", root, "add", "README.md" });
    try runGitOrFail(alloc, &.{ "git", "-C", root, "commit", "--quiet", "-m", "seed" });
}

fn runGitOrFail(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(alloc, io_mod.getIo(), .{ .argv = argv });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!git.termExitedZero(result.term)) return error.GitSetupFailed;
}
