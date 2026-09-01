//! `fx cto schema`: a JSON description of every entity's fields, every
//! event kind, and every action this system understands — generated via
//! Zig's own reflection (`@typeInfo`) over the real types `store.zig`
//! persists, not hand-maintained prose that can silently drift from them.
//!
//! This is D7's "world model" layer: read once (`fx cto schema`), a
//! fresh agent session knows this system's shape without reading any
//! `.zig` source file directly — the thing every session that built this
//! project had to do before this existed.

const std = @import("std");
const action_mod = @import("action.zig");
const event_mod = @import("event.zig");
const goal_mod = @import("goal.zig");
const release_mod = @import("release.zig");
const run_mod = @import("run.zig");
const task_mod = @import("task.zig");

pub fn render(writer: *std.Io.Writer) !void {
    try writer.print("{{\n  \"entities\": {{\n", .{});
    try renderEntity(writer, "task", task_mod.Task, true);
    try renderEntity(writer, "run", run_mod.Run, true);
    try renderEntity(writer, "release", release_mod.Release, true);
    try renderEntity(writer, "goal", goal_mod.Goal, false);
    try writer.print("  }},\n", .{});

    try renderEnumArray(writer, "  \"event_kinds\": ", event_mod.EventKind, true);
    try renderEnumArray(writer, "  \"actions\": ", action_mod.Action, true);
    try renderEnumArray(writer, "  \"task_statuses\": ", task_mod.TaskStatus, true);
    try renderEnumArray(writer, "  \"run_statuses\": ", run_mod.Status, true);
    try renderEnumArray(writer, "  \"goal_statuses\": ", goal_mod.Status, false);
    try writer.print("}}\n", .{});
}

fn renderEntity(writer: *std.Io.Writer, comptime name: []const u8, comptime T: type, comptime trailing_comma: bool) !void {
    try writer.print("    \"{s}\": {{\"id_prefix\": \"{s}\", \"fields\": {{", .{ name, name });
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (i > 0) try writer.print(", ", .{});
        try writer.print("\"{s}\": \"{s}\"", .{ field.name, @typeName(field.type) });
    }
    try writer.print("}}}}{s}\n", .{if (trailing_comma) "," else ""});
}

fn renderEnumArray(writer: *std.Io.Writer, comptime label: []const u8, comptime T: type, comptime trailing_comma: bool) !void {
    try writer.print("{s}[", .{label});
    inline for (@typeInfo(T).@"enum".fields, 0..) |field, i| {
        if (i > 0) try writer.print(", ", .{});
        try writer.print("\"{s}\"", .{field.name});
    }
    try writer.print("]{s}\n", .{if (trailing_comma) "," else ""});
}

test "render produces parseable JSON naming every task field and status" {
    const alloc = std.testing.allocator;
    var accumulating = std.Io.Writer.Allocating.init(alloc);
    defer accumulating.deinit();
    try render(&accumulating.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, accumulating.writer.buffered(), .{});
    defer parsed.deinit();

    const entities = parsed.value.object.get("entities").?.object;
    const task_fields = entities.get("task").?.object.get("fields").?.object;
    try std.testing.expect(task_fields.contains("required_capability"));
    try std.testing.expect(task_fields.contains("status"));

    const action_names = parsed.value.object.get("actions").?.array;
    var found_brief = false;
    for (action_names.items) |item| {
        if (std.mem.eql(u8, item.string, "brief")) found_brief = true;
    }
    try std.testing.expect(found_brief);
}
