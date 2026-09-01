/// `cto-dev` is a fixed engineer counterpart, not a general-purpose agent
/// registry: this PoC deliberately supports exactly one, so CTO delegates
/// self-improvement work to a single accountable owner instead of growing
/// an org chart.
pub const Counterpart = struct {
    id: []const u8,
    domain: []const u8,
    repository_path: []const u8,

    pub fn ctoDev(repository_path: []const u8) Counterpart {
        return .{
            .id = "cto-dev",
            .domain = "cto-platform",
            .repository_path = repository_path,
        };
    }
};
