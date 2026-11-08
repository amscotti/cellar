const std = @import("std");
const Db = @import("../store/sqlite.zig").Db;

/// Control-plane record of a cell. User data never lives here (ADR-0007).
pub const CellRec = struct {
    key: []const u8,
    module: []const u8 = "default",
    version: u32 = 1,
    blob_sha: []const u8 = "",
    created_at: i64 = 0,
    last_seen: i64 = 0,
};

pub const DeployRec = struct {
    module: []const u8,
    version: u32,
    blob_sha: []const u8,
    created_at: i64 = 0,
};

/// An immutable view of the control plane. Readers hold a pointer to one of
/// these; the writer builds a new one and swaps.
///
/// Readers touch a catalog only while holding `Registry.read_mu`, and the
/// publisher frees the previous catalog under that same lock. That is a reader-
/// writer exclusion rather than a refcount, deliberately: the read paths are
/// short and rare (a dashboard render, a cold start), and a lock is something I
/// can reason about completely at this hour, whereas "free the one from two
/// swaps ago" is a hope.
pub const Catalog = struct {
    cells: []const CellRec = &.{},
    deploys: []const DeployRec = &.{},
    /// One credential per cell that has one. Empty for cells that fall back to the
    /// shared `--cell-token`.
    keys: []const KeyRec = &.{},
};

/// A cell's own credential, stored as a SHA-256 digest so a stolen state.db does
/// not hand over usable tokens. One per cell: rotating replaces it (no overlap
/// yet, which is a planned stage-2 item, not an accident).
pub const KeyRec = struct {
    /// Short public id, so a key can be revoked without ever showing it again.
    id: []const u8,
    cell_key: []const u8,
    digest: [32]u8,
    /// False once revoked. Revoked rows are still published so a cell that has
    /// ever been keyed stays keyed: auth needs to tell "no credential" apart
    /// from "credential revoked", and only the former may use the shared token.
    live: bool = true,
};

const JobKind = union(enum) {
    upsert_cell: CellRec,
    upsert_deploy: DeployRec,
    upsert_key: KeyRec,
    revoke_key: []const u8,
    prune: u32,
    stop: void,
};

const Job = struct {
    kind: JobKind,
    /// Set by the writer after `kind` has been applied and published. `post`
    /// waits on this specific flag, so a poster can never be woken by another
    /// poster's job and return while its own write is still queued.
    done: *std.atomic.Value(bool),
    /// The writer stores the failure here (if any) before setting `done`, so a
    /// caller learns that its write did not land instead of assuming success.
    err_out: *?anyerror,
};

/// Single writer thread owns `state.db`; everything else reads a published
/// `Catalog`. Writes are synchronous from the caller's point of view (rare:
/// cell creation and deploys), reads never block.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db: *Db,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList(Job) = .empty,
    thread: ?std.Thread = null,
    running: bool = true,
    /// Posters inside `post`, so `deinit` can wait for them instead of freeing
    /// the mutex they are parked on.
    active_posters: usize = 0,

    /// Guards every reader's access to a `Catalog` and the publisher's swap.
    /// Held for the duration of a read, not just the pointer load.
    read_mu: std.Io.Mutex = .init,

    current: std.atomic.Value(*const Catalog),
    /// Catalogs replaced by a swap but not yet freed (a reader still holds one).
    retired: std.ArrayList(*const Catalog) = .empty,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) !*Registry {
        const path = try std.fmt.allocPrint(gpa, "{s}/state.db", .{data_dir});
        defer gpa.free(path);
        // 0700 for the directory that holds every secret; 0600 for the file itself as
        // defence in depth (the WAL and shm inherit the file's protection).
        const paths = @import("../store/paths.zig");
        paths.secureDataDir(gpa, io, data_dir);
        const db = try Db.open(gpa, path, 64, 32);
        // Anything that fails after this point (DDL, migration, publish)
        // must not leak the handle and its descriptors.
        errdefer db.close();
        paths.chmodPath(io, path, 0o600);

        db.internal = true;
        try db.exec("CREATE TABLE IF NOT EXISTS cells (id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, module TEXT NOT NULL, version INTEGER NOT NULL, blob_sha TEXT NOT NULL, created_at INTEGER NOT NULL, last_seen INTEGER NOT NULL)");
        try db.exec("CREATE TABLE IF NOT EXISTS deployments (module TEXT NOT NULL, version INTEGER NOT NULL, blob_sha TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (module, version))");
        try db.exec("CREATE TABLE IF NOT EXISTS registry_counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL)");
        // Several credentials per cell, so a key can be rotated with overlap: mint
        // the new one, move the client, revoke the old one. Revoking marks the row
        // rather than deleting it, so the audit trail of "this key existed" survives.
        try db.exec("CREATE TABLE IF NOT EXISTS cell_credentials (id TEXT PRIMARY KEY, cell_key TEXT NOT NULL, digest BLOB NOT NULL, created_at INTEGER NOT NULL, revoked_at INTEGER)");
        db.exec("CREATE INDEX IF NOT EXISTS cell_credentials_cell ON cell_credentials(cell_key)") catch {};
        // Migrate the one-key-per-cell table from the earlier shape, then drop it —
        // in one transaction, so a failed copy leaves cell_keys in place. Dropping
        // the source after a failed copy would destroy the only copy of every
        // credential and quietly downgrade those cells to the shared token.
        //
        // Separate exec calls, not one string: `Db.exec` prepares only the first
        // statement of a multi-statement string (see the storage review).
        // Probe first: "nothing to migrate" is the normal start and must
        // not look like a failed copy on every boot.
        const has_old_table: bool = blk: {
            const n = db.intValue("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='cell_keys'") catch null;
            break :blk (n orelse 0) > 0;
        };
        if (has_old_table) {
            db.exec("BEGIN IMMEDIATE") catch {};
        }
        // Only run the copy if we are actually in a transaction: with busy_timeout=0 a
        // second process on the data dir makes BEGIN fail with BUSY, and the INSERT and
        // DROP would then autocommit separately — leaving the source table next to a
        // duplicate copy, so the next start mints new ids and a revoked key can stay
        // live under one.
        if (db.inTx()) {
            var migrated = false;
            if (db.exec("INSERT OR IGNORE INTO cell_credentials (id,cell_key,digest,created_at) SELECT hex(randomblob(8)),cell_key,digest,created_at FROM cell_keys")) |_| {
                if (db.exec("DROP TABLE cell_keys")) |_| {
                    migrated = true;
                } else |_| {}
            } else |_| {}
            if (migrated) {
                // A COMMIT that fails may already have auto-rolled-back, which would undo
                // the DROP and leave the registry publishing pre-copy (empty) credentials
                // while cell_keys still holds them — an auth downgrade. Refuse to start.
                db.exec("COMMIT") catch return error.MigrationFailed;
            } else {
                db.exec("ROLLBACK") catch {};
            }
            // A COMMIT that failed leaves the transaction open; every later write would
            // join it and never be committed, so refuse to start.
            if (db.inTx()) {
                db.exec("ROLLBACK") catch {};
                if (db.inTx()) return error.MigrationFailed;
            }
        }
        db.internal = false;

        const self = try gpa.create(Registry);
        errdefer gpa.destroy(self);
        const empty = try gpa.create(Catalog);
        errdefer gpa.destroy(empty);
        empty.* = .{};
        self.* = .{ .gpa = gpa, .io = io, .db = db, .current = std.atomic.Value(*const Catalog).init(empty) };
        try self.publishLocked();
        return self;
    }

    pub fn start(self: *Registry) !void {
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Takes the read lock and returns the current snapshot. Every caller must
    /// pair it with `unlock()` once it stops touching the catalog; the publisher
    /// frees the previous snapshot under this same lock.
    pub fn lock(self: *Registry) *const Catalog {
        self.read_mu.lockUncancelable(self.io);
        return self.current.load(.acquire);
    }

    pub fn unlock(self: *Registry) void {
        self.read_mu.unlock(self.io);
    }

    /// Number of cells the control plane knows about. Short read, own lock.
    pub fn cellCount(self: *Registry) usize {
        _ = self.lock();
        defer self.unlock();
        return self.current.load(.acquire).cells.len;
    }

    pub fn upsertCell(self: *Registry, rec: CellRec) !void {
        try self.post(.{ .upsert_cell = rec });
    }

    pub fn upsertDeploy(self: *Registry, rec: DeployRec) !void {
        try self.post(.{ .upsert_deploy = rec });
    }

    pub fn nextVersion(self: *Registry, module: []const u8) u32 {
        const cat = self.lock();
        defer self.unlock();
        var max: u32 = 0;
        for (cat.deploys) |d| {
            if (std.mem.eql(u8, d.module, module) and d.version > max) max = d.version;
        }
        return max + 1;
    }

    /// Stops the writer thread and releases everything. The registry is
    /// process-lifetime in the server; this exists so tests can be leak-clean.
    pub fn deinit(self: *Registry) void {
        const io = self.io;
        self.mu.lockUncancelable(io);
        self.running = false;
        self.cond.broadcast(io);
        self.mu.unlock(io);
        if (self.thread) |t| t.join();

        // Release anyone still waiting on a job the writer will never reach, or
        // shutdown wedges a caller forever — and do not free the mutex they are
        // parked on until they have all left `post`.
        self.mu.lockUncancelable(io);
        while (true) {
            for (self.queue.items) |job| job.done.store(true, .release);
            self.cond.broadcast(io);
            if (self.active_posters == 0) break;
            self.mu.unlock(io);
            std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
            self.mu.lockUncancelable(io);
        }
        for (self.queue.items) |job| freeKind(self.gpa, &job.kind);
        self.queue.deinit(self.gpa);
        self.mu.unlock(io);

        self.read_mu.lockUncancelable(io);
        for (self.retired.items) |c| freeCatalog(self.gpa, c);
        self.retired.deinit(self.gpa);
        freeCatalog(self.gpa, self.current.load(.acquire));
        self.read_mu.unlock(io);

        self.db.close();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn post(self: *Registry, kind: JobKind) !void {
        const io = self.io;
        const gpa = self.gpa;

        // Without a writer thread this would wait forever, and it is called from
        // a shard thread: one failed spawn would silently wedge a whole shard.
        if (self.thread == null or !self.running) return error.NotRunning;

        // The job outlives the caller's request arena, so it owns its strings.
        // Borrowing them was a use-after-free: the deploy path frees its sha as
        // soon as the call returns, and a shard frees its cell key with the
        // arena.
        const owned = try ownKind(gpa, kind);
        // Ownership moves into the queue at the append below; before that, an error
        // must free the copy. Without the flag this errdefer also ran on a job the
        // writer thread had already applied and freed — a double free, unreachable
        // until a job could report a failure (revoking an unknown key id).
        var queued = false;
        errdefer if (!queued) freeKind(gpa, &owned);

        var done = std.atomic.Value(bool).init(false);
        var err: ?anyerror = null;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.active_posters += 1;
        defer self.active_posters -= 1;
        try self.queue.append(gpa, .{ .kind = owned, .done = &done, .err_out = &err });
        queued = true;
        self.cond.signal(io);
        while (!done.load(.acquire)) self.cond.wait(io, &self.mu) catch {};
        if (err) |e| return e;
    }

    fn loop(self: *Registry) void {
        const io = self.io;
        while (true) {
            self.mu.lockUncancelable(io);
            while (self.queue.items.len == 0 and self.running) {
                self.cond.wait(io, &self.mu) catch {};
            }
            if (!self.running) {
                self.mu.unlock(io);
                return;
            }
            var job = self.queue.orderedRemove(0);
            self.mu.unlock(io);

            self.apply(&job);
            freeKind(self.gpa, &job.kind);

            self.mu.lockUncancelable(io);
            job.done.store(true, .release);
            // Broadcast, not signal: several posters may be waiting and the
            // one that needs this wakeup is not necessarily the one that gets it.
            self.cond.broadcast(io);
            self.mu.unlock(io);
        }
    }

    fn apply(self: *Registry, job: *Job) void {
        switch (job.kind) {
            .stop => {},
            .upsert_cell => |r| {
                self.writeCell(r) catch |e| {
                    job.err_out.* = e;
                    return;
                };
                self.publishLocked() catch |e| {
                    job.err_out.* = e;
                };
            },
            .upsert_deploy => |r| {
                self.writeDeploy(r) catch |e| {
                    job.err_out.* = e;
                    return;
                };
                self.publishLocked() catch |e| {
                    job.err_out.* = e;
                };
            },
            .upsert_key => |r| {
                self.writeKey(r) catch |e| {
                    job.err_out.* = e;
                    return;
                };
                self.publishLocked() catch |e| {
                    job.err_out.* = e;
                };
            },
            .prune => |keep| {
                self.pruneDeployments(keep) catch |e| {
                    job.err_out.* = e;
                    return;
                };
                self.publishLocked() catch |e| {
                    job.err_out.* = e;
                };
            },
            .revoke_key => |id| {
                self.db.internal = true;
                const sql = "UPDATE cell_credentials SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL";
                const stmt = self.db.prepare(sql) catch |e| {
                    self.db.internal = false;
                    job.err_out.* = e;
                    return;
                };
                _ = sqlite_bind_int(stmt, 1, nowS());
                _ = sqlite_bind_text(stmt, 2, id);
                const stepped = step(stmt);
                const changed = self.db.changes();
                // Reset before any further prepare: `keyExists` prepares a
                // second statement, and at the cache cap that could
                // `clearStmts()` and finalize this one underneath us.
                _ = reset(stmt);
                if (stepped != sqlite_done) {
                    job.err_out.* = error.StepFailed;
                } else if (changed == 0) {
                    // Distinguish the two misses: "never issued" is a client error, while
                    // "already revoked" must stay a success so a retry after a dropped
                    // response does not abort a rotation script halfway through.
                    // A failed probe is an internal error, not "never issued".
                    if (self.keyExists(id)) |exists| {
                        job.err_out.* = if (exists) error.AlreadyRevoked else error.NotFound;
                    } else |e| {
                        job.err_out.* = e;
                    }
                }
                self.db.internal = false;
                self.publishLocked() catch |e| {
                    job.err_out.* = e;
                };
            },
        }
    }

    /// True when a credential row with this id exists, revoked or not. Called from the
    /// error path of a revoke, with `db.internal` already set. Errors are
    /// propagated: an unhealthy database must not masquerade as "never issued".
    fn keyExists(self: *Registry, id: []const u8) !bool {
        const stmt = try self.db.prepare("SELECT revoked_at FROM cell_credentials WHERE id = ?");
        defer _ = reset(stmt);
        _ = sqlite_bind_text(stmt, 1, id);
        return switch (step(stmt)) {
            row => true,
            sqlite_done => false,
            else => error.StepFailed,
        };
    }

    fn writeCell(self: *Registry, r: CellRec) !void {
        const gpa = self.gpa;
        const id = std.fmt.bytesToHex(@import("../store/paths.zig").keyId(r.key), .lower);
        // A caller that does not know the cell's module (the hot path only stamps
        // `last_seen`) must not erase what a deploy wrote; empty means "no
        // opinion", not "clear it".
        const sql = "INSERT INTO cells (id,key,module,version,blob_sha,created_at,last_seen) VALUES (?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET module=excluded.module, version=CASE WHEN excluded.version = 0 THEN cells.version ELSE excluded.version END, blob_sha=CASE WHEN excluded.blob_sha = '' THEN cells.blob_sha ELSE excluded.blob_sha END, last_seen=excluded.last_seen";
        self.db.internal = true;
        defer self.db.internal = false;
        const stmt = try self.db.prepare(sql);
        _ = sqlite_bind_text(stmt, 1, &id);
        _ = sqlite_bind_text(stmt, 2, r.key);
        _ = sqlite_bind_text(stmt, 3, r.module);
        _ = sqlite_bind_int(stmt, 4, r.version);
        _ = sqlite_bind_text(stmt, 5, r.blob_sha);
        _ = sqlite_bind_int(stmt, 6, r.created_at);
        _ = sqlite_bind_int(stmt, 7, r.last_seen);
        // Discarding this rc meant a failed INSERT looked like a successful
        // write; the caller was told its cell was recorded when it was not.
        if (step(stmt) != sqlite_done) {
            _ = reset(stmt);
            return error.StepFailed;
        }
        _ = reset(stmt);
        _ = gpa;
    }

    fn writeDeploy(self: *Registry, r: DeployRec) !void {
        const sql = "INSERT INTO deployments (module,version,blob_sha,created_at) VALUES (?,?,?,?) ON CONFLICT(module,version) DO UPDATE SET blob_sha=excluded.blob_sha";
        self.db.internal = true;
        defer self.db.internal = false;
        const stmt = try self.db.prepare(sql);
        _ = sqlite_bind_text(stmt, 1, r.module);
        _ = sqlite_bind_int(stmt, 2, r.version);
        _ = sqlite_bind_text(stmt, 3, r.blob_sha);
        _ = sqlite_bind_int(stmt, 4, r.created_at);
        if (step(stmt) != sqlite_done) {
            _ = reset(stmt);
            return error.StepFailed;
        }
        _ = reset(stmt);
    }

    fn writeKey(self: *Registry, r: KeyRec) !void {
        const sql = "INSERT INTO cell_credentials (id,cell_key,digest,created_at) VALUES (?,?,?,?)";
        self.db.internal = true;
        defer self.db.internal = false;
        const stmt = try self.db.prepare(sql);
        _ = sqlite_bind_text(stmt, 1, r.id);
        _ = sqlite_bind_text(stmt, 2, r.cell_key);
        _ = sqlite_bind_blob(stmt, 3, &r.digest);
        _ = sqlite_bind_int(stmt, 4, nowS());
        if (step(stmt) != sqlite_done) {
            _ = reset(stmt);
            return error.StepFailed;
        }
        _ = reset(stmt);
    }

    /// Set (or replace) a cell's own credential. The digest is computed by the
    /// caller, which is the only place that ever holds the token itself.
    pub fn putKey(self: *Registry, cell_key: []const u8, id: []const u8, digest: [32]u8) !void {
        try self.post(.{ .upsert_key = .{ .id = id, .cell_key = cell_key, .digest = digest } });
    }

    /// Keep only the newest `keep` deployment rows per module. Referenced blobs are
    /// computed by the caller from the published catalog, so pruning here never
    /// decides on its own what a cell still needs.
    fn pruneDeployments(self: *Registry, keep: u32) !void {
        const sql = "DELETE FROM deployments WHERE (module, version) NOT IN (SELECT module, version FROM (SELECT module, version, ROW_NUMBER() OVER (PARTITION BY module ORDER BY version DESC) AS rn FROM deployments) WHERE rn <= ?)";
        self.db.internal = true;
        defer self.db.internal = false;
        const stmt = try self.db.prepare(sql);
        _ = sqlite_bind_int(stmt, 1, keep);
        if (step(stmt) != sqlite_done) {
            _ = reset(stmt);
            return error.StepFailed;
        }
        _ = reset(stmt);
    }

    pub fn prune(self: *Registry, keep: u32) !void {
        try self.post(.{ .prune = keep });
    }

    pub fn revokeKey(self: *Registry, id: []const u8) !void {
        try self.post(.{ .revoke_key = id });
    }

    /// Rebuilds the catalog from the tables and swaps it in. O(cells+deploys),
    /// which is fine at control-plane frequencies.
    fn publishLocked(self: *Registry) !void {
        const gpa = self.gpa;

        var cell_buf = std.ArrayList(CellRec).empty;
        defer cell_buf.deinit(gpa);
        {
            self.db.internal = true;
            defer self.db.internal = false;
            const stmt = try self.db.prepare("SELECT key,module,version,blob_sha,created_at,last_seen FROM cells ORDER BY key");
            while (true) {
                const rc = step(stmt);
                if (rc != row) break;
                try cell_buf.append(gpa, .{
                    .key = try gpa.dupe(u8, col_text(stmt, 0) orelse ""),
                    .module = try gpa.dupe(u8, col_text(stmt, 1) orelse ""),
                    .version = @intCast(col_int(stmt, 2)),
                    .blob_sha = try gpa.dupe(u8, col_text(stmt, 3) orelse ""),
                    .created_at = col_int(stmt, 4),
                    .last_seen = col_int(stmt, 5),
                });
            }
            _ = reset(stmt);
        }

        var key_buf = std.ArrayList(KeyRec).empty;
        defer key_buf.deinit(gpa);
        {
            self.db.internal = true;
            defer self.db.internal = false;
            const stmt = try self.db.prepare("SELECT id,cell_key,digest,(revoked_at IS NULL) FROM cell_credentials ORDER BY cell_key");
            while (true) {
                const rc = step(stmt);
                if (rc != row) break;
                var digest: [32]u8 = @splat(0);
                const raw = sqlite.colBlob(stmt, 2) orelse &.{};
                @memcpy(digest[0..@min(raw.len, 32)], raw[0..@min(raw.len, 32)]);
                try key_buf.append(gpa, .{
                    .id = try gpa.dupe(u8, col_text(stmt, 0) orelse ""),
                    .cell_key = try gpa.dupe(u8, col_text(stmt, 1) orelse ""),
                    .digest = digest,
                    .live = col_int(stmt, 3) != 0,
                });
            }
            _ = reset(stmt);
        }

        var dep_buf = std.ArrayList(DeployRec).empty;
        defer dep_buf.deinit(gpa);
        {
            self.db.internal = true;
            defer self.db.internal = false;
            const stmt = try self.db.prepare("SELECT module,version,blob_sha,created_at FROM deployments ORDER BY module,version");
            while (true) {
                const rc = step(stmt);
                if (rc != row) break;
                try dep_buf.append(gpa, .{
                    .module = try gpa.dupe(u8, col_text(stmt, 0) orelse ""),
                    .version = @intCast(col_int(stmt, 1)),
                    .blob_sha = try gpa.dupe(u8, col_text(stmt, 2) orelse ""),
                    .created_at = col_int(stmt, 3),
                });
            }
            _ = reset(stmt);
        }

        const next = try gpa.create(Catalog);
        next.* = .{ .cells = try cell_buf.toOwnedSlice(gpa), .deploys = try dep_buf.toOwnedSlice(gpa), .keys = try key_buf.toOwnedSlice(gpa) };

        // Readers hold `read_mu` for as long as they touch a catalog, and this
        // takes the same lock, so by the time the swap happens no reader is
        // inside a snapshot and everything retired is provably unreachable.
        // (The old scheme freed "the one from two swaps ago" and a single deploy
        // publishes twice, which was enough to free a catalog mid-render.)
        self.read_mu.lockUncancelable(self.io);
        const old = self.current.swap(next, .acq_rel);
        self.retired.append(gpa, old) catch {};
        for (self.retired.items) |c| freeCatalog(gpa, c);
        self.retired.clearRetainingCapacity();
        self.read_mu.unlock(self.io);
    }
};

/// Copies a job's borrowed slices so the job can outlive the caller.
fn ownKind(gpa: std.mem.Allocator, kind: JobKind) !JobKind {
    return switch (kind) {
        .upsert_key => |r| .{ .upsert_key = .{
            .id = try gpa.dupe(u8, r.id),
            .cell_key = try gpa.dupe(u8, r.cell_key),
            .digest = r.digest,
        } },
        .revoke_key => |id| .{ .revoke_key = try gpa.dupe(u8, id) },
        .prune => |keep| .{ .prune = keep },
        .upsert_cell => |r| blk: {
            const key = try gpa.dupe(u8, r.key);
            errdefer gpa.free(key);
            const module = try gpa.dupe(u8, r.module);
            errdefer gpa.free(module);
            const sha = try gpa.dupe(u8, r.blob_sha);
            break :blk .{ .upsert_cell = .{
                .key = key,
                .module = module,
                .version = r.version,
                .blob_sha = sha,
                .created_at = r.created_at,
                .last_seen = r.last_seen,
            } };
        },
        .upsert_deploy => |r| blk: {
            const module = try gpa.dupe(u8, r.module);
            errdefer gpa.free(module);
            const sha = try gpa.dupe(u8, r.blob_sha);
            break :blk .{ .upsert_deploy = .{
                .module = module,
                .version = r.version,
                .blob_sha = sha,
                .created_at = r.created_at,
            } };
        },
        .stop => .{ .stop = {} },
    };
}

fn freeKind(gpa: std.mem.Allocator, kind: *const JobKind) void {
    switch (kind.*) {
        .upsert_cell => |r| {
            gpa.free(r.key);
            gpa.free(r.module);
            gpa.free(r.blob_sha);
        },
        .upsert_deploy => |r| {
            gpa.free(r.module);
            gpa.free(r.blob_sha);
        },
        .upsert_key => |r| {
            gpa.free(r.id);
            gpa.free(r.cell_key);
        },
        .revoke_key => |id| gpa.free(id),
        .prune => {},
        .stop => {},
    }
}

fn freeCatalog(gpa: std.mem.Allocator, c: *const Catalog) void {
    for (c.cells) |x| {
        gpa.free(x.key);
        gpa.free(x.module);
        gpa.free(x.blob_sha);
    }
    gpa.free(c.cells);
    for (c.deploys) |x| {
        gpa.free(x.module);
        gpa.free(x.blob_sha);
    }
    gpa.free(c.deploys);
    for (c.keys) |x| {
        gpa.free(x.id);
        gpa.free(x.cell_key);
    }
    gpa.free(c.keys);
    const ptr: *Catalog = @constCast(c);
    gpa.destroy(ptr);
}

// --- thin sqlite helpers delegating to the store wrapper, so this file never
// imports the C API (I10).
const sqlite = @import("../store/sqlite.zig");
const row = sqlite.SQLITE_ROW;
const sqlite_done = sqlite.SQLITE_DONE;

fn sqlite_bind_text(stmt: anytype, idx: c_int, s: []const u8) c_int {
    return sqlite.bindText(stmt, idx, s);
}
fn sqlite_bind_int(stmt: anytype, idx: c_int, v: anytype) c_int {
    return sqlite.bindInt(stmt, idx, @intCast(v));
}
fn sqlite_bind_blob(stmt: anytype, idx: c_int, bytes: []const u8) c_int {
    return sqlite.sqliteBindBlob(stmt, idx, bytes);
}
/// Wall clock seconds.
fn nowS() i64 {
    return @import("../util/sys.zig").realtimeSec();
}
fn step(stmt: anytype) c_int {
    return sqlite.step(stmt);
}
fn reset(stmt: anytype) c_int {
    return sqlite.reset(stmt);
}
fn col_text(stmt: anytype, i: c_int) ?[]const u8 {
    return sqlite.colText(stmt, i);
}
fn col_int(stmt: anytype, i: c_int) i64 {
    return sqlite.colInt(stmt, i);
}

test "registry upserts and publishes a catalog" {
    const testIo = @import("../util/test_io.zig").testIo;
    const io = testIo();
    const dir = "./.regtest";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const reg = try Registry.open(std.testing.allocator, io, dir);
    try reg.start();

    try std.testing.expectEqual(@as(usize, 0), reg.cellCount());

    try reg.upsertCell(.{ .key = "room-42", .module = "chat", .version = 1 });
    try std.testing.expectEqual(@as(usize, 1), reg.cellCount());
    {
        const cat = reg.lock();
        defer reg.unlock();
        try std.testing.expectEqualStrings("room-42", cat.cells[0].key);
    }

    // `version = 0` is how a caller says "I do not know which deployment version
    // this is" — a cold open knows the module but not the version, and stamping a
    // default here used to reset a cell's version on every restart.
    try reg.upsertCell(.{ .key = "room-42", .version = 0 });
    {
        const cat = reg.lock();
        defer reg.unlock();
        try std.testing.expectEqual(@as(u32, 1), cat.cells[0].version);
    }

    // A pin *does* carry a version.
    try reg.upsertCell(.{ .key = "room-42", .module = "chat", .version = 2, .blob_sha = "aa" });
    try std.testing.expectEqual(@as(usize, 1), reg.cellCount());
    {
        const cat = reg.lock();
        defer reg.unlock();
        try std.testing.expectEqual(@as(u32, 2), cat.cells[0].version);
    }

    try std.testing.expectEqual(@as(u32, 1), reg.nextVersion("chat"));
    try reg.upsertDeploy(.{ .module = "chat", .version = 1, .blob_sha = "aa" });
    try std.testing.expectEqual(@as(u32, 2), reg.nextVersion("chat"));
    {
        const cat = reg.lock();
        defer reg.unlock();
        try std.testing.expectEqual(@as(usize, 1), cat.deploys.len);
    }

    reg.deinit();
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}
