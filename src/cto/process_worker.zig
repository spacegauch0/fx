const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const io_mod = @import("../core/shared/io.zig");
const worker_mod = @import("worker.zig");

comptime {
    // The supervision loop below signals a whole process group via a raw
    // `kill(-pgid, ...)` and reaps with a raw `wait4(..., WNOHANG, ...)`.
    // Both are POSIX-only; this file has only ever been exercised on
    // Linux, where fx itself runs today. Fail loudly at compile time on an
    // unsupported target rather than silently mis-supervising a worker.
    if (builtin.os.tag != .linux) {
        @compileError("process_worker.zig only supports linux (raw process-group signal/reap)");
    }
}

/// Out-of-process worker dispatch (roadmap M4, decision D3).
///
/// The in-process `FxWorker`/`LiveRunner` pair (fx_worker.zig) is correct
/// for a one-shot CLI call, but cannot be preempted, cannot isolate a
/// crash, and cannot give `/interrupt` anything real to cancel. This
/// worker spawns the command as its own process **group** (`pgid = 0`) so
/// that cancelling it reaches not just the direct child but every
/// subprocess it spawns in turn (a coding agent runs shell tool calls,
/// which are exactly the grandchildren a single-pid signal would miss).
///
/// Cancellation and a wall-clock timeout are both handled the same way:
/// a marker file or an elapsed deadline causes this loop to signal the
/// whole group itself, rather than delegating to `std.process.Child.kill`
/// (which only ever signals the one pid it holds).
///
/// Bookkeeping (`runs/<run-id>.pid`, `.log`, `.interrupt`) lives under the
/// caller-supplied `cto_root`, not under `repository_path`, so it lands
/// next to the rest of this task's audit trail regardless of where
/// `cto_root` is configured.
pub const ProcessWorker = struct {
    /// Command to run, *not* including the prompt: the prompt is appended
    /// as the final argv element. Production callers pass the fx binary
    /// (`&.{fx_binary_path, "ask", "--yolo", "--no-save"}`); tests can pass
    /// `&.{"sh", "-c"}` to exercise timeout/interrupt paths quickly without
    /// depending on a real agent run.
    argv: []const []const u8,
    /// Wall-clock budget, mirrored from `WorkRequest.timeout_ms` by
    /// default; overridable here mainly for tests that want a short poll
    /// loop without waiting out a real 30-minute default.
    poll_interval_ms: i64 = 200,
    /// Grace period between SIGTERM and SIGKILL when a group refuses to
    /// exit promptly.
    kill_grace_ms: i64 = 5000,
    /// Captured stdout/stderr are each capped at this many bytes before
    /// `.cto/runs/<id>.log` is written; the rest is dropped (but still
    /// drained from the pipe, so a chatty child never blocks on a full
    /// pipe buffer).
    max_log_bytes: usize = 64 * 1024,

    pub fn asWorker(self: *ProcessWorker) worker_mod.Worker {
        return .{ .context = self, .runFn = runOpaque };
    }

    fn runOpaque(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: worker_mod.WorkRequest,
    ) !worker_mod.WorkResult {
        const self: *ProcessWorker = @ptrCast(@alignCast(context));
        return self.run(allocator, request);
    }

    pub fn run(
        self: *ProcessWorker,
        allocator: std.mem.Allocator,
        request: worker_mod.WorkRequest,
    ) !worker_mod.WorkResult {
        const io = io_mod.getIo();

        const full_argv = try allocator.alloc([]const u8, self.argv.len + 1);
        defer allocator.free(full_argv);
        @memcpy(full_argv[0..self.argv.len], self.argv);
        full_argv[self.argv.len] = request.prompt;

        var child = std.process.spawn(io, .{
            .argv = full_argv,
            .cwd = .{ .path = request.worktree_path },
            // A new process group led by the child itself, so a group-wide
            // signal reaches every subprocess it spawns, not just it.
            .pgid = 0,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| return .{
            .outcome = .failed,
            .summary = try std.fmt.allocPrint(allocator, "failed to spawn worker: {s}", .{@errorName(err)}),
        };
        const pid = child.id.?;

        const runs_dir = try std.fs.path.join(allocator, &.{ request.cto_root, "runs" });
        defer allocator.free(runs_dir);
        io_mod.makeDirRecursive(runs_dir) catch |err| {
            posix.kill(-pid, .KILL) catch {};
            _ = tryReapBlocking(pid);
            return .{
                .outcome = .failed,
                .summary = try std.fmt.allocPrint(allocator, "could not create {s}: {s}", .{ runs_dir, @errorName(err) }),
            };
        };

        const pid_path = try pidFilePath(allocator, request.cto_root, request.run_id);
        defer allocator.free(pid_path);
        const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
        defer allocator.free(pid_text);
        io_mod.writeFileAtomic(allocator, pid_path, pid_text) catch {};
        defer std.Io.Dir.deleteFileAbsolute(io, pid_path) catch {};

        const interrupt_path = try interruptMarkerPath(allocator, request.cto_root, request.run_id);
        defer allocator.free(interrupt_path);
        // Best-effort: a marker left over from a previous run with the same
        // id (should not happen; ids are never reused) must not
        // immediately cancel this one.
        std.Io.Dir.deleteFileAbsolute(io, interrupt_path) catch {};
        defer std.Io.Dir.deleteFileAbsolute(io, interrupt_path) catch {};

        var stdout_state: DrainState = .{};
        defer stdout_state.buf.deinit(allocator);
        var stderr_state: DrainState = .{};
        defer stderr_state.buf.deinit(allocator);

        // Draining runs on separate threads so the poll loop below can
        // watch the deadline/interrupt marker concurrently. If a drain
        // thread fails to start (extremely rare — thread creation is the
        // only fallible step), that stream's output is simply lost rather
        // than aborting the run: losing a log is recoverable, killing a
        // task over it is not.
        const stdout_thread: ?std.Thread = std.Thread.spawn(
            .{},
            drainInto,
            .{ allocator, child.stdout.?, self.max_log_bytes, &stdout_state },
        ) catch null;
        const stderr_thread: ?std.Thread = std.Thread.spawn(
            .{},
            drainInto,
            .{ allocator, child.stderr.?, self.max_log_bytes, &stderr_state },
        ) catch null;

        const deadline_ms = io_mod.milliTimestamp() +| request.timeout_ms;
        var kill_reason: ?[]const u8 = null;
        var sigterm_sent_at_ms: ?i64 = null;
        const term: std.process.Child.Term = while (true) {
            if (try tryReap(pid)) |reaped| break reaped;

            const now_ms = io_mod.milliTimestamp();
            if (sigterm_sent_at_ms) |sent_at| {
                if (now_ms - sent_at >= self.kill_grace_ms) posix.kill(-pid, .KILL) catch {};
            } else if (now_ms >= deadline_ms) {
                posix.kill(-pid, .TERM) catch {};
                sigterm_sent_at_ms = now_ms;
                kill_reason = "timeout";
            } else if (interruptRequested(interrupt_path)) {
                posix.kill(-pid, .TERM) catch {};
                sigterm_sent_at_ms = now_ms;
                kill_reason = "interrupted by operator";
            }

            io_mod.sleep(@as(u64, @intCast(self.poll_interval_ms)) * std.time.ns_per_ms);
        };
        // The direct child has exited (however it got there), but a group
        // is not the same as its leader: anything it backgrounded and
        // detached before exiting is still a member of process group
        // `pid` and would otherwise be an orphan. A trailing group-wide
        // kill is idempotent (harmless once the group is already empty)
        // and is the actual mechanism behind "no orphan child survives".
        posix.kill(-pid, .KILL) catch {};

        if (stdout_thread) |t| t.join();
        if (stderr_thread) |t| t.join();
        child.stdout.?.close(io);
        child.stderr.?.close(io);

        const log_path = try logFilePath(allocator, request.cto_root, request.run_id);
        defer allocator.free(log_path);
        const log_text = try std.fmt.allocPrint(
            allocator,
            "== stdout{s} ==\n{s}\n== stderr{s} ==\n{s}\n",
            .{
                if (stdout_state.truncated) " (truncated)" else "",
                stdout_state.buf.items,
                if (stderr_state.truncated) " (truncated)" else "",
                stderr_state.buf.items,
            },
        );
        defer allocator.free(log_text);
        // A lost log must never fail an otherwise-completed run.
        io_mod.writeFileAtomic(allocator, log_path, log_text) catch {};

        if (kill_reason) |reason| {
            return .{
                .outcome = if (std.mem.eql(u8, reason, "timeout")) .timed_out else .interrupted,
                .summary = try std.fmt.allocPrint(
                    allocator,
                    "worker in {s} was stopped ({s}); log: {s}",
                    .{ request.worktree_path, reason, log_path },
                ),
            };
        }

        return switch (term) {
            .exited => |code| .{
                .outcome = if (code == 0) .succeeded else .failed,
                .summary = try std.fmt.allocPrint(
                    allocator,
                    "fx agent ({s}, exit {d}) in {s}; log: {s}",
                    .{ if (code == 0) "succeeded" else "failed", code, request.worktree_path, log_path },
                ),
            },
            .signal => |sig| .{
                .outcome = .failed,
                .summary = try std.fmt.allocPrint(
                    allocator,
                    "fx agent in {s} was killed by signal {d}; log: {s}",
                    .{ request.worktree_path, @intFromEnum(sig), log_path },
                ),
            },
            else => .{
                .outcome = .failed,
                .summary = try std.fmt.allocPrint(
                    allocator,
                    "fx agent in {s} exited abnormally; log: {s}",
                    .{ request.worktree_path, log_path },
                ),
            },
        };
    }
};

const DrainState = struct {
    buf: std.ArrayList(u8) = .empty,
    truncated: bool = false,
};

/// Drains one pipe end to EOF into a capped buffer, discarding (but still
/// reading) anything past the cap so a chatty child never blocks on a full
/// pipe buffer while this worker is deciding whether to kill it.
fn drainInto(alloc: std.mem.Allocator, file: std.Io.File, cap: usize, state: *DrainState) void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(file.handle, &chunk) catch break;
        if (n == 0) break;
        if (state.buf.items.len >= cap) {
            state.truncated = true;
            continue;
        }
        const room = cap - state.buf.items.len;
        const take = @min(room, n);
        state.buf.appendSlice(alloc, chunk[0..take]) catch break;
        if (take < n) state.truncated = true;
    }
}

/// Non-blocking reap attempt. Returns `null` while the child is still
/// running, so the caller can keep polling for the deadline/interrupt
/// marker in between.
fn tryReap(pid: posix.pid_t) !?std.process.Child.Term {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const raw = posix.system.wait4(pid, &status, posix.W.NOHANG, null);
        switch (posix.errno(raw)) {
            .SUCCESS => {
                const reaped: posix.pid_t = @intCast(raw);
                if (reaped == 0) return null;
                return statusToTerm(@bitCast(status));
            },
            .INTR => continue,
            .CHILD => return .{ .unknown = 0 },
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Blocking reap used only on a spawn-adjacent failure path (e.g. the runs
/// directory could not be created) to avoid leaving a zombie behind.
/// Ignores the exit status: nothing downstream will look at a `WorkResult`
/// this path never produces.
fn tryReapBlocking(pid: posix.pid_t) void {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        switch (posix.errno(posix.system.wait4(pid, &status, 0, null))) {
            .INTR => continue,
            else => return,
        }
    }
}

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (posix.W.IFEXITED(status))
        .{ .exited = posix.W.EXITSTATUS(status) }
    else if (posix.W.IFSIGNALED(status))
        .{ .signal = posix.W.TERMSIG(status) }
    else
        .{ .unknown = status };
}

fn interruptRequested(interrupt_path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), interrupt_path, .{}) catch return false;
    _ = stat;
    return true;
}

pub fn pidFilePath(alloc: std.mem.Allocator, cto_root: []const u8, run_id: u64) ![]u8 {
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d}.pid", .{run_id});
    return std.fs.path.join(alloc, &.{ cto_root, "runs", name });
}

pub fn logFilePath(alloc: std.mem.Allocator, cto_root: []const u8, run_id: u64) ![]u8 {
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d}.log", .{run_id});
    return std.fs.path.join(alloc, &.{ cto_root, "runs", name });
}

pub fn interruptMarkerPath(alloc: std.mem.Allocator, cto_root: []const u8, run_id: u64) ![]u8 {
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d}.interrupt", .{run_id});
    return std.fs.path.join(alloc, &.{ cto_root, "runs", name });
}

/// Reads the pid recorded for a run, if one is currently on file. Used by
/// `fx cto interrupt` to report whether there is anything to cancel.
pub fn readPid(alloc: std.mem.Allocator, cto_root: []const u8, run_id: u64) !?posix.pid_t {
    const path = try pidFilePath(alloc, cto_root, run_id);
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const text = try io_mod.readFileToEnd(alloc, &file, 64);
    defer alloc.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.fmt.parseInt(posix.pid_t, trimmed, 10) catch null;
}

test "a quick command reports success and captures output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);

    var worker: ProcessWorker = .{ .argv = &.{ "sh", "-c" }, .poll_interval_ms = 20 };
    const result = try worker.run(std.testing.allocator, .{
        .task_id = 1,
        .run_id = 1,
        .repository_path = root,
        .worktree_path = root,
        .cto_root = root,
        .prompt = "echo hello-stdout; echo hello-stderr 1>&2",
        .timeout_ms = 5000,
    });
    defer std.testing.allocator.free(result.summary);
    try std.testing.expectEqual(worker_mod.Outcome.succeeded, result.outcome);

    const log_path = try logFilePath(std.testing.allocator, root, 1);
    defer std.testing.allocator.free(log_path);
    var log_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), log_path, .{});
    defer log_file.close(io_mod.getIo());
    const log_text = try io_mod.readFileToEnd(std.testing.allocator, &log_file, 4096);
    defer std.testing.allocator.free(log_text);
    try std.testing.expect(std.mem.find(u8, log_text, "hello-stdout") != null);
    try std.testing.expect(std.mem.find(u8, log_text, "hello-stderr") != null);

    // The pid file is cleaned up once the run has finished.
    try std.testing.expectEqual(@as(?posix.pid_t, null), try readPid(std.testing.allocator, root, 1));
}

test "a failing command is reported as failed, not crashed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);

    var worker: ProcessWorker = .{ .argv = &.{ "sh", "-c" }, .poll_interval_ms = 20 };
    const result = try worker.run(std.testing.allocator, .{
        .task_id = 1,
        .run_id = 2,
        .repository_path = root,
        .worktree_path = root,
        .cto_root = root,
        .prompt = "exit 3",
        .timeout_ms = 5000,
    });
    defer std.testing.allocator.free(result.summary);
    try std.testing.expectEqual(worker_mod.Outcome.failed, result.outcome);
}

// Also the closest thing to a direct test of pgid/group targeting: the
// spawned process traps and ignores SIGTERM, so only a real SIGKILL
// delivered to its process group (not just `Child.kill`, which signals a
// single pid) can end it before the 30s `sleep` would otherwise outlast
// the test.
test "a command that outlives its deadline is killed and reported as timed_out" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);

    var worker: ProcessWorker = .{ .argv = &.{ "sh", "-c" }, .poll_interval_ms = 20, .kill_grace_ms = 200 };
    const result = try worker.run(std.testing.allocator, .{
        .task_id = 1,
        .run_id = 3,
        .repository_path = root,
        .worktree_path = root,
        .cto_root = root,
        // Traps SIGTERM so the test also proves SIGKILL escalation works.
        .prompt = "trap '' TERM; sleep 30",
        .timeout_ms = 100,
    });
    defer std.testing.allocator.free(result.summary);
    try std.testing.expectEqual(worker_mod.Outcome.timed_out, result.outcome);
}

test "an interrupt marker cancels a run before its deadline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);

    const interrupt_path = try interruptMarkerPath(std.testing.allocator, root, 5);
    defer std.testing.allocator.free(interrupt_path);
    const runs_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "runs" });
    defer std.testing.allocator.free(runs_dir);
    try io_mod.makeDirRecursive(runs_dir);

    // Written concurrently by a background thread shortly after the
    // worker starts, mimicking a separate `fx cto interrupt 5` process.
    const Writer = struct {
        fn go(path: []const u8) void {
            io_mod.sleep(50 * std.time.ns_per_ms);
            io_mod.writeFileAtomic(std.testing.allocator, path, "") catch {};
        }
    };
    const writer_thread = try std.Thread.spawn(.{}, Writer.go, .{interrupt_path});
    defer writer_thread.join();

    var worker: ProcessWorker = .{ .argv = &.{ "sh", "-c" }, .poll_interval_ms = 20 };
    const result = try worker.run(std.testing.allocator, .{
        .task_id = 1,
        .run_id = 5,
        .repository_path = root,
        .worktree_path = root,
        .cto_root = root,
        .prompt = "sleep 30",
        .timeout_ms = 30_000,
    });
    defer std.testing.allocator.free(result.summary);
    try std.testing.expectEqual(worker_mod.Outcome.interrupted, result.outcome);
}
