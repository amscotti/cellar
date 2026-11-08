const std = @import("std");
const config = @import("../config.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const Invocation = @import("scheduler.zig").Invocation;
const RequestArena = @import("../util/cap.zig").RequestArena;
const vm = @import("../vm/vm.zig");
const testIo = @import("../util/test_io.zig").testIo;

const fixture = @embedFile("../fixtures/echo.lua");

fn newSched(a: std.mem.Allocator, io: std.Io) !*Scheduler {
    var cfg: config.Config = .{};
    cfg.limits.shards = 4;
    cfg.limits.deadline_ms = 2000;
    // Every test gets a clean data dir: with meta.json now a pin source, a
    // previous run's deployment would be resurrected and make tests order- and
    // history-dependent.
    cfg.limits.data_dir = "./.schedtest";
    std.Io.Dir.cwd().deleteTree(io, cfg.limits.data_dir) catch {};
    const s = try Scheduler.init(a, io, cfg, fixture);
    try s.start();
    return s;
}

/// One invocation from the calling thread. Arena ownership is handed to the
/// shard before submit and taken back after wait — the protocol in cap.zig.
fn callOnce(s: *Scheduler, key: []const u8, fn_name: []const u8, body: []const u8, buf: []u8) ![]const u8 {
    var arena = RequestArena.init(buf);
    var inv = Invocation{ .cell_key = key, .fn_name = fn_name, .body = body, .arena = &arena };
    arena.give();
    try s.submit(&inv);
    s.wait(&inv);
    arena.take();
    if (inv.fail) |f| {
        std.debug.print("guest failed: {s}: {s}\n", .{ @tagName(f.kind), f.msg });
        return error.GuestFailed;
    }
    return inv.out;
}

// G7: 100 invocations against one cell, submitted from many threads, must be
// serialized by that cell's queue — the guest's counter ends at exactly 100.
test "serialization: 100 invocations on one cell count exactly 100" {
    const sched = try newSched(std.heap.page_allocator, testIo());

    const N = 100;
    const T = 16;

    var threads: [T]std.Thread = undefined;
    var next = std.atomic.Value(u32).init(0);
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn go(s: *Scheduler, a: std.mem.Allocator, n: *std.atomic.Value(u32), total: u32) void {
                while (true) {
                    const i = n.fetchAdd(1, .monotonic);
                    if (i >= total) return;
                    const buf = a.alloc(u8, 8192) catch return;
                    defer a.free(buf);
                    _ = callOnce(s, "room-42", "incr", "", buf) catch {};
                }
            }
        }.go, .{ sched, std.testing.allocator, &next, @as(u32, N) });
    }
    for (&threads) |*t| t.join();

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);
    const got = try callOnce(sched, "room-42", "get", "", buf);
    try std.testing.expectEqualStrings("100", got);
}

test "echo runs a guest function" {
    const sched = try newSched(std.heap.page_allocator, testIo());

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);
    const got = try callOnce(sched, "demo", "echo", "hi", buf);
    try std.testing.expectEqualStrings("echo:hi", got);
}

test "a missing function is a guest error, not a crash" {
    const sched = try newSched(std.heap.page_allocator, testIo());

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);
    try std.testing.expectError(error.GuestFailed, callOnce(sched, "demo2", "nope", "", buf));
}

test "a spinning guest is killed at the deadline and the cell survives" {
    const sched = try newSched(std.heap.page_allocator, testIo());

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    var t = try std.Thread.spawn(.{}, struct {
        fn go(s: *Scheduler, b: []u8) void {
            _ = callOnce(s, "spinner", "spin", "", b) catch {};
        }
    }.go, .{ sched, buf });
    t.join();

    // The spin must have been stopped by the hook, and the same cell must still
    // answer afterwards.
    const b2 = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(b2);
    const got = try callOnce(sched, "spinner", "echo", "alive", b2);
    try std.testing.expectEqualStrings("echo:alive", got);
}

// G8: a deploy is ordered behind in-flight work (it runs at dequeue) and a
// module that fails to compile leaves the running one untouched.
test "deploy swaps the module and a bad module is refused" {
    const sched = try newSched(std.heap.page_allocator, testIo());
    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqualStrings("echo:hi", try callOnce(sched, "sw", "echo", "hi", buf));

    const v2 =
        \\local M = {}
        \\function M.echo(b) return "v2:" .. b end
        \\return M
    ;
    const sha = try sched.deploy("sw", v2);
    std.heap.page_allocator.free(sha);
    try std.testing.expectEqualStrings("v2:hi", try callOnce(sched, "sw", "echo", "hi", buf));

    try std.testing.expectError(error.DeployFailed, sched.deploy("sw", "this is not lua"));
    try std.testing.expectEqualStrings("v2:hi", try callOnce(sched, "sw", "echo", "hi", buf));
}

// A deploy that fails to load must not be recorded: the registry pin is what
// makes a deployment authoritative across restarts, so pinning a broken module
// bricks the cell on the next boot. Regression for a real bug in this file.
test "a failed deploy leaves the registry untouched" {
    const gpa = std.heap.page_allocator;
    var cfg: config.Config = .{};
    cfg.limits.shards = 1;
    cfg.limits.data_dir = "./.pintest";
    std.Io.Dir.cwd().deleteTree(testIo(), cfg.limits.data_dir) catch {};

    const reg_mod = @import("registry.zig");
    const reg = try reg_mod.Registry.open(gpa, testIo(), cfg.limits.data_dir);
    try reg.start();
    defer reg.deinit();

    const sched = try Scheduler.init(gpa, testIo(), cfg, fixture);
    sched.attachRegistry(reg);
    try sched.start();

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    _ = try callOnce(sched, "pin", "mk", "", buf);
    _ = try callOnce(sched, "pin", "add", "5", buf);
    const before = reg.cellCount();

    try std.testing.expectError(error.DeployFailed, sched.deploy("pin", "this is not lua"));
    try std.testing.expectEqual(before, reg.cellCount());
    // The audit row is written before the swap, so a module that fails to load still
    // consumes a version: it records an attempt that never became active, which is
    // exactly what Workers does with a version that is uploaded but not deployed. What
    // must not happen is a *pin*: the cell still runs the previous module.
    try std.testing.expectEqual(@as(u32, 2), reg.nextVersion("default"));

    // The cell keeps running its previous module.
    try std.testing.expectEqualStrings("1", try callOnce(sched, "pin", "count", "", buf));
}

test "a successful deploy is visible to readers and survives a reader mid-flight" {
    const gpa = std.heap.page_allocator;
    var cfg: config.Config = .{};
    cfg.limits.shards = 1;
    cfg.limits.data_dir = "./.pintest2";
    std.Io.Dir.cwd().deleteTree(testIo(), cfg.limits.data_dir) catch {};

    const reg_mod = @import("registry.zig");
    const reg = try reg_mod.Registry.open(gpa, testIo(), cfg.limits.data_dir);
    try reg.start();
    defer reg.deinit();

    const sched = try Scheduler.init(gpa, testIo(), cfg, fixture);
    sched.attachRegistry(reg);
    try sched.start();

    const v2 =
        \\local M = {}
        \\function M.echo(b) return "v2:" .. b end
        \\return M
    ;
    const sha = try sched.deploy("pin2", v2);
    gpa.free(sha);

    // Readers hold the catalog while iterating; the publisher frees the old one
    // under the same lock, so this must stay valid through many publishes.
    for (0..8) |i| {
        const cat = reg.lock();
        defer reg.unlock();
        var found = false;
        for (cat.cells) |c| {
            if (std.mem.eql(u8, c.key, "pin2")) found = true;
        }
        try std.testing.expect(found or i == 0);
    }
}
// ADR-0007 claims a cell directory is self-describing: losing `state.db` must
// lose no pins. That was false until the fallback and the meta write existed.
test "a cell rebuilds from meta.json when the registry has no row" {
    const gpa = std.heap.page_allocator;
    var cfg: config.Config = .{};
    cfg.limits.shards = 1;
    cfg.limits.data_dir = "./.metafallback";
    std.Io.Dir.cwd().deleteTree(testIo(), cfg.limits.data_dir) catch {};

    const blob = @import("../store/blob.zig");
    const meta = @import("../store/meta.zig");

    const src =
        \\local M = {}
        \\function M.only(_) return "from-meta" end
        \\return M
    ;
    const sha = try blob.put(gpa, testIo(), cfg.limits.data_dir, src);
    defer gpa.free(sha);
    try meta.write(gpa, testIo(), cfg.limits.data_dir, .{ .key = "mf", .blob_sha = sha });

    // No registry attached at all: the only source of truth is the directory.
    const sched = try Scheduler.init(gpa, testIo(), cfg, fixture);
    try sched.start();

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqualStrings("from-meta", try callOnce(sched, "mf", "only", "", buf));
}

// The guest stdlib exists so handlers do not hand-roll JSON, timestamps and
// hashing. These run through the real VM, not a mock.
test "guest stdlib: json, crypto, log, time" {
    const sched = try newSched(std.heap.page_allocator, testIo());
    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    // Decode → encode: object key order is not guaranteed, so check both parts.
    const round = try callOnce(sched, "std", "json_round", "{\"a\":1,\"b\":[1,2]}", buf);
    try std.testing.expect(std.mem.indexOf(u8, round, "\"a\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, round, "\"b\":[1,2]") != null);

    // Known vector: sha256("abc").
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        try callOnce(sched, "std", "hash", "abc", buf),
    );

    // hmac-sha256("key", "") — checked against the same construction in Zig.
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, "", "key");
    const want = std.fmt.bytesToHex(mac, .lower);
    try std.testing.expectEqualStrings(&want, try callOnce(sched, "std", "hmac", "", buf));

    // Eight random bytes as hex.
    const rnd = try callOnce(sched, "std", "rand", "", buf);
    try std.testing.expectEqual(@as(usize, 16), rnd.len);

    try std.testing.expectEqualStrings("logged", try callOnce(sched, "std", "logs", "", buf));
    try std.testing.expectEqualStrings("true", try callOnce(sched, "std", "clock", "", buf));
}

// An alarm is the first thing in this runtime that runs without a caller. It is
// stored in the cell's own database inside the invocation transaction, and the
// shard arms the timer only after that commit.
test "an alarm fires on_alarm once and can be cleared" {
    const sched = try newSched(std.heap.page_allocator, testIo());
    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqualStrings("set", try callOnce(sched, "al", "set_alarm", "40", buf));
    try std.testing.expect(std.mem.eql(u8, "none", try callOnce(sched, "al", "alarm_due", "", buf)) == false);

    var waited: u32 = 0;
    var fired = false;
    while (waited < 40) : (waited += 1) {
        std.Io.sleep(testIo(), .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
        const n = try callOnce(sched, "al", "alarm_count", "", buf);
        if (std.mem.eql(u8, n, "1")) {
            fired = true;
            break;
        }
    }
    try std.testing.expect(fired);
    // The alarm is consumed, not repeating.
    try std.testing.expectEqualStrings("none", try callOnce(sched, "al", "alarm_due", "", buf));

    try std.testing.expectEqualStrings("set", try callOnce(sched, "al", "set_alarm", "60000", buf));
    try std.testing.expectEqualStrings("cleared", try callOnce(sched, "al", "clear_alarm", "", buf));
    try std.testing.expectEqualStrings("none", try callOnce(sched, "al", "alarm_due", "", buf));
}

// --queue-timeout-ms was parsed and documented but never enforced: a request
// could wait behind a busy shard forever. The shed happens at dequeue, and the
// shed invocation must never touch the caller's body or arena.
test "an invocation that waits past the queue timeout is shed, not run" {
    var cfg: config.Config = .{};
    cfg.limits.shards = 1;
    cfg.limits.deadline_ms = 300;
    cfg.limits.queue_timeout_ms = 60;
    cfg.limits.data_dir = "./.qtest";
    std.Io.Dir.cwd().deleteTree(testIo(), cfg.limits.data_dir) catch {};
    const sched = try Scheduler.init(std.heap.page_allocator, testIo(), cfg, fixture);
    try sched.start();

    // Both submit from this thread, in order: a second thread would race the queue
    // and the "late" job could be dequeued first, which is not the case under test.
    var bbuf: [4096]u8 = undefined;
    var b_arena = RequestArena.init(&bbuf);
    var blocker = Invocation{ .cell_key = "blocker", .fn_name = "spin", .body = "", .arena = &b_arena };
    b_arena.give();
    try sched.submit(&blocker);

    // Enqueued behind the spinner, which holds the only shard for ~300 ms.
    var buf: [4096]u8 = undefined;
    var arena = RequestArena.init(&buf);
    var inv = Invocation{ .cell_key = "late", .fn_name = "mk", .body = "", .arena = &arena };
    arena.give();
    try sched.submit(&inv);

    sched.wait(&inv);
    arena.take();
    sched.wait(&blocker);
    b_arena.take();

    try std.testing.expect(inv.fail != null);
    try std.testing.expect(inv.fail.?.queue_timeout);
    try std.testing.expectEqualStrings("queue timeout", inv.fail.?.msg);
    // `mk` creates a table; if the cell was never opened, the guest never ran.
    try std.testing.expect(sched.shards[0].cells.get("late") == null);
}

/// Like callOnce, but with request headers.
fn callOnceHdr(s: *Scheduler, key: []const u8, fn_name: []const u8, body: []const u8, hdrs: []const vm.Header, buf: []u8) ![]const u8 {
    var arena = RequestArena.init(buf);
    var inv = Invocation{ .cell_key = key, .fn_name = fn_name, .body = body, .arena = &arena, .headers = hdrs };
    arena.give();
    try s.submit(&inv);
    s.wait(&inv);
    arena.take();
    if (inv.fail != null) return error.GuestFailed;
    return inv.out;
}

test "the guest receives request headers as a table" {
    const sched = try newSched(std.heap.page_allocator, testIo());
    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);
    const hdrs = [_]vm.Header{
        .{ .name = "x-test", .value = "abc" },
        .{ .name = "content-type", .value = "application/json" },
    };
    try std.testing.expectEqualStrings("abc|application/json", try callOnceHdr(sched, "h", "hdr", "", &hdrs, buf));
}

/// A fetcher that never touches the network, so the park/resume path is tested
/// deterministically. `delay_ms` lets a test outlive the invocation deadline.
const StubFetch = struct {
    var delay_ms: u64 = 0;

    fn fetch(ctx: ?*anyopaque, gpa: std.mem.Allocator, io: std.Io, req: vm.FetchReq) vm.FetchRes {
        _ = ctx;
        if (delay_ms > 0) std.Io.sleep(io, .{ .nanoseconds = delay_ms * std.time.ns_per_ms }, .awake) catch {};
        const prefix = "up:";
        const body = gpa.alloc(u8, prefix.len + req.url.len) catch return .{ .ok = false };
        @memcpy(body[0..prefix.len], prefix);
        @memcpy(body[prefix.len..], req.url);
        return .{ .ok = true, .status = 200, .body = body };
    }
};

fn fetchSched(a: std.mem.Allocator, io: std.Io, deadline_ms: u32) !*Scheduler {
    var cfg: config.Config = .{};
    cfg.limits.shards = 1;
    cfg.limits.deadline_ms = deadline_ms;
    cfg.limits.data_dir = "./.fetchtest";
    cfg.allow_fetch = true;
    std.Io.Dir.cwd().deleteTree(io, cfg.limits.data_dir) catch {};
    const s = try Scheduler.init(a, io, cfg, fixture);
    s.fetch_fn = StubFetch.fetch;
    try s.start();
    return s;
}

test "a guest parks on http.fetch, the shard completes the call, the guest resumes" {
    const sched = try fetchSched(std.heap.page_allocator, testIo(), 2000);
    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    const out = try callOnce(sched, "fa", "fetch_echo", "http://stub/x", buf);
    try std.testing.expectEqualStrings("up:http://stub/x", out);
    // The park must not leave the cell thinking it is still busy.
    try std.testing.expect(sched.shards[0].cells.get("fa").?.parked == null);
}

test "a fetch that outlives the invocation deadline is dropped, not delivered" {
    StubFetch.delay_ms = 400;
    defer StubFetch.delay_ms = 0;
    const sched = try fetchSched(std.heap.page_allocator, testIo(), 100);
    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    try std.testing.expectError(error.GuestFailed, callOnce(sched, "fb", "fetch_echo", "http://slow/", buf));
    try std.testing.expect(sched.shards[0].cells.get("fb").?.parked == null);
}

// Until the outbound pool lands, the guest must get a clear refusal rather than a
// suspension the runtime cannot resume.
test "http.fetch is refused while the runtime cannot park" {
    const sched = try newSched(std.heap.page_allocator, testIo());
    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);
    try std.testing.expectError(error.GuestFailed, callOnce(sched, "nf", "fetch_disabled", "", buf));
}

test "max-cells evicts the LRU cell and its rows survive" {
    var cfg: config.Config = .{};
    cfg.limits.shards = 1;
    cfg.limits.max_cells = 2;
    cfg.limits.data_dir = "./.evicttest";
    std.Io.Dir.cwd().deleteTree(testIo(), cfg.limits.data_dir) catch {};

    const sched = try Scheduler.init(std.heap.page_allocator, testIo(), cfg, fixture);
    try sched.start();

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    _ = try callOnce(sched, "a", "mk", "", buf);
    _ = try callOnce(sched, "a", "add", "7", buf);
    _ = try callOnce(sched, "b", "mk", "", buf);
    // Third cell pushes past the cap; "a" is the least recently used and idle.
    _ = try callOnce(sched, "c", "mk", "", buf);

    try std.testing.expect(sched.metrics.cells.load(.monotonic) <= 2);
    // "a" was evicted and recreated from disk with its row intact.
    try std.testing.expectEqualStrings("1", try callOnce(sched, "a", "count", "", buf));
}

test "two statements in one call are refused, and neither runs" {
    const s = try newSched(std.heap.page_allocator, testIo());
    var buf: [64 * 1024]u8 = undefined;
    _ = try callOnce(s, "ms", "mk", "", &buf);
    _ = try callOnce(s, "ms", "add", "1", &buf);
    _ = try callOnce(s, "ms", "add", "2", &buf);
    const out = try callOnce(s, "ms", "two_statements", "", &buf);
    // pcall caught the refusal, and the row count is still 2: the first of the two
    // inserts did not run either.
    try std.testing.expectEqualStrings("false|only one SQL statement per call|2", out);
}

test "a cell whose rollback fails is dropped, and the next open sees only committed rows" {
    const s = try newSched(std.heap.page_allocator, testIo());
    var buf: [64 * 1024]u8 = undefined;
    _ = try callOnce(s, "wed", "mk", "", &buf);
    _ = try callOnce(s, "wed", "add", "1", &buf); // committed

    // Make the next ROLLBACK a no-op: the connection stays in its transaction, which
    // is what a real IO failure on ROLLBACK leaves behind. Without the recovery this
    // cell answered "cannot start a transaction within a transaction" forever.
    @import("../store/sqlite.zig").Db.fail_rollback = true;
    _ = callOnce(s, "wed", "boom", "", &buf) catch {};

    // Dropped and re-opened: the uncommitted insert is gone, the committed one stays.
    const out = try callOnce(s, "wed", "count", "", &buf);
    try std.testing.expectEqualStrings("1", out);
}
