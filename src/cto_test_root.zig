//! Root for `zig build test-cto`: a module rooted at `src/` (like the real
//! `src/main.zig`, so `src/cto/*.zig`'s `../core/shared/io.zig`-style
//! imports resolve) that pulls in only the CTO subsystem's own import
//! graph, not the rest of fx. See build.zig's `test-cto` step.
comptime {
    _ = @import("cto/main.zig");
}
