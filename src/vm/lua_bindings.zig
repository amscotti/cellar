const std = @import("std");
const zlua = @import("zlua");
const c = zlua.c;
const Lua = zlua.Lua;
const vm = @import("vm.zig");
const lua_mod = @import("lua.zig");
const sq = @import("sqlite");
const Db = @import("../store/sqlite.zig").Db;

/// Text binds go through the store wrapper, which spells out
/// SQLITE_TRANSIENT's copy semantics portably (see store/sqlite.zig).
const store = @import("../store/sqlite.zig");

const Mode = enum { all, one, value, run };

fn fail(lua: *Lua, msg: []const u8) c_int {
    _ = lua.pushString(msg);
    return c.lua_error(@ptrCast(lua));
}

fn bindOne(L: ?*c.lua_State, stmt: *sq.sqlite3_stmt, idx: c_int, arg: c_int) void {
    switch (c.lua_type(L, arg)) {
        c.LUA_TNIL => _ = sq.sqlite3_bind_null(stmt, idx),
        c.LUA_TBOOLEAN => _ = sq.sqlite3_bind_int(stmt, idx, if (c.lua_toboolean(L, arg) != 0) 1 else 0),
        c.LUA_TNUMBER => {
            if (c.lua_isinteger(L, arg) != 0) {
                _ = sq.sqlite3_bind_int64(stmt, idx, @intCast(c.lua_tointegerx(L, arg, null)));
            } else {
                _ = sq.sqlite3_bind_double(stmt, idx, @floatCast(c.lua_tonumberx(L, arg, null)));
            }
        },
        else => {
            var len: usize = 0;
            const s = c.lua_tolstring(L, arg, &len);
            if (s != null) {
                _ = store.bindText(stmt, idx, s[0..len]);
            } else {
                _ = sq.sqlite3_bind_null(stmt, idx);
            }
        },
    }
}

fn pushColumn(L: ?*c.lua_State, stmt: *sq.sqlite3_stmt, col: c_int) void {
    switch (sq.sqlite3_column_type(stmt, col)) {
        sq.SQLITE_INTEGER => c.lua_pushinteger(L, @intCast(sq.sqlite3_column_int64(stmt, col))),
        sq.SQLITE_FLOAT => c.lua_pushnumber(L, @floatCast(sq.sqlite3_column_double(stmt, col))),
        sq.SQLITE_NULL => c.lua_pushnil(L),
        else => {
            const p = sq.sqlite3_column_text(stmt, col);
            const n: usize = @intCast(sq.sqlite3_column_bytes(stmt, col));
            if (p == null) c.lua_pushnil(L) else _ = c.lua_pushlstring(L, @ptrCast(p), n);
        },
    }
}

fn run(lua: *Lua, mode: Mode) c_int {
    const L: ?*c.lua_State = @ptrCast(lua);
    const ctx = lua_mod.tls_ctx orelse return fail(lua, "no host context");
    const db: *Db = @ptrCast(@alignCast(ctx.db orelse return fail(lua, "no database bound to this cell")));

    var len: usize = 0;
    const zp = c.luaL_checklstring(L, 1, &len);
    if (zp == null) return fail(lua, "sql required");
    const sql = zp[0..len];

    // One statement per call. `prepare` cannot report a tail, so a second statement
    // would be dropped without a word — the guest would see success and one of its
    // two writes would vanish. Refusing is the only answer that cannot lose data.
    if (db.hasTrailingStatement(sql)) return fail(lua, "only one SQL statement per call");
    const stmt = db.prepare(sql) catch |e| return fail(lua, @errorName(e));
    // Guard the cache against re-entry from a guest finalizer while this statement
    // is mid-step (see Db.step_depth).
    db.step_depth += 1;
    defer db.step_depth -= 1;
    db.deadline_ns = ctx.deadline_ns;
    defer db.deadline_ns = 0;

    const nargs = c.lua_gettop(L);
    var i: c_int = 2;
    while (i <= nargs) : (i += 1) bindOne(L, stmt, i - 1, i);

    if (mode == .run) {
        const rc = sq.sqlite3_step(stmt);
        _ = sq.sqlite3_reset(stmt);
        if (rc != sq.SQLITE_DONE and rc != sq.SQLITE_ROW) return fail(lua, "sql failed");
        c.lua_pushinteger(L, @intCast(sq.sqlite3_changes64(db.h)));
        return 1;
    }

    var rows: c_int = 0;
    c.lua_createtable(L, 0, 0);
    const ncols = sq.sqlite3_column_count(stmt);
    while (true) {
        const rc = sq.sqlite3_step(stmt);
        if (rc == sq.SQLITE_ROW) {
            rows += 1;
            if (mode == .value) {
                if (rows == 1) pushColumn(L, stmt, 0);
                continue;
            }
            c.lua_createtable(L, 0, ncols);
            var col: c_int = 0;
            while (col < ncols) : (col += 1) {
                pushColumn(L, stmt, col);
                const name = sq.sqlite3_column_name(stmt, col);
                if (name != null) c.lua_setfield(L, -2, name);
            }
            c.lua_rawseti(L, -2, rows);
            if (mode == .one) break;
        } else if (rc == sq.SQLITE_DONE) {
            break;
        } else {
            _ = sq.sqlite3_reset(stmt);
            return fail(lua, "sql step failed");
        }
    }
    _ = sq.sqlite3_reset(stmt);

    if (mode == .value) {
        if (rows == 0) {
            c.lua_pop(L, 1);
            c.lua_pushnil(L);
        } else {
            // stack: table, value -> keep the value
            c.lua_remove(L, -2);
        }
        return 1;
    }
    if (mode == .one and rows == 0) {
        c.lua_pop(L, 1);
        c.lua_pushnil(L);
        return 1;
    }
    return 1;
}

fn dbAll(L: ?*c.lua_State) callconv(.c) c_int {
    return run(@ptrCast(@alignCast(L.?)), .all);
}
fn dbOne(L: ?*c.lua_State) callconv(.c) c_int {
    return run(@ptrCast(@alignCast(L.?)), .one);
}
fn dbValue(L: ?*c.lua_State) callconv(.c) c_int {
    return run(@ptrCast(@alignCast(L.?)), .value);
}
fn dbRun(L: ?*c.lua_State) callconv(.c) c_int {
    return run(@ptrCast(@alignCast(L.?)), .run);
}

// --------------------------------------------------------------------- alarm

const alarms = @import("../runtime/alarms.zig");

fn bindDb(lua: *Lua) ?*Db {
    const ctx = lua_mod.tls_ctx orelse {
        _ = fail(lua, "no host context");
        return null;
    };
    return @ptrCast(@alignCast(ctx.db orelse {
        _ = fail(lua, "no database bound to this cell");
        return null;
    }));
}

/// `alarm.set(delay_ms)` — wake this cell once in `delay_ms`, calling `on_alarm`.
/// The row is written inside the invocation's transaction; the timer is armed by
/// the shard after the commit succeeds.
fn alarmSet(L: ?*c.lua_State) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(L.?));
    const db = bindDb(lua) orelse return c.lua_error(@ptrCast(lua));
    const ctx = lua_mod.tls_ctx.?;

    const ms = c.lua_tointegerx(L, 1, null);
    if (ms < 0) return fail(lua, "alarm.set(ms) takes a non-negative delay");
    // Ten years. The bound exists because `now + ms` overflows i64 and a panic on
    // the shard thread takes the whole process with it.
    if (ms > 10 * 365 * 24 * 3600 * 1000) return fail(lua, "alarm.set(ms) is too far in the future");
    const due = alarms.nowMs() +| ms;
    alarms.set(db, due) catch |e| return fail(lua, @errorName(e));
    ctx.alarm_due = due;
    c.lua_pushinteger(L, @intCast(due));
    return 1;
}

fn alarmClear(L: ?*c.lua_State) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(L.?));
    const db = bindDb(lua) orelse return c.lua_error(@ptrCast(lua));
    alarms.clear(db);
    lua_mod.tls_ctx.?.alarm_due = -1;
    return 0;
}

/// Due time in ms since the epoch, or nil when no alarm is set.
fn alarmGet(L: ?*c.lua_State) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(L.?));
    const db = bindDb(lua) orelse return c.lua_error(@ptrCast(lua));
    if (alarms.get(db)) |due| {
        c.lua_pushinteger(L, @intCast(due));
    } else {
        c.lua_pushnil(L);
    }
    return 1;
}

/// Installs the `db` table into the guest globals. Called after the module chunk
/// has run, so top-level code cannot touch the database: only functions invoked
/// inside an invocation transaction can (ADR-0004).
pub fn install(lua: *Lua, ctx: *vm.HostCtx) void {
    _ = ctx;
    lua.createTable(0, 4);
    lua.pushFunction(dbAll);
    lua.setField(-2, "exec");
    lua.pushFunction(dbRun);
    lua.setField(-2, "run");
    lua.pushFunction(dbOne);
    lua.setField(-2, "one");
    lua.pushFunction(dbValue);
    lua.setField(-2, "value");
    lua.setGlobal("db");

    lua.createTable(0, 3);
    lua.pushFunction(alarmSet);
    lua.setField(-2, "set");
    lua.pushFunction(alarmClear);
    lua.setField(-2, "clear");
    lua.pushFunction(alarmGet);
    lua.setField(-2, "get");
    lua.setGlobal("alarm");

    lua.createTable(0, 1);
    lua.pushFunction(httpFetch);
    lua.setField(-2, "fetch");
    lua.setGlobal("http");
}

/// `http.fetch(url [, opts])` — suspends the guest until the runtime has a
/// response, then returns `(ok, value)`: the body on success, the error string
/// otherwise.
///
/// The suspension is `lua_yield` without a continuation, so the values passed to
/// the resume become the results of this call. That keeps the guest's Lua code
/// linear — no callbacks, no promises — while the shard thread is free.
fn httpFetch(L: ?*c.lua_State) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(L.?));
    const ctx = lua_mod.tls_ctx orelse return fail(lua, "no host context");
    if (!ctx.allow_fetch) return fail(lua, "outbound network is not enabled");

    var len: usize = 0;
    const url_ptr = c.lua_tolstring(L, 1, &len);
    if (url_ptr == null or len == 0) return fail(lua, "http.fetch(url [, opts]) needs a url");

    c.lua_createtable(L, 0, 4);
    _ = c.lua_pushlstring(L, url_ptr, len);
    c.lua_setfield(L, -2, "url");

    var method: []const u8 = "GET";
    var body: []const u8 = "";
    var tmo: i64 = 5000;
    if (c.lua_istable(L, 2)) {
        _ = c.lua_getfield(L, 2, "method");
        if (c.lua_type(L, -1) == c.LUA_TSTRING) {
            var mlen: usize = 0;
            const mp = c.lua_tolstring(L, -1, &mlen);
            if (mp != null and mlen > 0 and mlen < 16) method = mp[0..mlen];
        }
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, 2, "body");
        if (c.lua_type(L, -1) == c.LUA_TSTRING) {
            var blen: usize = 0;
            const bp = c.lua_tolstring(L, -1, &blen);
            if (bp != null) body = bp[0..blen];
        }
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, 2, "timeout_ms");
        if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
            const v = c.lua_tointegerx(L, -1, null);
            if (v > 0) tmo = v;
        }
        c.lua_pop(L, 1);
    }

    _ = c.lua_pushlstring(L, method.ptr, method.len);
    c.lua_setfield(L, -2, "method");
    _ = c.lua_pushlstring(L, body.ptr, body.len);
    c.lua_setfield(L, -2, "body");
    c.lua_pushinteger(L, tmo);
    c.lua_setfield(L, -2, "timeout_ms");

    lua_mod.tls_yield_tag = true;
    lua.yield(1);
    unreachable;
}
