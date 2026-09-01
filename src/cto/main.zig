const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

const fx_worker_mod = @import("fx_worker.zig");
const git = @import("git.zig");
const kernel_mod = @import("kernel.zig");
const runtime_mod = @import("runtime.zig");
const store = @import("store.zig");
const task_mod = @import("task.zig");
const channel = @import("channel.zig");
const registry = @import("extensions/registry.zig");
const ingest_auth = @import("ingest_auth.zig");
const secrets = @import("secrets.zig");
const process_worker = @import("process_worker.zig");
const views = @import("views.zig");
const id_mod = @import("id.zig");
const schema_mod = @import("schema.zig");
const control_protocol = @import("control_protocol.zig");
const control_client = @import("control_client.zig");
const daemon_mod = @import("daemon.zig");
const writer_lock = @import("writer_lock.zig");

comptime {
    _ = @import("extension_contract.zig");
    _ = @import("extensions/registry.zig");
    _ = @import("channel.zig");
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

    if (std.mem.eql(u8, command, "daemon")) return runDaemon(alloc, cto_root, repository_path, args);
    if (std.mem.eql(u8, command, "ctl")) return runCtl(alloc, cto_root, args);
    if (std.mem.eql(u8, command, "schema")) {
        try withStderr(schema_mod.render, .{});
        return 0;
    }

    // D4: when a daemon owns this workspace, every command it understands
    // is proxied to it rather than read (or worse, written) directly —
    // `channel` and `ingest` are the two exceptions (stdin and free-text
    // sub-syntax the daemon doesn't parse) and stay direct-mode always.
    if (shouldProxyToDaemon(command) and control_client.daemonAvailable(alloc, cto_root)) {
        return proxyToDaemon(alloc, cto_root, args);
    }

    var writer_guard: ?writer_lock.Guard = null;
    if (isMutatingCommand(command)) {
        writer_guard = writer_lock.acquire(alloc, cto_root, 250) catch |err| {
            std.debug.print(
                "fx cto: could not acquire the workspace writer lock ({s}); " ++
                    "a daemon may already own {s}\n",
                .{ @errorName(err), cto_root },
            );
            return 1;
        };
    }
    defer if (writer_guard) |*guard| guard.release();

    var kernel = try kernel_mod.Kernel.init(alloc, cto_root);
    defer kernel.deinit();

    if (std.mem.eql(u8, command, "status")) {
        try printStatus(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "brief")) {
        try printBrief(alloc, &kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "explain")) return runExplain(&kernel, args);
    if (std.mem.eql(u8, command, "capabilities")) {
        try printCapabilities(alloc, &kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "tasks")) {
        try printTasks(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "goals")) {
        try printGoals(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "runs")) {
        try printRuns(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "decisions")) {
        try printDecisions(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "channel")) return runChannel(alloc, &kernel, args);
    if (std.mem.eql(u8, command, "interrupt")) return runInterrupt(alloc, &kernel, args);
    if (std.mem.eql(u8, command, "logs")) return runLogs(alloc, &kernel, args);
    if (std.mem.eql(u8, command, "observations")) {
        try printObservations(&kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "ingest")) {
        return runIngest(alloc, &kernel, args);
    }
    if (std.mem.eql(u8, command, "events")) {
        const since = parseSinceFlag(args[1..]) catch {
            std.debug.print("usage: fx cto events [--since <sequence>]\n", .{});
            return 1;
        };
        try printEvents(&kernel, since);
        return 0;
    }
    if (std.mem.eql(u8, command, "request")) {
        return runRequest(alloc, &kernel, args, repository_path, live_runner);
    }
    if (std.mem.eql(u8, command, "approve")) {
        return runApprove(alloc, &kernel, args, repository_path);
    }
    if (std.mem.eql(u8, command, "activate")) {
        return runActivate(alloc, &kernel, args, repository_path);
    }
    if (std.mem.eql(u8, command, "rollback")) {
        return runRollback(&kernel);
    }
    if (std.mem.eql(u8, command, "releases")) {
        try printReleases(alloc, &kernel);
        return 0;
    }
    if (std.mem.eql(u8, command, "review")) {
        return runReview(alloc, &kernel, args);
    }

    std.debug.print("fx cto: unknown command `{s}`\n\n", .{command});
    printHelp();
    return 1;
}

fn isMutatingCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "request") or
        std.mem.eql(u8, command, "approve") or
        std.mem.eql(u8, command, "activate") or
        std.mem.eql(u8, command, "rollback") or
        std.mem.eql(u8, command, "interrupt") or
        std.mem.eql(u8, command, "ingest") or
        std.mem.eql(u8, command, "channel");
}

/// `ingest` (reads a body from stdin) and `channel` (a free-text
/// sub-syntax the daemon doesn't parse, with its own D5 refusal logic)
/// stay direct-mode always. Everything else proxies when a daemon is
/// running, and only if it actually has a `control_protocol.Command`
/// counterpart — a typo'd command falls through to the normal
/// "unknown command" message instead of a confusing proxy attempt.
fn shouldProxyToDaemon(command: []const u8) bool {
    if (std.mem.eql(u8, command, "ingest") or std.mem.eql(u8, command, "channel")) return false;
    return std.meta.stringToEnum(control_protocol.Command, command) != null;
}

fn proxyToDaemon(alloc: std.mem.Allocator, cto_root: []const u8, args: []const [:0]const u8) !u8 {
    const command = std.meta.stringToEnum(control_protocol.Command, args[0]) orelse return 1;
    const argument: ?[]const u8 = if (args.len > 1) args[1] else null;
    const request_id = try std.fmt.allocPrint(alloc, "cli-{d}", .{io_mod.milliTimestamp()});
    const response = control_client.send(alloc, cto_root, .{
        .id = request_id,
        .command = command,
        .argument = argument,
    }) catch |err| {
        std.debug.print("fx cto: daemon request failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer response.deinit();
    if (response.value.output.len > 0) std.debug.print("{s}", .{response.value.output});
    if (response.value.error_message) |message| std.debug.print("fx cto: {s}\n", .{message});
    return response.value.exit_code;
}

fn runDaemon(
    alloc: std.mem.Allocator,
    cto_root: []const u8,
    repository_path: []const u8,
    args: []const [:0]const u8,
) !u8 {
    const exe = try std.process.executablePathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(exe);
    const absolute_repository_path = try store.resolveAbsolute(alloc, repository_path);
    daemon_mod.run(alloc, .{
        .cto_root = cto_root,
        .repository_path = absolute_repository_path,
        .fx_binary_path = exe,
        .once = args.len > 1 and std.mem.eql(u8, args[1], "--once"),
    }) catch |err| {
        std.debug.print("fx cto daemon: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn runCtl(alloc: std.mem.Allocator, cto_root: []const u8, args: []const [:0]const u8) !u8 {
    if (args.len < 2) {
        std.debug.print(
            "usage: fx cto ctl '{{\"id\":\"1\",\"command\":\"status\"}}'\n",
            .{},
        );
        return 1;
    }
    const parsed = control_protocol.decodeRequest(alloc, args[1]) catch |err| {
        std.debug.print("fx cto ctl: invalid request: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer parsed.deinit();
    const response = control_client.send(alloc, cto_root, parsed.value) catch |err| {
        std.debug.print("fx cto ctl: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer response.deinit();
    if (response.value.output.len > 0) std.debug.print("{s}", .{response.value.output});
    if (response.value.error_message) |message| std.debug.print("fx cto: {s}\n", .{message});
    return response.value.exit_code;
}

fn runReview(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel, args: []const [:0]const u8) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: fx cto review <task-id>\n", .{});
        return 1;
    }
    const id = id_mod.parse(.task, args[1]) orelse {
        std.debug.print("fx cto review: `{s}` is not a valid task id\n", .{args[1]});
        return 1;
    };
    var id_buf: [32]u8 = undefined;
    const label = id_mod.formatBuf(&id_buf, .task, id);
    const task = kernel.findTask(id) orelse {
        std.debug.print("fx cto review: {s} was not found\n", .{label});
        return 1;
    };
    const worktree_path = task.worktree_path orelse {
        std.debug.print("fx cto review: {s} has no candidate worktree\n", .{label});
        return 1;
    };
    const diff = git.extensionDiff(alloc, worktree_path) catch |err| {
        std.debug.print("fx cto review: could not render {s}: {s}\n", .{ label, @errorName(err) });
        return 1;
    };
    defer alloc.free(diff);
    if (diff.len == 0) {
        std.debug.print("{s} has no extension changes\n", .{label});
    } else {
        std.debug.print("{s}", .{diff});
    }
    return 0;
}

/// Feeds one raw provider event (JSON body on stdin) through the trusted
/// admission layer and then every registered connector
/// (`extensions/registry.zig`). A connector that returns an observation
/// gets it recorded, deduplicated by provider+delivery id.
///
/// Admission (size limit, event allowlist, HMAC signature) happens before
/// any connector sees the body. When a webhook secret is configured, an
/// unsigned or wrongly-signed body is refused; with no secret configured
/// an unsigned body is accepted, which is appropriate only because this
/// path is a local human piping a fixture, never a network listener.
fn runIngest(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel, args: []const [:0]const u8) !u8 {
    if (args.len < 3) {
        std.debug.print(
            "usage: fx cto ingest <event-name> <delivery-id> [--signature sha256=...] < body.json\n",
            .{},
        );
        return 1;
    }
    const event_name = args[1];
    const delivery_id = args[2];

    var signature_header: ?[]const u8 = null;
    var index: usize = 3;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--signature")) {
            index += 1;
            if (index >= args.len) {
                std.debug.print("fx cto ingest: --signature requires a value\n", .{});
                return 1;
            }
            signature_header = args[index];
        } else {
            std.debug.print("fx cto ingest: unexpected argument `{s}`\n", .{args[index]});
            return 1;
        }
    }

    const body = readStdinAlloc(alloc, ingest_auth.max_body_bytes + 1) catch |err| {
        std.debug.print("fx cto ingest: could not read the event body from stdin: {s}\n", .{@errorName(err)});
        return 1;
    };

    const secret = resolveWebhookSecret(alloc) catch |err| {
        std.debug.print("fx cto ingest: could not resolve the webhook secret: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer if (secret) |value| {
        @memset(value, 0);
        alloc.free(value);
    };

    const verdict = ingest_auth.admit(.{
        .event_name = event_name,
        .body = body,
        .signature_header = signature_header,
        .secret = secret,
    });
    if (!verdict.admitted()) {
        try kernel.recordIngestRejection(event_name, verdict.reason());
        std.debug.print("fx cto ingest: rejected — {s}\n", .{verdict.reason()});
        return 1;
    }

    if (registry.connectors.len == 0) {
        std.debug.print("no connectors are registered yet\n", .{});
        return 0;
    }

    var produced_observation = false;
    inline for (registry.connectors) |connector| {
        const maybe_observation = connector.normalize(alloc, .{
            .event_name = event_name,
            .delivery_id = delivery_id,
            .body = body,
        }) catch |err| {
            std.debug.print(
                "fx cto ingest: connector `{s}` rejected the event: {s}\n",
                .{ connector.id, @errorName(err) },
            );
            return 1;
        };
        if (maybe_observation) |observation| {
            produced_observation = true;
            const recorded = try kernel.recordObservation(observation);
            std.debug.print(
                "connector `{s}` {s} an observation for `{s}`\n",
                .{ connector.id, if (recorded) "recorded" else "saw a duplicate delivery of", connector.capability },
            );
        }
    }
    if (!produced_observation) {
        std.debug.print(
            "every registered connector ran but none produced an observation for this `{s}` event\n",
            .{event_name},
        );
    }
    return 0;
}

/// Resolves the GitHub webhook secret, or null when none is configured.
/// A missing HOME is treated as "no credentials file", not an error, so
/// the environment variable still works in a bare container.
fn resolveWebhookSecret(alloc: std.mem.Allocator) !?[]u8 {
    const home = io_mod.getenv("HOME") orelse return null;
    return secrets.resolve(alloc, home, .github_webhook_secret);
}

fn readStdinAlloc(alloc: std.mem.Allocator, max_bytes: usize) ![]u8 {
    const io = io_mod.getIo();
    var read_buf: [8192]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &read_buf);
    return reader.interface.allocRemaining(alloc, std.Io.Limit.limited(max_bytes));
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
    var id_buf: [32]u8 = undefined;
    const label = id_mod.formatBuf(&id_buf, .task, id);
    switch (task.status) {
        .approval_required => std.debug.print(
            "CTO created self-extension {s} for `{s}`; a candidate is ready and requires approval.\n" ++
                "Run `fx cto approve {s}` to activate it, or `fx cto events` to review the audit trail.\n",
            .{ label, task.required_capability, label },
        ),
        .failed => std.debug.print(
            "CTO created self-extension {s} for `{s}`, but the worker run failed.\n" ++
                "Run `fx cto events` for detail; the task and any partial worktree were left in place.\n",
            .{ label, task.required_capability },
        ),
        else => std.debug.print(
            "CTO created self-extension {s} for `{s}` (status={s}).\n",
            .{ label, task.required_capability, @tagName(task.status) },
        ),
    }
    return 0;
}

fn runApprove(
    alloc: std.mem.Allocator,
    kernel: *kernel_mod.Kernel,
    args: []const [:0]const u8,
    repository_path: []const u8,
) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: fx cto approve <task-id>\n", .{});
        return 1;
    }
    const id = id_mod.parse(.task, args[1]) orelse {
        std.debug.print("fx cto approve: `{s}` is not a valid task id\n", .{args[1]});
        return 1;
    };
    const repo = try store.resolveAbsolute(alloc, repository_path);
    const outcome = kernel.approve(repo, id) catch |err| {
        var id_buf: [32]u8 = undefined;
        std.debug.print("fx cto approve: could not approve {s}: {s}\n", .{ id_mod.formatBuf(&id_buf, .task, id), @errorName(err) });
        return 1;
    };
    return reportActivation(id, outcome);
}

fn runActivate(
    alloc: std.mem.Allocator,
    kernel: *kernel_mod.Kernel,
    args: []const [:0]const u8,
    repository_path: []const u8,
) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: fx cto activate <task-id>\n", .{});
        return 1;
    }
    const id = id_mod.parse(.task, args[1]) orelse {
        std.debug.print("fx cto activate: `{s}` is not a valid task id\n", .{args[1]});
        return 1;
    };
    const repo = try store.resolveAbsolute(alloc, repository_path);
    const outcome = kernel.activate(repo, id) catch |err| {
        var id_buf: [32]u8 = undefined;
        std.debug.print("fx cto activate: could not activate {s}: {s}\n", .{ id_mod.formatBuf(&id_buf, .task, id), @errorName(err) });
        return 1;
    };
    return reportActivation(id, outcome);
}

fn reportActivation(id: u64, outcome: kernel_mod.Kernel.ActivationOutcome) u8 {
    var id_buf: [32]u8 = undefined;
    const label = id_mod.formatBuf(&id_buf, .task, id);
    switch (outcome) {
        .activated => |release| {
            std.debug.print(
                "Approved {s}. Release v{d} is built, tested, and active.\n" ++
                    "  commit:  {s}\n  path:    {s}\n" ++
                    "`.cto/current` now points at it; `fx cto rollback` reverts.\n",
                .{ label, release.version, release.commit, release.path },
            );
            return 0;
        },
        .health_failed => |reason| {
            std.debug.print(
                "{s} is approved, but the release did not activate: {s}\n" ++
                    "The capability is still a candidate because it is not live.\n" ++
                    "Fix the candidate and retry with `fx cto activate {s}`.\n",
                .{ label, reason, label },
            );
            return 1;
        },
    }
}

fn runRollback(kernel: *kernel_mod.Kernel) !u8 {
    const previous = kernel.rollback() catch |err| switch (err) {
        error.NoActiveRelease => {
            std.debug.print("fx cto rollback: no release is active yet\n", .{});
            return 1;
        },
        error.NoPreviousRelease => {
            std.debug.print("fx cto rollback: the active release is the first one; nothing to roll back to\n", .{});
            return 1;
        },
        else => return err,
    };
    std.debug.print("Rolled back to release v{d} ({s}).\n", .{ previous.version, previous.path });
    return 0;
}

/// Entry point for a thin human-channel bridge. The bridge only forwards
/// text; all authorization and state changes remain owned by this CLI.
fn runChannel(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel, args: []const [:0]const u8) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: fx cto channel \"/status\"\n", .{});
        return 1;
    }
    switch (channel.parse(args[1])) {
        .status => try printStatus(kernel),
        .goals => try printGoals(kernel),
        .runs => try printRuns(kernel),
        .decisions => try printDecisions(kernel),
        .approve => |id| {
            // Decision D5 (docs/CTO_ROADMAP.md): approving a self-modifying
            // candidate activates new code, and this bridge is designed to
            // be driven by transports authenticated only by something as
            // weak as a chat ID. The refusal lives here, at the boundary,
            // rather than in a future bot that would have to remember it.
            var id_buf: [32]u8 = undefined;
            const label = id_mod.formatBuf(&id_buf, .task, id);
            std.debug.print(
                "{s} needs approval from the local CLI: `fx cto approve {s}`\n" ++
                    "Approving a candidate activates self-modifying code, which is not\n" ++
                    "delegated to a remote channel.\n",
                .{ label, label },
            );
            return 1;
        },
        .interrupt => |id| return interruptRun(alloc, kernel, id),
        .invalid => |text| {
            std.debug.print("unsupported channel command: {s}\n", .{text});
            return 1;
        },
    }
    return 0;
}

fn runExplain(kernel: *kernel_mod.Kernel, args: []const [:0]const u8) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: fx cto explain <kind>-<id>  (e.g. task-3, run-12, release-1, goal-2)\n", .{});
        return 1;
    }
    const parsed = id_mod.parseAny(args[1]) orelse {
        std.debug.print(
            "fx cto explain: `{s}` is not a valid id — expected `<kind>-<id>` (task-3, run-12, release-1, or goal-2)\n",
            .{args[1]},
        );
        return 1;
    };
    try withStderr(views.renderExplain, .{ kernel, parsed.kind, parsed.id });
    return 0;
}

fn runInterrupt(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel, args: []const [:0]const u8) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: fx cto interrupt <run-id>\n", .{});
        return 1;
    }
    // Strict, unlike `approve`/`activate`/`review`: a task id and a run id
    // are both small integers starting at 1, so a bare integer here is
    // genuinely ambiguous rather than merely inconvenient (D7).
    const run_id = id_mod.parseStrict(.run, args[1]) orelse {
        std.debug.print(
            "fx cto interrupt: `{s}` is not a valid run id — use the `run-<id>` form (e.g. `run-12`), " ++
                "not a bare number: a task id and a run id are both small integers, and this command only " ++
                "ever means a run.\n",
            .{args[1]},
        );
        return 1;
    };
    return interruptRun(alloc, kernel, run_id);
}

/// Cancels a run dispatched out-of-process (`process_worker.zig`) by
/// writing an interrupt marker next to its pid file. The owning process's
/// supervision loop — not this CLI invocation — is what actually signals
/// the worker's process group; that keeps there being exactly one signaler
/// even when `interrupt` runs concurrently with the run it is cancelling.
///
/// A run dispatched in-process (today's CLI default, see docs/CTO_ROADMAP.md
/// D3) has no pid file to find: it blocks the single `fx cto request`
/// invocation that started it and cannot be reached from a second process
/// at all. That is reported honestly rather than claimed as done.
fn interruptRun(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel, run_id: u64) !u8 {
    var id_buf: [32]u8 = undefined;
    const label = id_mod.formatBuf(&id_buf, .run, run_id);
    const pid = process_worker.readPid(alloc, kernel.cto_root, run_id) catch |err| {
        std.debug.print("fx cto interrupt: could not check {s}: {s}\n", .{ label, @errorName(err) });
        return 1;
    };
    if (pid == null) {
        try kernel.recordInterruptRequest(run_id, "no out-of-process worker found for this run");
        std.debug.print(
            "no running out-of-process worker was found for {s}.\n" ++
                "It may have already finished, or it was dispatched in-process (the CLI default),\n" ++
                "which cannot be cancelled from a separate command.\n",
            .{label},
        );
        return 1;
    }
    const marker_path = try process_worker.interruptMarkerPath(alloc, kernel.cto_root, run_id);
    defer alloc.free(marker_path);
    io_mod.writeFileAtomic(alloc, marker_path, "") catch |err| {
        std.debug.print("fx cto interrupt: could not signal {s}: {s}\n", .{ label, @errorName(err) });
        return 1;
    };
    try kernel.recordInterruptRequest(run_id, "signaled");
    std.debug.print("requested cancellation of {s} (pid {d}); it will stop shortly.\n", .{ label, pid.? });
    return 0;
}

/// Reads `.cto/runs/<run-id>.log` (M4's `process_worker.zig`) directly.
/// Always CLI-direct, never proxied to a daemon: this is a plain file read
/// with no kernel state or locking involved, so a daemon has nothing to
/// mediate here.
fn runLogs(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel, args: []const [:0]const u8) !u8 {
    if (args.len < 2) {
        std.debug.print("usage: fx cto logs <run-id> [--tail N]\n", .{});
        return 1;
    }
    const run_id = id_mod.parseStrict(.run, args[1]) orelse {
        std.debug.print(
            "fx cto logs: `{s}` is not a valid run id — use the `run-<id>` form (e.g. `run-12`), " ++
                "not a bare number\n",
            .{args[1]},
        );
        return 1;
    };

    var tail_lines: ?usize = null;
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--tail")) {
            index += 1;
            if (index >= args.len) {
                std.debug.print("fx cto logs: --tail requires a value\n", .{});
                return 1;
            }
            tail_lines = std.fmt.parseInt(usize, args[index], 10) catch {
                std.debug.print("fx cto logs: `{s}` is not a valid --tail count\n", .{args[index]});
                return 1;
            };
        } else {
            std.debug.print("fx cto logs: unexpected argument `{s}`\n", .{args[index]});
            return 1;
        }
    }

    const log_path = try process_worker.logFilePath(alloc, kernel.cto_root, run_id);
    defer alloc.free(log_path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), log_path, .{}) catch |err| {
        var id_buf: [32]u8 = undefined;
        const label = id_mod.formatBuf(&id_buf, .run, run_id);
        switch (err) {
            error.FileNotFound => std.debug.print(
                "no log recorded for {s}: it may not have dispatched out-of-process, or hasn't finished yet\n",
                .{label},
            ),
            else => std.debug.print("fx cto logs: could not read {s}'s log: {s}\n", .{ label, @errorName(err) }),
        }
        return 1;
    };
    defer file.close(io_mod.getIo());
    const text = try io_mod.readFileToEnd(alloc, &file, 16 * 1024 * 1024);
    defer alloc.free(text);

    std.debug.print("{s}", .{if (tail_lines) |n| tailLines(text, n) else text});
    return 0;
}

/// Returns the last `n` lines of `text` (a suffix slice, no copy). A log
/// this size (M4 caps each stream at 64KB) is small enough that scanning
/// backward for newlines is simpler and plenty fast, versus counting
/// lines forward and remembering a rolling window.
fn tailLines(text: []const u8, n: usize) []const u8 {
    if (n == 0) return "";
    // A trailing newline terminates the last line rather than separating
    // it from a line after it; exclude it from the scan so "the last 1
    // line" of "a\nb\nc\n" is "c\n", not "" (the boundary crossed by that
    // very last byte).
    var search_end = text.len;
    if (search_end > 0 and text[search_end - 1] == '\n') search_end -= 1;

    var remaining = n;
    var i = search_end;
    while (i > 0) {
        i -= 1;
        if (text[i] == '\n') {
            remaining -= 1;
            if (remaining == 0) return text[i + 1 ..];
        }
    }
    return text;
}

fn printHelp() void {
    std.debug.print(
        \\fx cto - a CTO runtime layered on top of the fx coding harness
        \\
        \\Commands:
        \\  status                    Show kernel, worker, and capability summary
        \\  brief                     One-call situational summary: what needs you, what's running, what failed
        \\  explain <kind>-<id>       Full causal story for one task/run/release/goal
        \\  capabilities              List every known capability and its status
        \\  request "<objective>"     Ask CTO to pursue an outcome
        \\  tasks                     List tasks and their lifecycle status
        \\  goals                     List durable outcome goals
        \\  runs                      List worker execution attempts
        \\  decisions                 List durable policy decisions
        \\  channel "<command>"       Execute a normalized human-channel command
        \\  ingest <event> <id>       Admit and normalize a raw event body (stdin)
        \\  observations              List recorded observations
        \\  review <task-id>          Show the candidate extension diff
        \\  approve <task-id>         Approve and activate a candidate
        \\  activate <task-id>        Retry activation of an approved candidate
        \\  releases                  List versioned releases and the active one
        \\  rollback                  Point the active release at the previous version
        \\  interrupt <run-id>        Cancel an out-of-process worker run
        \\  logs <run-id> [--tail N]  Show a worker run's captured stdout/stderr
        \\  events [--since N]        Show the append-only audit journal (optionally only what's new)
        \\  daemon [--once]           Run the local control-plane daemon (foreground)
        \\  ctl '<json>'              Send one versioned control-protocol request
        \\  schema                    Machine-readable description of every entity/event kind
        \\
    , .{});
}

/// Renders `views.zig`'s output to stderr — the CLI's half of the
/// "one rendering, two destinations" split; `daemon.zig` renders the same
/// functions into a socket response buffer instead.
fn printStatus(kernel: *kernel_mod.Kernel) !void {
    try withStderr(views.renderStatus, .{kernel});
}

fn printBrief(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel) !void {
    try withStderr(views.renderBrief, .{ alloc, kernel });
}

fn printCapabilities(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel) !void {
    try withStderr(views.renderCapabilities, .{ alloc, kernel });
}

fn printTasks(kernel: *kernel_mod.Kernel) !void {
    try withStderr(views.renderTasks, .{kernel});
}

fn printGoals(kernel: *kernel_mod.Kernel) !void {
    try withStderr(views.renderGoals, .{kernel});
}

fn printRuns(kernel: *kernel_mod.Kernel) !void {
    try withStderr(views.renderRuns, .{kernel});
}

fn printReleases(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel) !void {
    try withStderr(views.renderReleases, .{ alloc, kernel });
}

fn printObservations(kernel: *kernel_mod.Kernel) !void {
    try withStderr(views.renderObservations, .{kernel});
}

fn printDecisions(kernel: *kernel_mod.Kernel) !void {
    try withStderr(views.renderDecisions, .{kernel});
}

fn printEvents(kernel: *kernel_mod.Kernel, since: u64) !void {
    try withStderr(views.renderEvents, .{ kernel, since });
}

/// Parses an optional `--since <sequence>` flag; `rest` is the command's
/// arguments after the command name itself. No flag means "everything"
/// (sequence 0, since real sequences start at 1).
fn parseSinceFlag(rest: []const [:0]const u8) !u64 {
    if (rest.len == 0) return 0;
    if (rest.len == 2 and std.mem.eql(u8, rest[0], "--since")) {
        return std.fmt.parseInt(u64, rest[1], 10) catch error.InvalidSinceValue;
    }
    return error.InvalidSinceFlag;
}

fn withStderr(comptime renderFn: anytype, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stderr().writer(io_mod.getIo(), &buf);
    try @call(.auto, renderFn, .{&file_writer.interface} ++ args);
    try file_writer.interface.flush();
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

test "tailLines returns the last n lines, or the whole text when there are fewer" {
    try std.testing.expectEqualStrings("c\n", tailLines("a\nb\nc\n", 1));
    try std.testing.expectEqualStrings("b\nc\n", tailLines("a\nb\nc\n", 2));
    try std.testing.expectEqualStrings("a\nb\nc\n", tailLines("a\nb\nc\n", 10));
    try std.testing.expectEqualStrings("", tailLines("a\nb\nc\n", 0));
    try std.testing.expectEqualStrings("no newline", tailLines("no newline", 3));
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
