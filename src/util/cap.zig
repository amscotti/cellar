const std = @import("std");

/// A counting allocator with a hard ceiling. This is the only way to bound a
/// foreign allocator user (Lua) from the host: when `used + len` would exceed
/// `limit`, the allocation returns null and Lua raises a catchable LUA_ERRMEM.
/// Proven against Lua 5.4 (the `zlua` backend in `src/vm/lua.zig`).
pub const Cap = struct {
    child: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    peak: usize = 0,
    denied: u64 = 0,

    fn note(self: *Cap, delta: usize) void {
        self.used += delta;
        if (self.used > self.peak) self.peak = self.used;
    }

    fn a(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Cap = @ptrCast(@alignCast(ctx));
        if (self.used + len > self.limit) {
            self.denied += 1;
            return null;
        }
        const p = self.child.vtable.alloc(self.child.ptr, len, alignment, ra) orelse return null;
        self.note(len);
        return p;
    }

    fn r(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Cap = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.used + (new_len - memory.len) > self.limit) {
            self.denied += 1;
            return false;
        }
        if (!self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ra)) return false;
        self.used = self.used - memory.len + new_len;
        if (self.used > self.peak) self.peak = self.used;
        return true;
    }

    fn m(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Cap = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.used + (new_len - memory.len) > self.limit) {
            self.denied += 1;
            return null;
        }
        const p = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ra) orelse return null;
        self.used = self.used - memory.len + new_len;
        if (self.used > self.peak) self.peak = self.used;
        return p;
    }

    fn f(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Cap = @ptrCast(@alignCast(ctx));
        self.used -= memory.len;
        self.child.vtable.free(self.child.ptr, memory, alignment, ra);
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = a, .resize = r, .remap = m, .free = f };

    pub fn allocator(self: *Cap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

threadlocal var marker: u8 = 0;

/// Identity of the calling thread that does not depend on a std API.
pub fn currentThread() usize {
    return @intFromPtr(&marker);
}

/// One buffer per in-flight request, reset after the response is written.
/// Ownership is exclusive: the connection thread owns it, hands it to the shard
/// for the duration of the call, and takes it back before reset. `give`/`take`
/// assert that no two threads hold it at once.
pub const RequestArena = struct {
    buf: []u8,
    fba: std.heap.FixedBufferAllocator,
    owner: usize,

    pub fn init(buf: []u8) RequestArena {
        return .{ .buf = buf, .fba = .init(buf), .owner = currentThread() };
    }

    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        std.debug.assert(self.owner == currentThread());
        return self.fba.allocator();
    }

    pub fn give(self: *RequestArena) void {
        std.debug.assert(self.owner == currentThread());
        self.owner = 0;
    }

    pub fn take(self: *RequestArena) void {
        std.debug.assert(self.owner == 0);
        self.owner = currentThread();
    }

    pub fn reset(self: *RequestArena) void {
        std.debug.assert(self.owner == currentThread());
        self.fba.reset();
    }

    pub fn used(self: *RequestArena) usize {
        return self.fba.end_index;
    }
};

test "cap refuses past the limit and recovers when freed" {
    var cap = Cap{ .child = std.testing.allocator, .limit = 1024 };
    const al = cap.allocator();
    const a = try al.alloc(u8, 512);
    try std.testing.expect(cap.used == 512);
    try std.testing.expectError(error.OutOfMemory, al.alloc(u8, 1024));
    try std.testing.expect(cap.denied == 1);
    al.free(a);
    try std.testing.expect(cap.used == 0);
    const b = try al.alloc(u8, 1000);
    try std.testing.expect(cap.peak == 1000);
    al.free(b);
}

test "request arena hands off between owners" {
    const buf = try std.testing.allocator.alloc(u8, 256);
    defer std.testing.allocator.free(buf);
    var ra = RequestArena.init(buf);
    _ = try ra.allocator().alloc(u8, 64);
    ra.give();
    ra.take();
    try std.testing.expect(ra.used() == 64);
    ra.reset();
    try std.testing.expect(ra.used() == 0);
}
