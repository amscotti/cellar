const std = @import("std");
const zlua = @import("zlua");
const c = zlua.c;
const Lua = zlua.Lua;
const vm = @import("vm.zig");
const lua_mod = @import("lua.zig");
const json_util = @import("../util/json.zig");
const sys = @import("../util/sys.zig");

/// The guest standard library: `json`, `time`, `log`, `crypto`.
///
/// Nothing here can reach the network or the filesystem on purpose — a cell's
/// only state is its database, and the only way out is a response. These four
/// exist because every handler otherwise re-implements them badly: hand-rolled
/// JSON with a `string.format` loop, a timestamp from nowhere, hashing done by
/// concatenating strings.
fn fail(lua: *Lua, msg: []const u8) c_int {
    _ = lua.pushString(msg);
    return c.lua_error(@ptrCast(lua));
}

fn ctxOf(lua: *Lua) ?*vm.HostCtx {
    _ = lua;
    return lua_mod.tls_ctx;
}

// ---------------------------------------------------------------- json.encode

fn encodeValue(a: std.mem.Allocator, out: *std.ArrayList(u8), L: ?*c.lua_State, idx: c_int, depth: u32, null_idx: c_int) !void {
    // Depth-bounded: a self-referential table would otherwise be an infinite
    // recursion inside the guest's own invocation.
    if (depth > 32) return error.TooDeep;
    // A C function is only guaranteed LUA_MINSTACK (20) free slots, and each level
    // of this recursion holds a key and a value off lua_next. Without this, ~10
    // levels of nesting pushes past the stack top into unowned memory.
    if (c.lua_checkstack(L, 4) == 0) return error.TooDeep;
    switch (c.lua_type(L, idx)) {
        c.LUA_TNIL => try out.appendSlice(a, "null"),
        c.LUA_TBOOLEAN => try out.appendSlice(a, if (c.lua_toboolean(L, idx) != 0) "true" else "false"),
        c.LUA_TNUMBER => {
            var buf: [40]u8 = undefined;
            if (c.lua_isinteger(L, idx) != 0) {
                const sv = std.fmt.bufPrint(&buf, "{d}", .{c.lua_tointegerx(L, idx, null)}) catch return error.Encode;
                try out.appendSlice(a, sv);
            } else {
                // JSON has no inf/nan and `{d}` prints them, so a strict parser would
                // reject the whole body. Null is the conventional mapping.
                const v = c.lua_tonumberx(L, idx, null);
                if (!std.math.isFinite(v)) {
                    try out.appendSlice(a, "null");
                } else {
                    const sv = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return error.Encode;
                    try out.appendSlice(a, sv);
                }
            }
        },
        c.LUA_TSTRING => {
            var len: usize = 0;
            const p = c.lua_tolstring(L, idx, &len);
            if (p == null) return error.Encode;
            try out.append(a, '"');
            try json_util.escapeIntoList(a, out, p[0..len]);
            try out.append(a, '"');
        },
        c.LUA_TTABLE => {
            const abs = c.lua_absindex(L, idx);
            // `json.null` is a sentinel table: Lua tables cannot hold nil, so JSON
            // null needs a value that survives a decode/encode round trip.
            if (null_idx != 0 and c.lua_rawequal(L, abs, null_idx) != 0) {
                try out.appendSlice(a, "null");
                return;
            }
            const n = c.lua_rawlen(L, abs);
            var count: usize = 0;
            var all_int = true;
            c.lua_pushnil(L);
            while (c.lua_next(L, abs) != 0) {
                count += 1;
                if (c.lua_type(L, -2) != c.LUA_TNUMBER) all_int = false;
                c.lua_pop(L, 1);
            }
            if (all_int and count == n) {
                try out.append(a, '[');
                var i: usize = 1;
                while (i <= n) : (i += 1) {
                    if (i > 1) try out.append(a, ',');
                    _ = c.lua_rawgeti(L, abs, @intCast(i));
                    try encodeValue(a, out, L, -1, depth + 1, null_idx);
                    c.lua_pop(L, 1);
                }
                try out.append(a, ']');
            } else {
                try out.append(a, '{');
                var first = true;
                c.lua_pushnil(L);
                while (c.lua_next(L, abs) != 0) {
                    // Only string and number keys; a table key silently becomes
                    // "?" rather than corrupting the output.
                    var kbuf: [40]u8 = undefined;
                    var kslice: []const u8 = "?";
                    switch (c.lua_type(L, -2)) {
                        c.LUA_TSTRING => {
                            var klen: usize = 0;
                            const kp = c.lua_tolstring(L, -2, &klen);
                            if (kp != null) kslice = kp[0..klen];
                        },
                        c.LUA_TNUMBER => {
                            kslice = std.fmt.bufPrint(&kbuf, "{d}", .{c.lua_tointegerx(L, -2, null)}) catch "?";
                        },
                        else => {
                            c.lua_pop(L, 1);
                            continue;
                        },
                    }
                    if (!first) try out.append(a, ',');
                    first = false;
                    try out.append(a, '"');
                    try json_util.escapeIntoList(a, out, kslice);
                    try out.appendSlice(a, "\":");
                    try encodeValue(a, out, L, -1, depth + 1, null_idx);
                    c.lua_pop(L, 1);
                }
                try out.append(a, '}');
            }
        },
        // Functions, threads and userdata have no JSON representation; encoding
        // them as null is friendlier than failing the whole call.
        else => try out.appendSlice(a, "null"),
    }
}

fn jsonEncode(L: ?*c.lua_State) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(L.?));
    const ctx = ctxOf(lua) orelse return fail(lua, "no host context");
    if (c.lua_gettop(L) != 1) return fail(lua, "json.encode expects one value");

    _ = lua.getGlobal("json");
    _ = lua.getField(-1, "null");
    const null_idx = c.lua_absindex(L, -1);

    var out = std.ArrayList(u8).empty;
    encodeValue(ctx.arena, &out, L, 1, 0, null_idx) catch |e| return fail(lua, @errorName(e));
    defer out.deinit(ctx.arena);
    c.lua_pop(L, 2); // json, json.null
    // `pushString` wants a sentinel-terminated slice; dynamic strings go through
    // `lua_pushlstring`, which takes a pointer and a length.
    _ = c.lua_pushlstring(L, out.items.ptr, out.items.len);
    return 1;
}

// ---------------------------------------------------------------- json.decode

fn pushJsonValue(lua: *Lua, L: ?*c.lua_State, v: std.json.Value, null_idx: c_int, depth: u32) !void {
    // Same guarantee as json.encode: only LUA_MINSTACK slots are promised, and each
    // level of this recursion pushes one or two values. Deep guest input used to write
    // past the stack top into the thread's allocation.
    if (c.lua_checkstack(L, 4) == 0) return error.TooDeep;
    // checkstack bounds the Lua stack, not the native one: without this a 60k-deep
    // document (120 KB of brackets, inside max_body) recurses until the thread stack
    // runs out.
    if (depth > 64) return error.TooDeep;
    switch (v) {
        .null => c.lua_pushvalue(L, null_idx),
        .bool => |b| c.lua_pushboolean(L, if (b) 1 else 0),
        .integer => |i| c.lua_pushinteger(L, @intCast(i)),
        .float => |f| c.lua_pushnumber(L, @floatCast(f)),
        .number_string => |s| {
            const n = std.fmt.parseFloat(f64, s) catch {
                _ = c.lua_pushlstring(L, s.ptr, s.len);
                return;
            };
            c.lua_pushnumber(L, n);
        },
        .string => |s| _ = c.lua_pushlstring(L, s.ptr, s.len),
        .array => |arr| {
            c.lua_createtable(L, @intCast(arr.items.len), 0);
            for (arr.items, 0..) |item, i| {
                try pushJsonValue(lua, L, item, null_idx, depth + 1);
                c.lua_rawseti(L, -2, @intCast(i + 1));
            }
        },
        .object => |obj| {
            c.lua_createtable(L, 0, @intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |e| {
                // key first, then value: lua_settable(-3) reads the key at -2 and
                // the value at -1, and pushing them the other way round produced
                // `{"1":"a"}` for `{"a":1}`.
                _ = c.lua_pushlstring(L, e.key_ptr.ptr, e.key_ptr.len);
                try pushJsonValue(lua, L, e.value_ptr.*, null_idx, depth + 1);
                c.lua_settable(L, -3);
            }
        },
    }
}

fn jsonDecode(L: ?*c.lua_State) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(L.?));
    const ctx = ctxOf(lua) orelse return fail(lua, "no host context");

    var len: usize = 0;
    const zp = c.luaL_checklstring(L, 1, &len);
    if (zp == null) return fail(lua, "json.decode expects a string");
    const text = zp[0..len];

    // Parsed with its own arena: `parseFromSlice` builds an internal ArenaAllocator
    // over the allocator you give it, and the RequestArena never reclaims, so parsing
    // into ctx.arena permanently spent ~2.8 KB per call until the invocation 500'd.
    const scratch = lua_mod.tls_gpa orelse ctx.arena;
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, text, .{}) catch |e| {
        _ = lua.pushString(@errorName(e));
        _ = c.lua_error(@ptrCast(lua));
        return 0;
    };
    defer parsed.deinit();
    _ = lua.getGlobal("json");
    _ = lua.getField(-1, "null");
    const null_idx = c.lua_absindex(L, -1);
    pushJsonValue(lua, L, parsed.value, null_idx, 0) catch return fail(lua, "json.decode failed");
    // Stack is [body, json, json.null, value]; return the value and nothing else.
    // Popping two (as a first version did) returned `json` itself — the bug showed
    // up as `{"decode":null,"null":null,"encode":null}` coming back from a
    // round-trip.
    c.lua_remove(L, -2);
    c.lua_remove(L, -2);
    c.lua_remove(L, 1);
    return 1;
}

// ---------------------------------------------------------------------- time

fn nowNs() u64 {
    return @intCast(@max(sys.realtimeNs(), 0));
}

fn timeNowMs(L: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(L, @intCast(nowNs() / std.time.ns_per_ms));
    return 1;
}

fn timeNowS(L: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(L, @intCast(nowNs() / std.time.ns_per_s));
    return 1;
}

// ---------------------------------------------------------------------- log

fn logEmit(level: []const u8, L: ?*c.lua_State) c_int {
    var len: usize = 0;
    const zp = c.luaL_checklstring(L, 1, &len);
    const cell = if (lua_mod.tls_ctx) |ctx| ctx.cell_key else "?";
    const msg = if (zp == null) "" else zp[0..len];
    // stderr, not the response: a log line must never corrupt a body.
    std.debug.print("[{s}] cell={s} {s}\n", .{ level, cell, msg });
    c.lua_pushboolean(L, 1);
    return 1;
}

fn logInfo(L: ?*c.lua_State) callconv(.c) c_int {
    return logEmit("info", L);
}
fn logWarn(L: ?*c.lua_State) callconv(.c) c_int {
    return logEmit("warn", L);
}
fn logError(L: ?*c.lua_State) callconv(.c) c_int {
    return logEmit("error", L);
}

// ------------------------------------------------------------------- crypto

fn cryptoSha256(L: ?*c.lua_State) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(L.?));
    var len: usize = 0;
    const zp = c.luaL_checklstring(L, 1, &len);
    if (zp == null) return fail(lua, "crypto.sha256 expects a string");

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zp[0..len], &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    _ = lua.pushString(&hex);
    return 1;
}

fn cryptoHmacSha256(L: ?*c.lua_State) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(L.?));
    var klen: usize = 0;
    const kp = c.luaL_checklstring(L, 1, &klen);
    if (kp == null) return fail(lua, "crypto.hmac_sha256(key, msg)");

    var mlen: usize = 0;
    const mp = c.luaL_checklstring(L, 2, &mlen);
    if (mp == null) return fail(lua, "crypto.hmac_sha256(key, msg)");

    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, mp[0..mlen], kp[0..klen]);
    const hex = std.fmt.bytesToHex(mac, .lower);
    _ = lua.pushString(&hex);
    return 1;
}

fn cryptoRandom(L: ?*c.lua_State) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(L.?));
    const n = c.lua_tointegerx(L, 1, null);
    if (n <= 0 or n > 32) return fail(lua, "crypto.random(n) takes 1..32 bytes");

    var buf: [32]u8 = undefined;
    const want: usize = @intCast(n);
    if (!sys.fillRandom(buf[0..want])) return fail(lua, "no entropy");
    // bytesToHex needs a comptime-known length, so hex all 32 and take a prefix.
    const hex = std.fmt.bytesToHex(buf, .lower);
    _ = lua.pushString(hex[0 .. want * 2]);
    return 1;
}

// -------------------------------------------------------------------- install

fn table(lua: *Lua, entries: []const struct { [:0]const u8, *const fn (?*c.lua_State) callconv(.c) c_int }) void {
    lua.createTable(0, @intCast(entries.len));
    for (entries) |e| {
        lua.pushFunction(e[1]);
        lua.setField(-2, e[0]);
    }
}

/// Installed at module load, alongside `db`. `db` itself is bound only for the
/// duration of an invocation; these are pure functions of their arguments plus
/// the host context, so they are safe to expose from the start.
pub fn install(lua: *Lua, ctx: *vm.HostCtx) void {
    _ = ctx;

    table(lua, &.{
        .{ "encode", jsonEncode },
        .{ "decode", jsonDecode },
    });
    // Sentinel for JSON null: Lua tables cannot store nil, so an array containing
    // null would silently lose its length on decode. `json.null` round-trips.
    lua.createTable(0, 0);
    lua.setField(-2, "null");
    lua.setGlobal("json");

    table(lua, &.{
        .{ "now_ms", timeNowMs },
        .{ "now_s", timeNowS },
    });
    lua.setGlobal("time");

    table(lua, &.{
        .{ "info", logInfo },
        .{ "warn", logWarn },
        .{ "error", logError },
    });
    lua.setGlobal("log");

    table(lua, &.{
        .{ "sha256", cryptoSha256 },
        .{ "hmac_sha256", cryptoHmacSha256 },
        .{ "random", cryptoRandom },
    });
    lua.setGlobal("crypto");
}
