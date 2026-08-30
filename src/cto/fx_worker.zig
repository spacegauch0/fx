const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const self_exe = @import("../core/shared/self_exe.zig");
const git = @import("git.zig");
const worker_mod = @import("worker.zig");

const dispatch_env_var = "FX_CTO_DISPATCH_WORKER";
const prompt_record_name = ".cto-task-prompt.md";

pub const DispatchMode = enum {
    /// Prepares the worktree and records the exact command cto-dev would
    /// run, but does not invoke a live model. This is the default: a bare
    /// `fx cto request` must never silently spend model credits or touch
    /// the network.
    dry_run,
    /// Actually shells out to `fx ask` inside the task's worktree.
    live,
};

pub fn dispatchModeFromEnv() DispatchMode {
    const value = io_mod.getenv(dispatch_env_var) orelse return .dry_run;
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")) return .live;
    return .dry_run;
}

/// Adapter boundary between CTO and the existing fx harness.
///
/// CTO does not reimplement coding-agent behavior: it re-execs the fx binary
/// it is already running as (`self_exe.pathForPeerReexec`) with `fx ask`
/// inside the task's isolated worktree, reusing fx's existing noninteractive
/// agent/session runtime as-is.
pub const FxWorker = struct {
    dispatch: DispatchMode = .dry_run,

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

        const exe_path = self_exe.pathForPeerReexec(allocator) catch |err| {
            return .{
                .success = false,
                .summary = try std.fmt.allocPrint(
                    allocator,
                    "could not resolve the fx executable to dispatch as a worker: {s}",
                    .{@errorName(err)},
                ),
            };
        };
        defer allocator.free(exe_path);

        return switch (self.dispatch) {
            .dry_run => .{
                .success = true,
                .summary = try std.fmt.allocPrint(
                    allocator,
                    "cto-dev prepared the task in {s} (prompt recorded at {s}); " ++
                        "worker dispatch is disabled by default, set {s}=1 to run `{s} ask` live",
                    .{ request.worktree_path, prompt_record_name, dispatch_env_var, exe_path },
                ),
            },
            .live => self.runLive(allocator, exe_path, request),
        };
    }

    fn runLive(
        _: *FxWorker,
        allocator: std.mem.Allocator,
        exe_path: []const u8,
        request: worker_mod.WorkRequest,
    ) !worker_mod.WorkResult {
        const result = std.process.run(allocator, io_mod.getIo(), .{
            .argv = &.{ exe_path, "ask", "--yolo", "--no-save", request.prompt },
            .cwd = .{ .path = request.worktree_path },
        }) catch |err| {
            return .{
                .success = false,
                .summary = try std.fmt.allocPrint(
                    allocator,
                    "fx ask failed to run in {s}: {s}",
                    .{ request.worktree_path, @errorName(err) },
                ),
            };
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const ok = git.termExitedZero(result.term);
        return .{
            .success = ok,
            .summary = try std.fmt.allocPrint(
                allocator,
                "fx ask ({s}) in {s}",
                .{ if (ok) "succeeded" else "failed", request.worktree_path },
            ),
        };
    }
};
