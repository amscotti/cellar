const std = @import("std");
const c = @import("sqlite");

pub const Error = error{
    OpenFailed,
    PrepareFailed,
    StepFailed,
    SqlTooLong,
    StmtCacheFull,
    OutOfMemory,
};

/// Authorizer codes we refuse. Everything else passes. See ADR-0004: the guest
/// may read and write rows, but may not end the invocation transaction, open
/// another database, or change connection-level pragmas.
const denied_actions = [_]c_int{
    c.SQLITE_TRANSACTION,
    // SAVEPOINT is a separate code, and RELEASE commits the transaction when it
    // opened it: leaving it out handed the guest a COMMIT.
    c.SQLITE_SAVEPOINT,
    c.SQLITE_ATTACH,
    c.SQLITE_DETACH,
    c.SQLITE_PRAGMA,
};

/// `sqlite3_progress_handler` callback: non-zero interrupts the running statement.
/// Called every 10 000 VM instructions inside `sqlite3_step`, which is the only
/// place a runaway guest query can be stopped.
fn progress(p: ?*anyopaque) callconv(.c) c_int {
    const raw = p orelse return 0;
    const self: *Db = @ptrCast(@alignCast(raw));
    if (self.deadline_ns == 0) return 0;
    const now: u64 = @import("../util/sys.zig").monotonicNs();
    return if (now > self.deadline_ns) 1 else 0;
}

fn authorizer(
    ud: ?*anyopaque,
    action: c_int,
    p1: ?[*:0]const u8,
    p2: ?[*:0]const u8,
    dbname: ?[*:0]const u8,
    trigger: ?[*:0]const u8,
) callconv(.c) c_int {
    _ = p1;
    _ = p2;
    _ = dbname;
    _ = trigger;
    const db: *Db = @ptrCast(@alignCast(ud.?));
    if (db.internal) return c.SQLITE_OK;
    for (denied_actions) |a| {
        if (action == a) return c.SQLITE_DENY;
    }
    return c.SQLITE_OK;
}

/// Sentinel-terminated copy. `Allocator.dupeZ` was removed in 0.17 and SQLite's
/// C entry points want a NUL-terminated string.
fn toZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const buf = try a.alloc(u8, s.len + 1);
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

pub const Db = struct {
    gpa: std.mem.Allocator,
    h: *c.sqlite3,
    stmts: std.StringHashMap(*c.sqlite3_stmt),
    /// Set while the host itself is issuing SQL (transactions, pragmas) so the
    /// authorizer lets it through.
    internal: bool = false,
    /// Number of guest row loops currently stepping a cached statement. While this
    /// is non-zero the cache must not be cleared: a guest `__gc` finalizer can run
    /// during the loop (every row allocation can trigger a GC step), call back into
    /// db.*, and finalize the statement the outer loop is about to step again.
    step_depth: u32 = 0,
    /// Guest SQL is interrupted once this monotonic deadline passes. Set only while
    /// an invocation is running; sqlite3_step cannot be preempted otherwise (the Lua
    /// count hook never sees it), so one recursive CTE would pin the shard forever.
    deadline_ns: u64 = 0,
    /// Statements to keep cached. Was a literal 64 while `cap` was discarded.
    stmt_cap: usize = 64,

    pub fn open(gpa: std.mem.Allocator, path: []const u8, db_max_mb: u32, cap: usize) !*Db {
        const self = try gpa.create(Db);
        errdefer gpa.destroy(self);
        const zpath = try toZ(gpa, path);
        defer gpa.free(zpath);

        var h: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX;
        if (c.sqlite3_open_v2(zpath.ptr, &h, flags, null) != c.SQLITE_OK) {
            // SQLite returns a handle even on failure; leaving it open leaks its fds.
            if (h) |hh| _ = c.sqlite3_close_v2(hh);
            return Error.OpenFailed;
        }
        self.* = .{ .gpa = gpa, .h = h.?, .stmts = std.StringHashMap(*c.sqlite3_stmt).init(gpa) };
        // Every PRAGMA below can fail — read-only -wal/-shm, a database over the page
        // cap, a full disk. Without this the connection and its fds leak and cellFor
        // retries on every request, so one bad cell exhausts the process fd limit.
        errdefer _ = c.sqlite3_close_v2(h.?);

        self.internal = true;
        defer self.internal = false;
        // Durability and bounded memory. busy_timeout 0 because one connection
        // per cell is never contended by design.
        try self.exec("PRAGMA journal_mode=WAL");
        try self.exec("PRAGMA synchronous=FULL");
        try self.exec("PRAGMA foreign_keys=ON");
        try self.exec("PRAGMA busy_timeout=0");
        try self.exec("PRAGMA cache_size=-8192");
        try self.exec("PRAGMA wal_autocheckpoint=1000");
        if (db_max_mb > 0) {
            const pages = (@as(u64, db_max_mb) * 1024 * 1024) / 4096;
            var buf: [64]u8 = undefined;
            const sql = try std.fmt.bufPrint(&buf, "PRAGMA max_page_count={d}", .{pages});
            try self.exec(sql);
        }
        if (cap > 0) self.stmt_cap = cap;
        _ = c.sqlite3_set_authorizer(h.?, authorizer, self);
        _ = c.sqlite3_progress_handler(h.?, 10_000, progress, self);
        return self;
    }

    pub fn close(self: *Db) void {
        var it = self.stmts.iterator();
        while (it.next()) |e| {
            _ = c.sqlite3_finalize(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.stmts.deinit();
        self.internal = true;
        _ = c.sqlite3_exec(self.h, "PRAGMA wal_checkpoint(TRUNCATE)", null, null, null);
        _ = c.sqlite3_close_v2(self.h);
        self.gpa.destroy(self);
    }

    /// Host-only statement: runs to completion, results discarded.
    pub fn exec(self: *Db, sql: []const u8) !void {
        const zsql = try toZ(self.gpa, sql);
        defer self.gpa.free(zsql);
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.h, zsql.ptr, null, null, &errmsg);
        if (errmsg != null) c.sqlite3_free(errmsg);
        if (rc != c.SQLITE_OK) return Error.StepFailed;
    }

    pub fn prepare(self: *Db, sql: []const u8) !*c.sqlite3_stmt {
        if (self.stmts.get(sql)) |s| {
            // Same text while it is still stepping (re-entered from a finalizer):
            // resetting would truncate the outer result set, so refuse instead.
            if (c.sqlite3_stmt_busy(s) != 0) return Error.StmtCacheFull;
            _ = c.sqlite3_reset(s);
            _ = c.sqlite3_clear_bindings(s);
            return s;
        }
        if (sql.len > 100 * 1024) return Error.SqlTooLong;
        if (self.step_depth == 0 and self.stmts.count() >= self.stmt_cap) {
            // A full cache must not brick the cell. Guests that interpolate
            // values into SQL produce unbounded distinct texts, and the previous
            // behaviour (return an error forever) made such a cell permanently
            // unusable. Dropping the whole cache is crude but bounded, and
            // statements are simply re-prepared on next use.
            self.clearStmts();
        }
        const key = try self.gpa.dupe(u8, sql);
        errdefer self.gpa.free(key);
        const zsql = try toZ(self.gpa, sql);
        defer self.gpa.free(zsql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.h, zsql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK)
            return Error.PrepareFailed;
        // "If the input is an empty string or a comment, *ppStmt is set to NULL"
        // (sqlite3.h). Unwrapping that used to take the whole process down.
        const s = stmt orelse return Error.PrepareFailed;
        try self.stmts.put(key, s);
        return s;
    }

    /// True when `sql` contains more than one statement.
    ///
    /// `prepare` passes `pzTail = null`, so SQLite compiles the first statement and
    /// the rest is silently dropped: a guest writing two inserts got one, a 200, and
    /// an unchanged `changes()` count. Detecting the tail is cheap and lets the
    /// binding refuse instead of half-executing.
    pub fn hasTrailingStatement(self: *Db, sql: []const u8) bool {
        const zsql = toZ(self.gpa, sql) catch return false;
        defer self.gpa.free(zsql);
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        if (c.sqlite3_prepare_v2(self.h, zsql.ptr, @intCast(sql.len), &stmt, &tail) != c.SQLITE_OK)
            return false;
        if (stmt) |s| _ = c.sqlite3_finalize(s);
        const used = @intFromPtr(tail) - @intFromPtr(zsql.ptr);
        if (used >= sql.len) return false;
        return std.mem.trim(u8, sql[used..], " \t\r\n").len > 0;
    }

    /// `exec` with formatting, for the host's own one-off statements.
    pub fn execFmt(self: *Db, comptime fmt: []const u8, args: anytype) !void {
        const sql = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(sql);
        try self.exec(sql);
    }

    /// First column of the first row, or null. Host-only helper: guest SQL goes
    /// through the Lua bindings, which have their own row handling.
    pub fn intValue(self: *Db, sql: []const u8) !?i64 {
        const stmt = try self.prepare(sql);
        defer _ = reset(stmt);
        return switch (step(stmt)) {
            SQLITE_ROW => colInt(stmt, 0),
            SQLITE_DONE => null,
            else => error.StepFailed,
        };
    }

    pub fn begin(self: *Db) !void {
        self.internal = true;
        defer self.internal = false;
        try self.exec("BEGIN IMMEDIATE");
    }
    pub fn commit(self: *Db) !void {
        self.internal = true;
        defer self.internal = false;
        try self.exec("COMMIT");
    }
    /// Test-only: makes the next ROLLBACK a no-op, which leaves the connection in a
    /// transaction exactly as a real IO failure would. Tests need this because the
    /// recovery path cannot be reached any other way.
    pub var fail_rollback: bool = false;

    pub fn rollback(self: *Db) void {
        self.internal = true;
        defer self.internal = false;
        if (@import("builtin").is_test and fail_rollback) {
            fail_rollback = false;
            return;
        }
        self.exec("ROLLBACK") catch {};
    }
    pub fn inTx(self: *Db) bool {
        return c.sqlite3_get_autocommit(self.h) == 0;
    }
    /// Finalizes and forgets every cached statement. Used when the cache is
    /// full, and by `close`.
    fn clearStmts(self: *Db) void {
        var it = self.stmts.iterator();
        while (it.next()) |e| {
            _ = c.sqlite3_finalize(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.stmts.clearRetainingCapacity();
    }
    pub fn resetAll(self: *Db) void {
        var it = self.stmts.valueIterator();
        while (it.next()) |s| {
            _ = c.sqlite3_reset(s.*);
            _ = c.sqlite3_clear_bindings(s.*);
        }
    }
    pub fn changes(self: *Db) i64 {
        return c.sqlite3_changes64(self.h);
    }
    pub fn lastId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.h);
    }
    /// Logical size in bytes: pages × page size. The -wal file is reported
    /// separately by the caller.
    pub fn sizeBytes(self: *Db) u64 {
        var cnt: c_int = 0;
        var sz: c_int = 0;
        var s1: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.h, "PRAGMA page_count", -1, &s1, null) == c.SQLITE_OK) {
            if (c.sqlite3_step(s1.?) == c.SQLITE_ROW) cnt = c.sqlite3_column_int(s1.?, 0);
        }
        if (s1) |s| _ = c.sqlite3_finalize(s);
        var s2: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.h, "PRAGMA page_size", -1, &s2, null) == c.SQLITE_OK) {
            if (c.sqlite3_step(s2.?) == c.SQLITE_ROW) sz = c.sqlite3_column_int(s2.?, 0);
        }
        if (s2) |s| _ = c.sqlite3_finalize(s);
        return @as(u64, @intCast(cnt)) * @as(u64, @intCast(sz));
    }
};

// --- statement helpers used by control-plane code that must not import the C
// API directly (I10 keeps @import("sqlite") inside store/sqlite.zig).

pub const SQLITE_ROW: c_int = c.SQLITE_ROW;
pub const SQLITE_DONE: c_int = c.SQLITE_DONE;

/// `SQLITE_TRANSIENT` is `(destructor)-1`: "SQLite makes its own copy".
/// Zig cannot materialise that sentinel on targets where a function
/// pointer needs alignment (aarch64 rejects the cast at comptime), so
/// spell the semantics out: hand SQLite a malloc'd copy plus a real
/// destructor that frees it. Same contract, one small copy per bind.
fn freeBoundCopy(p: ?*anyopaque) callconv(.c) void {
    std.c.free(p);
}

fn boundCopy(bytes: []const u8) ?[*]const u8 {
    const buf: [*]u8 = @ptrCast(std.c.malloc(@max(bytes.len, 1)) orelse return null);
    if (bytes.len > 0) @memcpy(buf[0..bytes.len], bytes);
    return buf;
}

pub fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, s: []const u8) c_int {
    const copy = boundCopy(s) orelse return c.SQLITE_NOMEM;
    // Ownership transfers on every path: SQLite invokes the destructor
    // even when the bind itself fails (vdbeUnbind/MemSetStr error paths).
    return c.sqlite3_bind_text(stmt, idx, copy, @intCast(s.len), freeBoundCopy);
}

pub fn bindInt(stmt: *c.sqlite3_stmt, idx: c_int, v: i64) c_int {
    return c.sqlite3_bind_int64(stmt, idx, v);
}

pub fn step(stmt: *c.sqlite3_stmt) c_int {
    return c.sqlite3_step(stmt);
}

pub fn reset(stmt: *c.sqlite3_stmt) c_int {
    return c.sqlite3_reset(stmt);
}

pub fn colText(stmt: *c.sqlite3_stmt, i: c_int) ?[]const u8 {
    const p = c.sqlite3_column_text(stmt, i);
    if (p == null) return null;
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, i));
    return p[0..n];
}

pub fn colBlob(stmt: *c.sqlite3_stmt, i: c_int) ?[]const u8 {
    const p = c.sqlite3_column_blob(stmt, i);
    if (p == null) return null;
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, i));
    return @as([*]const u8, @ptrCast(p))[0..n];
}

pub fn sqliteBindBlob(stmt: *c.sqlite3_stmt, i: c_int, bytes: []const u8) c_int {
    const copy = boundCopy(bytes) orelse return c.SQLITE_NOMEM;
    return c.sqlite3_bind_blob(stmt, i, copy, @intCast(bytes.len), freeBoundCopy);
}

pub fn colInt(stmt: *c.sqlite3_stmt, i: c_int) i64 {
    return c.sqlite3_column_int64(stmt, i);
}

test "hasTrailingStatement distinguishes single from multi" {
    const io = @import("../util/test_io.zig").testIo();
    const dir = "./.testdata-sqlite";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const db = try Db.open(std.testing.allocator, "./.testdata-sqlite/t.db", 16, 8);
    defer db.close();
    db.internal = true;
    try db.exec("CREATE TABLE t (id INTEGER)");
    db.internal = false;
    try std.testing.expect(!db.hasTrailingStatement("SELECT 1"));
    try std.testing.expect(!db.hasTrailingStatement("SELECT 1;"));
    try std.testing.expect(db.hasTrailingStatement("SELECT 1; SELECT 2"));
    try std.testing.expect(db.hasTrailingStatement("INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)"));
}

test "bound text is copied at bind time" {
    const io = @import("../util/test_io.zig").testIo();
    const dir = "./.testdata-sqlite";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const db = try Db.open(std.testing.allocator, "./.testdata-sqlite/t.db", 16, 8);
    defer db.close();
    db.internal = true;
    try db.exec("CREATE TABLE t (v TEXT, b BLOB)");
    // Copy semantics: mutating the source after binding must not change
    // what the statement stores.
    var src = [_]u8{ 'a', 'b', 'c' };
    const ins = try db.prepare("INSERT INTO t (v, b) VALUES (?, ?)");
    try std.testing.expectEqual(c.SQLITE_OK, bindText(ins, 1, &src));
    try std.testing.expectEqual(c.SQLITE_OK, sqliteBindBlob(ins, 2, &src));
    src = .{ 'x', 'y', 'z' };
    try std.testing.expectEqual(SQLITE_DONE, step(ins));
    _ = reset(ins);
    // A bind to a nonexistent index fails; SQLite still invokes the
    // destructor, so this must neither leak nor double-free.
    _ = bindText(ins, 99, "nowhere");
    const sel = try db.prepare("SELECT v, b FROM t");
    try std.testing.expectEqual(SQLITE_ROW, step(sel));
    try std.testing.expectEqualStrings("abc", colText(sel, 0).?);
    try std.testing.expectEqualStrings("abc", colBlob(sel, 1).?);
    _ = reset(sel);
    db.internal = false;
}
