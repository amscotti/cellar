const std = @import("std");

/// SWIM-style membership, as a pure data structure.
///
/// Deliberately has no clock, no sockets and no threads: the caller supplies
/// `now_ms` and the probes it actually performs. That keeps the merge rules —
/// the part that is easy to get wrong and impossible to debug in a cluster —
/// testable on one machine, and it keeps this file free of anything that would
/// have to be rewritten when the transport lands.
///
/// Merge rules (SWIM §4.1, simplified):
///   * a higher incarnation always wins, whatever its state;
///   * at equal incarnation, a "worse" state wins (dead > suspect > alive) —
///     refuting a suspicion requires incrementing your own incarnation;
///   * a lower incarnation is stale and ignored;
///   * `dead` for a member we know at a higher incarnation is ignored, so a
///     delayed gossip message cannot kill a node that already refuted.
pub const State = enum(u8) { alive = 0, suspect = 1, dead = 2 };

pub const Member = struct {
    id: []u8,
    addr: []u8,
    incarnation: u64,
    state: State = .alive,
    last_seen_ms: u64 = 0,
};

pub const Update = struct {
    id: []const u8,
    addr: []const u8,
    incarnation: u64,
    state: State,
    now_ms: u64,
};

pub const Merge = enum { applied, stale, unknown_member };

pub const Table = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Member) = .empty,

    pub fn init(gpa: std.mem.Allocator) Table {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Table) void {
        for (self.items.items) |m| {
            self.gpa.free(m.id);
            self.gpa.free(m.addr);
        }
        self.items.deinit(self.gpa);
    }

    pub fn get(self: *Table, id: []const u8) ?*Member {
        for (self.items.items) |*m| {
            if (std.mem.eql(u8, m.id, id)) return m;
        }
        return null;
    }

    pub fn count(self: *const Table) usize {
        return self.items.items.len;
    }

    /// Adds a member, or refreshes one we already know. A join with a higher
    /// incarnation wins, which is the refutation path for a restarted node;
    /// membership alone cannot stop that node and its predecessor both serving,
    /// which is why ownership needs the epoch fence in CLUSTER.md §3.
    pub fn add(self: *Table, id: []const u8, addr: []const u8, incarnation: u64, now_ms: u64) !void {
        if (self.get(id)) |m| {
            if (incarnation > m.incarnation) {
                m.incarnation = incarnation;
                self.gpa.free(m.addr);
                m.addr = try self.gpa.dupe(u8, addr);
                m.state = .alive;
            }
            m.last_seen_ms = now_ms;
            return;
        }
        try self.items.append(self.gpa, .{
            .id = try self.gpa.dupe(u8, id),
            .addr = try self.gpa.dupe(u8, addr),
            .incarnation = incarnation,
            .last_seen_ms = now_ms,
        });
    }

    /// Applies a gossip update. Returns whether it changed anything, so callers
    /// can decide whether to re-gossip it (`applied`) or stay quiet.
    pub fn apply(self: *Table, u: Update) Merge {
        const m = self.get(u.id) orelse return .unknown_member;
        if (u.incarnation < m.incarnation) return .stale;
        if (u.incarnation == m.incarnation) {
            if (@backingInt(u.state) <= @backingInt(m.state)) {
                // Same or better state we already know: only refresh liveness.
                if (u.state == .alive) m.last_seen_ms = u.now_ms;
                return .stale;
            }
        } else {
            // Higher incarnation: refutation, so liveness is implied.
            m.last_seen_ms = u.now_ms;
        }
        m.incarnation = u.incarnation;
        m.state = u.state;
        return .applied;
    }

    /// Marks a member suspect at its current incarnation. A no-op if it is
    /// already suspect or dead, so repeated timeouts do not churn state.
    pub fn suspect(self: *Table, id: []const u8) bool {
        const m = self.get(id) orelse return false;
        if (m.state != .alive) return false;
        m.state = .suspect;
        return true;
    }

    /// Confirms death. Terminal for that incarnation: only a higher incarnation
    /// brings the member back.
    pub fn dead(self: *Table, id: []const u8) bool {
        const m = self.get(id) orelse return false;
        if (m.state == .dead) return false;
        m.state = .dead;
        return true;
    }

    pub fn aliveCount(self: *const Table) usize {
        var n: usize = 0;
        for (self.items.items) |m| {
            if (m.state == .alive) n += 1;
        }
        return n;
    }

    /// Probe targets: the least-recently-seen alive members, excluding self.
    /// Oldest-first is deliberate — it checks the nodes most likely to be dead
    /// using the fewest messages, which is the point of a gossip probe round.
    pub fn probeTargets(self: *const Table, arena: std.mem.Allocator, self_id: []const u8, k: usize) ![]const []const u8 {
        var idx = std.ArrayList(usize).empty;
        defer idx.deinit(arena);
        for (self.items.items, 0..) |m, i| {
            if (m.state != .alive) continue;
            if (std.mem.eql(u8, m.id, self_id)) continue;
            try idx.append(arena, i);
        }
        const items = self.items.items;
        std.mem.sort(usize, idx.items, items, struct {
            fn lessThan(rows: []Member, a: usize, b: usize) bool {
                if (rows[a].last_seen_ms == rows[b].last_seen_ms)
                    return std.mem.lessThan(u8, rows[a].id, rows[b].id);
                return rows[a].last_seen_ms < rows[b].last_seen_ms;
            }
        }.lessThan);

        const n = @min(k, idx.items.len);
        const out = try arena.alloc([]const u8, n);
        for (0..n) |i| out[i] = items[idx.items[i]].addr;
        return out;
    }
};

test "higher incarnation refutes a suspicion" {
    const a = std.testing.allocator;
    var t = Table.init(a);
    defer t.deinit();

    try t.add("n1", "10.0.0.1:7000", 1, 100);
    _ = t.suspect("n1");
    try std.testing.expectEqual(State.suspect, t.get("n1").?.state);

    try std.testing.expectEqual(Merge.applied, t.apply(.{
        .id = "n1",
        .addr = "10.0.0.1:7000",
        .incarnation = 2,
        .state = .alive,
        .now_ms = 200,
    }));
    // The refutation moves the incarnation too: the table reflects it, which is
    // what stops a replayed "suspect at 1" from taking hold again.
    try std.testing.expectEqual(State.alive, t.get("n1").?.state);
    try std.testing.expectEqual(@as(u64, 2), t.get("n1").?.incarnation);

    try std.testing.expectEqual(Merge.stale, t.apply(.{
        .id = "n1",
        .addr = "10.0.0.1:7000",
        .incarnation = 1,
        .state = .suspect,
        .now_ms = 300,
    }));
    try std.testing.expectEqual(State.alive, t.get("n1").?.state);
}

test "same incarnation, worse state wins and the table is idempotent" {
    const a = std.testing.allocator;
    var t = Table.init(a);
    defer t.deinit();
    try t.add("n1", "h:1", 5, 10);

    const upd = Update{ .id = "n1", .addr = "h:1", .incarnation = 5, .state = .suspect, .now_ms = 20 };
    try std.testing.expectEqual(Merge.applied, t.apply(upd));
    try std.testing.expectEqual(Merge.stale, t.apply(upd));
    try std.testing.expectEqual(State.suspect, t.get("n1").?.state);

    // An alive claim at the same incarnation does not clear it: that is exactly
    // the message a partition could replay.
    try std.testing.expectEqual(Merge.stale, t.apply(.{ .id = "n1", .addr = "h:1", .incarnation = 5, .state = .alive, .now_ms = 30 }));
    try std.testing.expectEqual(State.suspect, t.get("n1").?.state);
    try std.testing.expectEqual(@as(usize, 1), t.count());
}

test "a stale dead message cannot kill a refuted node" {
    const a = std.testing.allocator;
    var t = Table.init(a);
    defer t.deinit();
    try t.add("n1", "h:1", 9, 0);

    try std.testing.expectEqual(Merge.stale, t.apply(.{ .id = "n1", .addr = "h:1", .incarnation = 4, .state = .dead, .now_ms = 10 }));
    try std.testing.expectEqual(State.alive, t.get("n1").?.state);

    try std.testing.expectEqual(Merge.applied, t.apply(.{ .id = "n1", .addr = "h:1", .incarnation = 9, .state = .dead, .now_ms = 11 }));
    try std.testing.expectEqual(State.dead, t.get("n1").?.state);
    try std.testing.expectEqual(@as(usize, 0), t.aliveCount());
}

test "unknown members are reported rather than invented" {
    const a = std.testing.allocator;
    var t = Table.init(a);
    defer t.deinit();
    try std.testing.expectEqual(Merge.unknown_member, t.apply(.{ .id = "ghost", .addr = "h:9", .incarnation = 1, .state = .alive, .now_ms = 0 }));
    try std.testing.expectEqual(@as(usize, 0), t.count());
}

test "probe targets are alive, distinct, exclude self and oldest-first" {
    const a = std.testing.allocator;
    var t = Table.init(a);
    defer t.deinit();
    try t.add("self", "s:1", 1, 999);
    try t.add("n1", "a:1", 1, 50);
    try t.add("n2", "b:1", 1, 10);
    try t.add("n3", "c:1", 1, 30);
    try t.add("n4", "d:1", 1, 5);
    _ = t.dead("n4");

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const got = try t.probeTargets(arena.allocator(), "self", 2);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("b:1", got[0]); // last_seen 10
    try std.testing.expectEqualStrings("c:1", got[1]); // last_seen 30

    for (got) |addr| try std.testing.expect(!std.mem.eql(u8, addr, "s:1"));
    for (got) |addr| try std.testing.expect(!std.mem.eql(u8, addr, "d:1")); // dead
}
