const std = @import("std");
const build_options = @import("build_options");

/// Every size and limit in the system lives here. No magic numbers in the
/// request path; tests assert these defaults so a change is deliberate.
pub const Limits = struct {
    listen: []const u8 = "127.0.0.1:8080",
    data_dir: []const u8 = "./data",
    shards: u16 = 4,
    max_conns: u16 = 64,
    max_cells: u16 = 64,
    deadline_ms: u32 = 5000,
    queue_timeout_ms: u32 = 2000,
    fetch_workers: u32 = 4,
    /// How long SIGTERM waits for in-flight invocations before exiting anyway.
    drain_ms: u32 = 5000,
    /// Requests per second per cell; 0 disables the limiter.
    rate_per_s: u32 = 0,
    /// Tokens available at once; 0 means "same as rate".
    rate_burst: u32 = 0,
    /// Blobs younger than this are never garbage-collected: a deploy may have
    /// written the blob and not yet pinned it to a cell row.
    gc_min_age_s: u32 = 60,
    vm_budget_mb: u32 = 64,
    db_max_mb: u32 = 256,
    max_head: usize = 16 * 1024,
    max_body: usize = 1024 * 1024,
    max_source: usize = 512 * 1024,
    max_response: usize = 4 * 1024 * 1024,
    row_cap: usize = 10_000,
    sql_cap: usize = 100 * 1024,
    stmt_cache: usize = 64,
};

pub const Config = struct {
    limits: Limits = .{},
    admin_token: ?[]const u8 = null,
    /// Path to a file whose trimmed contents are the admin token.
    /// Resolved by `serve` (which owns an `Io`); takes precedence over
    /// the inline `--admin-token` so the secret never appears in `ps`.
    admin_token_file: ?[]const u8 = null,
    /// Password for `/c/...`. Null means the data plane is open (trusted guests,
    /// local play). Separate from `admin_token` so handing a client the invoke
    /// password does not hand it deploy rights.
    cell_token: ?[]const u8 = null,
    cell_token_file: ?[]const u8 = null,
    /// Serve `/admin` reads without a token even when the listener is not loopback.
    /// Off by default: the dashboard exposes cell names, module versions and counts,
    /// which is fine on a dev box and an information leak on a public one.
    admin_open: bool = false,
    /// Grant guests outbound network access (`http.fetch`). Off by default: it is
    /// a capability, and turning it on should be a decision, not a default.
    allow_fetch: bool = false,
    /// Allow `http.fetch` to reach private/loopback/link-local addresses.
    /// Off by default; only enable on a fully trusted network.
    fetch_allow_private: bool = false,
    /// Host allowlist for `http.fetch`. Empty means any public host.
    /// Entries are exact hosts or `*.suffix` (label boundary). Port is ignored.
    fetch_allow_hosts: []const []const u8 = &.{},
    /// Force `Secure` on the dashboard cookie. `null` means auto:
    /// Secure when the request arrived over HTTPS (via `X-Forwarded-Proto`
    /// from a terminating proxy) or the listener is not loopback.
    cookie_secure: ?bool = null,
    node_id: ?[]const u8 = null,
    advertise: ?[]const u8 = null,
    peers: []const []const u8 = &.{},
    vm: []const u8 = build_options.vm,
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidInteger,
    OutOfMemory,
};

/// Parses `--flag value` pairs. Every flag in the plan's table is accepted;
/// cluster flags are stored and unused in MVP (ADR-0016).
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Config {
    var cfg: Config = .{};
    var peers: std.ArrayList([]const u8) = .empty;
    var fetch_hosts: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (!std.mem.startsWith(u8, flag, "--")) return error.UnknownFlag;
        const name = flag[2..];

        if (std.mem.eql(u8, name, "peers")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            // Accept both repeated `--peers a --peers b` and one
            // comma-joined `--peers a,b`. The old code stored the joined
            // string as a single entry, which never matched the
            // `node_id@addr` shape the Locator expects, so placement
            // silently fell back to local.
            var parts = std.mem.splitScalar(u8, args[i], ',');
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len == 0) continue;
                try peers.append(allocator, trimmed);
            }
            continue;
        }
        if (std.mem.eql(u8, name, "fetch-allow-host")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            var parts = std.mem.splitScalar(u8, args[i], ',');
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len == 0) continue;
                try fetch_hosts.append(allocator, trimmed);
            }
            continue;
        }

        if (!isKnownFlag(name)) return error.UnknownFlag;
        i += 1;
        if (i >= args.len) return error.MissingValue;
        const val = args[i];

        if (std.mem.eql(u8, name, "listen")) {
            cfg.limits.listen = val;
        } else if (std.mem.eql(u8, name, "data")) {
            cfg.limits.data_dir = val;
        } else if (std.mem.eql(u8, name, "shards")) {
            cfg.limits.shards = try parseU16(val);
        } else if (std.mem.eql(u8, name, "max-conns")) {
            cfg.limits.max_conns = try parseU16(val);
        } else if (std.mem.eql(u8, name, "max-cells")) {
            cfg.limits.max_cells = try parseU16(val);
        } else if (std.mem.eql(u8, name, "deadline-ms")) {
            cfg.limits.deadline_ms = try parseU32(val);
        } else if (std.mem.eql(u8, name, "queue-timeout-ms")) {
            cfg.limits.queue_timeout_ms = try parseU32(val);
        } else if (std.mem.eql(u8, name, "vm-budget-mb")) {
            cfg.limits.vm_budget_mb = try parseU32(val);
        } else if (std.mem.eql(u8, name, "db-max-mb")) {
            cfg.limits.db_max_mb = try parseU32(val);
        } else if (std.mem.eql(u8, name, "admin-token")) {
            cfg.admin_token = val;
        } else if (std.mem.eql(u8, name, "admin-token-file")) {
            cfg.admin_token_file = val;
        } else if (std.mem.eql(u8, name, "cell-token")) {
            cfg.cell_token = val;
        } else if (std.mem.eql(u8, name, "cell-token-file")) {
            cfg.cell_token_file = val;
        } else if (std.mem.eql(u8, name, "admin-open")) {
            cfg.admin_open = !std.mem.eql(u8, val, "0") and !std.mem.eql(u8, val, "false");
        } else if (std.mem.eql(u8, name, "allow-fetch")) {
            cfg.allow_fetch = !std.mem.eql(u8, val, "0") and !std.mem.eql(u8, val, "false");
        } else if (std.mem.eql(u8, name, "fetch-allow-private")) {
            cfg.fetch_allow_private = !std.mem.eql(u8, val, "0") and !std.mem.eql(u8, val, "false");
        } else if (std.mem.eql(u8, name, "cookie-secure")) {
            cfg.cookie_secure = !std.mem.eql(u8, val, "0") and !std.mem.eql(u8, val, "false");
        } else if (std.mem.eql(u8, name, "fetch-workers")) {
            cfg.limits.fetch_workers = try parseU32(val);
        } else if (std.mem.eql(u8, name, "drain-ms")) {
            cfg.limits.drain_ms = try parseU32(val);
        } else if (std.mem.eql(u8, name, "rate-per-s")) {
            cfg.limits.rate_per_s = try parseU32(val);
        } else if (std.mem.eql(u8, name, "rate-burst")) {
            cfg.limits.rate_burst = try parseU32(val);
        } else if (std.mem.eql(u8, name, "gc-min-age-s")) {
            cfg.limits.gc_min_age_s = try parseU32(val);
        } else if (std.mem.eql(u8, name, "node-id")) {
            cfg.node_id = val;
        } else if (std.mem.eql(u8, name, "advertise")) {
            cfg.advertise = val;
        }
    }

    cfg.peers = try peers.toOwnedSlice(allocator);
    cfg.fetch_allow_hosts = try fetch_hosts.toOwnedSlice(allocator);
    return cfg;
}

fn isKnownFlag(name: []const u8) bool {
    const known = [_][]const u8{
        "listen",           "data",             "shards",      "max-conns",           "max-cells",        "deadline-ms",
        "queue-timeout-ms", "vm-budget-mb",     "db-max-mb",   "admin-token",         "admin-token-file", "cell-token",
        "cell-token-file",  "admin-open",       "allow-fetch", "fetch-allow-private", "cookie-secure",    "fetch-workers",
        "drain-ms",         "rate-per-s",       "rate-burst",  "gc-min-age-s",        "node-id",          "advertise",
        "peers",            "fetch-allow-host",
    };
    for (known) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

fn parseU16(s: []const u8) ParseError!u16 {
    return std.fmt.parseInt(u16, s, 10) catch error.InvalidInteger;
}

fn parseU32(s: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch error.InvalidInteger;
}

test "defaults match the plan's table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), &.{});
    try std.testing.expectEqualStrings("127.0.0.1:8080", cfg.limits.listen);
    try std.testing.expectEqual(@as(u16, 4), cfg.limits.shards);
    try std.testing.expectEqual(@as(u16, 64), cfg.limits.max_conns);
    try std.testing.expectEqual(@as(u32, 5000), cfg.limits.deadline_ms);
    try std.testing.expectEqual(@as(u32, 64), cfg.limits.vm_budget_mb);
    try std.testing.expectEqual(@as(usize, 10_000), cfg.limits.row_cap);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.admin_token);
    try std.testing.expectEqual(@as(usize, 0), cfg.peers.len);
}

test "flags override defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), &.{ "--listen", "0.0.0.0:9", "--shards", "7", "--admin-token", "t0k", "--peers", "a:1" });
    try std.testing.expectEqualStrings("0.0.0.0:9", cfg.limits.listen);
    try std.testing.expectEqual(@as(u16, 7), cfg.limits.shards);
    try std.testing.expectEqualStrings("t0k", cfg.admin_token.?);
    try std.testing.expectEqual(@as(usize, 1), cfg.peers.len);
}

test "comma-joined peers and fetch hosts are split" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), &.{ "--peers", "n1@10.0.0.1:8080,n2@10.0.0.2:8080", "--peers", "n3@10.0.0.3:8080", "--fetch-allow-host", "api.example.com,*.example.org" });
    try std.testing.expectEqual(@as(usize, 3), cfg.peers.len);
    try std.testing.expectEqualStrings("n1@10.0.0.1:8080", cfg.peers[0]);
    try std.testing.expectEqualStrings("n2@10.0.0.2:8080", cfg.peers[1]);
    try std.testing.expectEqualStrings("n3@10.0.0.3:8080", cfg.peers[2]);
    try std.testing.expectEqual(@as(usize, 2), cfg.fetch_allow_hosts.len);
}

test "unknown flag is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownFlag, parse(arena.allocator(), &.{"--nope"}));
    try std.testing.expectError(error.InvalidInteger, parse(arena.allocator(), &.{ "--shards", "x" }));
    try std.testing.expectError(error.MissingValue, parse(arena.allocator(), &.{"--shards"}));
}
