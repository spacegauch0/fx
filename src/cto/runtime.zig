const std = @import("std");

const candidate_mod = @import("candidate.zig");
const counterpart_mod = @import("counterpart.zig");
const fx_worker_mod = @import("fx_worker.zig");
const git = @import("git.zig");
const io_mod = @import("../core/shared/io.zig");
const kernel_mod = @import("kernel.zig");
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

    pub fn request(self: *Runtime, objective: []const u8) !?u64 {
        _ = try self.kernel.journal.append(.human_requested, "human", objective);

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

        _ = try self.kernel.journal.append(.worker_started, "cto-dev", "fx");

        var adapter = self.fx_worker.asWorker();
        const result = adapter.run(self.allocator, .{
            .task_id = task_id,
            .repository_path = self.counterpart.repository_path,
            .worktree_path = worktree_path,
            .prompt = prompt,
        }) catch |err| {
            const reason = try std.fmt.allocPrint(self.allocator, "worker crashed: {s}", .{@errorName(err)});
            defer self.allocator.free(reason);
            try self.kernel.markFailed(task_id, reason);
            return;
        };

        if (!result.success) {
            try self.kernel.markFailed(task_id, result.summary);
            return;
        }

        _ = try self.kernel.journal.append(.worker_completed, "cto-dev", result.summary);

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
};

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
    try std.testing.expectEqual(@as(usize, 1), kernel.journal.events.items.len);
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
