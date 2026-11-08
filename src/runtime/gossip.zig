const std = @import("std");
const membership = @import("membership.zig");

/// Wire format for the gossip loop, as a pure module.
///
/// The transport is not here on purpose. Encoding, bounds checking and the
/// "apply a peer's digest to my table" step are the parts that break under
/// fuzzing and partitions; a UDP socket is the easy part and can be swapped for
/// anything (UDP, TCP, a test harness) without touching this file.
///
/// Layout (little-endian, explicit lengths, no alignment):
///
///     magic "CGSP" | version u8 | kind u8 | reserved u16
///     incarnation u64 | seq u64
///     id_len   u8   | addr_len u8 | digest_len u16
///     id bytes | addr bytes | digest bytes
///
/// The digest is a `;`-separated list of `id,state,incarnation` entries. It is
/// capped, because an unbounded digest is an unbounded packet and an easy way to
/// make a node allocate its way to death.
pub const magic = [_]u8{ 'C', 'G', 'S', 'P' };
pub const version: u8 = 1;

pub const max_id = 64;
pub const max_addr = 96;
pub const max_digest = 1024;
pub const header_size = 4 + 1 + 1 + 2 + 8 + 8 + 1 + 1 + 2;

pub const Kind = enum(u8) { ping = 1, ack = 2, suspect = 3 };

pub const Msg = struct {
    kind: Kind,
    incarnation: u64,
    seq: u64,
    id: []const u8,
    addr: []const u8,
    digest: []const u8,
};

pub const DecodeError = error{ TooShort, BadMagic, BadVersion, BadKind, Oversize, Truncated };

pub fn encodedLen(m: Msg) usize {
    return header_size + m.id.len + m.addr.len + m.digest.len;
}

pub fn encode(a: std.mem.Allocator, m: Msg) ![]u8 {
    if (m.id.len > max_id or m.addr.len > max_addr or m.digest.len > max_digest) return error.Oversize;
    const out = try a.alloc(u8, encodedLen(m));
    var w: usize = 0;
    @memcpy(out[w..][0..4], &magic);
    w += 4;
    out[w] = version;
    w += 1;
    out[w] = @backingInt(m.kind);
    w += 1;
    w += 2; // reserved
    std.mem.writeInt(u64, out[w..][0..8], m.incarnation, .little);
    w += 8;
    std.mem.writeInt(u64, out[w..][0..8], m.seq, .little);
    w += 8;
    out[w] = @intCast(m.id.len);
    w += 1;
    out[w] = @intCast(m.addr.len);
    w += 1;
    std.mem.writeInt(u16, out[w..][0..2], @intCast(m.digest.len), .little);
    w += 2;
    @memcpy(out[w..][0..m.id.len], m.id);
    w += m.id.len;
    @memcpy(out[w..][0..m.addr.len], m.addr);
    w += m.addr.len;
    @memcpy(out[w..][0..m.digest.len], m.digest);
    return out;
}

/// Decodes into slices of `buf`: no allocation, no copies. A peer cannot make us
/// allocate by sending a large length field, because every length is checked
/// against the bytes that actually arrived.
pub fn decode(buf: []const u8) DecodeError!Msg {
    if (buf.len < header_size) return DecodeError.TooShort;
    if (!std.mem.eql(u8, buf[0..4], &magic)) return DecodeError.BadMagic;
    if (buf[4] != version) return DecodeError.BadVersion;
    const kind: Kind = switch (buf[5]) {
        1 => .ping,
        2 => .ack,
        3 => .suspect,
        else => return DecodeError.BadKind,
    };
    const incarnation = std.mem.readInt(u64, buf[8..16], .little);
    const seq = std.mem.readInt(u64, buf[16..24], .little);
    const id_len = buf[24];
    const addr_len = buf[25];
    const digest_len = std.mem.readInt(u16, buf[26..28], .little);

    if (id_len > max_id or addr_len > max_addr or digest_len > max_digest) return DecodeError.Oversize;
    const need = header_size + @as(usize, id_len) + addr_len + digest_len;
    if (buf.len < need) return DecodeError.Truncated;

    var w: usize = header_size;
    const id = buf[w..][0..id_len];
    w += id_len;
    const addr = buf[w..][0..addr_len];
    w += addr_len;
    const digest = buf[w..][0..digest_len];
    return .{ .kind = kind, .incarnation = incarnation, .seq = seq, .id = id, .addr = addr, .digest = digest };
}

/// One entry of a peer's digest.
pub const Entry = struct {
    id: []const u8,
    state: membership.State,
    incarnation: u64,
};

/// Iterates `id,state,incarnation;id,state,incarnation`. Malformed entries are
/// skipped rather than fatal: one bad peer must not stop us merging the rest.
pub const DigestIter = struct {
    rest: []const u8,

    pub fn next(self: *DigestIter) ?Entry {
        while (self.rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, ';') orelse self.rest.len;
            const item = self.rest[0..end];
            self.rest = if (end == self.rest.len) "" else self.rest[end + 1 ..];
            if (item.len == 0) continue;

            var it = std.mem.splitScalar(u8, item, ',');
            const id = it.next() orelse continue;
            const st = it.next() orelse continue;
            const inc_s = it.next() orelse continue;
            const state: membership.State = if (std.mem.eql(u8, st, "alive"))
                .alive
            else if (std.mem.eql(u8, st, "suspect"))
                .suspect
            else if (std.mem.eql(u8, st, "dead"))
                .dead
            else
                continue;
            const inc = std.fmt.parseInt(u64, inc_s, 10) catch continue;
            return .{ .id = id, .state = state, .incarnation = inc };
        }
        return null;
    }
};

/// Applies every well-formed entry of a peer's digest to `table`.
/// Returns how many changed something, which is a useful gossip metric.
pub fn applyDigest(table: *membership.Table, digest: []const u8, now_ms: u64) usize {
    var it = DigestIter{ .rest = digest };
    var changed: usize = 0;
    while (it.next()) |e| {
        const res = table.apply(.{
            .id = e.id,
            .addr = "", // digests carry identity and state, not addresses
            .incarnation = e.incarnation,
            .state = e.state,
            .now_ms = now_ms,
        });
        if (res == .applied) changed += 1;
    }
    return changed;
}

test "round trip and bounds" {
    const a = std.testing.allocator;
    const m = Msg{
        .kind = .ping,
        .incarnation = 7,
        .seq = 42,
        .id = "node-a",
        .addr = "10.0.0.1:7000",
        .digest = "node-b,alive,3;node-c,suspect,9",
    };
    const bytes = try encode(a, m);
    defer a.free(bytes);

    const got = try decode(bytes);
    try std.testing.expectEqual(Kind.ping, got.kind);
    try std.testing.expectEqual(@as(u64, 7), got.incarnation);
    try std.testing.expectEqual(@as(u64, 42), got.seq);
    try std.testing.expectEqualStrings("node-a", got.id);
    try std.testing.expectEqualStrings("10.0.0.1:7000", got.addr);
    try std.testing.expectEqualStrings(m.digest, got.digest);
}

test "a lying length field cannot make decode read past the buffer" {
    const a = std.testing.allocator;
    const bytes = try encode(a, .{
        .kind = .ack,
        .incarnation = 1,
        .seq = 1,
        .id = "n",
        .addr = "h:1",
        .digest = "",
    });
    defer a.free(bytes);

    // Claim a 500-byte id in a 30-byte packet.
    bytes[24] = 200;
    try std.testing.expectError(DecodeError.Oversize, decode(bytes));

    // Claim a digest that runs past the end.
    bytes[24] = 1;
    std.mem.writeInt(u16, bytes[26..28], 900, .little);
    try std.testing.expectError(DecodeError.Truncated, decode(bytes));
}

test "a truncated or foreign packet is rejected, not decoded" {
    const a = std.testing.allocator;
    const bytes = try encode(a, .{ .kind = .ping, .incarnation = 1, .seq = 1, .id = "n", .addr = "h:1", .digest = "" });
    defer a.free(bytes);

    try std.testing.expectError(DecodeError.TooShort, decode(bytes[0..10]));
    const copy = try a.dupe(u8, bytes);
    defer a.free(copy);
    copy[0] = 'X';
    try std.testing.expectError(DecodeError.BadMagic, decode(copy));
    copy[0] = 'C';
    copy[4] = 99;
    try std.testing.expectError(DecodeError.BadVersion, decode(copy));
    copy[4] = version;
    copy[5] = 77;
    try std.testing.expectError(DecodeError.BadKind, decode(copy));
}

test "a digest merges into the table and skips junk" {
    const a = std.testing.allocator;
    var t = membership.Table.init(a);
    defer t.deinit();
    try t.add("node-a", "h:1", 1, 0);
    try t.add("node-b", "h:2", 1, 0);

    const digest = "node-a,suspect,2;garbage;node-b,dead,5;node-c,alive,1;node-b,alive,4";
    const changed = applyDigest(&t, digest, 100);
    // node-a (suspect @2), node-b (dead @5) change; node-c is unknown; the
    // trailing alive@4 is stale against dead@5.
    try std.testing.expectEqual(@as(usize, 2), changed);
    try std.testing.expectEqual(membership.State.suspect, t.get("node-a").?.state);
    try std.testing.expectEqual(membership.State.dead, t.get("node-b").?.state);
    try std.testing.expectEqual(@as(usize, 2), t.count());
}
