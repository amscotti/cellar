const std = @import("std");
const config = @import("../config.zig");
const Scheduler = @import("../runtime/scheduler.zig").Scheduler;
const Invocation = @import("../runtime/scheduler.zig").Invocation;
const RequestArena = @import("../util/cap.zig").RequestArena;
const testIo = @import("../util/test_io.zig").testIo;

const fixture = @embedFile("../fixtures/echo.lua");

fn tmpData() []const u8 {
    return "./.testdata";
}

fn fresh(io: std.Io) !*Scheduler {
    std.Io.Dir.cwd().deleteTree(io, tmpData()) catch {};
    var cfg: config.Config = .{};
    cfg.limits.shards = 2;
    cfg.limits.deadline_ms = 3000;
    cfg.limits.data_dir = tmpData();
    const s = try Scheduler.init(std.heap.page_allocator, io, cfg, fixture);
    try s.start();
    return s;
}

fn call(s: *Scheduler, key: []const u8, fn_name: []const u8, body: []const u8, buf: []u8) ![]const u8 {
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

// G5: two cells running the same module cannot see each other's rows.
test "cells are isolated" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const sched = try fresh(threaded.io());

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqualStrings("ok", try call(sched, "a", "mk", "", buf));
    try std.testing.expectEqualStrings("ok", try call(sched, "b", "mk", "", buf));

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        _ = try call(sched, "a", "add", "10", buf);
        _ = try call(sched, "b", "add", "20", buf);
    }
    try std.testing.expectEqualStrings("3", try call(sched, "a", "count", "", buf));
    try std.testing.expectEqualStrings("3", try call(sched, "b", "count", "", buf));
    try std.testing.expectEqualStrings("10,10,10", try call(sched, "a", "rows", "", buf));
    try std.testing.expectEqualStrings("20,20,20", try call(sched, "b", "rows", "", buf));
}

// G6: a handler that writes and then raises leaves no trace.
test "an invocation is one transaction" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const sched = try fresh(threaded.io());

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    _ = try call(sched, "tx", "mk", "", buf);
    _ = try call(sched, "tx", "add", "1", buf);
    try std.testing.expectEqualStrings("1", try call(sched, "tx", "count", "", buf));
    try std.testing.expectError(error.GuestFailed, call(sched, "tx", "boom", "", buf));
    try std.testing.expectEqualStrings("1", try call(sched, "tx", "count", "", buf));
}

// G14: guest SQL cannot end the transaction, attach another database, or
// change connection pragmas.
test "authorizer refuses commit, attach and pragma" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const sched = try fresh(threaded.io());

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    _ = try call(sched, "auth", "mk", "", buf);
    try std.testing.expectEqualStrings("false", try call(sched, "auth", "try_commit", "", buf));
    try std.testing.expectEqualStrings("false", try call(sched, "auth", "try_attach", "", buf));
    try std.testing.expectEqualStrings("false", try call(sched, "auth", "try_pragma", "", buf));
    // And the transaction is still healthy afterwards.
    _ = try call(sched, "auth", "add", "7", buf);
    try std.testing.expectEqualStrings("1", try call(sched, "auth", "count", "", buf));
}

// G12: writes past --db-max-mb fail as a guest error, roll back, and leave the
// cell readable. A one-megabyte cap makes the failure cheap to reach.
test "database cap fails cleanly" {
    const io = testIo();

    std.Io.Dir.cwd().deleteTree(io, tmpData()) catch {};
    var cfg: config.Config = .{};
    cfg.limits.shards = 1;
    cfg.limits.deadline_ms = 20000;
    cfg.limits.data_dir = tmpData();
    cfg.limits.db_max_mb = 1;
    const sched = try Scheduler.init(std.heap.page_allocator, io, cfg, fixture);
    try sched.start();

    const buf = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqualStrings("ok", try call(sched, "cap", "mkbig", "", buf));
    try std.testing.expectEqualStrings("ok", try call(sched, "cap", "fillbig", "10", buf));
    try std.testing.expectEqualStrings("10", try call(sched, "cap", "countbig", "", buf));

    // 500 × 4 KiB is far past a 1 MiB page cap.
    try std.testing.expectError(error.GuestFailed, call(sched, "cap", "fillbig", "500", buf));

    // The failed transaction rolled back and the cell still answers.
    try std.testing.expectEqualStrings("10", try call(sched, "cap", "countbig", "", buf));
}
