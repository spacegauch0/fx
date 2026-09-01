const std = @import("std");

pub const Kind = enum {
    pull_request_merged,
};

pub const Provenance = struct {
    provider: []const u8,
    delivery_id: []const u8,
    repository: []const u8,
    url: []const u8,
};

pub const PullRequestMerged = struct {
    number: u64,
    title: []const u8,
    author: []const u8,
    merged_by: []const u8,
    head_sha: []const u8,
    base_branch: []const u8,
};

/// One provider-neutral fact observed by a CTO connector.
///
/// Every string is owned by the observation and released by `deinit`.
pub const Observation = struct {
    occurred_at_ms: i64,
    provenance: Provenance,
    payload: union(Kind) {
        pull_request_merged: PullRequestMerged,
    },

    pub fn kind(self: Observation) Kind {
        return std.meta.activeTag(self.payload);
    }

    pub fn deinit(self: Observation, alloc: std.mem.Allocator) void {
        alloc.free(self.provenance.provider);
        alloc.free(self.provenance.delivery_id);
        alloc.free(self.provenance.repository);
        alloc.free(self.provenance.url);
        switch (self.payload) {
            .pull_request_merged => |value| {
                alloc.free(value.title);
                alloc.free(value.author);
                alloc.free(value.merged_by);
                alloc.free(value.head_sha);
                alloc.free(value.base_branch);
            },
        }
    }
};
