const std = @import("std");
const config = @import("../config.zig");
const metrics = @import("metrics.zig");
const vm = @import("../vm/vm.zig");
const Lua = @import("../vm/lua.zig").Lua;
const cap = @import("../util/cap.zig");
const Db = @import("../store/sqlite.zig").Db;
const paths = @import("../store/paths.zig");
const meta = @import("../store/meta.zig");
const blob = @import("../store/blob.zig");
const sys = @import("../util/sys.zig");
const fetch_mod = @import("fetch.zig");
const alarms_mod = @import("alarms.zig");
const locator_mod = @import("locator.zig");

pub const Failure = struct {
    kind: metrics.Outcome,
    msg: []const u8,
    /// The invocation never ran: it waited past `--queue-timeout-ms` and was shed
    /// at dequeue. Distinct from `kind == .timeout`, which means the guest ran and
    /// was cut off at its deadline — different cause, different HTTP status.
    queue_timeout: bool = false,
};

/// One request in flight. Completion is signalled with a condition variable and
/// a predicate checked under the same mutex, so a fast shard cannot lose the
/// wakeup (the classic missed-notification bug).
pub const Invocation = struct {
    cell_key: []const u8,
    fn_name: []const u8,
    body: []const u8,
    arena: *cap.RequestArena,
    /// When set, this job installs a new module instead of calling a function.
    /// The shard takes ownership of the bytes and hands them to the cell.
    swap_src: ?[]u8 = null,
    /// Set by a deploy: a cell whose pinned blob cannot be read must still be openable,
    /// or the only writer of the pin fails with the pin's own error and the cell can
    /// never be repaired in band.
    allow_missing_pin: bool = false,

    /// Set at submit time. The shard compares this against its own clock at
    /// dequeue, so shedding a stale job needs no cross-thread flag: the waiter
    /// must stay parked until the shard is done with the invocation anyway, since
    /// the body and the arena belong to the caller.
    /// Set when this job takes a `VACUUM INTO` snapshot of the cell's database
    /// instead of invoking a function. Owned by the caller (the server), not the
    /// shard: unlike `swap_src`, a snapshot path is only read.
    snapshot_path: ?[]u8 = null,
    /// Request headers, owned by the invocation arena. Empty for alarms/deploys.
    headers: []const vm.Header = &.{},
    /// Set at submit time, handed to the guest in HostCtx and echoed in the
    /// response header. Eight random bytes is enough to join a log line to a
    /// request without pretending to be a trace id.
    id: [8]u8 = @splat(0),
    enqueued_ns: u64 = 0,
    queue_deadline_ns: u64 = 0,

    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    done: bool = false,
    out: []const u8 = &.{},
    fail: ?Failure = null,
};

const Cell = struct {
    key: []u8,
    machine: vm.Vm,
    db: *Db,
    /// The exact source this cell is running. Kept so a swap can free the old
    /// one and so `meta.json` can record what is pinned.
    src: []u8,
    version: u32 = 1,
    calls: u64 = 0,
    last_used: u64 = 0,
    /// Set while an invocation is suspended on a fetch. A parked cell is busy:
    /// its next invocation is deferred, never interleaved, because the
    /// transaction is still open (ADR-0024).
    parked: ?Parked = null,

    /// Set when SQLite would not roll back: the next invocation would fail at BEGIN
    /// with "cannot start a transaction within a transaction", so the shard drops the
    /// cell instead and the next open recovers from the WAL.
    wedged: bool = false,
};

/// A suspended invocation. It carries its own `HostCtx` because the one built in
/// `run` lived on the stack, and it is only resumed on the shard that parked it.
const Parked = struct {
    inv: *Invocation,
    /// Monotonic per-shard generation of this park. The invocation pointer alone is
    /// not an identity: it lives on a connection thread's stack, so a retry on the
    /// same keep-alive connection can land at the same address after a reaped
    /// invocation was completed, and a late completion would then resume the wrong
    /// guest (with another request's response).
    gen: u64,
    ctx: vm.HostCtx,
    req: vm.FetchReq,
    t0: u64,
    deadline_ns: u64,
};

/// A fetch result posted back from a pool thread. `key` and `res.body`/`res.err`
/// are owned by the scheduler (gpa) and freed by the shard after use.
const Completion = struct {
    key: []u8,
    inv: *Invocation,
    gen: u64,
    res: vm.FetchRes,
};

const FetchJob = struct {
    shard: *Shard,
    key: []u8,
    inv: *Invocation,
    gen: u64,
    req: vm.FetchReq,
};

pub const QueueFull = error{QueueFull};

const queue_cap = 256;

/// Only used if `getrandom` fails: correlation ids still need to be unique.
var id_fallback = std.atomic.Value(u64).init(0);

const Shard = struct {
    sched: *Scheduler,
    id: usize,
    thread: ?std.Thread = null,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList(*Invocation) = .empty,
    cells: std.StringHashMap(*Cell),
    inflight: u32 = 0,

    /// Invocations waiting because their cell is parked on a fetch. Only touched
    /// by the shard thread.
    deferred: std.ArrayList(*Invocation) = .empty,
    /// Fetch results waiting to be resumed. Posted by pool threads under `mu`.
    completions: std.ArrayList(Completion) = .empty,

    /// Aborts parked invocations that are past their deadline. Runs on the shard
    /// thread with the mutex dropped: it touches the cell's VM, its transaction and
    /// its arena, which only this thread may do.
    ///
    /// This exists because a fetch worker cannot be cancelled — `std.http.Client`
    /// hands back no handle for an in-flight request. Without a timer the shard only
    /// learns about a slow upstream when the response arrives; an upstream that
    /// accepts and never answers never completes at all, and the transaction, the
    /// cell and one worker stay gone for the life of the process.
    fn reapExpired(self: *Shard) void {
        const now_ns = now();
        var victims: [32]*Cell = undefined;
        var n: usize = 0;
        var it = self.cells.valueIterator();
        while (it.next()) |cp| {
            const c = cp.*;
            const p = c.parked orelse continue;
            if (now_ns < p.deadline_ns) continue;
            if (n == victims.len) break;
            victims[n] = c;
            n += 1;
        }
        for (victims[0..n]) |c| {
            const parked = c.parked orelse continue;
            c.machine.abort();
            c.parked = null;
            self.rollbackCell(c);
            parked.inv.arena.give();
            self.complete(parked.inv, .timeout, "deadline exceeded", &.{}, parked.t0);
            self.drainDeferred(c.key);
        }
    }

    /// Rolls back and, if SQLite refuses, marks the cell for the shard to drop.
    ///
    /// `ROLLBACK` fails under exactly the conditions that made `COMMIT` fail (IO
    /// error, full disk, a corrupted file). Swallowing that left the connection in a
    /// transaction for the life of the process: every later invocation on the cell
    /// then failed at `BEGIN IMMEDIATE` with "cannot start a transaction within a
    /// transaction", and nothing said why. Closing the connection rolls back
    /// implicitly, so dropping the cell is the recovery.
    fn rollbackCell(self: *Shard, cell: *Cell) void {
        _ = self;
        cell.db.resetAll();
        cell.db.rollback();
        if (cell.db.inTx()) cell.wedged = true;
    }

    /// Removes a cell from this shard and frees everything it owns. Caller guarantees
    /// nothing is parked and no invocation is in flight for it.
    fn dropCell(self: *Shard, key: []const u8) void {
        const c = self.cells.get(key) orelse return;
        _ = self.cells.remove(key);
        self.sched.alarms.disarm(key);
        const gpa = self.sched.gpa;
        c.machine.deinit();
        c.db.close();
        gpa.free(c.src);
        gpa.free(c.key);
        gpa.destroy(c);
    }

    /// Drops cells whose rollback failed. Runs on the shard thread between
    /// invocations, never while one is parked.
    fn dropWedged(self: *Shard) void {
        while (true) {
            var victim: ?*Cell = null;
            var it = self.cells.valueIterator();
            while (it.next()) |cp| {
                if (cp.*.wedged and cp.*.parked == null) {
                    victim = cp.*;
                    break;
                }
            }
            const c = victim orelse return;
            std.debug.print("cellar: cell {s} could not roll back; dropped so the next open recovers\n", .{c.key});
            self.dropCell(c.key);
        }
    }

    fn loop(self: *Shard) void {
        const io = self.sched.io;
        while (true) {
            // Both run unconditionally: a shard that is busy with other cells would
            // otherwise never enter the idle branch below, and a parked invocation's
            // deadline would go unnoticed while its queue keeps filling.
            self.dropWedged();
            self.reapExpired();
            self.mu.lockUncancelable(io);
            while (self.queue.items.len == 0 and self.completions.items.len == 0) {
                // Timed rather than indefinite: a parked invocation whose upstream
                // never answers has no other wakeup (see reapExpired).
                self.cond.waitTimeout(io, &self.mu, .{ .duration = .{ .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms }, .clock = .awake } }) catch {};
                if (self.queue.items.len > 0 or self.completions.items.len > 0) break;
                // Inside the idle wait, not just at the top of the loop: this is where
                // the shard actually sits while a cell is parked, and the timed wait is
                // the only thing that wakes it.
                self.mu.unlock(io);
                self.reapExpired();
                self.mu.lockUncancelable(io);
            }
            if (self.completions.items.len > 0) {
                const c = self.completions.orderedRemove(0);
                self.mu.unlock(io);
                self.handleCompletion(c);
                continue;
            }
            const inv = self.queue.orderedRemove(0);
            // A parked cell must not run a second invocation: its transaction is
            // still open, and two guests sharing it would see each other's writes.
            const busy = if (self.cells.get(inv.cell_key)) |c| c.parked != null else false;
            if (busy) {
                if (self.deferred.append(self.sched.gpa, inv)) |_| {
                    self.mu.unlock(io);
                    continue;
                } else |_| {}
            }
            self.inflight += 1;
            self.mu.unlock(io);

            self.run(inv);

            self.mu.lockUncancelable(io);
            self.inflight -= 1;
            self.mu.unlock(io);
        }
    }

    fn run(self: *Shard, inv: *Invocation) void {
        const cfg = &self.sched.cfg;

        // A deploy is a queue job like any other, which is what makes the swap
        // ordered against invocations: it happens at dequeue, never mid-call.
        if (inv.swap_src) |src| {
            self.swapModule(inv.cell_key, inv.swap_src.?) catch |err| {
                self.completeRaw(inv, .internal, @errorName(err), &.{});
                return;
            };
            _ = src;
            self.completeRaw(inv, .ok, "", &.{});
            return;
        }

        self.sched.metrics.begin();
        const t0 = now();

        // A snapshot runs on the cell's own thread, outside any transaction
        // (VACUUM cannot run inside one). That is the whole point: it sees a
        // consistent database with no concurrent writer, which is what makes the
        // copy worth restoring from.
        if (inv.snapshot_path) |out_path| {
            const cell = self.cellFor(inv.cell_key, false) catch |err| {
                self.complete(inv, .internal, @errorName(err), &.{}, t0);
                return;
            };
            var sql_buf: [1024]u8 = undefined;
            const sql = std.fmt.bufPrint(&sql_buf, "VACUUM INTO '{s}'", .{out_path}) catch {
                self.complete(inv, .internal, "snapshot path too long", &.{}, t0);
                return;
            };
            cell.db.internal = true;
            const res = cell.db.exec(sql);
            cell.db.internal = false;
            if (res) |_| {
                self.complete(inv, .ok, "", &.{}, t0);
            } else |err| {
                self.complete(inv, .internal, @errorName(err), &.{}, t0);
            }
            return;
        }
        // Load shedding: a job that waited longer than --queue-timeout-ms never
        // runs. Checked at dequeue rather than by the waiter, because the waiter
        // must stay blocked until the shard is finished with the body and the
        // arena — the invocation's buffers belong to the caller. Deploys are
        // exempt: a late deploy still needs to happen.
        if (inv.queue_deadline_ns != 0 and t0 > inv.queue_deadline_ns) {
            // This path completes by hand, so it must account for the work itself.
            _ = self.sched.outstanding.fetchSub(1, .monotonic);
            inv.fail = .{ .kind = .timeout, .msg = "queue timeout", .queue_timeout = true };
            self.sched.metrics.end(t0 - inv.enqueued_ns, .timeout);
            const io = self.sched.io;
            inv.mu.lockUncancelable(io);
            inv.done = true;
            inv.cond.signal(io);
            inv.mu.unlock(io);
            return;
        }

        const cell = self.cellFor(inv.cell_key, inv.allow_missing_pin) catch |err| {
            self.complete(inv, .internal, @errorName(err), &.{}, t0);
            return;
        };

        // Ownership of the arena moves to this shard for the duration of the call.
        inv.arena.take();

        // A guest SQL error unwinds with lua_error, which skips the binding's defers:
        // step_depth and deadline_ns would stay set for the life of the cell and the
        // statement cache would never be evicted again. Reset them per invocation.
        cell.db.step_depth = 0;
        cell.db.deadline_ns = 0;
        var ctx = vm.HostCtx{
            .cell_key = cell.key,
            .arena = inv.arena.allocator(),
            .deadline_ns = now() +| (@as(u64, cfg.limits.deadline_ms) * std.time.ns_per_ms),
            .db = cell.db,
            .invocation_id = inv.id,
            .allow_fetch = cfg.allow_fetch and self.sched.fetch_threads.len > 0,
            .headers = inv.headers,
        };
        var out: std.ArrayList(u8) = .empty;
        // One transaction per invocation (ADR-0004). The guest cannot end it:
        // the authorizer refuses TRANSACTION, SAVEPOINT, ATTACH and PRAGMA from
        // guest SQL.
        //
        // Both failure directions used to be swallowed, and both are data bugs:
        //   * if BEGIN fails the guest must not run at all — otherwise it runs in
        //     autocommit and an "ok" result means nothing;
        //   * if COMMIT fails the invocation must not report success. SQLite
        //     leaves the transaction open on a constraint or IO error, so the
        //     next invocation would silently join it and commit both.
        cell.db.begin() catch |err| {
            inv.arena.give();
            self.complete(inv, .guest_error, @errorName(err), &.{}, t0);
            return;
        };
        // An alarm invocation consumes its alarm before the guest runs: if
        // `on_alarm` does not schedule another one, this cell must not fire again
        // on every restart.
        if (std.mem.eql(u8, inv.fn_name, "on_alarm")) alarms_mod.clear(cell.db);
        const call_res = cell.machine.call(&ctx, inv.fn_name, inv.body, &out);
        // A park leaves the transaction open, the client waiting and the cell
        // busy, and hands the request to the outbound pool. Everything after this
        // point happens in `handleCompletion`, on this same shard thread.
        var outcome: vm.Outcome = undefined;
        switch (call_res) {
            .done => |o| outcome = o,
            .park => |req| {
                const gen = self.sched.park_gen.fetchAdd(1, .monotonic);
                cell.parked = .{ .inv = inv, .gen = gen, .ctx = ctx, .req = req, .t0 = t0, .deadline_ns = ctx.deadline_ns };
                cell.calls += 1;
                cell.last_used = now();
                self.submitFetch(cell.key, inv, req, ctx.deadline_ns, gen);
                return;
            },
        }
        cell.calls += 1;
        cell.last_used = now();
        switch (outcome) {
            .ok => {
                cell.db.commit() catch |err| {
                    self.rollbackCell(cell);
                    inv.arena.give();
                    self.complete(inv, .guest_error, @errorName(err), &.{}, t0);
                    return;
                };
                // Only now: an alarm set by an invocation that rolled back must
                // not exist, and the row it wrote is gone with the transaction.
                if (ctx.alarm_due > 0) {
                    self.sched.alarms.arm(cell.key, ctx.alarm_due);
                } else if (ctx.alarm_due < 0) {
                    self.sched.alarms.disarm(cell.key);
                }
            },
            else => {
                self.rollbackCell(cell);
            },
        }
        // Hand the arena back BEFORE signalling completion: the waiter must not
        // observe `done` while the arena is still owned by this thread.
        inv.arena.give();

        switch (outcome) {
            .ok => self.complete(inv, .ok, "", out.items, t0),
            .guest_error => |m| self.complete(inv, .guest_error, m, &.{}, t0),
            .timeout => self.complete(inv, .timeout, "deadline exceeded", &.{}, t0),
            .oom => self.complete(inv, .guest_error, "out of memory", &.{}, t0),
        }
    }

    // ------------------------------------------------------------- fetch parking

    fn freeRes(self: *Shard, res: vm.FetchRes) void {
        const gpa = self.sched.gpa;
        if (res.body.len > 0) gpa.free(res.body);
        if (res.err.len > 0) gpa.free(res.err);
    }

    /// Called from a pool thread. The completion list is the only cross-thread
    /// state here, and it is guarded by the same mutex as the queue.
    fn postCompletion(self: *Shard, c: Completion) void {
        const io = self.sched.io;
        self.mu.lockUncancelable(io);
        self.completions.append(self.sched.gpa, c) catch {
            // Should be unreachable: capacity is reserved at start(). If it happens,
            // say so loudly — dropping the only wakeup strands an invocation.
            std.debug.print("cellar: FATAL dropped fetch completion for {s} (completions full)\n", .{c.key});
            self.mu.unlock(io);
            self.sched.gpa.free(c.key);
            self.freeRes(c.res);
            return;
        };
        self.cond.signal(io);
        self.mu.unlock(io);
    }

    /// Hand a request to the pool. The invocation's arena stays owned by this
    /// shard, so the request slices remain valid while the fetch is in flight.
    fn submitFetch(self: *Shard, key: []const u8, inv: *Invocation, req: vm.FetchReq, deadline_ns: u64, gen: u64) void {
        const gpa = self.sched.gpa;

        const job = gpa.create(FetchJob) catch return self.failFetch(key, inv, "out of memory");
        const kcopy = gpa.dupe(u8, key) catch {
            gpa.destroy(job);
            return self.failFetch(key, inv, "out of memory");
        };
        // The job owns its request, not the invocation arena. It used to borrow the
        // arena slices, which was safe only while an aborted invocation was
        // impossible: the deadline reaper aborts a parked invocation while its fetch
        // is still in flight, hands the arena to the next request, and the pool
        // thread then read freed memory.
        const url = gpa.dupe(u8, req.url) catch {
            gpa.free(kcopy);
            gpa.destroy(job);
            return self.failFetch(key, inv, "out of memory");
        };
        const method = gpa.dupe(u8, req.method) catch {
            gpa.free(kcopy);
            gpa.free(url);
            gpa.destroy(job);
            return self.failFetch(key, inv, "out of memory");
        };
        const body = gpa.dupe(u8, req.body) catch {
            gpa.free(kcopy);
            gpa.free(url);
            gpa.free(method);
            gpa.destroy(job);
            return self.failFetch(key, inv, "out of memory");
        };
        // Never let a fetch outlive the invocation's deadline by much.
        const remain_ms = if (deadline_ns > now()) (deadline_ns - now()) / std.time.ns_per_ms else 1;
        job.* = .{ .shard = self, .key = kcopy, .inv = inv, .gen = gen, .req = .{
            .url = url,
            .method = method,
            .body = body,
            .timeout_ms = @intCast(@max(@min(@as(u64, req.timeout_ms), remain_ms), 1)),
        } };
        self.sched.enqueueFetch(job);
    }

    /// Abort a parked invocation that never made it to the pool.
    fn failFetch(self: *Shard, key: []const u8, inv: *Invocation, msg: []const u8) void {
        if (self.cells.get(key)) |c| {
            c.machine.abort();
            c.parked = null;
            self.rollbackCell(c);
        }
        inv.arena.give();
        self.complete(inv, .internal, msg, &.{}, now());
        self.drainDeferred(key);
    }

    /// Resume a parked invocation with the response, or kill it at its deadline.
    fn handleCompletion(self: *Shard, c: Completion) void {
        const gpa = self.sched.gpa;
        defer gpa.free(c.key);
        defer self.freeRes(c.res);

        const cell = self.cells.get(c.key) orelse return;
        // Mutable copy: the resume may set `alarm_due` again, and re-parking must
        // carry that forward.
        var p = cell.parked orelse return;
        // Generation, not the pointer: see Parked.gen.
        if (p.gen != c.gen or p.inv != c.inv) return;

        if (now() > p.deadline_ns) {
            // Out of time while parked. Drop the coroutine and the transaction;
            // the guest never sees this response, so a late completion is exactly
            // the case the design says must be dropped rather than delivered.
            cell.machine.abort();
            cell.parked = null;
            self.rollbackCell(cell);
            p.inv.arena.give();
            self.complete(p.inv, .timeout, "deadline exceeded", &.{}, p.t0);
            self.drainDeferred(c.key);
            return;
        }

        cell.parked = null;
        var out: std.ArrayList(u8) = .empty;
        switch (cell.machine.resumeFetch(&p.ctx, c.res, &out)) {
            .park => |req| {
                const gen = self.sched.park_gen.fetchAdd(1, .monotonic);
                cell.parked = .{ .inv = p.inv, .gen = gen, .ctx = p.ctx, .req = req, .t0 = p.t0, .deadline_ns = p.deadline_ns };
                self.submitFetch(cell.key, p.inv, req, p.deadline_ns, gen);
            },
            .done => |outcome| {
                switch (outcome) {
                    .ok => {
                        cell.db.commit() catch |err| {
                            self.rollbackCell(cell);
                            p.inv.arena.give();
                            self.complete(p.inv, .guest_error, @errorName(err), &.{}, p.t0);
                            self.drainDeferred(c.key);
                            return;
                        };
                        if (p.ctx.alarm_due > 0) {
                            self.sched.alarms.arm(cell.key, p.ctx.alarm_due);
                        } else if (p.ctx.alarm_due < 0) {
                            self.sched.alarms.disarm(cell.key);
                        }
                    },
                    else => {
                        self.rollbackCell(cell);
                    },
                }
                p.inv.arena.give();
                switch (outcome) {
                    .ok => self.complete(p.inv, .ok, "", out.items, p.t0),
                    .guest_error => |m| self.complete(p.inv, .guest_error, m, &.{}, p.t0),
                    .timeout => self.complete(p.inv, .timeout, "deadline exceeded", &.{}, p.t0),
                    .oom => self.complete(p.inv, .guest_error, "out of memory", &.{}, p.t0),
                }
                self.drainDeferred(c.key);
            },
        }
    }

    /// Put a cell's deferred invocations back at the head of the queue, in order.
    /// Only the shard thread touches `deferred`.
    fn drainDeferred(self: *Shard, key: []const u8) void {
        const gpa = self.sched.gpa;
        var ready: std.ArrayList(*Invocation) = .empty;
        defer ready.deinit(gpa);

        var i: usize = 0;
        while (i < self.deferred.items.len) {
            if (std.mem.eql(u8, self.deferred.items[i].cell_key, key)) {
                const inv = self.deferred.orderedRemove(i);
                ready.append(gpa, inv) catch {
                    self.deferred.append(gpa, inv) catch {};
                    continue;
                };
                continue;
            }
            i += 1;
        }
        if (ready.items.len == 0) return;

        const io = self.sched.io;
        self.mu.lockUncancelable(io);
        self.queue.insertSlice(gpa, 0, ready.items) catch {
            // Cannot re-queue: serve them now rather than strand the clients.
            self.mu.unlock(io);
            for (ready.items) |inv| self.run(inv);
            return;
        };
        self.cond.signal(io);
        self.mu.unlock(io);
    }

    /// Enforces `--max-cells` for this shard: evicts the least-recently-used cell
    /// that has no queued work.
    ///
    /// The check and the teardown happen with the queue mutex held, so a submit
    /// cannot land for the victim between the two. That is the race the review
    /// flagged (freeing a cell that still has queued invocations) removed rather
    /// than mitigated. If every resident cell has queued work we stay over the
    /// cap instead of dropping someone's request.
    fn evictIfNeeded(self: *Shard) void {
        const max = self.sched.cfg.limits.max_cells;
        if (max == 0 or self.cells.count() < max) return;
        const io = self.sched.io;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        var victim: ?*Cell = null;
        var victim_used: u64 = std.math.maxInt(u64);
        var it = self.cells.iterator();
        while (it.next()) |e| {
            const c = e.value_ptr.*;
            if (self.queuedFor(c.key)) continue;
            // Never evict a cell with an invocation parked mid-transaction: closing
            // the db under an open transaction is silent corruption.
            if (c.parked != null) continue;
            if (c.last_used <= victim_used) {
                victim_used = c.last_used;
                victim = c;
            }
        }
        const v = victim orelse return;

        _ = self.cells.remove(v.key);
        // VM first: its finalizers may still call the db.* bindings.
        v.machine.deinit();
        v.db.close();
        self.sched.gpa.free(v.key);
        self.sched.gpa.free(v.src);
        self.sched.gpa.destroy(v);
        _ = self.sched.metrics.cells.fetchSub(1, .monotonic);
    }

    fn queuedFor(self: *Shard, key: []const u8) bool {
        for (self.queue.items) |inv| {
            if (std.mem.eql(u8, inv.cell_key, key)) return true;
        }
        return false;
    }

    /// Installs `owned` as the cell's module. Takes ownership of the bytes on
    /// both paths; on failure the cell keeps running its previous module.
    fn swapModule(self: *Shard, key: []const u8, owned: []u8) !void {
        const gpa = self.sched.gpa;
        // Freed on every error path; ownership moves into the cell on success.
        errdefer gpa.free(owned);

        // Whether this call creates the cell matters on the failure path: a cell
        // created here (with the built-in module, because its pin was unreadable) must
        // not stay resident if the new module then fails to load — it would serve the
        // fixture over the cell's real data for the life of the process, which is
        // exactly what ModuleUnavailable exists to prevent.
        const existed = self.cells.get(key) != null;
        const cell = try self.cellFor(key, true);

        const machine = try Lua.create(gpa, @as(usize, self.sched.cfg.limits.vm_budget_mb) * 1024 * 1024);
        errdefer machine.deinit();

        var ctx = vm.HostCtx{ .cell_key = cell.key, .arena = gpa };
        machine.load(&ctx, owned, key) catch |err| {
            if (!existed) {
                // Also disarm: cellFor arms the alarm row before the module is in place,
                // and a fired alarm on the fixture would run `on_alarm`, delete the row
                // and durably consume the real module's alarm.
                self.sched.alarms.disarm(key);
                self.dropCell(key);
            }
            return err;
        };

        const old_machine = cell.machine;
        const old_src = cell.src;
        cell.machine = machine;
        cell.src = owned;
        cell.version += 1;
        old_machine.deinit();
        gpa.free(old_src);
    }

    /// One JSON object per line on stderr, so a log shipper can key on
    /// `invocation_id` and join it to the response header. Successful fast
    /// invocations are sampled 1-in-100: at 1k/s a line each is ~20 GB/day, and an
    /// ok that finishes in 300 µs is not what anyone is looking for.
    fn logInvocation(inv: *Invocation, kind: metrics.Outcome, dur_ns: u64) void {
        const ms = @as(f64, @floatFromInt(dur_ns)) / 1e6;
        if (kind == .ok and ms < 100.0 and inv.id[0] % 100 != 0) return;

        const json = @import("../util/json.zig");
        var cell_buf: [256]u8 = undefined;
        var fn_buf: [128]u8 = undefined;
        const cell_s = json.escapeInto(&cell_buf, inv.cell_key);
        const fn_s = json.escapeInto(&fn_buf, inv.fn_name);
        const id_hex = std.fmt.bytesToHex(inv.id, .lower);
        const ts = @as(f64, @floatFromInt(alarms_mod.nowMs())) / 1000.0;
        const level: []const u8 = switch (kind) {
            .ok => "info",
            .guest_error => "warn",
            .timeout, .internal => "error",
        };
        var line: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{{\"ts\":{d:.3},\"level\":\"{s}\",\"msg\":\"invoke\",\"id\":\"{s}\",\"cell\":\"{s}\",\"fn\":\"{s}\",\"outcome\":\"{s}\",\"duration_ms\":{d:.3}}}\n", .{
            ts, level, &id_hex, cell_s, fn_s, @tagName(kind), ms,
        }) catch return;
        std.debug.print("{s}", .{text});
    }

    fn completeRaw(self: *Shard, inv: *Invocation, kind: metrics.Outcome, msg: []const u8, out: []const u8) void {
        _ = self.sched.outstanding.fetchSub(1, .monotonic);
        inv.out = out;
        inv.fail = if (kind == .ok) null else .{ .kind = kind, .msg = msg };
        logInvocation(inv, kind, 0);
        const io = self.sched.io;
        inv.mu.lockUncancelable(io);
        inv.done = true;
        inv.cond.signal(io);
        inv.mu.unlock(io);
    }

    fn complete(self: *Shard, inv: *Invocation, kind: metrics.Outcome, msg: []const u8, out: []const u8, t0: u64) void {
        _ = self.sched.outstanding.fetchSub(1, .monotonic);
        inv.out = out;
        inv.fail = if (kind == .ok) null else .{ .kind = kind, .msg = msg };
        const dur = now() - t0;
        self.sched.metrics.end(dur, kind);
        logInvocation(inv, kind, dur);
        const io = self.sched.io;
        inv.mu.lockUncancelable(io);
        inv.done = true;
        inv.cond.signal(io);
        inv.mu.unlock(io);
    }

    fn cellFor(self: *Shard, key: []const u8, allow_missing_pin: bool) !*Cell {
        const gpa = self.sched.gpa;
        if (self.cells.get(key)) |c| return c;
        self.evictIfNeeded();
        const c = try gpa.create(Cell);
        errdefer gpa.destroy(c);
        const owned = try gpa.dupe(u8, key);
        errdefer gpa.free(owned);
        const p = try paths.cellPaths(gpa, self.sched.io, self.sched.cfg.limits.data_dir, key);
        defer p.deinit(gpa);
        // Refuse a directory that belongs to a different key: the digest makes
        // collisions infeasible, and this makes a copied or edited data dir fail
        // loudly instead of serving another cell's rows.
        try paths.claim(gpa, self.sched.io, p.dir, key);
        const db = try Db.open(gpa, p.db, self.sched.cfg.limits.db_max_mb, self.sched.cfg.limits.stmt_cache);
        errdefer db.close();
        const machine = try Lua.create(gpa, @as(usize, self.sched.cfg.limits.vm_budget_mb) * 1024 * 1024);
        errdefer machine.deinit();
        // Rehydrate: the registry first (it is the authority), then this cell's
        // own meta.json — the "state.db was lost" recovery ADR-0007 promises —
        // then the built-in fixture.
        var pinned: ?[]u8 = null;
        defer if (pinned) |pin_buf| gpa.free(pin_buf);

        if (self.sched.registry) |reg| {
            const cat = reg.lock();
            for (cat.cells) |rec| {
                if (rec.blob_sha.len == 0 or !std.mem.eql(u8, rec.key, key)) continue;
                pinned = gpa.dupe(u8, rec.blob_sha) catch null;
                break;
            }
            reg.unlock();
        }
        if (pinned == null) {
            var mbuf: [512]u8 = undefined;
            if (meta.read(gpa, self.sched.io, self.sched.cfg.limits.data_dir, key, &mbuf)) |json| {
                var sbuf: [128]u8 = undefined;
                if (meta.field(json, "blob_sha", &sbuf)) |sha| {
                    // Only a real digest; an empty or short value means "no pin".
                    if (sha.len == 64) pinned = gpa.dupe(u8, sha) catch null;
                }
            } else |_| {}
        }

        var src: []u8 = undefined;
        if (pinned) |sha| {
            // A pin that cannot be loaded is not a reason to run different code.
            // Falling back to the built-in fixture here served the cell's real data
            // with the wrong handlers — silently, and then rewrote meta.json with an
            // empty pin, so the documented recovery path was gone too. Refusing is
            // the only answer that cannot corrupt anything.
            src = blob.getAlloc(gpa, self.sched.io, self.sched.cfg.limits.data_dir, sha, self.sched.cfg.limits.max_source) catch |err| blk: {
                // A deploy is the one caller allowed to proceed: it is about to replace
                // the module and rewrite the pin, so refusing here would leave the cell
                // permanently undeployable.
                if (allow_missing_pin) {
                    std.debug.print("cellar: cell {s} is pinned to unreadable blob {s} ({s}); opening it so the deploy can replace the pin\n", .{ key, sha, @errorName(err) });
                    break :blk try gpa.dupe(u8, self.sched.module_src);
                }
                std.debug.print("cellar: cell {s} is pinned to blob {s} but it cannot be read ({s}); refusing to substitute the built-in module\n", .{ key, sha, @errorName(err) });
                return error.ModuleUnavailable;
            };
        } else {
            src = try gpa.dupe(u8, self.sched.module_src);
        }
        errdefer gpa.free(src);
        var ctx = vm.HostCtx{ .cell_key = owned, .arena = gpa };
        try machine.load(&ctx, src, key);
        c.* = .{ .key = owned, .machine = machine, .db = db, .src = src };
        try self.cells.put(owned, c);
        // A cell that was evicted or restarted keeps its alarm: the row is in its
        // own database, and re-arming here is what makes it survive a process.
        if (alarms_mod.get(db)) |due| self.sched.alarms.arm(owned, due);
        // Self-describing cell directory: record the pin actually in force, so a
        // directory that outlives state.db still knows which module it was running.
        // Record the pin actually in force. Never blank it: an empty pin looks like
        // "this cell was never deployed" and destroys the on-disk fallback.
        const pin_text: []const u8 = if (pinned) |sha| sha else "";
        meta.write(gpa, self.sched.io, self.sched.cfg.limits.data_dir, .{
            .key = owned,
            .blob_sha = pin_text,
            .owner_node = self.sched.node_id,
            .epoch = 1,
            .created_at = wallSeconds(),
            .last_seen = wallSeconds(),
        }) catch {};
        if (self.sched.registry) |reg| {
            reg.upsertCell(.{
                .key = owned,
                // Version 0 means "no opinion": a cold open knows which module
                // to run but not which global deployment version it came from,
                // and stamping 1 here used to reset a cell's version on restart.
                .version = 0,
                .blob_sha = pin_text,
                .created_at = wallSeconds(),
                .last_seen = wallSeconds(),
            }) catch {};
        }
        _ = self.sched.metrics.cells.fetchAdd(1, .monotonic);
        return c;
    }
};

pub const Scheduler = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    metrics: metrics.Metrics = .{},
    shards: []Shard,
    module_src: []const u8,
    locator: locator_mod.Locator,
    node_id: []const u8,
    registry: ?*@import("registry.zig").Registry = null,
    started_ns: u64 = 0,
    /// Serializes deploys: version allocation and publication must not interleave.
    deploy_mu: std.Io.Mutex = .init,
    /// One thread for every armed alarm in the process.
    alarms: *alarms_mod.Timer = undefined,
    /// Outbound fetch pool (ADR-0024). Threads exist only when `--allow-fetch` is set.
    fetch_threads: []std.Thread = &.{},
    fetch_mu: std.Io.Mutex = .init,
    fetch_cond: std.Io.Condition = .init,
    fetch_queue: std.ArrayList(*FetchJob) = .empty,
    fetch_fn: fetch_mod.FetchFn = fetch_mod.defaultFetch,
    fetch_ctx: ?*anyopaque = null,
    fetch_policy: fetch_mod.FetchPolicy = .{},
    /// Set by the drain watcher on SIGTERM. New invocations are refused, in-flight
    /// ones are allowed to finish.
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Invocations accepted by `submit` and not yet completed. The drain waits on
    /// this rather than on the metrics gauge, which only moves once `run()` starts.
    outstanding: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Source of park generations (see Parked.gen).
    park_gen: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config, module_src: []const u8) !*Scheduler {
        const self = try gpa.create(Scheduler);
        errdefer gpa.destroy(self);
        const n = @max(@as(usize, 1), cfg.limits.shards);
        const shards = try gpa.alloc(Shard, n);
        for (shards, 0..) |*s, i| {
            s.* = .{
                .sched = self,
                .id = i,
                .cells = std.StringHashMap(*Cell).init(gpa),
            };
        }
        self.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .shards = shards,
            .module_src = module_src,
            .node_id = cfg.node_id orelse "local",
            .locator = .{ .node_id = cfg.node_id orelse "local", .advertise = cfg.advertise, .peers = cfg.peers },
            .fetch_policy = .{
                .allow_private = cfg.fetch_allow_private,
                .allow_hosts = cfg.fetch_allow_hosts,
            },
        };
        self.fetch_ctx = &self.fetch_policy;
        self.alarms = try gpa.create(alarms_mod.Timer);
        self.alarms.* = alarms_mod.Timer.init(gpa, io, self, fireThunk);
        return self;
    }

    pub fn enqueueFetch(self: *Scheduler, job: *FetchJob) void {
        const io = self.io;
        self.fetch_mu.lockUncancelable(io);
        self.fetch_queue.append(self.gpa, job) catch {
            self.fetch_mu.unlock(io);
            job.shard.failFetch(job.key, job.inv, "fetch queue full");
            self.gpa.free(job.key);
            self.gpa.destroy(job);
            return;
        };
        self.fetch_cond.signal(io);
        self.fetch_mu.unlock(io);
    }

    /// Pool thread. Blocking here is harmless; blocking on a shard would stall
    /// every cell that shard owns.
    fn fetchWorker(self: *Scheduler) void {
        const io = self.io;
        while (true) {
            self.fetch_mu.lockUncancelable(io);
            while (self.fetch_queue.items.len == 0) self.fetch_cond.wait(io, &self.fetch_mu) catch {};
            const job = self.fetch_queue.orderedRemove(0);
            self.fetch_mu.unlock(io);

            const res = self.fetch_fn(self.fetch_ctx, self.gpa, io, job.req);
            // The job owned these (see submitFetch); the response is separate.
            self.gpa.free(job.req.url);
            self.gpa.free(job.req.method);
            self.gpa.free(job.req.body);
            job.shard.postCompletion(.{ .key = job.key, .inv = job.inv, .gen = job.gen, .res = res });
            self.gpa.destroy(job);
        }
    }

    fn fireThunk(ctx: *anyopaque, key: []const u8) void {
        const self: *Scheduler = @ptrCast(@alignCast(ctx));
        self.fireAlarm(key);
    }

    /// Runs `on_alarm` for one cell from the timer thread. The alarm invocation is
    /// an ordinary invocation: same queue, same transaction, same deadline.
    fn fireAlarm(self: *Scheduler, key: []const u8) void {
        var stack: [1024]u8 = undefined;
        var arena = cap.RequestArena.init(&stack);
        var inv = Invocation{
            .cell_key = key,
            .fn_name = "on_alarm",
            .body = "",
            .arena = &arena,
        };
        arena.give();
        self.submit(&inv) catch {
            arena.take();
            return;
        };
        self.wait(&inv);
        arena.take();
    }

    /// Take a consistent copy of one cell's database. Runs on the cell's shard
    /// thread, so there is no concurrent writer; the caller supplies the path.
    pub fn snapshot(self: *Scheduler, cell_key: []const u8, out_path: []const u8) !void {
        var stack: [1024]u8 = undefined;
        var arena = cap.RequestArena.init(&stack);
        const owned = try self.gpa.dupe(u8, out_path);
        defer self.gpa.free(owned);
        var inv = Invocation{
            .cell_key = cell_key,
            .fn_name = "snapshot",
            .body = "",
            .arena = &arena,
            .snapshot_path = owned,
        };
        arena.give();
        self.submit(&inv) catch return error.QueueFull;
        self.wait(&inv);
        arena.take();
        if (inv.fail != null) return error.SnapshotFailed;
    }

    /// Where should this cell run? MVP answers `.local` unless the operator
    /// supplied `--peers`, in which case rendezvous hashing over the member set
    /// decides. The HTTP layer turns a `.remote` into a 307 (ADR-0016).
    pub fn placement(self: *const Scheduler, key: []const u8) locator_mod.Placement {
        return self.locator.resolve(key);
    }

    pub fn attachRegistry(self: *Scheduler, reg: *@import("registry.zig").Registry) void {
        self.registry = reg;
    }

    pub fn uptimeSeconds(self: *const Scheduler) u64 {
        if (self.started_ns == 0) return 0;
        const d = now() -| self.started_ns;
        return d / std.time.ns_per_s;
    }

    /// Publishes `source` as the module for `cell_key` and waits for the owning
    /// shard to adopt it, so a caller holding the returned sha can rely on the
    /// next invocation running it. The blob is content-addressed, so deploying
    /// the same bytes twice is free.
    pub fn deploy(self: *Scheduler, cell_key: []const u8, source: []const u8) ![]const u8 {
        // Serializes version allocation with publication: `nextVersion` reads
        // the catalog and `upsertDeploy` writes it, and two deploys interleaving
        // there would both claim version N+1 — the second silently overwriting
        // the first in `deployments`. Deploys are rare; a mutex is the honest
        // fix and it also stops two deploys racing on one cell's swap.
        self.deploy_mu.lockUncancelable(self.io);
        defer self.deploy_mu.unlock(self.io);

        if (source.len > self.cfg.limits.max_source) return error.SourceTooLarge;
        const sha = try blob.put(self.gpa, self.io, self.cfg.limits.data_dir, source);
        errdefer self.gpa.free(sha);

        const owned = try self.gpa.dupe(u8, source);
        var stack: [1024]u8 = undefined;
        var arena = cap.RequestArena.init(&stack);
        var inv = Invocation{
            .cell_key = cell_key,
            .fn_name = "deploy",
            .body = "",
            .arena = &arena,
            .swap_src = owned,
            .allow_missing_pin = true,
        };
        // The audit row is written *before* the swap. An unused version is harmless —
        // it is an attempt that never became active — while a swapped module with no
        // version row is a deployment that never existed, and the order here is the
        // only thing that makes the row survive a crash in the swap.
        var ver: u32 = 0;
        if (self.registry) |reg| {
            ver = reg.nextVersion("default");
            reg.upsertDeploy(.{
                .module = "default",
                .version = ver,
                .blob_sha = sha,
                .created_at = wallSeconds(),
            }) catch return error.PinFailed;
        }

        arena.give();
        self.submit(&inv) catch {
            self.gpa.free(owned);
            return error.QueueFull;
        };
        self.wait(&inv);
        arena.take();
        if (inv.fail) |_| return error.DeployFailed;

        // The active pin is the acknowledgement: a 200 before it is a lying ack, and
        // the next restart would run the previous module — or the fixture — against
        // data the new module already wrote.
        if (self.registry) |reg| {
            reg.upsertCell(.{
                .key = cell_key,
                .module = "default",
                .version = ver,
                .blob_sha = sha,
                .created_at = wallSeconds(),
                .last_seen = wallSeconds(),
            }) catch |e| {
                // The module is already live and writing. Keep the local pin truthful so
                // this node does not revert on restart, and tell the caller the deploy is
                // not done — retrying is mandatory, not optional.
                std.debug.print("cellar: cell {s} is running the new module but its pin failed: {s}\n", .{ cell_key, @errorName(e) });
                meta.write(self.gpa, self.io, self.cfg.limits.data_dir, .{
                    .key = cell_key,
                    .module = "default",
                    .version = ver,
                    .blob_sha = sha,
                    .owner_node = self.node_id,
                    .epoch = 1,
                    .created_at = wallSeconds(),
                    .last_seen = wallSeconds(),
                }) catch {};
                return error.PinLive;
            };
        }
        // meta.json is the second copy, for a data dir that loses state.db. It is a
        // cache rather than the authority, so a failure here is loud but not fatal:
        // the registry already holds the pin.
        meta.write(self.gpa, self.io, self.cfg.limits.data_dir, .{
            .key = cell_key,
            .blob_sha = sha,
            .owner_node = self.node_id,
            .epoch = 1,
            .created_at = wallSeconds(),
            .last_seen = wallSeconds(),
        }) catch |e| std.debug.print("cellar: meta.json pin write failed (registry still holds the pin): {s}\n", .{@errorName(e)});
        return sha;
    }

    /// Serializes blob GC against deploys. A deploy writes its blob before it pins
    /// it, and that window is unbounded — the swap can sit behind up to `queue_cap`
    /// invocations, and a parked cell blocks its own shard until its fetch resolves.
    /// GC's mtime grace only approximates the window; this closes it.
    pub fn lockDeploys(self: *Scheduler) void {
        self.deploy_mu.lockUncancelable(self.io);
    }

    pub fn unlockDeploys(self: *Scheduler) void {
        self.deploy_mu.unlock(self.io);
    }

    pub fn start(self: *Scheduler) !void {
        // A completion is the only wakeup a parked invocation gets. If appending one
        // had to allocate and failed, the invocation, its open transaction and its
        // cell would be stranded forever — no timeout reaches it. Reserve the slots
        // before any fetch can be submitted.
        for (self.shards) |*s| {
            s.completions.ensureTotalCapacity(self.gpa, 4096) catch |e|
                std.debug.print("cellar: could not reserve fetch-completion slots: {s}\n", .{@errorName(e)});
        }
        try self.alarms.start();
        if (self.cfg.allow_fetch) {
            const n: usize = @max(self.cfg.limits.fetch_workers, 1);
            self.fetch_threads = try self.gpa.alloc(std.Thread, n);
            for (self.fetch_threads) |*t| t.* = try std.Thread.spawn(.{}, fetchWorker, .{self});
        }
        for (self.shards) |*s| {
            s.thread = try std.Thread.spawn(.{}, Shard.loop, .{s});
        }
    }

    pub fn submit(self: *Scheduler, inv: *Invocation) QueueFull!void {
        const h = std.hash.Wyhash.hash(0x9e3779b9, inv.cell_key);
        const s = &self.shards[h % self.shards.len];
        inv.enqueued_ns = now();
        if (!sys.fillRandom(&inv.id)) {
            // No entropy is fatal for auth, not for correlation: fall back to a
            // counter so a log line still has an id.
            const n = id_fallback.fetchAdd(1, .monotonic);
            std.mem.writeInt(u64, &inv.id, n, .little);
        }
        const qms = self.cfg.limits.queue_timeout_ms;
        inv.queue_deadline_ns = if (qms == 0) 0 else inv.enqueued_ns + @as(u64, qms) * std.time.ns_per_ms;
        s.mu.lockUncancelable(self.io);
        defer s.mu.unlock(self.io);
        if (s.queue.items.len >= queue_cap) return error.QueueFull;
        s.queue.append(self.gpa, inv) catch return error.QueueFull;
        // Counted from admission, not from `run()`: an invocation on the queue, a
        // deferred one and a parked one are all work the process still owes a
        // client, and shutdown has to wait for them.
        _ = self.outstanding.fetchAdd(1, .monotonic);
        s.cond.signal(self.io);
    }

    pub fn wait(self: *Scheduler, inv: *Invocation) void {
        inv.mu.lockUncancelable(self.io);
        while (!inv.done) {
            inv.cond.wait(self.io, &inv.mu) catch {};
        }
        inv.mu.unlock(self.io);
    }
};

pub fn now() u64 {
    return sys.monotonicNs();
}

/// Wall-clock seconds since the epoch, for records a human will read. `now()`
/// is monotonic (uptime), which is the wrong thing to store in a timestamp.
pub fn wallSeconds() i64 {
    return sys.realtimeSec();
}
