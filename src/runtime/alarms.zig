const std = @import("std");
const Db = @import("../store/sqlite.zig").Db;
const sys = @import("../util/sys.zig");

/// One alarm per cell, like Durable Objects: a cell stores *when* it wants to be
/// woken, not a list of timers, so re-scheduling is idempotent and there is no
/// way to leak timers.
///
/// The row lives in the cell's own database, inside the invocation's transaction,
/// so an alarm set by an invocation that later fails never exists — the alarm and
/// the state change it belongs to commit together or not at all.
pub const table_sql = "create table if not exists _cellar_alarm (due_ms integer not null)";

pub fn set(db: *Db, due_ms: i64) !void {
    db.internal = true;
    defer db.internal = false;
    try db.exec(table_sql);
    try db.exec("delete from _cellar_alarm");
    try db.execFmt("insert into _cellar_alarm (due_ms) values ({d})", .{due_ms});
}

pub fn clear(db: *Db) void {
    db.internal = true;
    defer db.internal = false;
    db.exec(table_sql) catch return;
    db.exec("delete from _cellar_alarm") catch {};
}

/// Due time, or null when the cell has no alarm.
pub fn get(db: *Db) ?i64 {
    db.internal = true;
    defer db.internal = false;
    db.exec(table_sql) catch return null;
    const v = db.intValue("select due_ms from _cellar_alarm limit 1") catch return null;
    return v;
}

/// Wall clock in milliseconds.
pub fn nowMs() i64 {
    return sys.realtimeMs();
}

/// A single thread that holds every armed alarm and calls `on_fire` when one is
/// due. Polls at 100 ms rather than sleeping on a condvar with a timeout: the
/// timeout variant of `Condition.wait` differs between Zig versions, and 100 ms
/// of slop is irrelevant next to a network round trip.
pub const Timer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mu: std.Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,
    thread: ?std.Thread = null,
    running: bool = true,
    on_fire: *const fn (ctx: *anyopaque, key: []const u8) void,
    ctx: *anyopaque,

    pub const tick_ns: u64 = 100 * std.time.ns_per_ms;

    const Entry = struct { key: []u8, due_ms: i64 };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, ctx: *anyopaque, on_fire: *const fn (*anyopaque, []const u8) void) Timer {
        return .{ .gpa = gpa, .io = io, .ctx = ctx, .on_fire = on_fire };
    }

    pub fn deinit(self: *Timer) void {
        const io = self.io;
        self.mu.lockUncancelable(io);
        self.running = false;
        self.mu.unlock(io);
        if (self.thread) |t| t.join();
        for (self.entries.items) |e| self.gpa.free(e.key);
        self.entries.deinit(self.gpa);
    }

    pub fn start(self: *Timer) !void {
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Arms (or re-arms) a cell's alarm. Later due times replace earlier ones:
    /// there is exactly one alarm per cell.
    pub fn arm(self: *Timer, key: []const u8, due_ms: i64) void {
        const io = self.io;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.due_ms = due_ms;
                return;
            }
        }
        const copy = self.gpa.dupe(u8, key) catch return;
        self.entries.append(self.gpa, .{ .key = copy, .due_ms = due_ms }) catch self.gpa.free(copy);
    }

    pub fn disarm(self: *Timer, key: []const u8) void {
        const io = self.io;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].key, key)) {
                const e = self.entries.orderedRemove(i);
                self.gpa.free(e.key);
                continue;
            }
            i += 1;
        }
    }

    pub fn pending(self: *Timer) usize {
        const io = self.io;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.entries.items.len;
    }

    fn loop(self: *Timer) void {
        const io = self.io;
        while (true) {
            {
                self.mu.lockUncancelable(io);
                if (!self.running) {
                    self.mu.unlock(io);
                    return;
                }
                self.mu.unlock(io);
            }

            std.Io.sleep(io, .{ .nanoseconds = tick_ns }, .awake) catch {};

            const now = nowMs();
            var due: ?[]u8 = null;
            {
                self.mu.lockUncancelable(io);
                var i: usize = 0;
                while (i < self.entries.items.len) {
                    if (self.entries.items[i].due_ms <= now) {
                        const e = self.entries.orderedRemove(i);
                        // Ownership of `e.key` moves to `due`; freeing it here too
                        // was a double free (the `defer` below frees it).
                        due = e.key;
                        break;
                    }
                    i += 1;
                }
                self.mu.unlock(io);
            }
            if (due) |key| {
                defer self.gpa.free(key);
                self.on_fire(self.ctx, key);
            }
        }
    }
};

// ---------------------------------------------------------------- store tests

const testIo = @import("../util/test_io.zig").testIo;

test "an alarm is stored, replaced and cleared" {
    const a = std.testing.allocator;
    const io = testIo();
    const path = "./.alarmtest/db.sqlite";
    std.Io.Dir.cwd().deleteTree(io, "./.alarmtest") catch {};
    std.Io.Dir.cwd().createDirPath(io, "./.alarmtest") catch {};

    const db = try Db.open(a, path, 16, 8);
    defer db.close();

    try std.testing.expect(get(db) == null);
    try set(db, 1000);
    try std.testing.expectEqual(@as(i64, 1000), get(db).?);
    try set(db, 2000); // replaces, does not accumulate
    try std.testing.expectEqual(@as(i64, 2000), get(db).?);

    clear(db);
    try std.testing.expect(get(db) == null);

    std.Io.Dir.cwd().deleteTree(io, "./.alarmtest") catch {};
}

// ---------------------------------------------------------------- timer tests

const FireCount = struct {
    count: u32 = 0,
    last: [64]u8 = undefined,
    last_len: usize = 0,

    fn onFire(ctx: *anyopaque, key: []const u8) void {
        const self: *FireCount = @ptrCast(@alignCast(ctx));
        self.count += 1;
        const n = @min(key.len, self.last.len);
        @memcpy(self.last[0..n], key[0..n]);
        self.last_len = n;
    }
};

test "a due alarm fires once and a disarmed one never fires" {
    const a = std.testing.allocator;
    const io = testIo();

    var fired = FireCount{};
    var t = Timer.init(a, io, &fired, FireCount.onFire);
    try t.start();
    defer t.deinit();

    const now = nowMs();
    t.arm("cell-a", now - 1); // already due
    t.arm("cell-b", now + 60_000); // far future

    // Poll for up to 2 s: the timer ticks at 100 ms.
    var waited: u32 = 0;
    while (fired.count == 0 and waited < 20) : (waited += 1) {
        std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }

    try std.testing.expectEqual(@as(u32, 1), fired.count);
    try std.testing.expectEqualStrings("cell-a", fired.last[0..fired.last_len]);
    try std.testing.expectEqual(@as(usize, 1), t.pending()); // b still armed

    t.disarm("cell-b");
    try std.testing.expectEqual(@as(usize, 0), t.pending());
}
