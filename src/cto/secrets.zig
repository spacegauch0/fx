//! Keyed secret resolution for the CTO layer.
//!
//! Secrets never live in `.cto/`: that directory is workspace-local and
//! sits next to a git repo. They resolve from the environment first, then
//! from a private keyed file under fx's profile directory, following the
//! same convention MCP credentials already use (`~/.fx/<dir>/credentials.json`).
//!
//! This is deliberately not `host.SecretStore`. That interface is a
//! single-slot store built for the one fx gateway credential; CTO needs
//! several independently-rotatable secrets, and widening a credential path
//! the rest of fx depends on is the wrong blast radius for an additive
//! layer. See docs/CTO_ROADMAP.md (D1).

const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

pub const credentials_dir_name = "cto-credentials";
pub const credentials_file_name = "credentials.json";
pub const max_credentials_bytes: usize = 64 * 1024;

pub const Key = enum {
    github_webhook_secret,
    github_token,
    telegram_token,

    /// Environment variable consulted before the credentials file.
    pub fn envVar(self: Key) []const u8 {
        return switch (self) {
            .github_webhook_secret => "FX_CTO_GITHUB_WEBHOOK_SECRET",
            .github_token => "FX_CTO_GITHUB_TOKEN",
            .telegram_token => "FX_CTO_TELEGRAM_TOKEN",
        };
    }

    /// Key used inside the credentials JSON object.
    pub fn fileKey(self: Key) []const u8 {
        return @tagName(self);
    }
};

pub const ResolveError = error{
    /// The credentials file is readable by group or others. Refused rather
    /// than used, the way ssh refuses a permissive private key.
    CredentialsFilePermissive,
    CredentialsFileMalformed,
} || std.mem.Allocator.Error;

pub fn credentialsPath(alloc: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ home, ".fx", credentials_dir_name, credentials_file_name });
}

/// Precedence rule, extracted so it is testable without mutating the
/// process-wide environment: a present, non-empty environment value wins,
/// otherwise the credentials file supplies the value.
pub fn selectSecret(env_value: ?[]const u8, file_value: ?[]const u8) ?[]const u8 {
    if (env_value) |value| {
        if (value.len > 0) return value;
    }
    if (file_value) |value| {
        if (value.len > 0) return value;
    }
    return null;
}

/// Resolves one secret. Returns null when it is configured nowhere.
///
/// The caller owns the returned bytes and should zero them before freeing;
/// they are never logged, journaled, or included in an error message.
pub fn resolve(alloc: std.mem.Allocator, home: []const u8, key: Key) ResolveError!?[]u8 {
    if (io_mod.getenv(key.envVar())) |value| {
        if (value.len > 0) return try alloc.dupe(u8, value);
    }
    const path = try credentialsPath(alloc, home);
    defer alloc.free(path);
    return resolveFromFile(alloc, path, key);
}

/// Reads one key out of a credentials file, refusing a file whose mode
/// lets anyone but the owner read it.
pub fn resolveFromFile(alloc: std.mem.Allocator, path: []const u8, key: Key) ResolveError!?[]u8 {
    const zio = io_mod.getIo();
    const stat = std.Io.Dir.cwd().statFile(zio, path, .{ .follow_symlinks = false }) catch return null;
    if (stat.kind != .file) return null;
    if (stat.permissions.toMode() & 0o077 != 0) return error.CredentialsFilePermissive;

    var file = std.Io.Dir.openFileAbsolute(zio, path, .{}) catch return null;
    defer file.close(zio);
    const bytes = io_mod.readFileToEnd(alloc, &file, max_credentials_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CredentialsFileMalformed,
    };
    defer {
        @memset(bytes, 0);
        alloc.free(bytes);
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.CredentialsFileMalformed;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.CredentialsFileMalformed,
    };
    const entry = object.get(key.fileKey()) orelse return null;
    const value = switch (entry) {
        .string => |text| text,
        else => return error.CredentialsFileMalformed,
    };
    if (value.len == 0) return null;
    return try alloc.dupe(u8, value);
}

test "environment value takes precedence over the credentials file" {
    try std.testing.expectEqualStrings("from-env", selectSecret("from-env", "from-file").?);
    try std.testing.expectEqualStrings("from-file", selectSecret(null, "from-file").?);
    // An empty environment value is treated as unset rather than as an
    // empty secret, so an exported-but-blank variable cannot shadow a
    // configured file value.
    try std.testing.expectEqualStrings("from-file", selectSecret("", "from-file").?);
    try std.testing.expect(selectSecret(null, null) == null);
    try std.testing.expect(selectSecret("", "") == null);
}

test "env var names are distinct and namespaced" {
    var seen: std.BufSet = .init(std.testing.allocator);
    defer seen.deinit();
    for ([_]Key{ .github_webhook_secret, .github_token, .telegram_token }) |key| {
        try std.testing.expect(std.mem.startsWith(u8, key.envVar(), "FX_CTO_"));
        try std.testing.expect(!seen.contains(key.envVar()));
        try seen.insert(key.envVar());
    }
}

test "credentials file is read only when its mode excludes group and other" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "credentials.json" });
    defer alloc.free(path);

    try io_mod.writeFileAtomic(alloc, path, "{\"github_webhook_secret\":\"from-file\"}");
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), path, .fromMode(0o600), .{});

    const resolved = (try resolveFromFile(alloc, path, .github_webhook_secret)).?;
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("from-file", resolved);

    // A key the file does not carry is absent, not an error.
    try std.testing.expect((try resolveFromFile(alloc, path, .telegram_token)) == null);

    // Group-readable is refused outright rather than silently trusted.
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), path, .fromMode(0o640), .{});
    try std.testing.expectError(
        error.CredentialsFilePermissive,
        resolveFromFile(alloc, path, .github_webhook_secret),
    );
}

test "a missing credentials file is absent rather than an error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "absent.json" });
    defer alloc.free(path);

    try std.testing.expect((try resolveFromFile(alloc, path, .github_webhook_secret)) == null);
}

test "malformed credentials file is reported rather than ignored" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "credentials.json" });
    defer alloc.free(path);

    try io_mod.writeFileAtomic(alloc, path, "not json at all");
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), path, .fromMode(0o600), .{});
    try std.testing.expectError(
        error.CredentialsFileMalformed,
        resolveFromFile(alloc, path, .github_webhook_secret),
    );
}
