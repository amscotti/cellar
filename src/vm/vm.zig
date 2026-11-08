const std = @import("std");

/// Per-invocation host context. The only thing a backend may touch besides its
/// own state; passed by pointer for the duration of one call.
/// One request header, copied into the invocation arena by the server. Guests get
/// these as a table so a webhook receiver can verify a signature header.
pub const Header = struct { name: []const u8, value: []const u8 };

pub const HostCtx = struct {
    cell_key: []const u8,
    arena: std.mem.Allocator,
    deadline_ns: u64 = 0,
    invocation_id: [8]u8 = @splat(0),
    /// Set by `alarm.set`/`alarm.clear` during an invocation: >0 a due time, <0 a
    /// clear, 0 no change. The shard applies it only after the transaction
    /// commits, so an alarm never outlives a rolled-back invocation.
    alarm_due: i64 = 0,
    /// Bound by the runtime for the duration of an invocation. Null during
    /// module load, which is what keeps top-level guest code away from SQL.
    db: ?*anyopaque = null,
    /// Whether the guest may call `http.fetch`. False until the runtime can park
    /// an invocation; a binding that yields with nobody to resume it would hang
    /// the shard.
    allow_fetch: bool = false,
    /// Request headers, empty for alarms and deploys.
    headers: []const Header = &.{},
};

/// An outbound request a guest yielded. Every slice is owned by the invocation's
/// arena, which outlives the park because the caller is still waiting.
pub const FetchReq = struct {
    method: []const u8,
    url: []const u8,
    body: []const u8,
    timeout_ms: u32,
};

pub const FetchRes = struct {
    ok: bool,
    status: u16 = 0,
    body: []const u8 = "",
    err: []const u8 = "",
};

/// `call` either finishes or suspends. A park is the guest saying "I need the
/// network"; the runtime is then responsible for resuming it on the same thread,
/// with the same transaction still open.
pub const CallResult = union(enum) {
    done: Outcome,
    park: FetchReq,
};

pub const Outcome = union(enum) {
    ok,
    guest_error: []const u8,
    timeout,
    oom,
};

/// The single seam between the runtime and an embedded language (ADR-0002).
/// A new backend implements these four operations plus the caps constant.
pub const Vm = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Caps = struct {
        preempt: bool,
        hard_mem_limit: bool,
        catchable_oom: bool,
    };

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        /// Compile and install `src` as the module this VM runs.
        load: *const fn (ptr: *anyopaque, ctx: *HostCtx, src: []const u8, name: []const u8) anyerror!void,
        /// Call `fn_name(body)`; append the returned string to `out`. Returns a
        /// park instead when the guest suspends on an outbound request.
        call: *const fn (ptr: *anyopaque, ctx: *HostCtx, fn_name: []const u8, body: []const u8, out: *std.ArrayList(u8)) CallResult,
        /// Continue a parked invocation with the result of its request.
        resume_fetch: *const fn (ptr: *anyopaque, ctx: *HostCtx, res: FetchRes, out: *std.ArrayList(u8)) CallResult,
        /// Throw away a parked invocation (deadline, cancelled client). The
        /// coroutine's stack is dropped without running any more guest code.
        abort: *const fn (ptr: *anyopaque) void,
        heap_used: *const fn (ptr: *anyopaque) usize,
    };

    pub fn deinit(self: Vm) void {
        self.vtable.deinit(self.ptr);
    }
    pub fn load(self: Vm, ctx: *HostCtx, src: []const u8, name: []const u8) !void {
        return self.vtable.load(self.ptr, ctx, src, name);
    }
    pub fn call(self: Vm, ctx: *HostCtx, fn_name: []const u8, body: []const u8, out: *std.ArrayList(u8)) CallResult {
        return self.vtable.call(self.ptr, ctx, fn_name, body, out);
    }
    pub fn resumeFetch(self: Vm, ctx: *HostCtx, res: FetchRes, out: *std.ArrayList(u8)) CallResult {
        return self.vtable.resume_fetch(self.ptr, ctx, res, out);
    }
    pub fn abort(self: Vm) void {
        self.vtable.abort(self.ptr);
    }
    pub fn heapUsed(self: Vm) usize {
        return self.vtable.heap_used(self.ptr);
    }
};
