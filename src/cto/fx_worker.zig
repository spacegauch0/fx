const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const worker_mod = @import("worker.zig");

const dispatch_env_var = "FX_CTO_DISPATCH_WORKER";
const prompt_record_name = ".cto-task-prompt.md";

pub const DispatchMode = enum {
    /// Prepares the worktree and records the exact command cto-dev would
    /// run, but does not invoke a live model. This is the default: a bare
    /// `fx cto request` must never silently spend model credits or touch
    /// the network.
    dry_run,
    /// Runs fx's headless agent/session runtime inside the task's worktree.
    live,
};

/// Composition-root hook into fx's real headless agent runtime. Keeping the
/// callback here lets the CTO layer depend on a small typed contract instead
/// of importing the application's provider, tool, and credential wiring.
pub const LiveRunner = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: worker_mod.WorkRequest,
    ) anyerror!worker_mod.WorkResult,

    pub fn run(
        self: LiveRunner,
        allocator: std.mem.Allocator,
        request: worker_mod.WorkRequest,
    ) !worker_mod.WorkResult {
        return self.run_fn(self.context, allocator, request);
    }
};

pub fn dispatchModeFromEnv() DispatchMode {
    const value = io_mod.getenv(dispatch_env_var) orelse return .dry_run;
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")) return .live;
    return .dry_run;
}

/// Adapter boundary between CTO and the existing fx harness.
///
/// CTO does not reimplement coding-agent behavior. The composition root
/// injects fx's existing headless agent/session runtime, which this adapter
/// invokes inside the task's isolated worktree.
pub const FxWorker = struct {
    dispatch: DispatchMode = .dry_run,
    live_runner: ?LiveRunner = null,

    pub fn asWorker(self: *FxWorker) worker_mod.Worker {
        return .{ .context = self, .runFn = runOpaque };
    }

    fn runOpaque(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: worker_mod.WorkRequest,
    ) !worker_mod.WorkResult {
        const self: *FxWorker = @ptrCast(@alignCast(context));
        return self.run(allocator, request);
    }

    pub fn run(
        self: *FxWorker,
        allocator: std.mem.Allocator,
        request: worker_mod.WorkRequest,
    ) !worker_mod.WorkResult {
        const prompt_path = try std.fs.path.join(allocator, &.{ request.worktree_path, prompt_record_name });
        defer allocator.free(prompt_path);
        io_mod.writeFileAtomic(allocator, prompt_path, request.prompt) catch |err| {
            return .{
                .success = false,
                .summary = try std.fmt.allocPrint(
                    allocator,
                    "failed to record the implementation task in the worktree: {s}",
                    .{@errorName(err)},
                ),
            };
        };

        return switch (self.dispatch) {
            .dry_run => .{
                .success = true,
                .summary = try std.fmt.allocPrint(
                    allocator,
                    "cto-dev prepared the task in {s} (prompt recorded at {s}); " ++
                        "worker dispatch is disabled by default, set {s}=1 to run the fx agent live",
                    .{ request.worktree_path, prompt_record_name, dispatch_env_var },
                ),
            },
            .live => self.runLive(allocator, request),
        };
    }

    fn runLive(
        self: *FxWorker,
        allocator: std.mem.Allocator,
        request: worker_mod.WorkRequest,
    ) !worker_mod.WorkResult {
        const runner = self.live_runner orelse {
            return .{
                .success = false,
                .summary = try allocator.dupe(u8, "fx agent runtime is unavailable"),
            };
        };
        return runner.run(allocator, request);
    }
};

test "live dispatch uses the injected fx runtime" {
    const Probe = struct {
        called: bool = false,
        expected_worktree: []const u8,

        fn run(raw: ?*anyopaque, alloc: std.mem.Allocator, request: worker_mod.WorkRequest) !worker_mod.WorkResult {
            const probe: *@This() = @ptrCast(@alignCast(raw.?));
            probe.called = true;
            try std.testing.expectEqualStrings(probe.expected_worktree, request.worktree_path);
            return .{
                .success = true,
                .summary = try alloc.dupe(u8, "agent completed"),
            };
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);

    var probe: Probe = .{ .expected_worktree = root };
    var worker: FxWorker = .{
        .dispatch = .live,
        .live_runner = .{ .context = &probe, .run_fn = Probe.run },
    };
    const result = try worker.run(std.testing.allocator, .{
        .task_id = 1,
        .repository_path = root,
        .worktree_path = root,
        .prompt = "implement it",
    });
    defer std.testing.allocator.free(result.summary);

    try std.testing.expect(probe.called);
    try std.testing.expect(result.success);
}
