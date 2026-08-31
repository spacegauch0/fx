const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const control_protocol = @import("control_protocol.zig");
const git = @import("git.zig");
const kernel_mod = @import("kernel.zig");
const process_worker_mod = @import("process_worker.zig");
const runtime_mod = @import("runtime.zig");
const store = @import("store.zig");
const views = @import("views.zig");
const writer_lock = @import("writer_lock.zig");

const max_request_bytes = 64 * 1024;

pub const Config = struct {
    cto_root: []const u8,
    repository_path: []const u8,
    fx_binary_path: []const u8,
    /// Serve exactly one connection then return. Used by tests and by
    /// `fx cto daemon --once` for a scripted smoke check; a real deployment
    /// never sets this.
    once: bool = false,
};

/// Runs the daemon in the foreground: acquires the workspace writer lock
/// for as long as the daemon lives (D4 — the daemon is the single writer
/// for its whole lifetime, not per-request), binds the control socket
/// (D2 — a Unix socket under `socketDir()`, a private `0700` directory;
/// authentication is that filesystem permission), and serves requests
/// until the process is killed (or, in `--once` mode, until the first
/// request completes).
pub fn run(gpa: std.mem.Allocator, config: Config) !void {
    if (comptime builtin.os.tag == .windows) return error.UnixSocketsUnsupported;
    if (!std.Io.net.has_unix_sockets) return error.UnixSocketsUnsupported;

    var writer_guard = writer_lock.acquire(gpa, config.cto_root, 250) catch |err| switch (err) {
        error.LockBusy => {
            std.debug.print("fx cto daemon: another writer already owns {s}\n", .{config.cto_root});
            return err;
        },
        else => return err,
    };
    defer writer_guard.release();

    const socket_path = try socketPath(gpa, config.cto_root);
    defer gpa.free(socket_path);

    const io = io_mod.getIo();
    const dir = try socketDir(gpa);
    defer gpa.free(dir);
    try ensurePrivateSocketDir(dir);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    }

    std.debug.print("fx cto daemon: ready ({s})\n", .{socket_path});
    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);
        handleConnection(gpa, config, &stream) catch |err| {
            std.debug.print("fx cto daemon: request failed: {s}\n", .{@errorName(err)});
        };
        if (config.once) return;
    }
}

fn handleConnection(gpa: std.mem.Allocator, config: Config, stream: *std.Io.net.Stream) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = io_mod.getIo();

    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const raw_line = reader.interface.takeDelimiterExclusive('\n') catch |err| return err;
    if (raw_line.len > max_request_bytes) return error.RequestTooLarge;

    const parsed = control_protocol.decodeRequest(alloc, raw_line) catch |err| {
        return writeResponse(stream, alloc, .{
            .id = "invalid",
            .ok = false,
            .exit_code = 2,
            .output = "",
            .error_message = @errorName(err),
        });
    };
    defer parsed.deinit();
    const request = parsed.value;

    if (request.command == .health or request.command == .ready) {
        return writeResponse(stream, alloc, .{
            .id = request.id,
            .ok = true,
            .exit_code = 0,
            .output = if (request.command == .health) "healthy\n" else "ready\n",
        });
    }

    const outcome = execute(alloc, config, request) catch |err| {
        return writeResponse(stream, alloc, .{
            .id = request.id,
            .ok = false,
            .exit_code = 1,
            .output = "",
            .error_message = @errorName(err),
        });
    };
    return writeResponse(stream, alloc, .{
        .id = request.id,
        .ok = outcome.exit_code == 0,
        .exit_code = outcome.exit_code,
        .output = outcome.text,
    });
}

const Outcome = struct { exit_code: u8, text: []const u8 };

fn execute(alloc: std.mem.Allocator, config: Config, request: control_protocol.Request) !Outcome {
    const repository_path = try store.resolveAbsolute(alloc, config.repository_path);
    var kernel = try kernel_mod.Kernel.init(alloc, config.cto_root);
    defer kernel.deinit();

    switch (request.command) {
        .health, .ready => unreachable, // handled in handleConnection before execute() is ever called
        .ingest => return .{
            .exit_code = 2,
            .text = "ingest reads a body from stdin and is CLI/direct-mode only; run `fx cto ingest` directly.\n",
        },
        .request => return executeRequest(alloc, config, repository_path, &kernel, request.argument),
        .approve => return executeActivation(alloc, repository_path, &kernel, request.argument, .approve),
        .activate => return executeActivation(alloc, repository_path, &kernel, request.argument, .activate),
        .rollback => return executeRollback(alloc, &kernel),
        .interrupt => return executeInterrupt(alloc, &kernel, request.argument),
        .review => return executeReview(alloc, &kernel, request.argument),
        else => return executeReadView(alloc, &kernel, request.command),
    }
}

fn executeRequest(
    alloc: std.mem.Allocator,
    config: Config,
    repository_path: []const u8,
    kernel: *kernel_mod.Kernel,
    argument: ?[]const u8,
) !Outcome {
    const objective = argument orelse return .{ .exit_code = 2, .text = "request requires an objective argument\n" };
    var process_worker: process_worker_mod.ProcessWorker = .{
        .argv = &.{ config.fx_binary_path, "ask", "--yolo", "--no-save" },
    };
    var runtime = runtime_mod.Runtime.initWithWorker(alloc, kernel, repository_path, process_worker.asWorker());
    const task_id = try runtime.request(objective);
    const id = task_id orelse return .{
        .exit_code = 0,
        .text = "request accepted; no missing capability was detected\n",
    };
    const task = kernel.findTask(id) orelse return error.TaskNotFound;
    return .{
        .exit_code = if (task.status == .failed) 1 else 0,
        .text = try std.fmt.allocPrint(
            alloc,
            "task #{d} [{s}] {s}\n",
            .{ id, @tagName(task.status), task.required_capability },
        ),
    };
}

const ActivationVerb = enum { approve, activate };

fn executeActivation(
    alloc: std.mem.Allocator,
    repository_path: []const u8,
    kernel: *kernel_mod.Kernel,
    argument: ?[]const u8,
    verb: ActivationVerb,
) !Outcome {
    const id_text = argument orelse return .{ .exit_code = 2, .text = "a task id argument is required\n" };
    const id = std.fmt.parseInt(u64, id_text, 10) catch return .{ .exit_code = 2, .text = "invalid task id\n" };
    const outcome = switch (verb) {
        .approve => kernel.approve(repository_path, id),
        .activate => kernel.activate(repository_path, id),
    } catch |err| return .{
        .exit_code = 1,
        .text = try std.fmt.allocPrint(alloc, "could not activate task #{d}: {s}\n", .{ id, @errorName(err) }),
    };
    return switch (outcome) {
        .activated => |release| .{
            .exit_code = 0,
            .text = try std.fmt.allocPrint(
                alloc,
                "release v{d} is built, tested, and active (commit {s})\n",
                .{ release.version, release.commit },
            ),
        },
        .health_failed => |reason| .{
            .exit_code = 1,
            .text = try std.fmt.allocPrint(alloc, "approved but not live: {s}\n", .{reason}),
        },
    };
}

fn executeRollback(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel) !Outcome {
    const previous = kernel.rollback() catch |err| return .{
        .exit_code = 1,
        .text = try std.fmt.allocPrint(alloc, "rollback failed: {s}\n", .{@errorName(err)}),
    };
    return .{
        .exit_code = 0,
        .text = try std.fmt.allocPrint(alloc, "rolled back to release v{d} ({s})\n", .{ previous.version, previous.path }),
    };
}

fn executeInterrupt(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel, argument: ?[]const u8) !Outcome {
    const id_text = argument orelse return .{ .exit_code = 2, .text = "interrupt requires a run id\n" };
    const run_id = std.fmt.parseInt(u64, id_text, 10) catch return .{ .exit_code = 2, .text = "invalid run id\n" };
    const pid = try process_worker_mod.readPid(alloc, kernel.cto_root, run_id);
    if (pid == null) {
        try kernel.recordInterruptRequest(run_id, "no out-of-process worker found for this run");
        return .{ .exit_code = 1, .text = "no running out-of-process worker was found for that run\n" };
    }
    const marker = try process_worker_mod.interruptMarkerPath(alloc, kernel.cto_root, run_id);
    try io_mod.writeFileAtomic(alloc, marker, "");
    try kernel.recordInterruptRequest(run_id, "signaled via control socket");
    return .{ .exit_code = 0, .text = try std.fmt.allocPrint(alloc, "interrupt requested for run #{d}\n", .{run_id}) };
}

fn executeReview(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel, argument: ?[]const u8) !Outcome {
    const id_text = argument orelse return .{ .exit_code = 2, .text = "review requires a task id\n" };
    const id = std.fmt.parseInt(u64, id_text, 10) catch return .{ .exit_code = 2, .text = "invalid task id\n" };
    const task = kernel.findTask(id) orelse return .{ .exit_code = 1, .text = "task not found\n" };
    const worktree_path = task.worktree_path orelse return .{ .exit_code = 1, .text = "task has no candidate worktree\n" };
    const diff = try git.extensionDiff(alloc, worktree_path);
    return .{ .exit_code = 0, .text = if (diff.len == 0) "no extension changes\n" else diff };
}

fn executeReadView(alloc: std.mem.Allocator, kernel: *kernel_mod.Kernel, command: control_protocol.Command) !Outcome {
    var accumulating = std.Io.Writer.Allocating.init(alloc);
    defer accumulating.deinit();
    switch (command) {
        .status => try views.renderStatus(&accumulating.writer, kernel),
        .capabilities => try views.renderCapabilities(&accumulating.writer, alloc, kernel),
        .tasks => try views.renderTasks(&accumulating.writer, kernel),
        .goals => try views.renderGoals(&accumulating.writer, kernel),
        .runs => try views.renderRuns(&accumulating.writer, kernel),
        .decisions => try views.renderDecisions(&accumulating.writer, kernel),
        .observations => try views.renderObservations(&accumulating.writer, kernel),
        .events => try views.renderEvents(&accumulating.writer, kernel),
        .releases => try views.renderReleases(&accumulating.writer, alloc, kernel),
        else => unreachable, // every remaining Command variant is handled in execute() before reaching here
    }
    return .{ .exit_code = 0, .text = try alloc.dupe(u8, accumulating.writer.buffered()) };
}

fn writeResponse(stream: *std.Io.net.Stream, alloc: std.mem.Allocator, response: control_protocol.Response) !void {
    const encoded = try control_protocol.encodeResponse(alloc, response);
    var buffer: [8192]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.writeAll(encoded);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

/// Directory the control socket lives in: `$XDG_RUNTIME_DIR/fx-cto/`,
/// falling back to `~/.cache/fx/cto/` (D2). Deliberately *not* inside
/// `.cto/` itself: `sockaddr_un.sun_path` is capped at
/// `std.Io.net.UnixAddress.max_len` (108 bytes on Linux), and a project
/// checked out several directories deep — completely ordinary for a CI
/// runner or a sandboxed dev environment — routinely blows that budget on
/// its own, before any socket filename is even appended. A short,
/// XDG-standard rendezvous directory keeps the path budget spent on
/// something that doesn't grow with the workspace's location.
///
/// Pure given its inputs, unlike a version that calls `io_mod.getenv`
/// directly: `io_mod`'s environ is process-global mutable state that only
/// a real `cto_main.run()` invocation populates (via `setEnvironBlock`),
/// so a function that read it internally could not be unit-tested without
/// either depending on test execution order or reaching into another
/// module's private state. `socketDir`/`socketPath` below resolve the
/// environment once, at the real entry points, and pass it in.
fn socketDirFor(alloc: std.mem.Allocator, xdg_runtime_dir: ?[]const u8, home: ?[]const u8) ![]u8 {
    if (xdg_runtime_dir) |dir| {
        if (dir.len > 0) return std.fs.path.join(alloc, &.{ dir, "fx-cto" });
    }
    const resolved_home = home orelse return error.NoHomeDirectory;
    return std.fs.path.join(alloc, &.{ resolved_home, ".cache", "fx", "cto" });
}

fn socketDir(alloc: std.mem.Allocator) ![]u8 {
    return socketDirFor(alloc, io_mod.getenv("XDG_RUNTIME_DIR"), io_mod.getenv("HOME"));
}

fn socketPathFor(
    alloc: std.mem.Allocator,
    cto_root: []const u8,
    xdg_runtime_dir: ?[]const u8,
    home: ?[]const u8,
) ![]u8 {
    const root = try store.resolveAbsolute(alloc, cto_root);
    defer alloc.free(root);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root, &digest, .{});
    var hex_buf: [16]u8 = undefined;
    const hash_hex = hexPrefix(&hex_buf, digest[0..8]);

    const dir = try socketDirFor(alloc, xdg_runtime_dir, home);
    defer alloc.free(dir);
    var name_buf: [24]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}.sock", .{hash_hex});
    return std.fs.path.join(alloc, &.{ dir, name });
}

/// Absolute path to the control socket for a given `.cto` root. Shared by
/// the daemon (bind) and the control client (connect) so the two can never
/// disagree about where it lives. Multiple workspaces share `socketDir`,
/// so the filename is a short hash of the workspace's absolute `.cto`
/// root rather than something workspace-path-shaped, keeping the whole
/// path both short and unique per workspace.
pub fn socketPath(alloc: std.mem.Allocator, cto_root: []const u8) ![]u8 {
    return socketPathFor(alloc, cto_root, io_mod.getenv("XDG_RUNTIME_DIR"), io_mod.getenv("HOME"));
}

/// Creates `socketDir()` if needed and forces it to `0700`: D2's whole
/// authentication argument ("authentication *is* the filesystem
/// permission") depends on this, so a failure to set the mode is
/// propagated rather than swallowed — better a daemon that refuses to
/// start than one listening in a directory anyone on the box can read.
fn ensurePrivateSocketDir(dir: []const u8) !void {
    const io = io_mod.getIo();
    try io_mod.makeDirRecursive(dir);
    // `.iterate = true` matters here, not just for symmetry with
    // `io_mod`'s own verified-dir helpers: a directory opened without it
    // can come back as a Linux `O_PATH` descriptor, and `fchmod`-family
    // operations reject those with `EBADF`, which this Io implementation
    // treats as a programmer-bug panic rather than a recoverable error.
    var handle = try std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true, .follow_symlinks = false });
    defer handle.close(io);
    try handle.setPermissions(io, std.Io.File.Permissions.fromMode(0o700));
}

fn hexPrefix(buf: []u8, bytes: []const u8) []const u8 {
    const charset = "0123456789abcdef";
    var i: usize = 0;
    while (i < bytes.len and i * 2 + 1 < buf.len) : (i += 1) {
        buf[i * 2] = charset[bytes[i] >> 4];
        buf[i * 2 + 1] = charset[bytes[i] & 0xF];
    }
    return buf[0 .. i * 2];
}

test "socketPath is stable, short, and distinct per workspace" {
    // Exercises the pure `socketPathFor` directly with synthetic
    // XDG_RUNTIME_DIR/HOME values rather than depending on `io_mod.getenv`,
    // whose backing state is only populated by a real `cto_main.run()`
    // invocation (or by a test that explicitly sets it up, as the
    // real-socket test below does) — a plain unit test must not depend on
    // that having happened already, which is a question of *test
    // execution order*, not of anything this function does.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });
    defer alloc.free(cto_root);
    const other_cto_root = try std.fs.path.join(alloc, &.{ root, "elsewhere", ".cto" });
    defer alloc.free(other_cto_root);

    const first = try socketPathFor(alloc, cto_root, null, "/synthetic/home");
    defer alloc.free(first);
    const second = try socketPathFor(alloc, cto_root, null, "/synthetic/home");
    defer alloc.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(first.len <= std.Io.net.UnixAddress.max_len);
    try std.testing.expect(std.mem.endsWith(u8, first, ".sock"));
    try std.testing.expect(std.mem.indexOf(u8, first, "/.cto/") == null);

    const other = try socketPathFor(alloc, other_cto_root, null, "/synthetic/home");
    defer alloc.free(other);
    try std.testing.expect(!std.mem.eql(u8, first, other));

    try std.testing.expectError(error.NoHomeDirectory, socketPathFor(alloc, cto_root, null, null));

    const with_runtime_dir = try socketPathFor(alloc, cto_root, "/run/user/1000", "/synthetic/home");
    defer alloc.free(with_runtime_dir);
    try std.testing.expect(std.mem.startsWith(u8, with_runtime_dir, "/run/user/1000/fx-cto/"));
}

test "the daemon answers a health probe over the real socket and releases its lock on exit" {
    // `run()` resolves the real socket directory via `io_mod.getenv`,
    // which — unlike `socketPathFor` above — is production code and
    // rightly depends on it. That backing state is process-global and
    // only a real `cto_main.run()` invocation populates it, so this test
    // populates it itself with the real environment rather than relying
    // on some other test file having already done so as a side effect
    // (which is what let this exact test pass under `zig build test`'s
    // full suite while failing under the new, smaller `test-cto` binary
    // — a real, if quiet, test-isolation bug this milestone's own faster
    // build step caught).
    io_mod.setRawEnviron(std.c.environ);

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });
    defer alloc.free(cto_root);

    const config: Config = .{
        .cto_root = cto_root,
        .repository_path = root,
        .fx_binary_path = "/bin/true",
        .once = true,
    };

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn go(cfg: Config) void {
            run(std.heap.page_allocator, cfg) catch {};
        }
    }.go, .{config});

    const control_client = @import("control_client.zig");
    var connected = false;
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        if (control_client.daemonAvailable(alloc, cto_root)) {
            connected = true;
            break;
        }
        io_mod.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(connected);
    server_thread.join();

    // The daemon released its writer lock on exit, so a direct acquire
    // (what the CLI does for a mutating command with no daemon running)
    // must succeed rather than finding it still held.
    var guard = try writer_lock.acquire(alloc, cto_root, 50);
    guard.release();
}
