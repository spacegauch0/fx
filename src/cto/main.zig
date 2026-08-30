const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

const fx_worker_mod = @import("fx_worker.zig");
const git = @import("git.zig");
const kernel_mod = @import("kernel.zig");
const runtime_mod = @import("runtime.zig");
const store = @import("store.zig");
const task_mod = @import("task.zig");

comptime {
    _ = @import("extension_contract.zig");
    _ = @import("extensions/registry.zig");
}

const default_cto_root = ".cto";
const default_repository_path = ".";

/// Entry point for `fx cto ...`, called from fx's composition root
/// (src/main.zig) before the normal interactive/TUI runtime boots. This
/// module owns its own I/O setup and never returns a Zig error to the
/// caller: an unreadable `.cto/` file or a missing task id becomes a clean
/// CLI message and a nonzero exit code, not a crash.
///
/// `environ_block` is the real process environment: git/zig subprocess
/// spawning and `FX_CTO_DISPATCH_WORKER` both need it, not a default search
/// path baked into a bare `Threaded.init`.
pub fn run(
    gpa: std.mem.Allocator,
    args: []const [:0]const u8,
    environ_block: std.process.Environ.Block,
    live_runner: ?fx_worker_mod.LiveRunner,
) u8 {
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .{ .block = environ_block } });
    defer threaded.deinit();
    io_mod.setIo(threaded.io());
    io_mod.setEnvironBlock(environ_block);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    return runInner(arena.allocator(), args, default_cto_root, default_repository_path, live_runner) catch |err| {
        std.debug.print("fx cto: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn runInner(
    alloc: std.mem.Allocator,
    args: []const [:0]const u8,
    cto_root: []const u8,
    repository_path: []const u8,
    live_runner: ?fx_worker_mod.LiveRunner,
) !u8 {
    if (args.len == 0 or isHelp(args[0])) {
        printHelp();
        return 0;
    }
    const command = args[0];

    var kernel = try kernel_mod.Kernel.init(alloc, cto_root);
    defer kernel.deinit();

    if (std.mem.eql(u8, command, "status")) {
        printStatus(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "capabilities")) {
        try printCapabilities(alloc, &kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "tasks")) {
        printTasks(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "goals")) {
        printGoals(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "runs")) {
        printRuns(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "events")) {
        printEvents(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "request")) {
        return runRequest(alloc, &kernel, args, repository_path, live_runner);
    }
    if (std.mem.eql(u8, command, "approve")) {
        return runApprove(&kernel, args);
    }
    if (std.mem.eql(u8, command, "review")) {
        return runReview(alloc, &kernel, args);
    }

    std.debug.print("fx cto: unknown command `{s}`\n\n", .{command});
    printHelp();
    return 1;
}

fn runReview(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel, args: []const [:0]const u8) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: fx cto review <task-id>\n", .{});
        return 1;
    }
    const id = std.fmt.parseInt(u64, args[1], 10) catch {
        std.debug.print("fx cto review: `{s}` is not a valid task id\n", .{args[1]});
        return 1;
    };
    const task = kernel.findTask(id) orelse {
        std.debug.print("fx cto review: task #{d} was not found\n", .{id});
        return 1;
    };
    const worktree_path = task.worktree_path orelse {
        std.debug.print("fx cto review: task #{d} has no candidate worktree\n", .{id});
        return 1;
    };
    const diff = git.extensionDiff(alloc, worktree_path) catch |err| {
        std.debug.print("fx cto review: could not render task #{d}: {s}\n", .{ id, @errorName(err) });
        return 1;
    };
    defer alloc.free(diff);
    if (diff.len == 0) {
        std.debug.print("task #{d} has no extension changes\n", .{id});
    } else {
        std.debug.print("{s}", .{diff});
    }
    return 0;
}

fn isHelp(command: []const u8) bool {
    return std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h");
}

fn runRequest(
    alloc: std.mem.Allocator,
    kernel: *kernel_mod.Kernel,
    args: []const [:0]const u8,
    repository_path: []const u8,
    live_runner: ?fx_worker_mod.LiveRunner,
) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: fx cto request \"<objective>\"\n", .{});
        return 1;
    }
    const objective = args[1];
    const absolute_repository_path = try store.resolveAbsolute(alloc, repository_path);

    var runtime = runtime_mod.Runtime.init(
        alloc,
        kernel,
        absolute_repository_path,
        fx_worker_mod.dispatchModeFromEnv(),
        live_runner,
    );
    const task_id = try runtime.request(objective);

    const id = task_id orelse {
        std.debug.print("CTO accepted the request; no missing capability was detected.\n", .{});
        return 0;
    };
    const task = kernel.findTask(id) orelse return error.TaskNotFound;
    switch (task.status) {
        .approval_required => std.debug.print(
            "CTO created self-extension task #{d} for `{s}`; a candidate is ready and requires approval.\n" ++
                "Run `fx cto approve {d}` to activate it, or `fx cto events` to review the audit trail.\n",
            .{ id, task.required_capability, id },
        ),
        .failed => std.debug.print(
            "CTO created self-extension task #{d} for `{s}`, but the worker run failed.\n" ++
                "Run `fx cto events` for detail; the task and any partial worktree were left in place.\n",
            .{ id, task.required_capability },
        ),
        else => std.debug.print(
            "CTO created self-extension task #{d} for `{s}` (status={s}).\n",
            .{ id, task.required_capability, @tagName(task.status) },
        ),
    }
    return 0;
}

fn runApprove(kernel: *kernel_mod.Kernel, args: []const [:0]const u8) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: fx cto approve <task-id>\n", .{});
        return 1;
    }
    const id = std.fmt.parseInt(u64, args[1], 10) catch {
        std.debug.print("fx cto approve: `{s}` is not a valid task id\n", .{args[1]});
        return 1;
    };
    kernel.approve(id) catch |err| {
        std.debug.print("fx cto approve: could not approve task #{d}: {s}\n", .{ id, @errorName(err) });
        return 1;
    };
    std.debug.print("Approved task #{d}; capability activated.\n", .{id});
    return 0;
}

fn printHelp() void {
    std.debug.print(
        \\fx cto - a CTO runtime layered on top of the fx coding harness
        \\
        \\Commands:
        \\  status                    Show kernel, worker, and capability summary
        \\  capabilities              List every known capability and its status
        \\  request "<objective>"     Ask CTO to pursue an outcome
        \\  tasks                     List tasks and their lifecycle status
        \\  goals                     List durable outcome goals
        \\  runs                      List worker execution attempts
        \\  review <task-id>          Show the candidate extension diff
        \\  approve <task-id>         Activate a candidate awaiting approval
        \\  events                    Show the append-only audit journal
        \\
    , .{});
}

fn printStatus(kernel: *kernel_mod.Kernel) void {
    const counts = kernel.capabilities.count();
    var pending: usize = 0;
    for (kernel.tasks.items) |task| {
        switch (task.status) {
            .completed, .rejected, .failed => {},
            else => pending += 1,
        }
    }
    std.debug.print(
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

fn printCapabilities(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel) !void {
    const entries = try kernel.capabilities.sortedEntries(alloc);
    defer alloc.free(entries);
    for (entries) |capability| {
        std.debug.print(
            "{s}: {s} ({s})\n",
            .{ capability.name, @tagName(capability.status), capability.source },
        );
    }
}

fn printTasks(kernel: *kernel_mod.Kernel) void {
    if (kernel.tasks.items.len == 0) {
        std.debug.print("no tasks yet\n", .{});
        return;
    }
    for (kernel.tasks.items) |task| {
        std.debug.print(
            "#{d} [{s}] {s} -> {s}\n",
            .{ task.id, @tagName(task.status), task.required_capability, task.assignee },
        );
    }
}

fn printGoals(kernel: *kernel_mod.Kernel) void {
    if (kernel.goals.items.len == 0) {
        std.debug.print("no goals yet\n", .{});
        return;
    }
    for (kernel.goals.items) |goal| {
        std.debug.print("#{d} [{s}] {s}\n", .{ goal.id, @tagName(goal.status), goal.objective });
    }
}

fn printRuns(kernel: *kernel_mod.Kernel) void {
    if (kernel.runs.items.len == 0) {
        std.debug.print("no runs yet\n", .{});
        return;
    }
    for (kernel.runs.items) |worker_run| {
        std.debug.print("#{d} task #{d} [{s}] {s}\n", .{ worker_run.id, worker_run.task_id, @tagName(worker_run.status), worker_run.worker });
    }
}

fn printEvents(kernel: *kernel_mod.Kernel) void {
    if (kernel.journal.events.items.len == 0) {
        std.debug.print("no events yet\n", .{});
        return;
    }
    for (kernel.journal.events.items) |event| {
        std.debug.print(
            "{d} {s} {s}: {s}\n",
            .{ event.sequence, @tagName(event.kind), event.subject, event.detail },
        );
    }
}

test "printHelp does not require a kernel and always succeeds" {
    printHelp();
}

test "isHelp recognizes help spellings and rejects other commands" {
    try std.testing.expect(isHelp("help"));
    try std.testing.expect(isHelp("--help"));
    try std.testing.expect(isHelp("-h"));
    try std.testing.expect(!isHelp("status"));
}

test "runInner routes status, capabilities, request, tasks, events, and approve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });

    // Give the tmp dir its own git repo so `fx cto request`'s worktree
    // creation cannot walk upward and mistake the real fx checkout for the
    // test's repository. The worktree it creates has no build.zig, so
    // candidate validation fails fast rather than running a real build.
    for ([_][]const []const u8{
        &.{ "git", "-C", root, "init", "--quiet" },
        &.{ "git", "-C", root, "config", "user.email", "cto@example.com" },
        &.{ "git", "-C", root, "config", "user.name", "cto" },
    }) |argv| {
        const result = try std.process.run(alloc, io_mod.getIo(), .{ .argv = argv });
        alloc.free(result.stdout);
        alloc.free(result.stderr);
    }
    const readme_path = try std.fs.path.join(alloc, &.{ root, "README.md" });
    var readme = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), readme_path, .{ .truncate = true });
    try readme.writeStreamingAll(io_mod.getIo(), "seed\n");
    readme.close(io_mod.getIo());
    for ([_][]const []const u8{
        &.{ "git", "-C", root, "add", "README.md" },
        &.{ "git", "-C", root, "commit", "--quiet", "-m", "seed" },
    }) |argv| {
        const result = try std.process.run(alloc, io_mod.getIo(), .{ .argv = argv });
        alloc.free(result.stdout);
        alloc.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), try runInner(alloc, &.{"status"}, cto_root, root, null));
    try std.testing.expectEqual(@as(u8, 0), try runInner(alloc, &.{"capabilities"}, cto_root, root, null));
    try std.testing.expectEqual(@as(u8, 0), try runInner(alloc, &.{"tasks"}, cto_root, root, null));
    try std.testing.expectEqual(@as(u8, 0), try runInner(alloc, &.{"events"}, cto_root, root, null));

    try std.testing.expectEqual(
        @as(u8, 0),
        try runInner(alloc, &.{ "request", "watch merged pull requests" }, cto_root, root, null),
    );

    var kernel = try kernel_mod.Kernel.init(alloc, cto_root);
    defer kernel.deinit();
    try std.testing.expectEqual(@as(usize, 1), kernel.tasks.items.len);
    try std.testing.expectEqual(task_mod.TaskStatus.failed, kernel.tasks.items[0].status);

    try std.testing.expectEqual(@as(u8, 1), try runInner(alloc, &.{"unknown-command"}, cto_root, root, null));
    try std.testing.expectEqual(@as(u8, 1), try runInner(alloc, &.{ "approve", "not-a-number" }, cto_root, root, null));
    try std.testing.expectEqual(@as(u8, 1), try runInner(alloc, &.{ "approve", "999" }, cto_root, root, null));
}
