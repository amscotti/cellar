const std = @import("std");
const zlua = @import("zlua");
/// The raw C API: needed where ziglua's wrappers only accept sentinel strings.
const c = zlua.c;
const vm = @import("vm.zig");
const lua_bindings = @import("lua_bindings.zig");
const stdlib = @import("stdlib.zig");
const Cap = @import("../util/cap.zig").Cap;
const sys = @import("../util/sys.zig");

/// The current invocation's host context, read by the `db.*` bindings. Sound
/// because exactly one cell runs per thread at a time (ADR-0003).
pub threadlocal var tls_ctx: ?*vm.HostCtx = null;

/// Set by the `http.fetch` binding immediately before it yields. A yield with this
/// clear did not come from us — `coroutine.yield({url=...})` in guest code would
/// otherwise park the invocation and make the host perform a request that
/// `--allow-fetch` was supposed to forbid. Threadlocal because the C bindings only
/// have the Lua state, not the backend struct.
pub threadlocal var tls_yield_tag: bool = false;

/// Set when the count hook fires. A guest can `pcall` the deadline error and return
/// normally; without this flag the scheduler would commit its work and answer 200
/// after the deadline, with the runtime believing the invocation succeeded.
pub threadlocal var tls_deadline_hit: bool = false;

/// The VM's underlying allocator, for stdlib calls that need memory which must be
/// freed within the invocation. The request arena never reclaims, so anything parsed
/// or built into it is gone for the rest of the request.
pub threadlocal var tls_gpa: ?std.mem.Allocator = null;

/// Lua 5.4 backend. The only file that touches the Lua C API.
///
/// - Memory: a `Cap` allocator wraps the process allocator with a hard byte
///   ceiling; past it Lua raises a catchable LUA_ERRMEM (proven in the spike).
/// - Preemption: a count hook checks a thread-local deadline and raises a Lua
///   error, so `while true do end` dies at the deadline.
pub const Lua = struct {
    lua: *zlua.Lua,
    cap: *Cap,
    budget: usize,
    /// The coroutine of a suspended invocation, or null. It stays referenced by
    /// the main stack while parked, so the GC cannot collect it.
    parked: ?*zlua.Lua = null,

    threadlocal var hook_deadline_ns: i64 = 0;

    pub const caps: vm.Vm.Caps = .{ .preempt = true, .hard_mem_limit = true, .catchable_oom = true };

    pub fn create(gpa: std.mem.Allocator, budget_bytes: usize) !vm.Vm {
        const self = try gpa.create(Lua);
        errdefer gpa.destroy(self);
        const cap = try gpa.create(Cap);
        errdefer gpa.destroy(cap);
        cap.* = .{ .child = gpa, .limit = budget_bytes };
        const lua = try zlua.Lua.init(cap.allocator());
        errdefer lua.deinit();
        // Curated subset: no io/os/package/debug. Sandboxing and cold-start win.
        lua.openBase();
        lua.openTable();
        lua.openString();
        lua.openMath();
        lua.openCoroutine();
        lua.openUtf8();
        // Invariant I6: the guest cannot reach the filesystem. openBase registers
        // load/loadfile/dofile, and `loadfile("/proc/self/maps")` leaks host memory
        // into an error string while `dofile` executes host files outright. `load`
        // also accepts binary chunks by default, which is the documented bytecode
        // escape once string.dump exists.
        for ([_][:0]const u8{ "load", "loadfile", "dofile", "collectgarbage" }) |name| {
            lua.pushNil();
            lua.setGlobal(name);
        }
        // Finalizers are the one piece of guest code that runs with `allowhook = 0`:
        // Lua disables the hook around a `__gc` metamethod, so `while true do end` in
        // one pins the shard with no deadline and no way back. The hook cannot fix
        // that, so the door is shut instead — `setmetatable` refuses a `__gc` field.
        // `collectgarbage` is nil'd above so a guest cannot force a collection cycle
        // to reach one either.
        lua.pushFunction(safeSetMetatable);
        lua.setGlobal("setmetatable");
        // The module lookup runs on the main state, outside any coroutine, so it
        // needs a hook of its own: a `__index` metamethod that loops forever would
        // otherwise pin the shard with no deadline. It no-ops when no invocation is
        // in flight (`hook_deadline_ns == 0`).
        lua.setHook(hook, .{ .count = true }, 1000);
        self.* = .{ .lua = lua, .cap = cap, .budget = budget_bytes };
        return .{ .ptr = self, .vtable = &.{ .deinit = vDeinit, .load = vLoad, .call = vCall, .resume_fetch = vResume, .abort = vAbort, .heap_used = vHeapUsed } };
    }

    fn vDeinit(ptr: *anyopaque) void {
        const self: *Lua = @ptrCast(@alignCast(ptr));
        const gpa = self.cap.child;
        self.lua.deinit();
        const cap = self.cap;
        gpa.destroy(cap);
        gpa.destroy(self);
    }

    fn vLoad(ptr: *anyopaque, ctx: *vm.HostCtx, src: []const u8, name: []const u8) !void {
        _ = name;
        const self: *Lua = @ptrCast(@alignCast(ptr));
        const zsrc = try toZ(ctx.arena, src);
        // Top-level guest code runs here, outside any invocation. Without a deadline
        // a module whose first line is `while true do end` pins the shard on deploy
        // and again on every cold open.
        hook_deadline_ns = @intCast(ctx.deadline_ns);
        defer hook_deadline_ns = 0;
        try self.lua.loadString(zsrc);
        // A module chunk returns its table of functions; keep it in a global.
        try self.lua.protectedCall(.{ .args = 0, .results = 1 });
        self.lua.setGlobal("__module");
        self.lua.pop(0);
        // Bindings go in after the chunk has run, so top-level guest code cannot
        // reach the database; only functions called inside a transaction can.
        lua_bindings.install(self.lua, ctx);
        stdlib.install(self.lua, ctx);
    }

    fn nowNs() i64 {
        return @intCast(sys.monotonicNs());
    }

    fn noopHook(state: ?*zlua.LuaState, ar: ?*zlua.c.lua_Debug) callconv(.c) void {
        _ = state;
        _ = ar;
    }

    fn hook(state: ?*zlua.LuaState, ar: ?*zlua.c.lua_Debug) callconv(.c) void {
        _ = ar;
        if (hook_deadline_ns != 0 and nowNs() > hook_deadline_ns) {
            tls_deadline_hit = true;
            _ = zlua.c.lua_pushstring(state.?, "deadline exceeded");
            _ = zlua.c.lua_error(state.?);
        }
    }

    /// Pushes `__module[fn]`. Called under `lua_pcall`, because the lookup can hit a
    /// guest `__index` metamethod: an error raised there would otherwise longjmp
    /// with no handler installed and abort the whole process.
    const LookupArg = struct { name: [*]const u8, len: usize };

    fn lookupThunk(L: ?*c.lua_State) callconv(.c) c_int {
        const p = c.lua_touserdata(L, 1) orelse return 0;
        const arg: *LookupArg = @ptrCast(@alignCast(p));
        _ = c.lua_getglobal(L, "__module");
        // `lua_gettable`, not a raw get: a module that builds its table lazily
        // should still work — the pcall is what makes the metamethod safe.
        _ = c.lua_pushlstring(L, arg.name, arg.len);
        _ = c.lua_gettable(L, -2);
        return 1;
    }

    fn vCall(ptr: *anyopaque, ctx: *vm.HostCtx, fn_name: []const u8, body: []const u8, out: *std.ArrayList(u8)) vm.CallResult {
        const self: *Lua = @ptrCast(@alignCast(ptr));

        // Look the function up in the module table, protected: the table is the
        // guest's, and indexing it can run guest code.
        tls_deadline_hit = false;
        tls_yield_tag = false;
        tls_gpa = self.cap.child;
        defer tls_gpa = null;
        var larg = LookupArg{ .name = fn_name.ptr, .len = fn_name.len };
        // ziglua's Lua wraps the state; cast once, explicitly, because @ptrCast
        // cannot infer the destination through a C variadic-ish signature.
        const st: ?*c.lua_State = @ptrCast(self.lua);
        c.lua_pushcclosure(st, lookupThunk, 0);
        _ = c.lua_pushlightuserdata(st, &larg);
        hook_deadline_ns = @intCast(ctx.deadline_ns);
        defer hook_deadline_ns = 0;
        // `lua_pcall` is an inline wrapper that passes an untyped NULL to a
        // function-pointer parameter in this translate-c output; call pcallk.
        const lrc = c.lua_pcallk(st, 1, 1, 0, 0, null);
        if (lrc != c.LUA_OK) {
            const msg = self.lua.toString(-1) catch "module lookup failed";
            self.lua.pop(1);
            if (std.mem.indexOf(u8, msg, "deadline exceeded") != null) return .{ .done = .timeout };
            return .{ .done = .{ .guest_error = ctx.arena.dupe(u8, msg) catch "module lookup failed" } };
        }
        // The thunk already resolved the field (and reported "not found" as nil).
        if (!self.lua.isFunction(-1)) {
            self.lua.pop(1);
            return .{ .done = .{ .guest_error = "function not found" } };
        }
        // [f] -> [f, f] -> [f]: one reference for the coroutine, one to call.
        self.lua.pushValue(-1);
        self.lua.remove(-2);

        // One coroutine per invocation. This is the seam `http.fetch` needs: a
        // yield has somewhere to land only if the guest runs on a coroutine rather
        // than directly on the main state. Today the coroutine is resumed once and
        // never yields, so the observable behaviour is identical to the old
        // protected call — the difference is that `lua_yield` becomes possible.
        const zbody = toZ(ctx.arena, body) catch return .{ .done = .{ .guest_error = "oom" } };
        const co = self.lua.newThread(); // [f, thread]
        self.lua.pushValue(-2); // [f, thread, f]
        self.lua.moveToThread(co, 1); // co: [f]
        _ = co.pushString(zbody); // co: [f, body]
        // Headers as a table, second argument. Names are normalised to lowercase
        // by the server so `headers["stripe-signature"]` works whatever case the
        // sender used.
        c.lua_createtable(@ptrCast(co), 0, @intCast(ctx.headers.len));
        for (ctx.headers) |h| {
            _ = c.lua_pushlstring(@ptrCast(co), h.name.ptr, h.name.len);
            _ = c.lua_pushlstring(@ptrCast(co), h.value.ptr, h.value.len);
            c.lua_settable(@ptrCast(co), -3); // co: [f, body, headers]
        }

        hook_deadline_ns = @intCast(ctx.deadline_ns);
        defer hook_deadline_ns = 0;
        tls_ctx = ctx;
        defer tls_ctx = null;
        co.setHook(hook, .{ .count = true }, 1000);

        const res = co.resumeThread(self.lua, 2);
        if (tls_deadline_hit) {
            tls_deadline_hit = false;
            self.lua.pop(2);
            return .{ .done = .timeout };
        }
        if (res) |r| {
            if (r[0] == .yield) {
                if (!tls_yield_tag) {
                    self.lua.pop(2);
                    return .{ .done = .{ .guest_error = "unexpected yield" } };
                }
                tls_yield_tag = false;
                // The guest suspended on an outbound request. The thread stays
                // referenced by the main stack ([f, thread]); dropping it here
                // would let the GC collect a coroutine we intend to resume.
                const req = self.takeRequest(ctx, co) catch |e| {
                    self.lua.pop(2);
                    return .{ .done = .{ .guest_error = @errorName(e) } };
                };
                self.parked = co;
                return .{ .park = req };
            }
            return self.finish(ctx, co, r[1], out);
        } else |err| {
            const outcome = self.errorOutcome(ctx, co, err);
            self.lua.pop(2);
            return .{ .done = outcome };
        }
    }

    /// Continue a parked invocation. The values pushed on the coroutine become the
    /// results of the `http.fetch(...)` call the guest suspended in.
    fn vResume(ptr: *anyopaque, ctx: *vm.HostCtx, res: vm.FetchRes, out: *std.ArrayList(u8)) vm.CallResult {
        const self: *Lua = @ptrCast(@alignCast(ptr));
        const co = self.parked orelse return .{ .done = .{ .guest_error = "no parked invocation" } };

        tls_gpa = self.cap.child;
        defer tls_gpa = null;
        tls_yield_tag = false;
        co.pushBoolean(res.ok);
        _ = co.pushString(if (res.ok) res.body else res.err);

        hook_deadline_ns = @intCast(ctx.deadline_ns);
        defer hook_deadline_ns = 0;
        tls_ctx = ctx;
        defer tls_ctx = null;
        co.setHook(hook, .{ .count = true }, 1000);

        const r = co.resumeThread(self.lua, 2);
        if (tls_deadline_hit) {
            tls_deadline_hit = false;
            self.parked = null;
            self.lua.pop(2);
            return .{ .done = .timeout };
        }
        if (r) |ok| {
            if (ok[0] == .yield) {
                if (!tls_yield_tag) {
                    self.parked = null;
                    self.lua.pop(2);
                    return .{ .done = .{ .guest_error = "unexpected yield" } };
                }
                tls_yield_tag = false;
                const req = self.takeRequest(ctx, co) catch |e| {
                    self.parked = null;
                    self.lua.pop(2);
                    return .{ .done = .{ .guest_error = @errorName(e) } };
                };
                return .{ .park = req };
            }
            return self.finish(ctx, co, ok[1], out);
        } else |err| {
            const outcome = self.errorOutcome(ctx, co, err);
            self.parked = null;
            self.lua.pop(2);
            return .{ .done = outcome };
        }
    }

    /// Drop a parked invocation without running more guest code. Popping the
    /// thread object makes the coroutine unreachable, so the GC reclaims it and
    /// its stack; there is nothing to unwind because it is not running.
    fn vAbort(ptr: *anyopaque) void {
        const self: *Lua = @ptrCast(@alignCast(ptr));
        if (self.parked == null) return;
        self.lua.pop(2);
        self.parked = null;
    }

    fn finish(self: *Lua, ctx: *vm.HostCtx, co: *zlua.Lua, nres: c_int, out: *std.ArrayList(u8)) vm.CallResult {
        defer {
            self.lua.pop(2);
            self.parked = null;
        }
        if (nres != 1) return .{ .done = .{ .guest_error = "handler must return a string" } };
        const s = co.toString(-1) catch return .{ .done = .{ .guest_error = "handler must return a string" } };
        out.appendSlice(ctx.arena, s) catch return .{ .done = .oom };
        return .{ .done = .ok };
    }

    fn errorOutcome(self: *Lua, ctx: *vm.HostCtx, co: *zlua.Lua, err: anyerror) vm.Outcome {
        _ = self;
        // The error object Lua left on the coroutine's stack is the message.
        const msg = co.toString(-1) catch @errorName(err);
        const dup = ctx.arena.dupe(u8, msg) catch "out of memory reporting error";
        if (std.mem.eql(u8, msg, "not enough memory")) return .oom;
        if (std.mem.indexOf(u8, msg, "deadline exceeded") != null) return .timeout;
        return .{ .guest_error = dup };
    }

    /// Read the request table the guest yielded. Copied into the invocation arena,
    /// which lives until the client gets its response.
    fn takeRequest(self: *Lua, ctx: *vm.HostCtx, co: *zlua.Lua) !vm.FetchReq {
        _ = self;
        const a = ctx.arena;
        // Everything below is the guest's value. Indexing a non-table (or a table
        // with an `__index` metamethod) here runs unprotected C API calls, and an
        // error there longjmps to abort(). Type-check first, then read the fields
        // raw so no guest code can run during the read.
        if (!co.isTable(-1)) return error.NotARequest;
        const L: ?*c.lua_State = @ptrCast(co);
        _ = c.lua_pushlstring(L, "url", 3);
        _ = c.lua_rawget(L, -2);
        const url = try a.dupe(u8, co.toString(-1) catch "");
        co.pop(1);
        _ = c.lua_pushlstring(L, "method", 6);
        _ = c.lua_rawget(L, -2);
        const method = try a.dupe(u8, co.toString(-1) catch "GET");
        co.pop(1);
        _ = c.lua_pushlstring(L, "body", 4);
        _ = c.lua_rawget(L, -2);
        const body = try a.dupe(u8, co.toString(-1) catch "");
        co.pop(1);
        _ = c.lua_pushlstring(L, "timeout_ms", 10);
        _ = c.lua_rawget(L, -2);
        const tmo = co.toInteger(-1) catch 5000;
        co.pop(1);
        if (url.len == 0) return error.UrlRequired;
        return .{
            .method = method,
            .url = url,
            .body = body,
            .timeout_ms = @intCast(@max(@min(tmo, 60000), 1)),
        };
    }

    fn vHeapUsed(ptr: *anyopaque) usize {
        const self: *Lua = @ptrCast(@alignCast(ptr));
        return self.cap.used;
    }
};
/// `setmetatable` with `__gc` removed. Everything else behaves identically:
/// `lua_setmetatable` pops the metatable off the top and sets it on the value at
/// the given index, which is exactly what the stock function does.
fn safeSetMetatable(L: ?*c.lua_State) callconv(.c) c_int {
    if (c.lua_type(L, 1) != c.LUA_TTABLE) {
        _ = c.lua_pushstring(L, "bad argument #1 to 'setmetatable' (table expected)");
        return c.lua_error(L);
    }
    if (c.lua_gettop(L) < 2) _ = c.lua_settop(L, 2);
    // lua_setmetatable does `mt = hvalue(top)` with no type check, so a string
    // passed here would be stored as a Table* and dereferenced on the next
    // metamethod lookup. The stock function raises; this one must too.
    if (c.lua_type(L, 2) != c.LUA_TTABLE and c.lua_type(L, 2) != c.LUA_TNIL) {
        _ = c.lua_pushstring(L, "bad argument #2 to 'setmetatable' (nil or table expected)");
        return c.lua_error(L);
    }
    if (c.lua_type(L, 2) == c.LUA_TTABLE) {
        _ = c.lua_pushstring(L, "__gc");
        _ = c.lua_rawget(L, 2);
        const has_gc = c.lua_type(L, -1) != c.LUA_TNIL;
        c.lua_pop(L, 1);
        if (has_gc) {
            _ = c.lua_pushstring(L, "cellar: __gc is not allowed (finalizers run without the deadline hook)");
            return c.lua_error(L);
        }
    }
    _ = c.lua_settop(L, 2);
    _ = c.lua_setmetatable(L, 1);
    c.lua_pushvalue(L, 1);
    return 1;
}

/// Copies `s` into a sentinel-terminated slice owned by `a`. Zig 0.17 removed
/// `Allocator.dupeZ`, and ziglua's string APIs want `[:0]const u8`.
fn toZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const buf = try a.alloc(u8, s.len + 1);
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}
