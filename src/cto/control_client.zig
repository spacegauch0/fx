const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const control_protocol = @import("control_protocol.zig");
const daemon = @import("daemon.zig");

/// Sends one request over the control socket and waits for the matching
/// response. The connection is one-shot: dial, write one line, read one
/// line, close — matching the daemon's per-connection handling.
pub fn send(
    alloc: std.mem.Allocator,
    cto_root: []const u8,
    request: control_protocol.Request,
) !std.json.Parsed(control_protocol.Response) {
    if (comptime builtin.os.tag == .windows) return error.UnixSocketsUnsupported;
    const io = io_mod.getIo();

    const socket_path = try daemon.socketPath(alloc, cto_root);
    defer alloc.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try address.connect(io);
    defer stream.close(io);

    const encoded = try std.json.Stringify.valueAlloc(alloc, request, .{});
    defer alloc.free(encoded);
    var write_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(encoded);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = try reader.interface.takeDelimiterExclusive('\n');
    const parsed = try std.json.parseFromSlice(control_protocol.Response, alloc, line, .{});
    if (parsed.value.version != control_protocol.protocol_version) {
        parsed.deinit();
        return error.UnsupportedProtocolVersion;
    }
    return parsed;
}

/// Cheap liveness probe: is a daemon listening on this workspace's socket
/// right now? Any failure — no socket file, connection refused, a
/// malformed response — is treated as "no," never propagated as an error,
/// since the only decision this feeds is "proxy to the daemon or go
/// direct."
pub fn daemonAvailable(alloc: std.mem.Allocator, cto_root: []const u8) bool {
    const parsed = send(alloc, cto_root, .{ .id = "probe", .command = .health }) catch return false;
    defer parsed.deinit();
    return parsed.value.ok;
}
