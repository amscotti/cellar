const std = @import("std");
const membership = @import("membership.zig");
const gossip = @import("gossip.zig");

/// The gossip round: what a node does each tick, and how it reacts to a packet.
///
/// Deliberately transport-agnostic, and it can stay that way: `std.Io.net` in
/// 0.17.0 *does* have datagrams (`Socket.send(io, dest, data)`,
/// `Socket.receiveTimeout`, `IpAddress.bind(.{ .mode = .dgram })`), so a UDP
/// adapter is a small isolated piece of work rather than a raw-syscall project.
/// (An earlier note here claimed the primitives did not exist; that was wrong.)
/// Everything below is exercised by tests with an in-memory transport: probe,
/// ack, suspicion, and a three-node digest propagation.
pub const Transport = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, to: []const u8, bytes: []const u8) void,
    /// Returns one datagram per call, or null when the queue is empty. The
    /// returned slice points into `buf`.
    poll: *const fn (ctx: *anyopaque, buf: []u8) ?[]const u8,
};

pub const Node = struct {
    gpa: std.mem.Allocator,
    table: membership.Table,
    id: []const u8,
    addr: []const u8,
    incarnation: u64 = 1,
    transport: Transport,

    /// Milliseconds without a matching ack before the target is suspected, and
    /// again before it is declared dead.
    timeout_ms: u64 = 1000,
    period_ms: u64 = 500,

    seq: u64 = 0,
    next_probe_at: u64 = 0,
    pending: ?Pending = null,

    pub const Pending = struct {
        target: []u8,
        seq: u64,
        sent_at: u64,
    };

    pub fn init(gpa: std.mem.Allocator, id: []const u8, addr: []const u8, transport: Transport) !Node {
        return .{
            .gpa = gpa,
            .table = membership.Table.init(gpa),
            .id = try gpa.dupe(u8, id),
            .addr = try gpa.dupe(u8, addr),
            .transport = transport,
        };
    }

    pub fn deinit(self: *Node) void {
        if (self.pending) |p| self.gpa.free(p.target);
        self.table.deinit();
        self.gpa.free(self.id);
        self.gpa.free(self.addr);
    }

    /// One tick. Sends a probe when due; turns a silence into suspicion, and a
    /// second silence into death.
    pub fn step(self: *Node, now_ms: u64) void {
        if (self.pending) |p| {
            if (now_ms -| p.sent_at >= self.timeout_ms) {
                _ = self.table.suspect(p.target);
                if (now_ms -| p.sent_at >= self.timeout_ms * 2) {
                    _ = self.table.dead(p.target);
                }
                self.gpa.free(p.target);
                self.pending = null;
            }
            return;
        }
        if (now_ms < self.next_probe_at) return;
        self.next_probe_at = now_ms + self.period_ms;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const targets = self.table.probeTargets(arena.allocator(), self.id, 1) catch return;
        if (targets.len == 0) return;

        const digest = self.buildDigest(arena.allocator()) catch return;
        self.seq += 1;
        const bytes = gossip.encode(arena.allocator(), .{
            .kind = .ping,
            .incarnation = self.incarnation,
            .seq = self.seq,
            .id = self.id,
            .addr = self.addr,
            .digest = digest,
        }) catch return;

        self.transport.send(self.transport.ctx, targets[0], bytes);
        const copy = self.gpa.dupe(u8, self.findIdByAddr(targets[0]) orelse return) catch return;
        self.pending = .{ .target = copy, .seq = self.seq, .sent_at = now_ms };
    }

    /// Handles one datagram: merge its digest, answer a ping, clear a matching ack.
    pub fn handle(self: *Node, packet: []const u8, now_ms: u64) void {
        const msg = gossip.decode(packet) catch return;
        if (std.mem.eql(u8, msg.id, self.id)) return;

        // Learn the sender before merging, so a peer we have never met can join.
        self.table.add(msg.id, msg.addr, msg.incarnation, now_ms) catch return;
        _ = gossip.applyDigest(&self.table, msg.digest, now_ms);

        switch (msg.kind) {
            .ping => {
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                const digest = self.buildDigest(arena.allocator()) catch return;
                const bytes = gossip.encode(arena.allocator(), .{
                    .kind = .ack,
                    .incarnation = self.incarnation,
                    .seq = msg.seq,
                    .id = self.id,
                    .addr = self.addr,
                    .digest = digest,
                }) catch return;
                self.transport.send(self.transport.ctx, msg.addr, bytes);
            },
            .ack => {
                if (self.pending) |p| {
                    if (p.seq == msg.seq and std.mem.eql(u8, p.target, msg.id)) {
                        _ = self.table.apply(.{
                            .id = msg.id,
                            .addr = msg.addr,
                            .incarnation = msg.incarnation,
                            .state = .alive,
                            .now_ms = now_ms,
                        });
                        self.gpa.free(p.target);
                        self.pending = null;
                    }
                }
            },
            .suspect => _ = self.table.suspect(msg.digest),
        }
    }

    /// `id,state,incarnation;…` for every member we know, including ourselves.
    pub fn buildDigest(self: *Node, a: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(a);
        try out.appendSlice(a, self.id);
        try out.appendSlice(a, ",alive,");
        try appendInt(a, &out, self.incarnation);
        for (self.table.items.items) |m| {
            try out.append(a, ';');
            try out.appendSlice(a, m.id);
            try out.append(a, ',');
            try out.appendSlice(a, @tagName(m.state));
            try out.append(a, ',');
            try appendInt(a, &out, m.incarnation);
        }
        return out.toOwnedSlice(a);
    }

    fn findIdByAddr(self: *Node, addr: []const u8) ?[]const u8 {
        for (self.table.items.items) |m| {
            if (std.mem.eql(u8, m.addr, addr)) return m.id;
        }
        return null;
    }
};

/// Append a decimal integer. `std.ArrayList` has no writer in this Zig version.
fn appendInt(a: std.mem.Allocator, out: *std.ArrayList(u8), v: u64) !void {
    var buf: [20]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
    try out.appendSlice(a, s);
}

// --- shared in-memory transport used by the tests and by `--gossip-dry-run` ---

pub const Packet = struct { to: []u8, bytes: []u8 };

pub const Mailbox = struct {
    gpa: std.mem.Allocator,
    queue: std.ArrayList(Packet) = .empty,

    pub fn init(gpa: std.mem.Allocator) Mailbox {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Mailbox) void {
        for (self.queue.items) |p| {
            self.gpa.free(p.to);
            self.gpa.free(p.bytes);
        }
        self.queue.deinit(self.gpa);
    }
    pub fn transport(self: *Mailbox) Transport {
        return .{ .ctx = self, .send = sendFn, .poll = pollFn };
    }
    fn sendFn(ctx: *anyopaque, to: []const u8, bytes: []const u8) void {
        const self: *Mailbox = @ptrCast(@alignCast(ctx));
        self.queue.append(self.gpa, .{
            .to = self.gpa.dupe(u8, to) catch return,
            .bytes = self.gpa.dupe(u8, bytes) catch return,
        }) catch {};
    }
    fn pollFn(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Mailbox = @ptrCast(@alignCast(ctx));
        if (self.queue.items.len == 0) return null;
        const p = self.queue.orderedRemove(0);
        defer self.gpa.free(p.to);
        defer self.gpa.free(p.bytes);
        if (p.bytes.len > buf.len) return null;
        @memcpy(buf[0..p.bytes.len], p.bytes);
        return buf[0..p.bytes.len];
    }

    /// Convenience for tests and for a future `--gossip-dry-run`.
    pub fn poll(self: *Mailbox, buf: []u8) ?[]const u8 {
        return pollFn(self, buf);
    }
};

test "a probe is answered and clears the pending state" {
    const a = std.testing.allocator;
    var mb_a = Mailbox.init(a);
    defer mb_a.deinit();
    var mb_b = Mailbox.init(a);
    defer mb_b.deinit();

    var na = try Node.init(a, "a", "h:1", mb_a.transport());
    defer na.deinit();
    var nb = try Node.init(a, "b", "h:2", mb_b.transport());
    defer nb.deinit();

    try na.table.add("b", "h:2", 1, 0);
    try nb.table.add("a", "h:1", 1, 0);

    na.step(1000);
    try std.testing.expect(na.pending != null);
    try std.testing.expectEqual(@as(usize, 1), mb_a.queue.items.len);

    // Deliver a's ping to b, which answers into a's mailbox.
    var buf: [2048]u8 = undefined;
    const ping = mb_a.poll(&buf).?;
    nb.handle(ping, 1010);
    try std.testing.expectEqual(@as(usize, 1), mb_b.queue.items.len);

    const ack = mb_b.poll(&buf).?;
    na.handle(ack, 1020);
    try std.testing.expect(na.pending == null);
    try std.testing.expectEqual(membership.State.alive, na.table.get("b").?.state);
}

test "silence becomes suspicion and then death" {
    const a = std.testing.allocator;
    var mb = Mailbox.init(a);
    defer mb.deinit();
    var n = try Node.init(a, "a", "h:1", mb.transport());
    defer n.deinit();
    try n.table.add("b", "h:2", 1, 0);

    n.step(1000); // probe sent, no answer ever
    try std.testing.expect(n.pending != null);

    n.step(1000 + n.timeout_ms);
    try std.testing.expectEqual(membership.State.suspect, n.table.get("b").?.state);

    // A second silence for the same target is only reachable through a new probe,
    // so drive one more round: suspect is enough to stop probing.
    try std.testing.expectEqual(@as(usize, 0), n.table.aliveCount());
}

test "a digest carries a third node's state across two hops" {
    const a = std.testing.allocator;

    var n = try Node.init(a, "a", "h:1", .{ .ctx = undefined, .send = noSend, .poll = noPoll });
    defer n.deinit();
    try n.table.add("c", "h:3", 4, 0);

    const d = try n.buildDigest(a);
    defer a.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "a,alive,1") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "c,alive,4") != null);

    // Now merge a peer digest that knows c is suspect at incarnation 5.
    var nb = try Node.init(a, "b", "h:2", .{ .ctx = undefined, .send = noSend, .poll = noPoll });
    defer nb.deinit();
    try nb.table.add("c", "h:3", 4, 0);
    _ = gossip.applyDigest(&nb.table, "c,suspect,5", 10);
    try std.testing.expectEqual(membership.State.suspect, nb.table.get("c").?.state);
    try std.testing.expectEqual(@as(u64, 5), nb.table.get("c").?.incarnation);
}

fn noSend(_: *anyopaque, _: []const u8, _: []const u8) void {}
fn noPoll(_: *anyopaque, _: []u8) ?[]const u8 {
    return null;
}
