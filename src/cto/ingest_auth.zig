//! Admission control for raw provider events.
//!
//! This is trusted-runtime code and runs *before* any connector sees a
//! body: signature verification, size limits, and the event-name allowlist
//! all belong to the kernel, not to a mutable extension. A connector stays
//! a pure normalizer that is only ever handed input this module admitted.
//!
//! Webhook bodies are attacker-controlled. Every rejection below is a
//! distinct, auditable reason rather than a generic failure, so the
//! journal can distinguish misconfiguration from a probe.

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// GitHub caps webhook deliveries at 25 MB, but the events CTO handles are
/// a few KB. A tighter bound keeps a hostile sender from making the
/// process allocate on its behalf.
pub const max_body_bytes: usize = 1024 * 1024;

pub const github_signature_header = "X-Hub-Signature-256";
pub const github_signature_prefix = "sha256=";
const digest_length = HmacSha256.mac_length;
const signature_hex_length = digest_length * 2;

/// Event names the trusted layer will admit. Deliberately maintained here
/// rather than derived from the connector registry: what is admissible is
/// a kernel policy decision, and a self-generated connector must not be
/// able to widen the set of traffic that reaches it.
pub const allowed_github_events = [_][]const u8{
    "pull_request",
};

pub const Verdict = enum {
    ok,
    body_too_large,
    signature_missing,
    signature_malformed,
    signature_mismatch,
    event_not_allowed,

    pub fn admitted(self: Verdict) bool {
        return self == .ok;
    }

    /// Operator-facing explanation. Never includes any part of the
    /// signature, the secret, or the body.
    pub fn reason(self: Verdict) []const u8 {
        return switch (self) {
            .ok => "admitted",
            .body_too_large => "event body exceeds the accepted size limit",
            .signature_missing => "a webhook secret is configured but the delivery carried no signature",
            .signature_malformed => "signature header is not a well-formed sha256=<hex> value",
            .signature_mismatch => "signature does not match the configured webhook secret",
            .event_not_allowed => "event name is not in the trusted allowlist",
        };
    }
};

pub fn isAllowedGithubEvent(event_name: []const u8) bool {
    for (allowed_github_events) |allowed| {
        if (std.mem.eql(u8, allowed, event_name)) return true;
    }
    return false;
}

/// Verifies GitHub's `X-Hub-Signature-256` over the exact raw body.
///
/// The comparison is constant-time: a byte-wise early return would leak
/// the expected digest one byte at a time to a sender who can retry.
pub fn verifyGithubSignature(secret: []const u8, body: []const u8, signature_header: []const u8) Verdict {
    if (!std.mem.startsWith(u8, signature_header, github_signature_prefix)) return .signature_malformed;
    const hex = signature_header[github_signature_prefix.len..];
    if (hex.len != signature_hex_length) return .signature_malformed;

    var provided: [digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&provided, hex) catch return .signature_malformed;

    var expected: [digest_length]u8 = undefined;
    HmacSha256.create(&expected, body, secret);

    if (!std.crypto.timing_safe.eql([digest_length]u8, expected, provided)) return .signature_mismatch;
    return .ok;
}

pub const Admission = struct {
    event_name: []const u8,
    body: []const u8,
    /// Null when the delivery carried no signature header.
    signature_header: ?[]const u8 = null,
    /// Null when no webhook secret is configured. Unsigned bodies are then
    /// admitted, which is only appropriate for a locally-supplied body
    /// (a human piping a fixture into `fx cto ingest`), never for a
    /// network listener.
    secret: ?[]const u8 = null,
};

pub fn admit(request: Admission) Verdict {
    if (request.body.len > max_body_bytes) return .body_too_large;
    if (!isAllowedGithubEvent(request.event_name)) return .event_not_allowed;
    const secret = request.secret orelse return .ok;
    const header = request.signature_header orelse return .signature_missing;
    return verifyGithubSignature(secret, request.body, header);
}

const fixture_secret = "It's a Secret to Everybody";
const fixture_body = "Hello, World!";
// Published GitHub documentation vector for the pair above.
const fixture_signature = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17";

test "accepts GitHub's own published signature vector" {
    try std.testing.expectEqual(
        Verdict.ok,
        verifyGithubSignature(fixture_secret, fixture_body, fixture_signature),
    );
}

test "rejects a tampered body and a wrong secret distinctly from a malformed header" {
    try std.testing.expectEqual(
        Verdict.signature_mismatch,
        verifyGithubSignature(fixture_secret, "Hello, World?", fixture_signature),
    );
    try std.testing.expectEqual(
        Verdict.signature_mismatch,
        verifyGithubSignature("the wrong secret", fixture_body, fixture_signature),
    );
    for ([_][]const u8{
        "",
        "757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17",
        "sha1=757107ea",
        "sha256=",
        "sha256=deadbeef",
        "sha256=zzz107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17",
    }) |header| {
        try std.testing.expectEqual(
            Verdict.signature_malformed,
            verifyGithubSignature(fixture_secret, fixture_body, header),
        );
    }
}

test "admit enforces size, allowlist, and signature in that order" {
    const oversized = try std.testing.allocator.alloc(u8, max_body_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');

    // Size is checked before anything parses or hashes the body.
    try std.testing.expectEqual(Verdict.body_too_large, admit(.{
        .event_name = "pull_request",
        .body = oversized,
        .secret = fixture_secret,
        .signature_header = fixture_signature,
    }));

    try std.testing.expectEqual(Verdict.event_not_allowed, admit(.{
        .event_name = "issue_comment",
        .body = fixture_body,
    }));

    // A configured secret makes a signature mandatory.
    try std.testing.expectEqual(Verdict.signature_missing, admit(.{
        .event_name = "pull_request",
        .body = fixture_body,
        .secret = fixture_secret,
    }));

    try std.testing.expectEqual(Verdict.ok, admit(.{
        .event_name = "pull_request",
        .body = fixture_body,
        .secret = fixture_secret,
        .signature_header = fixture_signature,
    }));

    // With no secret configured an unsigned local body is admitted.
    try std.testing.expectEqual(Verdict.ok, admit(.{
        .event_name = "pull_request",
        .body = fixture_body,
    }));
}

test "every verdict carries a distinct operator-facing reason" {
    var seen: std.BufSet = .init(std.testing.allocator);
    defer seen.deinit();
    for (std.enums.values(Verdict)) |verdict| {
        try std.testing.expect(verdict.reason().len > 0);
        try std.testing.expect(!seen.contains(verdict.reason()));
        try seen.insert(verdict.reason());
    }
    try std.testing.expect(Verdict.ok.admitted());
    try std.testing.expect(!Verdict.signature_mismatch.admitted());
}
