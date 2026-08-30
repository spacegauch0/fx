//! GitHub's first CTO extension: normalize only a merged pull-request webhook.
//! It is intentionally pure: signature verification, delivery persistence, and
//! policy live in the trusted runtime around this connector.
const std = @import("std");
const contract = @import("../extension_contract.zig");
const observation = @import("../observation.zig");

pub const connector: contract.Connector = .{
    .id = "github-events",
    .capability = "github.pull_request.merged",
    .context = @ptrCast(@constCast(&unit)),
    .normalize_fn = normalize,
};

var unit: u8 = 0;

fn stringAt(root: std.json.Value, keys: []const []const u8) ?[]const u8 {
    var value = root;
    for (keys) |key| {
        const object = switch (value) {
            .object => |item| item,
            else => return null,
        };
        value = object.get(key) orelse return null;
    }
    return switch (value) {
        .string => |item| item,
        else => null,
    };
}

fn integerAt(root: std.json.Value, keys: []const []const u8) ?i64 {
    var value = root;
    for (keys) |key| {
        const object = switch (value) {
            .object => |item| item,
            else => return null,
        };
        value = object.get(key) orelse return null;
    }
    return switch (value) {
        .integer => |item| item,
        else => null,
    };
}

fn boolAt(root: std.json.Value, keys: []const []const u8) ?bool {
    var value = root;
    for (keys) |key| {
        const object = switch (value) {
            .object => |item| item,
            else => return null,
        };
        value = object.get(key) orelse return null;
    }
    return switch (value) {
        .bool => |item| item,
        else => null,
    };
}

fn duplicate(alloc: std.mem.Allocator, value: ?[]const u8) ![]const u8 {
    return alloc.dupe(u8, value orelse "");
}

fn normalize(_: *anyopaque, alloc: std.mem.Allocator, event: contract.RawEvent) !?observation.Observation {
    if (!std.mem.eql(u8, event.event_name, "pull_request")) return null;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, event.body, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, stringAt(parsed.value, &.{"action"}) orelse "", "closed")) return null;
    if (!(boolAt(parsed.value, &.{ "pull_request", "merged" }) orelse false)) return null;
    const number = integerAt(parsed.value, &.{ "pull_request", "number" }) orelse return error.InvalidWebhook;
    return .{
        .occurred_at_ms = 0,
        .provenance = .{ .provider = try alloc.dupe(u8, "github"), .delivery_id = try alloc.dupe(u8, event.delivery_id), .repository = try duplicate(alloc, stringAt(parsed.value, &.{ "repository", "full_name" })), .url = try duplicate(alloc, stringAt(parsed.value, &.{ "pull_request", "html_url" })) },
        .payload = .{ .pull_request_merged = .{ .number = @intCast(number), .title = try duplicate(alloc, stringAt(parsed.value, &.{ "pull_request", "title" })), .author = try duplicate(alloc, stringAt(parsed.value, &.{ "pull_request", "user", "login" })), .merged_by = try duplicate(alloc, stringAt(parsed.value, &.{ "pull_request", "merged_by", "login" })), .head_sha = try duplicate(alloc, stringAt(parsed.value, &.{ "pull_request", "head", "sha" })), .base_branch = try duplicate(alloc, stringAt(parsed.value, &.{ "pull_request", "base", "ref" })) } },
    };
}

test "normalizes only a merged GitHub pull request" {
    const raw = "{\"action\":\"closed\",\"repository\":{\"full_name\":\"spacegauch0/fx\"},\"pull_request\":{\"number\":1,\"merged\":true,\"title\":\"CTO\",\"html_url\":\"https://github.com/spacegauch0/fx/pull/1\",\"user\":{\"login\":\"diego\"},\"merged_by\":{\"login\":\"reviewer\"},\"head\":{\"sha\":\"abc\"},\"base\":{\"ref\":\"main\"}}}";
    const result = try connector.normalize(std.testing.allocator, .{ .event_name = "pull_request", .delivery_id = "delivery-1", .body = raw });
    defer result.?.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), result.?.payload.pull_request_merged.number);
    try std.testing.expectEqualStrings("spacegauch0/fx", result.?.provenance.repository);
}
