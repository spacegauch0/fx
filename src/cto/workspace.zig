const std = @import("std");

/// Path conventions for where a task's worktree and candidate branch live.
/// Kept as pure string formatting; `git.zig` is what actually touches disk.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    repository_path: []const u8,
    root_path: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        repository_path: []const u8,
        root_path: []const u8,
    ) Workspace {
        return .{
            .allocator = allocator,
            .repository_path = repository_path,
            .root_path = root_path,
        };
    }

    pub fn worktreePath(self: Workspace, task_id: u64) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/worktrees/task-{d}",
            .{ self.root_path, task_id },
        );
    }

    pub fn candidateBranch(self: Workspace, task_id: u64) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "candidate/task-{d}",
            .{task_id},
        );
    }
};

test "worktree and candidate paths are namespaced per task" {
    const ws = Workspace.init(std.testing.allocator, ".", "/repo/.cto");

    const worktree_path = try ws.worktreePath(7);
    defer std.testing.allocator.free(worktree_path);
    try std.testing.expectEqualStrings("/repo/.cto/worktrees/task-7", worktree_path);

    const branch = try ws.candidateBranch(7);
    defer std.testing.allocator.free(branch);
    try std.testing.expectEqualStrings("candidate/task-7", branch);
}
