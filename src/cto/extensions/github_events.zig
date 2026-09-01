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

/// Parses GitHub's webhook timestamp format (RFC 3339, always UTC with a
/// literal "Z", no fractional seconds — e.g. "2024-01-15T10:30:00Z") into
/// epoch milliseconds. Returns null for anything else rather than guessing.
fn parseGithubTimestampMs(text: []const u8) ?i64 {
    if (text.len != 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or
        text[13] != ':' or text[16] != ':' or text[19] != 'Z') return null;

    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;

    // Howard Hinnant's days_from_civil: days since 1970-01-01 for a proleptic
    // Gregorian calendar date, valid for any year this connector will ever see.
    const y: i64 = if (month <= 2) year - 1 else year;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const adjusted_month = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days_since_epoch = era * 146097 + doe - 719468;

    const seconds_since_epoch = days_since_epoch * 86400 + hour * 3600 + minute * 60 + second;
    return seconds_since_epoch * 1000;
}

fn normalize(_: *anyopaque, alloc: std.mem.Allocator, event: contract.RawEvent) !?observation.Observation {
    if (!std.mem.eql(u8, event.event_name, "pull_request")) return null;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, event.body, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, stringAt(parsed.value, &.{"action"}) orelse "", "closed")) return null;
    if (!(boolAt(parsed.value, &.{ "pull_request", "merged" }) orelse false)) return null;
    const number = integerAt(parsed.value, &.{ "pull_request", "number" }) orelse return error.InvalidWebhook;
    const occurred_at_ms = parseGithubTimestampMs(
        stringAt(parsed.value, &.{ "pull_request", "merged_at" }) orelse "",
    ) orelse 0;
    return .{
        .occurred_at_ms = occurred_at_ms,
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
    // No merged_at in this fixture: falls back to 0 rather than guessing.
    try std.testing.expectEqual(@as(i64, 0), result.?.occurred_at_ms);
}

test "normalize preserves the GitHub-reported merge time" {
    const raw = "{\"action\":\"closed\",\"repository\":{\"full_name\":\"spacegauch0/fx\"},\"pull_request\":{\"number\":2,\"merged\":true,\"merged_at\":\"2024-01-15T10:30:00Z\",\"title\":\"CTO\",\"html_url\":\"https://github.com/spacegauch0/fx/pull/2\",\"user\":{\"login\":\"diego\"},\"merged_by\":{\"login\":\"reviewer\"},\"head\":{\"sha\":\"abc\"},\"base\":{\"ref\":\"main\"}}}";
    const result = try connector.normalize(std.testing.allocator, .{ .event_name = "pull_request", .delivery_id = "delivery-2", .body = raw });
    defer result.?.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1705314600000), result.?.occurred_at_ms);
}

test "parseGithubTimestampMs matches known epoch anchors" {
    try std.testing.expectEqual(@as(i64, 0), parseGithubTimestampMs("1970-01-01T00:00:00Z").?);
    try std.testing.expectEqual(@as(i64, 86400000), parseGithubTimestampMs("1970-01-02T00:00:00Z").?);
    try std.testing.expectEqual(@as(i64, 946684800000), parseGithubTimestampMs("2000-01-01T00:00:00Z").?);
    try std.testing.expectEqual(@as(i64, 1705314600000), parseGithubTimestampMs("2024-01-15T10:30:00Z").?);
    // 2024 is a leap year: 2024-02-29 must exist and be exactly one day
    // before 2024-03-01.
    const feb29 = parseGithubTimestampMs("2024-02-29T00:00:00Z").?;
    const mar01 = parseGithubTimestampMs("2024-03-01T00:00:00Z").?;
    try std.testing.expectEqual(@as(i64, 86400000), mar01 - feb29);
}

test "parseGithubTimestampMs rejects malformed timestamps" {
    try std.testing.expect(parseGithubTimestampMs("") == null);
    try std.testing.expect(parseGithubTimestampMs("not-a-date") == null);
    try std.testing.expect(parseGithubTimestampMs("2024-01-15T10:30:00+00:00") == null);
    try std.testing.expect(parseGithubTimestampMs("2024-13-01T00:00:00Z") == null);
}
