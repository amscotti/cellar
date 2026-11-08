const std = @import("std");
const vm = @import("vm.zig");
const Lua = @import("lua.zig").Lua;
const RequestArena = @import("../util/cap.zig").RequestArena;

/// The suspension protocol, exercised through the real VM. No scheduler here: the
/// test plays the part of the runtime — call, get a park, resume with a response.
const src =
    \\local M = {}
    \\function M.go(_)
    \\  local ok, body = http.fetch("http://example.test/x", { method = "POST", body = "hi", timeout_ms = 250 })
    \\  if not ok then return "err:" .. body end
    \\  return "got:" .. body
    \\end
    \\function M.twice(_)
    \\  local _, a = http.fetch("http://example.test/1")
    \\  local _, b = http.fetch("http://example.test/2")
    \\  return a .. "|" .. b
    \\end
    \\function M.nofetch(_)
    \\  return "plain"
    \\end
    \\return M
;

fn nowNs() u64 {
    return @import("../util/sys.zig").monotonicNs();
}

const Harness = struct {
    arena: RequestArena,
    ctx: vm.HostCtx,
    machine: vm.Vm,

    /// In-place: `RequestArena.allocator()` binds to the arena's own address, so a
    /// Harness returned by value would hand out an allocator pointing at a dead
    /// stack slot. That is exactly the crash this test file hit first.
    fn init(self: *Harness, a: std.mem.Allocator, buf: []u8) !void {
        self.arena = RequestArena.init(buf);
        self.ctx = .{
            .cell_key = "t",
            .arena = self.arena.allocator(),
            .allow_fetch = true,
            .deadline_ns = nowNs() + 10 * std.time.ns_per_s,
        };
        self.machine = try Lua.create(a, 4 * 1024 * 1024);
    }

    fn deinit(self: *Harness) void {
        self.machine.deinit();
    }
};

test "a guest suspends on http.fetch and resumes with the response" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    try h.machine.load(&h.ctx, src, "t");

    // `out` is filled by the VM with the *invocation arena*, which is what the
    // runtime does too — so it must not be deinit'd with the testing allocator.
    var out = std.ArrayList(u8).empty;

    const r1 = h.machine.call(&h.ctx, "go", "", &out);
    switch (r1) {
        .park => |p| {
            try std.testing.expectEqualStrings("http://example.test/x", p.url);
            try std.testing.expectEqualStrings("POST", p.method);
            try std.testing.expectEqualStrings("hi", p.body);
            try std.testing.expectEqual(@as(u32, 250), p.timeout_ms);
        },
        .done => return error.ExpectedPark,
    }

    const r2 = h.machine.resumeFetch(&h.ctx, .{ .ok = true, .status = 200, .body = "hello" }, &out);
    switch (r2) {
        .done => |o| try std.testing.expect(o == .ok),
        .park => return error.ExpectedDone,
    }
    try std.testing.expectEqualStrings("got:hello", out.items);
}

test "a failed fetch is a value the guest can handle, not a crash" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    try h.machine.load(&h.ctx, src, "t");

    // `out` is filled by the VM with the *invocation arena*, which is what the
    // runtime does too — so it must not be deinit'd with the testing allocator.
    var out = std.ArrayList(u8).empty;

    _ = h.machine.call(&h.ctx, "go", "", &out);
    const r = h.machine.resumeFetch(&h.ctx, .{ .ok = false, .err = "connection refused" }, &out);
    switch (r) {
        .done => |o| try std.testing.expect(o == .ok),
        .park => return error.ExpectedDone,
    }
    try std.testing.expectEqualStrings("err:connection refused", out.items);
}

test "a guest can suspend twice in one invocation" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    try h.machine.load(&h.ctx, src, "t");

    // `out` is filled by the VM with the *invocation arena*, which is what the
    // runtime does too — so it must not be deinit'd with the testing allocator.
    var out = std.ArrayList(u8).empty;

    const r1 = h.machine.call(&h.ctx, "twice", "", &out);
    switch (r1) {
        .park => |p| try std.testing.expectEqualStrings("http://example.test/1", p.url),
        .done => return error.ExpectedPark,
    }
    const r2 = h.machine.resumeFetch(&h.ctx, .{ .ok = true, .body = "one" }, &out);
    switch (r2) {
        .park => |p| try std.testing.expectEqualStrings("http://example.test/2", p.url),
        .done => return error.ExpectedPark,
    }
    const r3 = h.machine.resumeFetch(&h.ctx, .{ .ok = true, .body = "two" }, &out);
    switch (r3) {
        .done => |o| try std.testing.expect(o == .ok),
        .park => return error.ExpectedDone,
    }
    try std.testing.expectEqualStrings("one|two", out.items);
}

test "aborting a parked invocation leaves the VM usable" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    try h.machine.load(&h.ctx, src, "t");

    // `out` is filled by the VM with the *invocation arena*, which is what the
    // runtime does too — so it must not be deinit'd with the testing allocator.
    var out = std.ArrayList(u8).empty;

    _ = h.machine.call(&h.ctx, "go", "", &out);
    h.machine.abort();

    var out2 = std.ArrayList(u8).empty;
    const r = h.machine.call(&h.ctx, "nofetch", "", &out2);
    switch (r) {
        .done => |o| try std.testing.expect(o == .ok),
        .park => return error.ExpectedDone,
    }
    try std.testing.expectEqualStrings("plain", out2.items);
}

// ---------------------------------------------------------------- hardening
// One test per attack from the adversarial VM review. Each of these killed the
// process (or escaped the sandbox) before the corresponding fix; they are here so
// it cannot come back.

const hostile_mod =
    \\local M = {}
    \\return setmetatable(M, { __index = function() error("boom from index") end })
;

test "an erroring __index on the module table is a guest error, not an abort" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    try h.machine.load(&h.ctx, hostile_mod, "t");
    var out = std.ArrayList(u8).empty;
    switch (h.machine.call(&h.ctx, "go", "", &out)) {
        .done => |o| switch (o) {
            .guest_error => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "boom from index") != null),
            else => return error.ExpectedGuestError,
        },
        .park => return error.ExpectedDone,
    }
}

const spinning_index =
    \\return setmetatable({}, { __index = function() while true do end end })
;

test "an infinite __index is cut off by the deadline" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    h.ctx.deadline_ns = nowNs() + 200 * std.time.ns_per_ms;
    try h.machine.load(&h.ctx, spinning_index, "t");
    var out = std.ArrayList(u8).empty;
    switch (h.machine.call(&h.ctx, "go", "", &out)) {
        .done => |o| try std.testing.expect(o == .timeout),
        .park => return error.ExpectedDone,
    }
}

const forged_yield =
    \\local M = {}
    \\function M.go(_) coroutine.yield({ url = "http://evil.test/steal" }) return "ran" end
    \\function M.num(_) coroutine.yield(1) return "ran" end
    \\return M
;

test "a yield that did not come from http.fetch is rejected" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    // No outbound network for this cell: a forged yield must not become a park.
    h.ctx.allow_fetch = false;
    try h.machine.load(&h.ctx, forged_yield, "t");
    var out = std.ArrayList(u8).empty;
    switch (h.machine.call(&h.ctx, "go", "", &out)) {
        .done => |o| switch (o) {
            .guest_error => |msg| try std.testing.expectEqualStrings("unexpected yield", msg),
            else => return error.ExpectedGuestError,
        },
        .park => return error.ForgedYieldAccepted,
    }
    switch (h.machine.call(&h.ctx, "num", "", &out)) {
        .done => |o| switch (o) {
            .guest_error => |msg| try std.testing.expectEqualStrings("unexpected yield", msg),
            else => return error.ExpectedGuestError,
        },
        .park => return error.ForgedYieldAccepted,
    }
}

const loaders =
    \\local M = {}
    \\function M.go(_)
    \\  return tostring(load) .. "|" .. tostring(loadfile) .. "|" .. tostring(dofile)
    \\end
    \\return M
;

test "the guest cannot load code from disk" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    try h.machine.load(&h.ctx, loaders, "t");
    var out = std.ArrayList(u8).empty;
    switch (h.machine.call(&h.ctx, "go", "", &out)) {
        .done => |o| try std.testing.expect(o == .ok),
        .park => return error.ExpectedDone,
    }
    try std.testing.expectEqualStrings("nil|nil|nil", out.items);
}

const deep =
    \\local M = {}
    \\function M.go(_)
    \\  local t = {}
    \\  for i = 1, 20 do t = { inner = t } end
    \\  return json.encode(t)
    \\end
    \\return M
;

test "json.encode of a deeply nested table does not overflow the C stack" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 256 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    try h.machine.load(&h.ctx, deep, "t");
    var out = std.ArrayList(u8).empty;
    switch (h.machine.call(&h.ctx, "go", "", &out)) {
        .done => |o| try std.testing.expect(o == .ok),
        .park => return error.ExpectedDone,
    }
    try std.testing.expect(std.mem.indexOf(u8, out.items, "inner") != null);
}

const json_stress =
    \\local M = {}
    \\function M.decode_many(_)
    \\  local n = 0
    \\  for i = 1, 2000 do
    \\    local v = json.decode('{"a":1,"b":[1,2,3],"c":"x"}')
    \\    n = n + v.a
    \\  end
    \\  return "n=" .. n
    \\end
    \\function M.finite(_)
    \\  return json.encode({ x = 0/0, y = math.huge, ok = 1.5 })
    \\end
    \\return M
;

test "json.decode does not spend the request arena" {
    const a = std.testing.allocator;
    // 128 KiB is plenty for the result; 2000 decodes at ~2.8 KB each (the old
    // behaviour: the parse tree allocated from ctx.arena, which never reclaims)
    // would exhaust it long before the loop ended.
    const buf = try a.alloc(u8, 128 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    try h.machine.load(&h.ctx, json_stress, "t");
    var out = std.ArrayList(u8).empty;
    switch (h.machine.call(&h.ctx, "decode_many", "", &out)) {
        .done => |o| try std.testing.expect(o == .ok),
        .park => return error.ExpectedDone,
    }
    try std.testing.expectEqualStrings("n=2000", out.items);
}

test "json.encode maps nan and inf to null instead of emitting invalid JSON" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    try h.machine.load(&h.ctx, json_stress, "t");
    var out = std.ArrayList(u8).empty;
    switch (h.machine.call(&h.ctx, "finite", "", &out)) {
        .done => |o| try std.testing.expect(o == .ok),
        .park => return error.ExpectedDone,
    }
    try std.testing.expect(std.mem.indexOf(u8, out.items, "nan") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "inf") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "null") != null);
}

const finalizers =
    \\local M = {}
    \\function M.no_gc(_)
    \\  local ok, err = pcall(function()
    \\    setmetatable({}, { __gc = function() while true do end end })
    \\  end)
    \\  return tostring(ok) .. "|" .. tostring(err)
    \\end
    \\function M.no_cg(_) return tostring(collectgarbage) end
    \\function M.still_works(_)
    \\  local t = setmetatable({}, { __index = function() return 7 end })
    \\  return tostring(t.missing)
    \\end
    \\return M
;

test "a __gc finalizer is refused, because it would run without the hook" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 * 1024);
    defer a.free(buf);
    var h: Harness = undefined;
    try h.init(a, buf);
    defer h.deinit();
    try h.machine.load(&h.ctx, finalizers, "t");
    var out = std.ArrayList(u8).empty;
    switch (h.machine.call(&h.ctx, "no_gc", "", &out)) {
        .done => |o| try std.testing.expect(o == .ok),
        .park => return error.ExpectedDone,
    }
    try std.testing.expect(std.mem.indexOf(u8, out.items, "false|cellar: __gc is not allowed") != null);

    // collectgarbage is gone too, so a guest cannot force a collection cycle.
    var out2 = std.ArrayList(u8).empty;
    _ = h.machine.call(&h.ctx, "no_cg", "", &out2);
    try std.testing.expectEqualStrings("nil", out2.items);

    // ...and ordinary metatables still behave.
    var out3 = std.ArrayList(u8).empty;
    _ = h.machine.call(&h.ctx, "still_works", "", &out3);
    try std.testing.expectEqualStrings("7", out3.items);
}
