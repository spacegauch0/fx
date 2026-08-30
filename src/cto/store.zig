//! Local-file persistence for `.cto/` state: capabilities.json, tasks.json,
//! and the append-only events.jsonl journal. Deliberately boring: whole
//! files are read and rewritten atomically rather than reaching for a
//! database or an event-sourcing framework, which is appropriate at this
//! scale (a handful of capabilities and tasks per repository).

const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const capability_mod = @import("capability.zig");
const task_mod = @import("task.zig");
const event_mod = @import("event.zig");
const goal_mod = @import("goal.zig");
const run_mod = @import("run.zig");
const observation_mod = @import("observation.zig");

pub const events_file_name = "events.jsonl";
pub const observations_file_name = "observations.jsonl";
pub const capabilities_file_name = "capabilities.json";
pub const tasks_file_name = "tasks.json";
pub const goals_file_name = "goals.json";
pub const runs_file_name = "runs.json";
pub const versions_dir_name = "versions";

/// Resolves `input` (which may be relative, e.g. the default ".cto") to an
/// absolute path so every persistence call can use fx's absolute-path-only
/// durable I/O helpers regardless of the caller's current directory.
pub fn resolveAbsolute(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(input)) return alloc.dupe(u8, input);
    const cwd = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(cwd);
    return std.fs.path.join(alloc, &.{ cwd, input });
}

pub fn ensureRoot(alloc: std.mem.Allocator, cto_root_abs: []const u8) !void {
    try io_mod.makeDirRecursive(cto_root_abs);
    const versions_dir = try pathIn(alloc, cto_root_abs, versions_dir_name);
    defer alloc.free(versions_dir);
    try io_mod.makeDirRecursive(versions_dir);
}

fn pathIn(alloc: std.mem.Allocator, cto_root_abs: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ cto_root_abs, name });
}

fn readFileIfExists(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &file, 16 * 1024 * 1024);
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| i,
        else => null,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

// -- goals.json and runs.json -------------------------------------------

pub fn loadGoals(alloc: std.mem.Allocator, cto_root_abs: []const u8) ![]goal_mod.Goal {
    const path = try pathIn(alloc, cto_root_abs, goals_file_name);
    defer alloc.free(path);
    const bytes = try readFileIfExists(alloc, path) orelse return &.{};
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |value| value.items,
        else => return &.{},
    };
    var goals: std.ArrayList(goal_mod.Goal) = .empty;
    errdefer goals.deinit(alloc);
    for (items) |item| {
        const obj = switch (item) {
            .object => |value| value,
            else => continue,
        };
        const id = jsonInt(obj, "id") orelse continue;
        const objective = jsonString(obj, "objective") orelse continue;
        const status = std.meta.stringToEnum(goal_mod.Status, jsonString(obj, "status") orelse "active") orelse .active;
        try goals.append(alloc, .{ .id = @intCast(id), .objective = try alloc.dupe(u8, objective), .status = status, .created_at_ms = jsonInt(obj, "created_at_ms") orelse 0 });
    }
    return goals.toOwnedSlice(alloc);
}

pub fn saveGoals(alloc: std.mem.Allocator, cto_root_abs: []const u8, goals: []const goal_mod.Goal) !void {
    const path = try pathIn(alloc, cto_root_abs, goals_file_name);
    defer alloc.free(path);
    const bytes = try std.json.Stringify.valueAlloc(alloc, goals, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    try io_mod.writeFileAtomic(alloc, path, bytes);
}

pub fn loadRuns(alloc: std.mem.Allocator, cto_root_abs: []const u8) ![]run_mod.Run {
    const path = try pathIn(alloc, cto_root_abs, runs_file_name);
    defer alloc.free(path);
    const bytes = try readFileIfExists(alloc, path) orelse return &.{};
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |value| value.items,
        else => return &.{},
    };
    var runs: std.ArrayList(run_mod.Run) = .empty;
    errdefer runs.deinit(alloc);
    for (items) |item| {
        const obj = switch (item) {
            .object => |value| value,
            else => continue,
        };
        const id = jsonInt(obj, "id") orelse continue;
        const task_id = jsonInt(obj, "task_id") orelse continue;
        const worker = jsonString(obj, "worker") orelse continue;
        const status = std.meta.stringToEnum(run_mod.Status, jsonString(obj, "status") orelse "started") orelse .started;
        try runs.append(alloc, .{ .id = @intCast(id), .task_id = @intCast(task_id), .worker = try alloc.dupe(u8, worker), .status = status, .started_at_ms = jsonInt(obj, "started_at_ms") orelse 0, .finished_at_ms = jsonInt(obj, "finished_at_ms") });
    }
    return runs.toOwnedSlice(alloc);
}

pub fn saveRuns(alloc: std.mem.Allocator, cto_root_abs: []const u8, runs: []const run_mod.Run) !void {
    const path = try pathIn(alloc, cto_root_abs, runs_file_name);
    defer alloc.free(path);
    const bytes = try std.json.Stringify.valueAlloc(alloc, runs, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    try io_mod.writeFileAtomic(alloc, path, bytes);
}

// -- capabilities.json -------------------------------------------------

const CapabilityRecord = struct {
    name: []const u8,
    status: []const u8,
    source: []const u8,
};

/// Loads persisted capabilities into `registry`. Returns `false` when no
/// capabilities.json exists yet, so the caller knows to bootstrap instead.
pub fn loadCapabilities(
    alloc: std.mem.Allocator,
    cto_root_abs: []const u8,
    registry: *capability_mod.Registry,
) !bool {
    const path = try pathIn(alloc, cto_root_abs, capabilities_file_name);
    defer alloc.free(path);
    const bytes = try readFileIfExists(alloc, path) orelse return false;
    defer alloc.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return true,
    };
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = jsonString(obj, "name") orelse continue;
        const status_str = jsonString(obj, "status") orelse continue;
        const source = jsonString(obj, "source") orelse "kernel";
        const status = std.meta.stringToEnum(capability_mod.Status, status_str) orelse .missing;
        try registry.put(
            try alloc.dupe(u8, name),
            status,
            try alloc.dupe(u8, source),
        );
    }
    return true;
}

pub fn saveCapabilities(
    alloc: std.mem.Allocator,
    cto_root_abs: []const u8,
    registry: *const capability_mod.Registry,
) !void {
    const sorted = try registry.sortedEntries(alloc);
    defer alloc.free(sorted);

    var records: std.ArrayList(CapabilityRecord) = .empty;
    defer records.deinit(alloc);
    for (sorted) |capability| {
        try records.append(alloc, .{
            .name = capability.name,
            .status = @tagName(capability.status),
            .source = capability.source,
        });
    }

    const path = try pathIn(alloc, cto_root_abs, capabilities_file_name);
    defer alloc.free(path);
    const bytes = try std.json.Stringify.valueAlloc(alloc, records.items, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    try io_mod.writeFileAtomic(alloc, path, bytes);
}

// -- tasks.json ----------------------------------------------------------

const TaskRecord = struct {
    id: u64,
    objective: []const u8,
    assignee: []const u8,
    required_capability: []const u8,
    status: []const u8,
    candidate_ref: ?[]const u8 = null,
    worktree_path: ?[]const u8 = null,
    build_ok: bool = false,
    test_ok: bool = false,
    created_at_ms: i64 = 0,
};

pub fn loadTasks(alloc: std.mem.Allocator, cto_root_abs: []const u8) ![]task_mod.Task {
    const path = try pathIn(alloc, cto_root_abs, tasks_file_name);
    defer alloc.free(path);
    const bytes = try readFileIfExists(alloc, path) orelse return &.{};
    defer alloc.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return &.{},
    };

    var tasks: std.ArrayList(task_mod.Task) = .empty;
    errdefer tasks.deinit(alloc);
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const id = jsonInt(obj, "id") orelse continue;
        const objective = jsonString(obj, "objective") orelse continue;
        const assignee = jsonString(obj, "assignee") orelse "cto-dev";
        const required_capability = jsonString(obj, "required_capability") orelse continue;
        const status_str = jsonString(obj, "status") orelse "created";
        const status = std.meta.stringToEnum(task_mod.TaskStatus, status_str) orelse .created;
        const candidate_ref = if (jsonString(obj, "candidate_ref")) |s| try alloc.dupe(u8, s) else null;
        const worktree_path = if (jsonString(obj, "worktree_path")) |s| try alloc.dupe(u8, s) else null;

        try tasks.append(alloc, .{
            .id = @intCast(id),
            .objective = try alloc.dupe(u8, objective),
            .assignee = try alloc.dupe(u8, assignee),
            .required_capability = try alloc.dupe(u8, required_capability),
            .status = status,
            .candidate_ref = candidate_ref,
            .worktree_path = worktree_path,
            .build_ok = jsonBool(obj, "build_ok") orelse false,
            .test_ok = jsonBool(obj, "test_ok") orelse false,
            .created_at_ms = jsonInt(obj, "created_at_ms") orelse 0,
        });
    }
    return tasks.toOwnedSlice(alloc);
}

pub fn saveTasks(alloc: std.mem.Allocator, cto_root_abs: []const u8, tasks: []const task_mod.Task) !void {
    var records: std.ArrayList(TaskRecord) = .empty;
    defer records.deinit(alloc);
    for (tasks) |task| {
        try records.append(alloc, .{
            .id = task.id,
            .objective = task.objective,
            .assignee = task.assignee,
            .required_capability = task.required_capability,
            .status = @tagName(task.status),
            .candidate_ref = task.candidate_ref,
            .worktree_path = task.worktree_path,
            .build_ok = task.build_ok,
            .test_ok = task.test_ok,
            .created_at_ms = task.created_at_ms,
        });
    }

    const path = try pathIn(alloc, cto_root_abs, tasks_file_name);
    defer alloc.free(path);
    const bytes = try std.json.Stringify.valueAlloc(alloc, records.items, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    try io_mod.writeFileAtomic(alloc, path, bytes);
}

// -- events.jsonl ----------------------------------------------------------

const EventRecord = struct {
    sequence: u64,
    kind: []const u8,
    subject: []const u8,
    detail: []const u8,
    timestamp_ms: i64,
};

pub fn loadEvents(alloc: std.mem.Allocator, cto_root_abs: []const u8) ![]event_mod.Event {
    const path = try pathIn(alloc, cto_root_abs, events_file_name);
    defer alloc.free(path);
    const bytes = try readFileIfExists(alloc, path) orelse return &.{};
    defer alloc.free(bytes);

    var events: std.ArrayList(event_mod.Event) = .empty;
    errdefer events.deinit(alloc);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const kind_str = jsonString(obj, "kind") orelse continue;
        const kind = std.meta.stringToEnum(event_mod.EventKind, kind_str) orelse continue;
        const sequence = jsonInt(obj, "sequence") orelse continue;

        try events.append(alloc, .{
            .sequence = @intCast(sequence),
            .kind = kind,
            .subject = try alloc.dupe(u8, jsonString(obj, "subject") orelse ""),
            .detail = try alloc.dupe(u8, jsonString(obj, "detail") orelse ""),
            .timestamp_ms = jsonInt(obj, "timestamp_ms") orelse 0,
        });
    }
    return events.toOwnedSlice(alloc);
}

/// Appends one event as a single JSON line. Read-modify-write on the whole
/// file, which is simple and correct at PoC scale; a high-volume journal
/// would want a real append-mode file handle instead.
pub fn appendEvent(alloc: std.mem.Allocator, cto_root_abs: []const u8, event: event_mod.Event) !void {
    const path = try pathIn(alloc, cto_root_abs, events_file_name);
    defer alloc.free(path);
    const existing = try readFileIfExists(alloc, path);
    defer if (existing) |bytes| alloc.free(bytes);

    const record = EventRecord{
        .sequence = event.sequence,
        .kind = @tagName(event.kind),
        .subject = event.subject,
        .detail = event.detail,
        .timestamp_ms = event.timestamp_ms,
    };
    const line = try std.json.Stringify.valueAlloc(alloc, record, .{});
    defer alloc.free(line);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);
    if (existing) |bytes| try buffer.appendSlice(alloc, bytes);
    try buffer.appendSlice(alloc, line);
    try buffer.append(alloc, '\n');

    try io_mod.writeFileAtomic(alloc, path, buffer.items);
}

// -- observations.jsonl ------------------------------------------------

/// Flat, single-variant-per-line record. `kind` selects which of the
/// `pull_request_merged_*` fields are meaningful; a new observation kind
/// gets its own optional field group here rather than a nested JSON
/// object, matching how every other record in this file stays flat.
const ObservationRecord = struct {
    kind: []const u8,
    occurred_at_ms: i64,
    provenance_provider: []const u8,
    provenance_delivery_id: []const u8,
    provenance_repository: []const u8,
    provenance_url: []const u8,
    pull_request_merged_number: u64 = 0,
    pull_request_merged_title: []const u8 = "",
    pull_request_merged_author: []const u8 = "",
    pull_request_merged_merged_by: []const u8 = "",
    pull_request_merged_head_sha: []const u8 = "",
    pull_request_merged_base_branch: []const u8 = "",
};

fn observationToRecord(observation: observation_mod.Observation) ObservationRecord {
    var record = ObservationRecord{
        .kind = @tagName(observation.kind()),
        .occurred_at_ms = observation.occurred_at_ms,
        .provenance_provider = observation.provenance.provider,
        .provenance_delivery_id = observation.provenance.delivery_id,
        .provenance_repository = observation.provenance.repository,
        .provenance_url = observation.provenance.url,
    };
    switch (observation.payload) {
        .pull_request_merged => |value| {
            record.pull_request_merged_number = value.number;
            record.pull_request_merged_title = value.title;
            record.pull_request_merged_author = value.author;
            record.pull_request_merged_merged_by = value.merged_by;
            record.pull_request_merged_head_sha = value.head_sha;
            record.pull_request_merged_base_branch = value.base_branch;
        },
    }
    return record;
}

fn recordToObservation(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !?observation_mod.Observation {
    const kind_str = jsonString(obj, "kind") orelse return null;
    const kind = std.meta.stringToEnum(observation_mod.Kind, kind_str) orelse return null;
    const provenance = observation_mod.Provenance{
        .provider = try alloc.dupe(u8, jsonString(obj, "provenance_provider") orelse ""),
        .delivery_id = try alloc.dupe(u8, jsonString(obj, "provenance_delivery_id") orelse ""),
        .repository = try alloc.dupe(u8, jsonString(obj, "provenance_repository") orelse ""),
        .url = try alloc.dupe(u8, jsonString(obj, "provenance_url") orelse ""),
    };
    const payload: @FieldType(observation_mod.Observation, "payload") = switch (kind) {
        .pull_request_merged => .{ .pull_request_merged = .{
            .number = @intCast(jsonInt(obj, "pull_request_merged_number") orelse 0),
            .title = try alloc.dupe(u8, jsonString(obj, "pull_request_merged_title") orelse ""),
            .author = try alloc.dupe(u8, jsonString(obj, "pull_request_merged_author") orelse ""),
            .merged_by = try alloc.dupe(u8, jsonString(obj, "pull_request_merged_merged_by") orelse ""),
            .head_sha = try alloc.dupe(u8, jsonString(obj, "pull_request_merged_head_sha") orelse ""),
            .base_branch = try alloc.dupe(u8, jsonString(obj, "pull_request_merged_base_branch") orelse ""),
        } },
    };
    return .{
        .occurred_at_ms = jsonInt(obj, "occurred_at_ms") orelse 0,
        .provenance = provenance,
        .payload = payload,
    };
}

pub fn loadObservations(alloc: std.mem.Allocator, cto_root_abs: []const u8) ![]observation_mod.Observation {
    const path = try pathIn(alloc, cto_root_abs, observations_file_name);
    defer alloc.free(path);
    const bytes = try readFileIfExists(alloc, path) orelse return &.{};
    defer alloc.free(bytes);

    var observations: std.ArrayList(observation_mod.Observation) = .empty;
    errdefer observations.deinit(alloc);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const observation = (try recordToObservation(alloc, obj)) orelse continue;
        try observations.append(alloc, observation);
    }
    return observations.toOwnedSlice(alloc);
}

/// Appends one observation as a single JSON line. The caller is
/// responsible for deduplicating by (provider, delivery_id) first —
/// this function only ever appends.
pub fn appendObservation(alloc: std.mem.Allocator, cto_root_abs: []const u8, observation: observation_mod.Observation) !void {
    const path = try pathIn(alloc, cto_root_abs, observations_file_name);
    defer alloc.free(path);
    const existing = try readFileIfExists(alloc, path);
    defer if (existing) |bytes| alloc.free(bytes);

    const record = observationToRecord(observation);
    const line = try std.json.Stringify.valueAlloc(alloc, record, .{});
    defer alloc.free(line);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);
    if (existing) |bytes| try buffer.appendSlice(alloc, bytes);
    try buffer.appendSlice(alloc, line);
    try buffer.append(alloc, '\n');

    try io_mod.writeFileAtomic(alloc, path, buffer.items);
}

// -- versions/ -------------------------------------------------------------

pub const VersionRecord = struct {
    task_id: u64,
    capability: []const u8,
    candidate_ref: []const u8,
    worktree_path: []const u8,
    build_ok: bool,
    test_ok: bool,
    summary: []const u8,
    created_at_ms: i64,
    approved: bool = false,
    approved_at_ms: ?i64 = null,
};

pub fn saveVersionRecord(alloc: std.mem.Allocator, cto_root_abs: []const u8, record: VersionRecord) !void {
    const versions_dir = try pathIn(alloc, cto_root_abs, versions_dir_name);
    defer alloc.free(versions_dir);
    const file_name = try std.fmt.allocPrint(alloc, "task-{d}.json", .{record.task_id});
    defer alloc.free(file_name);
    const path = try std.fs.path.join(alloc, &.{ versions_dir, file_name });
    defer alloc.free(path);

    const bytes = try std.json.Stringify.valueAlloc(alloc, record, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    try io_mod.writeFileAtomic(alloc, path, bytes);
}

test "capabilities round-trip through disk with a stable sort order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });
    try ensureRoot(alloc, cto_root);

    var registry = capability_mod.Registry.init(alloc);
    try registry.bootstrap();
    try saveCapabilities(alloc, cto_root, &registry);

    var loaded = capability_mod.Registry.init(alloc);
    const existed = try loadCapabilities(alloc, cto_root, &loaded);
    try std.testing.expect(existed);
    try std.testing.expect(loaded.isAvailable("filesystem.read"));
    try std.testing.expect(!loaded.isAvailable("github.pull_request.merged"));
}

test "loadCapabilities reports missing file so the caller bootstraps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");

    var registry = capability_mod.Registry.init(alloc);
    const existed = try loadCapabilities(alloc, root, &registry);
    try std.testing.expect(!existed);
}

test "tasks round-trip preserves optional candidate and worktree fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });
    try ensureRoot(alloc, cto_root);

    const tasks = [_]task_mod.Task{.{
        .id = 1,
        .objective = "watch merged pull requests",
        .assignee = "cto-dev",
        .required_capability = "github.pull_request.merged",
        .status = .approval_required,
        .candidate_ref = "candidate/task-1",
        .worktree_path = "/repo/.cto/worktrees/task-1",
        .build_ok = true,
        .test_ok = true,
        .created_at_ms = 42,
    }};
    try saveTasks(alloc, cto_root, &tasks);

    const loaded = try loadTasks(alloc, cto_root);
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqual(@as(u64, 1), loaded[0].id);
    try std.testing.expectEqualStrings("watch merged pull requests", loaded[0].objective);
    try std.testing.expectEqual(task_mod.TaskStatus.approval_required, loaded[0].status);
    try std.testing.expectEqualStrings("candidate/task-1", loaded[0].candidate_ref.?);
    try std.testing.expectEqualStrings("/repo/.cto/worktrees/task-1", loaded[0].worktree_path.?);
    try std.testing.expect(loaded[0].build_ok);
    try std.testing.expect(loaded[0].test_ok);
}

test "events append incrementally and reload in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const cto_root = try std.fs.path.join(alloc, &.{ root, ".cto" });
    try ensureRoot(alloc, cto_root);

    try appendEvent(alloc, cto_root, event_mod.Event.init(1, .human_requested, "human", "watch merged pull requests"));
    try appendEvent(alloc, cto_root, event_mod.Event.init(2, .capability_missing, "github.pull_request.merged", "watch merged pull requests"));

    const events = try loadEvents(alloc, cto_root);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(u64, 1), events[0].sequence);
    try std.testing.expectEqual(event_mod.EventKind.human_requested, events[0].kind);
    try std.testing.expectEqual(@as(u64, 2), events[1].sequence);
    try std.testing.expectEqual(event_mod.EventKind.capability_missing, events[1].kind);
    try std.testing.expectEqualStrings("github.pull_request.merged", events[1].subject);
}
