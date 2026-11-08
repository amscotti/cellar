const std = @import("std");

/// Token-bucket rate limiter, keyed by an opaque string (a cell key).
///
/// Why per cell and not per client: the thing a single bad actor can do to this
/// runtime is make one cell hot, and every request for that cell lands on the same
/// shard and the same database. Bounding per cell bounds the damage without needing
/// to trust an identity — and it works even when the data plane is open.
///
/// The table is fixed-size because the key is user-chosen: an unbounded map keyed by
/// cell name is the same cardinality bomb the metrics avoid. When it fills, the
/// least-recently-used entry is evicted, so a flood of distinct keys degrades to
/// "everyone shares the table" rather than to unbounded memory.
pub const Limiter = struct {
    pub const capacity = 512;

    mu: std.Io.Mutex = .init,
    entries: [capacity]Entry = @splat(.{}),
    rate_per_s: f64,
    burst: f64,

    const Entry = struct {
        digest: [32]u8 = @splat(0),
        tokens: f64 = 0,
        last_ns: u64 = 0,
        used: bool = false,
    };

    pub fn init(rate_per_s: f64, burst: f64) Limiter {
        return .{ .rate_per_s = @max(rate_per_s, 0.001), .burst = @max(burst, 1) };
    }

    /// Returns true if the request may proceed, consuming one token.
    pub fn allow(self: *Limiter, io: std.Io, key: []const u8, now_ns: u64) bool {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});

        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        var slot: ?*Entry = null;
        var free: ?*Entry = null;
        var lru: ?*Entry = null;
        for (&self.entries) |*e| {
            if (!e.used) {
                if (free == null) free = e;
                continue;
            }
            if (std.mem.eql(u8, &e.digest, &digest)) {
                slot = e;
                break;
            }
            if (lru == null or e.last_ns < lru.?.last_ns) lru = e;
        }

        if (slot == null) {
            const e = free orelse lru orelse &self.entries[0];
            e.* = .{ .digest = digest, .tokens = self.burst, .last_ns = now_ns, .used = true };
            slot = e;
        }

        const e = slot.?;
        const elapsed_s = if (now_ns > e.last_ns)
            @as(f64, @floatFromInt(now_ns - e.last_ns)) / @as(f64, std.time.ns_per_s)
        else
            0;
        e.tokens = @min(self.burst, e.tokens + elapsed_s * self.rate_per_s);
        e.last_ns = now_ns;

        if (e.tokens < 1) return false;
        e.tokens -= 1;
        return true;
    }
};

test "burst then refuse, and refill over time" {
    const io = @import("test_io.zig").testIo();
    var l = Limiter.init(10, 3); // 10/s, burst 3
    var t: u64 = 1_000_000_000;

    try std.testing.expect(l.allow(io, "a", t));
    try std.testing.expect(l.allow(io, "a", t));
    try std.testing.expect(l.allow(io, "a", t));
    try std.testing.expect(!l.allow(io, "a", t)); // burst exhausted

    // A different key has its own bucket.
    try std.testing.expect(l.allow(io, "b", t));

    // 100 ms at 10/s = one token back.
    t += 100 * std.time.ns_per_ms;
    try std.testing.expect(l.allow(io, "a", t));
    // And just one: the second immediate call has nothing left.
    try std.testing.expect(!l.allow(io, "a", t));
}

test "a fresh key starts full, and the table never grows past capacity" {
    const io = @import("test_io.zig").testIo();
    var l = Limiter.init(1, 1);
    var t: u64 = 1;
    var i: usize = 0;
    // More distinct keys than the table holds: every one still gets a first token,
    // because eviction gives the slot a full bucket.
    while (i < Limiter.capacity * 2) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "cell-{d}", .{i});
        try std.testing.expect(l.allow(io, key, t));
        t += 1;
    }
}
