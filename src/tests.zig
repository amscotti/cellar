//! Test root: imports every module with tests so `zig build test` sees them.

test {
    _ = @import("config.zig");
    _ = @import("util/cap.zig");
    _ = @import("util/ratelimit.zig");
    _ = @import("runtime/metrics.zig");
    _ = @import("runtime/locator.zig");
    _ = @import("runtime/membership.zig");
    _ = @import("runtime/gossip.zig");
    _ = @import("runtime/gossip_net.zig");
    _ = @import("vm/lua_test.zig");
    _ = @import("runtime/fetch.zig");
    _ = @import("runtime/alarms.zig");
    _ = @import("runtime/registry.zig");
    _ = @import("runtime/scheduler_test.zig");
    _ = @import("store/db_test.zig");
    _ = @import("store/paths.zig");
    _ = @import("store/blob.zig");
    _ = @import("store/meta.zig");
    _ = @import("http/router.zig");
    _ = @import("http/admin.zig");
    _ = @import("http/server.zig");
    _ = @import("store/sqlite.zig");
    _ = @import("util/json.zig");
    _ = @import("util/sys.zig");
}
