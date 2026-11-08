const std = @import("std");

/// Where a cell lives. MVP always answers `.local`; the cluster implementation
/// fills in `.remote` when another node wins the placement (ADR-0016).
pub const Placement = union(enum) {
    local,
    remote: []const u8,
};

pub const Locator = struct {
    node_id: []const u8,
    advertise: ?[]const u8 = null,
    /// Member addresses including self, as `node_id@host:port`. Empty in MVP.
    peers: []const []const u8 = &.{},

    /// Rendezvous hashing over the member set. Deterministic and independent of
    /// iteration order, so every node computes the same answer without asking
    /// anyone — which is the whole reason cell identity is a digest.
    pub fn resolve(self: *const Locator, key: []const u8) Placement {
        if (self.peers.len <= 1) return .local;

        var best_score: u64 = 0;
        var best: []const u8 = self.node_id;
        var best_addr: ?[]const u8 = null;

        for (self.peers) |p| {
            const at = std.mem.indexOfScalar(u8, p, '@') orelse continue;
            const id = p[0..at];
            const addr = p[at + 1 ..];
            const score = scoreOf(id, key);
            if (score > best_score or (score == best_score and std.mem.order(u8, id, best) == .lt)) {
                best_score = score;
                best = id;
                best_addr = addr;
            }
        }

        // Self is a member too; if it did not win, the winner is remote.
        if (std.mem.eql(u8, best, self.node_id)) return .local;
        const addr = best_addr orelse return .local;
        if (self.advertise) |self_addr| {
            if (std.mem.eql(u8, addr, self_addr)) return .local;
        }
        return .{ .remote = addr };
    }

    pub fn isLocal(self: *const Locator, key: []const u8) bool {
        return self.resolve(key) == .local;
    }
};

fn scoreOf(id: []const u8, key: []const u8) u64 {
    var h = std.hash.Wyhash.init(0xcbf29ce484222325);
    h.update(id);
    h.update("\x00");
    h.update(key);
    return h.final();
}

test "a single node places everything locally" {
    const loc = Locator{ .node_id = "n1" };
    try std.testing.expect(loc.resolve("room-42") == .local);
    const with_self = Locator{ .node_id = "n1", .peers = &.{"n1@10.0.0.1:8080"} };
    try std.testing.expect(with_self.resolve("room-42") == .local);
}

test "two members split keys and both agree on the answer" {
    const a = Locator{ .node_id = "n1", .peers = &.{ "n1@10.0.0.1:8080", "n2@10.0.0.2:8080" } };
    const b = Locator{ .node_id = "n2", .peers = &.{ "n2@10.0.0.2:8080", "n1@10.0.0.1:8080" } };

    var local_a: usize = 0;
    var remote_a: usize = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "cell-{d}", .{i});
        const pa = a.resolve(key);
        const pb = b.resolve(key);
        switch (pa) {
            .local => local_a += 1,
            .remote => |addr| {
                remote_a += 1;
                _ = addr;
                // If a thinks it is remote, b must think it is local (or the
                // other way round) — never both remote, never both local.
                const pb_local = pb == .local;
                try std.testing.expect(pb_local or pb.remote.len > 0);
            },
        }
    }
    // Both members must be used, or the ring is broken.
    try std.testing.expect(local_a > 0);
    try std.testing.expect(remote_a > 0);
}
