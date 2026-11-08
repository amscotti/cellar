const std = @import("std");
const config = @import("../config.zig");
const router = @import("router.zig");
const Scheduler = @import("../runtime/scheduler.zig").Scheduler;
const Invocation = @import("../runtime/scheduler.zig").Invocation;
const RequestArena = @import("../util/cap.zig").RequestArena;
const ratelimit = @import("../util/ratelimit.zig");
const sys = @import("../util/sys.zig");
const paths_mod = @import("../store/paths.zig");

/// One limiter per process; null when `--rate-per-s` is 0.
var limiter: ?ratelimit.Limiter = null;

/// HTTP/1.1, one thread per connection, blocking. A fixed 16 KiB head buffer
/// bounds the header block; the request arena bounds the body and response.
pub fn serve(gpa: std.mem.Allocator, cfg_in: config.Config, module_src: []const u8) !void {
    var cfg = cfg_in;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Token resolution order: --*-token-file > --*-token > environment >
    // generated (admin only). A file or the environment keeps the secret
    // out of `ps` output and shell history; for anything beyond a laptop,
    // prefer `--admin-token-file` (mode 0600) and never rely on the
    // generated token, which is printed once and lost on restart.
    cfg.admin_token = try resolveToken(gpa, io, cfg.admin_token_file, cfg.admin_token, "CELLAR_ADMIN_TOKEN");
    cfg.cell_token = try resolveToken(gpa, io, cfg.cell_token_file, cfg.cell_token, "CELLAR_CELL_TOKEN");
    // An empty token is not a token. `--admin-token "$UNSET_VAR"` used to turn
    // the auth check into "every empty credential matches".
    if (cfg.admin_token == null or cfg.admin_token.?.len == 0) {
        // Never "no auth": generate one and print it once so the operator can
        // use it. Losing the token means restarting, which is acceptable for a
        // control-plane secret.
        var raw: [16]u8 = undefined;
        if (!sys.fillRandom(&raw)) return error.NoEntropy;
        const hex = std.fmt.bytesToHex(raw, .lower);
        cfg.admin_token = try gpa.dupe(u8, &hex);
        std.debug.print("cellar: generated admin token (set --admin-token-file to persist it): {s}\n", .{cfg.admin_token.?});
    }
    if (cfg.cell_token) |t| if (t.len == 0) {
        cfg.cell_token = null;
    };

    const sched = try Scheduler.init(gpa, io, cfg, module_src);
    sched.started_ns = @import("../runtime/scheduler.zig").now();
    try sched.start();
    // Graceful shutdown: SIGTERM stops new work and waits for accepted invocations.
    if (cfg.limits.rate_per_s > 0) {
        const burst = if (cfg.limits.rate_burst > 0) cfg.limits.rate_burst else cfg.limits.rate_per_s;
        limiter = ratelimit.Limiter.init(@floatFromInt(cfg.limits.rate_per_s), @floatFromInt(burst));
        std.debug.print("cellar: rate limit {d}/s per cell (burst {d})\n", .{ cfg.limits.rate_per_s, burst });
    }
    installStopSignals();
    _ = try std.Thread.spawn(.{}, drainWatcher, .{ sched, cfg.limits.drain_ms });

    const Registry = @import("../runtime/registry.zig").Registry;
    // Before anything writes into it: this directory holds state.db (credential
    // digests), blobs (module source) and snapshots (full database copies).
    paths_mod.secureDataDir(gpa, io, cfg.limits.data_dir);
    const reg = Registry.open(gpa, io, cfg.limits.data_dir) catch |err| {
        // Continuing without the registry silently downgrades every keyed cell to the
        // shared token (or to no check at all), so this is fatal rather than degraded.
        std.debug.print("cellar: registry failed to open ({s}); refusing to serve with per-cell auth disabled\n", .{@errorName(err)});
        return err;
    };
    // A registry whose writer thread failed to start must not be attached: `post` would
    // block a shard thread forever on a condvar nobody signals.
    if (reg.start()) |_| {
        sched.attachRegistry(reg);
    } else |err| {
        std.debug.print("cellar: registry disabled ({s}); deployments will not survive a restart\n", .{@errorName(err)});
        reg.deinit();
    }

    const addr = try parseListen(cfg.limits.listen);
    var srv = try addr.listen(io, .{ .reuse_address = true });
    defer srv.deinit();

    std.debug.print("cellar listening on {s} (shards={d}, vm={s})\n", .{ cfg.limits.listen, cfg.limits.shards, cfg.vm });

    // Bounded concurrency: each accepted connection gets a thread and a
    // `max_response` arena, so an unbounded accept loop was a trivial way to
    // exhaust memory. Refusing the socket is the honest answer.
    while (true) {
        const stream = srv.accept(io) catch continue;
        const live = live_conns.fetchAdd(1, .monotonic) + 1;
        if (live > cfg.limits.max_conns) {
            _ = live_conns.fetchSub(1, .monotonic);
            stream.close(io);
            continue;
        }
        const t = std.Thread.spawn(.{}, conn, .{ io, gpa, sched, stream, cfg }) catch {
            _ = live_conns.fetchSub(1, .monotonic);
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

fn parseListen(s: []const u8) !std.Io.net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.BadListenAddress;
    const host = s[0..colon];
    const port = try std.fmt.parseInt(u16, s[colon + 1 ..], 10);
    return std.Io.net.IpAddress.parse(host, port);
}

fn envGet(name: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name.ptr) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

fn readTokenFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return error.EmptyTokenFile;
    return gpa.dupe(u8, trimmed);
}

fn resolveToken(
    gpa: std.mem.Allocator,
    io: std.Io,
    file: ?[]const u8,
    inline_token: ?[]const u8,
    comptime env_name: [:0]const u8,
) !?[]const u8 {
    if (file) |path| return try readTokenFile(gpa, io, path);
    if (inline_token) |t| if (t.len > 0) return t;
    if (envGet(env_name)) |v| return try gpa.dupe(u8, v);
    return inline_token;
}

/// Whether the dashboard cookie for this request should carry `Secure`.
/// Explicit `--cookie-secure` wins; otherwise Secure when a terminating
/// proxy says the client used HTTPS (`X-Forwarded-Proto: https`) or the
/// listener is not loopback. Plain loopback HTTP stays without it, or the
/// browser would refuse the cookie in local development.
fn cookieSecureFor(req: *std.http.Server.Request, cfg: config.Config) bool {
    if (cfg.cookie_secure) |v| return v;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-forwarded-proto") and
            std.ascii.eqlIgnoreCase(std.mem.trim(u8, h.value, " \t"), "https")) return true;
    }
    return !listenerIsLoopback(cfg.limits.listen);
}

/// Log the real error, answer with a generic envelope. Raw Zig error names
/// (`StepFailed`, `OutOfMemory`, …) are internals, not an API.
fn internalError(req: *std.http.Server.Request, where: []const u8, err: anyerror) !void {
    std.debug.print("cellar: {s} failed: {s}\n", .{ where, @errorName(err) });
    return respond(req, .internal_server_error, "{\"error\":{\"kind\":\"internal\",\"message\":\"internal error\"}}");
}

var live_conns = std.atomic.Value(u32).init(0);
/// Connections with a request in flight (as opposed to idle keep-alive sockets parked in
/// receiveHead). Only these can still owe a client a response, so only these should hold
/// up shutdown — an idle socket never observes `stopping` and would otherwise burn the
/// whole grace period on every SIGTERM.
var busy_conns = std.atomic.Value(u32).init(0);

fn conn(io: std.Io, gpa: std.mem.Allocator, sched: *Scheduler, stream: std.Io.net.Stream, cfg: config.Config) void {
    defer _ = live_conns.fetchSub(1, .monotonic);
    const buf = gpa.alloc(u8, cfg.limits.max_response) catch {
        // Allocating the arena can fail under exactly the memory pressure the
        // connection cap exists to survive; leaking the socket there would make
        // the failure invisible to the counter.
        stream.close(io);
        return;
    };
    defer gpa.free(buf);
    var ra = RequestArena.init(buf);

    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);
    var hs = std.http.Server.init(&sr.interface, &sw.interface);

    while (true) {
        var req = hs.receiveHead() catch break;
        _ = busy_conns.fetchAdd(1, .monotonic);
        handle(sched, &req, &ra, cfg) catch {
            _ = busy_conns.fetchSub(1, .monotonic);
            break;
        };
        _ = busy_conns.fetchSub(1, .monotonic);
        ra.reset();
        // Draining: finish this response, close the connection. Waiting for the
        // invocation alone is not enough — the response is still in the buffered
        // writer until this loop exits and flushes.
        if (sched.stopping.load(.acquire)) break;
        if (!req.head.keep_alive) break;
    }
    _ = sw.interface.flush() catch {};
    stream.close(io);
}

/// Looks for a `transfer-encoding` field name in the raw head, tolerant of the
/// whitespace-before-colon form that std's parser silently drops.
fn rawHasTransferEncoding(head: []const u8) bool {
    var it = std.mem.splitScalar(u8, head, '\n');
    _ = it.next(); // request line
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t\r");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return true;
    }
    return false;
}

/// Refuse a request whose framing is ambiguous, and close the connection: keeping it
/// open is what turns a disagreement into a desync.
fn rejectFraming(req: *std.http.Server.Request) !void {
    req.head.keep_alive = false;
    return respond(req, .bad_request, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"ambiguous request framing\"}}");
}

fn handle(sched: *Scheduler, req: *std.http.Server.Request, ra: *RequestArena, cfg: config.Config) !void {
    const target = req.head.target;
    body_consumed = false;

    // Framing hygiene, before anything can read a body. A front end and this origin
    // must not disagree about where a request ends:
    //  - Content-Length together with Transfer-Encoding is the classic TE.CL split;
    //    RFC 9112 requires rejecting the pair.
    //  - A body on a method that cannot carry one is never drained by std, so those
    //    bytes are parsed as the *next* request on the same connection (CL.0), and
    //    that second request never passed through any proxy or access log.
    if (req.head.content_length != null and req.head.transfer_encoding != .none)
        return rejectFraming(req);
    // std's parser drops a header whose name has whitespace before the colon and maps
    // `Transfer-Encoding: gzip` to a content encoding, so `head.transfer_encoding`
    // can be `.none` on a request that carried one. Check the raw head instead: that
    // is the only place both cases are visible.
    if (req.head.transfer_encoding == .none and rawHasTransferEncoding(req.head_buffer))
        return rejectFraming(req);
    if (!req.head.method.requestHasBody() and
        ((req.head.content_length orelse 0) > 0 or req.head.transfer_encoding != .none))
        return rejectFraming(req);

    // A request with neither Content-Length nor Transfer-Encoding makes
    // `std.http.Server.discardBody` assert when we respond, and an assert in a
    // connection thread aborts the whole process. `curl -X POST` with no body is
    // exactly that request — found by hitting /admin/key without `-d`. Giving the
    // request explicit zero framing is enough; the body is trivially empty.
    if (req.head.content_length == null and req.head.transfer_encoding == .none)
        req.head.content_length = 0;

    // Reads are open (loopback by default); only mutations need the token.
    const mutating = std.mem.startsWith(u8, target, "/admin/deploy") or
        std.mem.startsWith(u8, target, "/admin/evict") or
        std.mem.startsWith(u8, target, "/admin/key") or
        std.mem.startsWith(u8, target, "/admin/revoke") or
        std.mem.startsWith(u8, target, "/admin/snapshot") or
        std.mem.startsWith(u8, target, "/admin/gc");
    if (mutating) {
        if (!authorized(req, cfg.admin_token, true))
            return respond(req, .unauthorized, "{\"error\":{\"kind\":\"unauthorized\",\"message\":\"admin token required\"}}");
        // A cookie-authenticated mutation must come from this origin. SameSite=Strict
        // still sends the cookie to another port on the same host, and a page served
        // there can POST a form here; the dashboard's own form carries
        // `Sec-Fetch-Site: same-origin`. Machines send a header instead and skip this.
        if (!hasHeaderToken(req, cfg.admin_token) and !sameOrigin(req))
            return respond(req, .forbidden, "{\"error\":{\"kind\":\"forbidden\",\"message\":\"cross-origin admin mutation refused\"}}");
    }

    // Admin reads are open on a loopback listener (the default) and gated everywhere
    // else. The dashboard exposes cell names, module versions and key counts; that is
    // fine on a dev box and an information leak on a public one, and "it listens on
    // loopback" is the only reason it was ever safe.
    if (!mutating and std.mem.startsWith(u8, target, "/admin")) {
        if (!adminReadAllowed(req, cfg, target))
            return respond(req, .unauthorized, "{\"error\":{\"kind\":\"unauthorized\",\"message\":\"admin token required for reads off loopback\"}}");
    }

    if (std.mem.startsWith(u8, target, "/admin/key")) {
        if (req.head.method != .POST)
            return respond(req, .method_not_allowed, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"POST required\"}}");
        const cell = queryParam(target, "cell") orelse
            return respond(req, .bad_request, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"cell required\"}}");
        if (!router.validCellKey(cell))
            return respond(req, .bad_request, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"invalid cell key\"}}");
        const reg = sched.registry orelse
            return respond(req, .service_unavailable, "{\"error\":{\"kind\":\"internal\",\"message\":\"registry unavailable\"}}");

        // 32 random bytes, hex-encoded: the token the caller keeps. Only the
        // SHA-256 of it is stored, so a stolen state.db holds no usable secret.
        var raw: [32]u8 = undefined;
        if (!sys.fillRandom(&raw))
            return respond(req, .internal_server_error, "{\"error\":{\"kind\":\"internal\",\"message\":\"no entropy\"}}");
        const token = std.fmt.bytesToHex(raw, .lower);
        var id_raw: [4]u8 = undefined;
        if (!sys.fillRandom(&id_raw))
            return respond(req, .internal_server_error, "{\"error\":{\"kind\":\"internal\",\"message\":\"no entropy\"}}");
        const key_id = std.fmt.bytesToHex(id_raw, .lower);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&token, &digest, .{});
        reg.putKey(cell, &key_id, digest) catch |err|
            return internalError(req, "putKey", err);

        var body: [320]u8 = undefined;
        const json = std.fmt.bufPrint(&body, "{{\"ok\":true,\"cell\":\"{s}\",\"key_id\":\"{s}\",\"token\":\"{s}\"}}", .{ cell, key_id, token }) catch "{}";
        return respond(req, .ok, json);
    }

    if (std.mem.startsWith(u8, target, "/admin/revoke")) {
        if (req.head.method != .POST)
            return respond(req, .method_not_allowed, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"POST required\"}}");
        const key_id = queryParam(target, "key_id") orelse
            return respond(req, .bad_request, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"key_id required\"}}");
        const reg = sched.registry orelse
            return respond(req, .service_unavailable, "{\"error\":{\"kind\":\"internal\",\"message\":\"registry unavailable\"}}");
        reg.revokeKey(key_id) catch |err| switch (err) {
            error.NotFound => return respond(req, .not_found, "{\"error\":{\"kind\":\"not_found\",\"message\":\"no key with that id was ever issued\"}}"),
            // Already dead: a retry after a lost response succeeds, so a rotation script
            // does not abort between "old key revoked" and "new key installed".
            error.AlreadyRevoked => return respond(req, .ok, "{\"ok\":true,\"revoked\":false,\"reason\":\"already revoked\"}"),
            else => return internalError(req, "revokeKey", err),
        };
        return respond(req, .ok, "{\"ok\":true,\"revoked\":true}");
    }

    if (std.mem.startsWith(u8, target, "/admin/deploy")) {
        if (req.head.method != .POST)
            return respond(req, .method_not_allowed, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"POST required\"}}");

        const a = ra.allocator();
        // `req.head`'s slices are only valid until the body is read: the head
        // buffer is reused for the body. Copy what we need before touching it,
        // otherwise `startsWith` runs off the end of a freed slice.
        var ctype: []const u8 = "";
        if (req.head.content_type) |ct| ctype = try a.dupe(u8, ct);
        var qcell: []const u8 = "";
        if (queryParam(target, "cell")) |c| qcell = try a.dupe(u8, c);

        // Copied BEFORE the body is read: `req.head`'s strings are invalidated once
        // the body reader initialises (I16). Bounded so a header flood cannot fill the
        // request arena.
        var hdrs = std.ArrayList(@import("../vm/vm.zig").Header).empty;
        {
            var hit = req.iterateHeaders();
            var total: usize = 0;
            while (hit.next()) |h| {
                if (hdrs.items.len >= 32 or total >= 16 * 1024) break;
                const raw_name = ra.allocator().dupe(u8, h.name) catch break;
                const name = raw_name;
                for (name) |*ch| ch.* = std.ascii.toLower(ch.*);
                const value = ra.allocator().dupe(u8, h.value) catch break;
                total += name.len + value.len;
                hdrs.append(ra.allocator(), .{ .name = name, .value = value }) catch break;
            }
        }

        var bbuf: [4096]u8 = undefined;
        const br = req.readerExpectContinue(&bbuf) catch {
            req.head.keep_alive = false;
            return respond(req, .expectation_failed, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"expectation failed\"}}");
        };
        body_consumed = true;
        const body = br.allocRemaining(ra.allocator(), .limited(cfg.limits.max_source)) catch {
            req.head.keep_alive = false;
            return respond(req, .payload_too_large, "{\"error\":{\"kind\":\"limit_exceeded\",\"message\":\"source too large\"}}");
        };

        var cell: []const u8 = "";
        var src: []const u8 = body;
        var from_form = false;
        // An explicit `?cell=` means "the body is the source", whatever the
        // Content-Type says: curl and most HTTP clients default to
        // application/x-www-form-urlencoded, and sniffing on that header alone
        // turned every raw deploy into a form parse that found no fields.
        if (qcell.len == 0 and ctype.len > 0) {
            if (std.mem.startsWith(u8, ctype, "application/x-www-form-urlencoded")) {
                from_form = true;
                cell = decodeForm(ra.allocator(), body, "cell") orelse "";
                src = decodeForm(ra.allocator(), body, "source") orelse "";
            }
        }
        if (!from_form) {
            cell = qcell;
        }
        if (!router.validCellKey(cell)) {
            if (from_form) return renderWith(sched, req, ra, "cell key is required (letters, digits, . _ : -)");
            return respond(req, .bad_request, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"cell parameter required\"}}");
        }

        const sha = sched.deploy(cell, src) catch |err| {
            // PinLive is the one failure where the module is already serving: the caller
            // must know a retry is required, not that nothing happened.
            std.debug.print("cellar: deploy failed: {s}\n", .{@errorName(err)});
            const kind: []const u8 = if (err == error.PinLive) "deploy_live_unpinned" else "deploy_failed";
            const message: []const u8 = if (err == error.PinLive)
                "module is live but its pin was not written - retry the deploy"
            else
                "deploy failed (module rejected or queue full); see server log";
            const status: std.http.Status = if (err == error.PinLive) .internal_server_error else .bad_request;
            if (from_form) return renderWith(sched, req, ra, message);
            var out: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&out, "{{\"error\":{{\"kind\":\"{s}\",\"message\":\"{s}\"}}}}", .{ kind, message }) catch "{\"error\":{\"kind\":\"deploy_failed\"}}";
            return respond(req, status, msg);
        };
        defer sched.gpa.free(sha);

        if (from_form) {
            return req.respond("", .{
                .status = .see_other,
                .extra_headers = &.{.{ .name = "location", .value = "/admin" }},
            });
        }
        var out: [512]u8 = undefined;
        const ok = std.fmt.bufPrint(&out, "{{\"ok\":true,\"cell\":\"{s}\",\"sha\":\"{s}\"}}", .{ cell, sha }) catch "{\"ok\":true}";
        return respond(req, .ok, ok);
    }

    if (std.mem.eql(u8, target, "/admin") or std.mem.startsWith(u8, target, "/admin?")) {
        // `/admin?token=…` trades the token for an HttpOnly cookie and redirects,
        // so the browser's deploy form can authenticate without JS and the token
        // does not stay in the address bar or in history.
        if (queryParam(target, "token")) |t| {
            if (cfg.admin_token) |want| {
                // Same constant-time comparison as every other auth path: `mem.eql`
                // is a byte-at-a-time oracle on the token.
                if (std.crypto.timing_safe.eql([32]u8, digestOf(t), digestOf(want))) {
                    const secure: []const u8 = if (cookieSecureFor(req, cfg)) "; Secure" else "";
                    const cookie = try std.fmt.allocPrint(ra.allocator(), "cellar_token={s}; HttpOnly; SameSite=Strict; Path=/{s}", .{ t, secure });
                    return req.respond("", .{
                        .status = .see_other,
                        .extra_headers = &.{
                            .{ .name = "location", .value = "/admin" },
                            .{ .name = "set-cookie", .value = cookie },
                            .{ .name = "cache-control", .value = "no-store" },
                        },
                    });
                }
            }
        }
        return renderWith(sched, req, ra, null);
    }
    // Per-cell detail, JSON. Deliberately reads only the control plane and the
    // filesystem: the shard's in-memory cell table belongs to its own thread, and a
    // dashboard that races the scheduler is worse than a dashboard with fewer fields.
    // Blob GC. Deployment rows are pruned to the newest N per module, then any blob
    // file not referenced by a live cell or a surviving deployment is removed. Only on
    // explicit admin request: deleting content-addressed storage is not something a
    // deploy should do behind the operator's back.
    if (std.mem.startsWith(u8, target, "/admin/gc")) {
        if (req.head.method != .POST)
            return respond(req, .method_not_allowed, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"POST required\"}}");
        const reg = sched.registry orelse
            return respond(req, .service_unavailable, "{\"error\":{\"kind\":\"internal\",\"message\":\"registry unavailable\"}}");
        const keep: u32 = blk: {
            const q = queryParam(target, "keep") orelse break :blk 10;
            break :blk std.fmt.parseInt(u32, q, 10) catch 10;
        };
        // keep=0 erases the whole deployment log, including every rollback target.
        if (keep == 0)
            return respond(req, .bad_request, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"keep must be at least 1\"}}");
        // One deploy at a time, and none while the walk decides what is garbage:
        // otherwise a blob written by a deploy that has not pinned it yet looks
        // unreferenced, and the 60 s mtime grace is only a heuristic.
        sched.lockDeploys();
        defer sched.unlockDeploys();
        reg.prune(keep) catch |err|
            return internalError(req, "gc prune", err);

        const a = ra.allocator();
        var referenced = std.StringHashMap(void).init(a);
        {
            const cat = reg.lock();
            // Dupe into the arena while the lock is held. A StringHashMap stores
            // the key slice by reference, and the catalog frees its strings on the
            // next publish — which reg.unlock() below makes possible.
            for (cat.cells) |c| {
                if (c.blob_sha.len == 0) continue;
                const owned = a.dupe(u8, c.blob_sha) catch continue;
                referenced.put(owned, {}) catch {};
            }
            for (cat.deploys) |d| {
                if (d.blob_sha.len == 0) continue;
                const owned = a.dupe(u8, d.blob_sha) catch continue;
                referenced.put(owned, {}) catch {};
            }
            reg.unlock();
        }

        // A cell whose state.db row is gone still pins its module in meta.json —
        // that is ADR-0007's recovery path, and GC must not eat the blob it names.
        // The directory is the digest, not the key, so read every cell's file.
        const meta_mod = @import("../store/meta.zig");
        var meta_pins = std.ArrayList([]const u8).empty;
        const cells_root = std.fmt.allocPrint(a, "{s}/cells", .{cfg.limits.data_dir}) catch "";
        if (std.Io.Dir.cwd().openDir(sched.io, cells_root, .{ .iterate = true })) |cd0| {
            var cd = cd0;
            defer cd.close(sched.io);
            var cit = cd.iterate();
            while (cit.next(sched.io) catch null) |ce| {
                const mp = std.fmt.allocPrint(a, "{s}/{s}/meta.json", .{ cells_root, ce.name }) catch continue;
                const f = std.Io.Dir.cwd().openFile(sched.io, mp, .{}) catch continue;
                var mbuf: [4096]u8 = undefined;
                const n = f.readPositionalAll(sched.io, &mbuf, 0) catch {
                    f.close(sched.io);
                    continue;
                };
                f.close(sched.io);
                var sha_out: [128]u8 = undefined;
                if (meta_mod.field(mbuf[0..n], "blob_sha", &sha_out)) |pinned| {
                    if (pinned.len > 0) meta_pins.append(a, a.dupe(u8, pinned) catch continue) catch {};
                }
            }
        } else |_| {}

        var deleted: usize = 0;
        var kept: usize = 0;
        const blobs_path = std.fmt.allocPrint(a, "{s}/blobs", .{cfg.limits.data_dir}) catch
            return respond(req, .internal_server_error, "{}");
        if (std.Io.Dir.cwd().openDir(sched.io, blobs_path, .{ .iterate = true })) |opened| {
            var dir = opened;
            defer dir.close(sched.io);
            var it = dir.iterate();
            while (it.next(sched.io) catch null) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;
                const sha = entry.name[0 .. entry.name.len - ".bin".len];
                if (referenced.contains(sha)) {
                    kept += 1;
                    continue;
                }
                var pinned_by_meta = false;
                for (meta_pins.items) |mp_sha| {
                    if (std.mem.eql(u8, mp_sha, sha)) {
                        pinned_by_meta = true;
                        break;
                    }
                }
                if (pinned_by_meta) {
                    kept += 1;
                    continue;
                }
                // A blob written in the last minute may belong to a deploy that has not
                // pinned its cell row yet; deleting it would leave a cell pointing at a
                // file that no longer exists.
                const st = std.Io.Dir.statFile(dir, sched.io, entry.name, .{}) catch continue;
                if (wallNs() - @as(i64, @intCast(st.mtime.nanoseconds)) < @as(i64, cfg.limits.gc_min_age_s) * std.time.ns_per_s) {
                    kept += 1;
                    continue;
                }
                dir.deleteFile(sched.io, entry.name) catch continue;
                deleted += 1;
            }
        } else |_| {}

        var out: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&out, "{{\"ok\":true,\"keep\":{d},\"kept\":{d},\"deleted\":{d}}}", .{ keep, kept, deleted }) catch "{}";
        return respond(req, .ok, body);
    }

    if (std.mem.startsWith(u8, target, "/admin/snapshot")) {
        if (req.head.method != .POST)
            return respond(req, .method_not_allowed, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"POST required\"}}");
        const cell = queryParam(target, "cell") orelse
            return respond(req, .bad_request, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"cell required\"}}");
        if (!router.validCellKey(cell))
            return respond(req, .bad_request, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"invalid cell key\"}}");

        // The path is computed here, never taken from the request: an admin endpoint
        // that writes to a caller-supplied path is a file-write primitive.
        const dir = std.fmt.allocPrint(ra.allocator(), "{s}/snapshots", .{cfg.limits.data_dir}) catch
            return respond(req, .internal_server_error, "{}");
        std.Io.Dir.cwd().createDirPath(sched.io, dir) catch {};
        const path = std.fmt.allocPrint(ra.allocator(), "{s}/{s}-{d}.db", .{ dir, cell, wallSeconds() }) catch
            return respond(req, .internal_server_error, "{}");

        sched.snapshot(cell, path) catch |err|
            return internalError(req, "snapshot", err);

        var size: u64 = 0;
        if (std.Io.Dir.cwd().statFile(sched.io, path, .{})) |st| {
            size = st.size;
        } else |_| {}

        var out: [768]u8 = undefined;
        const body = std.fmt.bufPrint(&out, "{{\"ok\":true,\"cell\":\"{s}\",\"path\":\"{s}\",\"bytes\":{d}}}", .{ cell, path, size }) catch "{}";
        return respond(req, .ok, body);
    }

    if (std.mem.startsWith(u8, target, "/admin/cells/")) {
        const rest = target["/admin/cells/".len..];
        const q = std.mem.indexOfScalar(u8, rest, '?') orelse rest.len;
        const cell = rest[0..q];
        if (!router.validCellKey(cell))
            return respond(req, .bad_request, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"invalid cell key\"}}");
        const paths = @import("../store/paths.zig");

        var module: []const u8 = "";
        var version: u32 = 0;
        var blob: []const u8 = "";
        var created: i64 = 0;
        var last_seen: i64 = 0;
        var keys: usize = 0;
        if (sched.registry) |reg| {
            const cat = reg.lock();
            for (cat.cells) |c| {
                if (std.mem.eql(u8, c.key, cell)) {
                    // Copy out under the lock: the catalog and every string in it
                    // are freed by the next publish, which can run the moment
                    // reg.unlock() returns — and this handler does two statFile
                    // calls before it formats these.
                    module = ra.allocator().dupe(u8, c.module) catch c.module;
                    blob = ra.allocator().dupe(u8, c.blob_sha) catch c.blob_sha;
                    version = c.version;
                    created = c.created_at;
                    last_seen = c.last_seen;
                }
            }
            for (cat.keys) |k| {
                if (k.live and std.mem.eql(u8, k.cell_key, cell)) keys += 1;
            }
            reg.unlock();
        }

        var db_bytes: u64 = 0;
        var wal_bytes: u64 = 0;
        if (paths.cellPaths(ra.allocator(), null, cfg.limits.data_dir, cell)) |p| {
            if (std.Io.Dir.cwd().statFile(sched.io, p.db, .{})) |st| {
                db_bytes = st.size;
            } else |_| {}
            const wal = std.fmt.allocPrint(ra.allocator(), "{s}-wal", .{p.db}) catch "";
            if (wal.len > 0) {
                if (std.Io.Dir.cwd().statFile(sched.io, wal, .{})) |st| {
                    wal_bytes = st.size;
                } else |_| {}
            }
        } else |_| {}

        var out: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&out, "{{\"cell\":\"{s}\",\"module\":\"{s}\",\"version\":{d},\"blob_sha\":\"{s}\",\"created_at\":{d},\"last_seen\":{d},\"db_bytes\":{d},\"wal_bytes\":{d},\"keys\":{d}}}", .{
            cell,
            module,
            version,
            blob,
            created,
            last_seen,
            db_bytes,
            wal_bytes,
            keys,
        }) catch "{}";
        return respond(req, .ok, body);
    }

    if (std.mem.startsWith(u8, target, "/admin/cells")) {
        const admin = @import("admin.zig");
        const rows = admin.cellRows(ra.allocator(), sched) catch
            return respond(req, .internal_server_error, "{}");
        return respondHtml(req, .ok, rows);
    }

    // Server-sent events: one stat frame per second. The dashboard's counters
    // move without a refresh and without polling; the client is
    // `new EventSource('/admin/events')`.
    if (std.mem.startsWith(u8, target, "/admin/events")) {
        var sbuf: [1024]u8 = undefined;
        var bw = try req.respondStreaming(&sbuf, .{ .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "x-accel-buffering", .value = "no" },
            },
            .transfer_encoding = .chunked,
        } });
        var i: usize = 0;
        // Bounded so a curl without --max-time still terminates; a real client
        // reconnects, which is what EventSource does anyway.
        while (i < 600 and !sched.stopping.load(.acquire)) : (i += 1) {
            var ev: [256]u8 = undefined;
            const m = &sched.metrics;
            const known: usize = if (sched.registry) |r| r.cellCount() else 0;
            const frame = std.fmt.bufPrint(&ev, "event: stats\ndata: {{\"uptime\":{d},\"cells\":{d},\"resident\":{d},\"invocations\":{d},\"errors\":{d}}}\n\n", .{
                sched.uptimeSeconds(),
                known,
                m.cells.load(.monotonic),
                m.invocations.load(.monotonic),
                m.errors.load(.monotonic),
            }) catch break;
            bw.writer.writeAll(frame) catch break;
            // BodyWriter.flush() only flushes the protocol writer, not its own
            // buffer: without writer.flush() the frame sits in `sbuf` until it
            // fills or the stream ends, which looks like an empty SSE feed.
            bw.writer.flush() catch break;
            bw.flush() catch break;
            std.Io.sleep(sched.io, .{ .nanoseconds = std.time.ns_per_s }, .awake) catch break;
        }
        bw.end() catch {};
        return;
    }

    if (std.mem.eql(u8, target, "/metrics")) {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(ra.allocator());
        const known: usize = if (sched.registry) |r| r.cellCount() else 0;
        const up_ns = if (sched.started_ns != 0) @import("../runtime/scheduler.zig").now() - sched.started_ns else 0;
        sched.metrics.renderText(ra.allocator(), &out, .{
            .version = "0.1.0",
            .vm = cfg.vm,
            .shards = cfg.limits.shards,
            .max_cells = cfg.limits.max_cells,
            .deadline_ms = cfg.limits.deadline_ms,
            .uptime_s = up_ns / std.time.ns_per_s,
            .cells_known = known,
            .cells_resident = sched.metrics.cells.load(.monotonic),
        }) catch return respond(req, .internal_server_error, "{}");
        guardKeepAlive(req);
        return req.respond(out.items, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" },
                .{ .name = "server", .value = "cellar" },
            },
        });
    }

    if (std.mem.eql(u8, target, "/healthz")) {
        var out: [512]u8 = undefined;
        // Two different numbers, two different names: `cells` is what the
        // registry knows about on disk, `resident` is what this process holds in
        // memory right now. Reporting one under the other's name is a bug
        // waiting to be written against.
        const known: usize = if (sched.registry) |r| r.cellCount() else 0;
        // `max_cells` is per shard, so the effective ceiling is shards × max_cells.
        // Reporting both is the only way the number can be checked from outside.
        const body = std.fmt.bufPrint(&out, "{{\"ok\":true,\"cells\":{d},\"resident\":{d},\"max_cells\":{d},\"shards\":{d},\"invocations\":{d},\"errors\":{d},\"version\":\"0.1.0\"}}", .{
            known,
            sched.metrics.cells.load(.monotonic),
            cfg.limits.max_cells,
            cfg.limits.shards,
            sched.metrics.invocations.load(.monotonic),
            sched.metrics.errors.load(.monotonic),
        }) catch "{}";
        return respond(req, .ok, body);
    }

    const route = router.parse(target) catch
        return respond(req, .not_found, "{\"error\":{\"kind\":\"not_found\",\"message\":\"no route\"}}");

    // Copy the identity out of the head BEFORE the body reader initialises:
    // `readerExpectNone` calls `head.invalidateStrings()` and the body then reuses
    // the same buffer, so `route.cell` afterwards is body bytes. A request whose
    // body spelled a different cell key used to invoke that cell.
    const cell_key = ra.allocator().dupe(u8, route.cell) catch
        return respond(req, .internal_server_error, "{}");
    const fn_name = ra.allocator().dupe(u8, route.fn_name) catch
        return respond(req, .internal_server_error, "{}");

    if (!router.validCellKey(cell_key))
        return respond(req, .bad_request, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"invalid cell key\"}}");

    if (req.head.method != .POST)
        return respond(req, .method_not_allowed, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"POST required\"}}");

    // Rate limit per cell, before anything expensive. Keyed on the cell rather than
    // the credential: the damage a bad actor can do here is make one cell hot, and
    // that cell shares a shard and a database with nothing else.
    if (limiter) |*l| {
        if (!l.allow(sched.io, cell_key, @import("../runtime/scheduler.zig").now())) {
            guardKeepAlive(req);
            return req.respond("{\"error\":{\"kind\":\"rate_limited\",\"message\":\"too many requests\"}}", .{
                .status = .too_many_requests,
                .extra_headers = &.{
                    .{ .name = "retry-after", .value = "1" },
                    .{ .name = "content-type", .value = "application/json" },
                },
            });
        }
    }

    // Drain: once SIGTERM has been seen, refuse new work so the process can finish
    // what it already accepted instead of dying mid-transaction.
    if (sched.stopping.load(.acquire))
        return respond(req, .service_unavailable, "{\"error\":{\"kind\":\"draining\",\"message\":\"server is shutting down\"}}");

    // Data-plane auth. Off unless `--cell-token` is set: the README says guest code
    // is trusted, so the default stays open for local play; setting it is what makes
    // a box on the network safe-ish. Checked before the body is read.
    //
    // A cell with its own credential requires it and ignores the shared token —
    // otherwise one leaked global password would still open every cell.
    var has_own = false;
    var key_ok = false;
    if (sched.registry) |reg| {
        const cat = reg.lock();
        for (cat.keys) |k| {
            if (!std.mem.eql(u8, k.cell_key, cell_key)) continue;
            // Keyed means "has ever had a credential", revoked rows included:
            // otherwise revoking the last key silently fell a cell back to the
            // shared token (or to no check at all), the opposite of what revoking
            // is for.
            has_own = true;
            // Any live key for the cell is acceptable: that is what makes rotation
            // with overlap possible — mint, move the client, then revoke.
            if (k.live and authorizedDigest(req, k.digest, false)) key_ok = true;
        }
        reg.unlock();
    }
    if (has_own) {
        if (!key_ok)
            return respond(req, .unauthorized, "{\"error\":{\"kind\":\"unauthorized\",\"message\":\"cell key required\"}}");
    } else if (cfg.cell_token) |want| {
        // An empty token is a token nobody can send, not "no token configured".
        // Skipping the check here was the sibling of the empty-admin-token bug.
        if (want.len == 0 or !authorized(req, want, false))
            return respond(req, .unauthorized, "{\"error\":{\"kind\":\"unauthorized\",\"message\":\"cell token required\"}}");
    }

    // Cluster seam: a cell that belongs to another node is redirected, never
    // served locally (ADR-0016). In MVP this branch is only reachable when
    // --peers is set.
    switch (sched.placement(cell_key)) {
        .local => {},
        .remote => |addr| {
            var loc: [512]u8 = undefined;
            const dest = std.fmt.bufPrint(&loc, "http://{s}/c/{s}/{s}", .{ addr, cell_key, fn_name }) catch "";
            guardKeepAlive(req);
            return req.respond("", .{
                .status = .temporary_redirect,
                .extra_headers = &.{
                    .{ .name = "location", .value = dest },
                    .{ .name = "server", .value = "cellar" },
                },
            });
        },
    }

    // Copied BEFORE the body is read: `req.head`'s strings are invalidated once
    // the body reader initialises (I16). Bounded so a header flood cannot fill the
    // request arena.
    var hdrs = std.ArrayList(@import("../vm/vm.zig").Header).empty;
    {
        var hit = req.iterateHeaders();
        var total: usize = 0;
        while (hit.next()) |h| {
            if (hdrs.items.len >= 32 or total >= 16 * 1024) break;
            const raw_name = ra.allocator().dupe(u8, h.name) catch break;
            const name = raw_name;
            for (name) |*ch| ch.* = std.ascii.toLower(ch.*);
            const value = ra.allocator().dupe(u8, h.value) catch break;
            total += name.len + value.len;
            hdrs.append(ra.allocator(), .{ .name = name, .value = value }) catch break;
        }
    }

    var bbuf: [4096]u8 = undefined;
    // readerExpectNone asserts `head.expect == null`, and a client sending
    // `Expect: 100-continue` made that assert abort the whole process.
    const br = req.readerExpectContinue(&bbuf) catch {
        req.head.keep_alive = false;
        return respond(req, .expectation_failed, "{\"error\":{\"kind\":\"bad_request\",\"message\":\"expectation failed\"}}");
    };
    body_consumed = true;
    const body = br.allocRemaining(ra.allocator(), .limited(cfg.limits.max_body)) catch {
        // Do not keep a connection whose body we stopped reading: the rest of it
        // would be parsed as the next request (CL desync).
        req.head.keep_alive = false;
        return respond(req, .payload_too_large, "{\"error\":{\"kind\":\"limit_exceeded\",\"message\":\"body too large\"}}");
    };

    var inv = Invocation{ .cell_key = cell_key, .fn_name = fn_name, .body = body, .arena = ra, .headers = hdrs.items };
    ra.give();
    sched.submit(&inv) catch {
        ra.take();
        return respond(req, .service_unavailable, "{\"error\":{\"kind\":\"limit_exceeded\",\"message\":\"queue full\"}}");
    };
    sched.wait(&inv);
    ra.take();

    // Every invoke response carries the invocation id, so a caller can quote it
    // when asking "why was this slow" and the log line can be found by grep.
    const id_hex = std.fmt.bytesToHex(inv.id, .lower);

    if (inv.fail) |f| {
        // A shed invocation is 503 with a retry hint (the server is busy); a guest
        // that ran too long is 504 (the work itself timed out). Different fixes.
        const status: std.http.Status = switch (f.kind) {
            .timeout => if (f.queue_timeout) .service_unavailable else .gateway_timeout,
            .internal => .internal_server_error,
            else => .internal_server_error,
        };
        var esc_buf: [512]u8 = undefined;
        const json = @import("../util/json.zig");
        const safe = json.escapeInto(&esc_buf, json.utf8Prefix(f.msg, 150));
        var out: [1024]u8 = undefined;
        const kind: []const u8 = if (f.queue_timeout) "overloaded" else @tagName(f.kind);
        const msg = std.fmt.bufPrint(&out, "{{\"error\":{{\"kind\":\"{s}\",\"message\":\"{s}\"}}}}", .{ kind, safe }) catch "{\"error\":{\"kind\":\"internal\",\"message\":\"error\"}}";
        if (f.queue_timeout) {
            return req.respond(msg, .{
                .status = status,
                .extra_headers = &.{
                    .{ .name = "retry-after", .value = "1" },
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "x-cellar-invocation", .value = &id_hex },
                },
            });
        }
        return req.respond(msg, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "server", .value = "cellar" },
                .{ .name = "x-cellar-invocation", .value = &id_hex },
            },
        });
    }

    return req.respond(inv.out, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "server", .value = "cellar" },
            .{ .name = "x-cellar-invocation", .value = &id_hex },
        },
    });
}

var stop_requested = std.atomic.Value(bool).init(false);

/// SIGTERM/SIGINT handler. Signal handlers may only touch async-signal-safe things,
/// so this stores a flag and nothing else.
fn onStopSignal(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

fn installStopSignals() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onStopSignal },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// Waits for the signal, then lets accepted work finish.
///
/// The invariant is the same one the whole runtime is built on: an invocation is a
/// transaction. Killing the process mid-flight costs a client its response and
/// leaves SQLite to roll back on the next open; draining costs a few milliseconds
/// and keeps both. Bounded by `drain_ms` so a wedged guest cannot block shutdown
/// forever — whatever is still open then is rolled back by WAL recovery.
fn drainWatcher(sched: *Scheduler, drain_ms: u64) void {
    const io = sched.io;
    while (!stop_requested.load(.acquire)) {
        std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }
    sched.stopping.store(true, .release);
    const n = sched.outstanding.load(.monotonic);
    std.debug.print("cellar: draining ({d} outstanding)\n", .{n});

    const t0 = @import("../runtime/scheduler.zig").now();
    while (sched.outstanding.load(.monotonic) > 0) {
        if (@import("../runtime/scheduler.zig").now() - t0 > drain_ms * std.time.ns_per_ms) {
            std.debug.print("cellar: drain timed out, exiting with work in flight\n", .{});
            break;
        }
        std.Io.sleep(io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    }

    // An invocation is done when it has committed, not when the client has the
    // bytes: the response sits in the connection's buffered writer until that thread
    // flushes and closes. Exiting on `inflight == 0` alone truncates responses —
    // found by G3 failing roughly one run in three with a body and no status line.
    // Long enough to flush a response that legitimately takes as long as an
    // invocation may: a flat 1 s truncated slow clients, which is the same class of
    // bug the drain was introduced to fix.
    const grace_ms: u64 = @max(1000, sched.cfg.limits.deadline_ms + 1000);
    const t1 = @import("../runtime/scheduler.zig").now();
    while (busy_conns.load(.monotonic) > 0) {
        if (@import("../runtime/scheduler.zig").now() - t1 > grace_ms * std.time.ns_per_ms) {
            std.debug.print("cellar: {d} request(s) still in flight, exiting anyway\n", .{busy_conns.load(.monotonic)});
            break;
        }
        std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    }

    std.debug.print("cellar: drained, exiting\n", .{});
    std.process.exit(0);
}

fn respondHtml(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    guardKeepAlive(req);
    return req.respond(body, .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}

fn renderWith(sched: *Scheduler, req: *std.http.Server.Request, ra: *RequestArena, err_msg: ?[]const u8) !void {
    const admin = @import("admin.zig");
    const a = ra.allocator();

    var ubuf: [32]u8 = undefined;
    var cbuf: [24]u8 = undefined;
    var rbuf: [24]u8 = undefined;
    var ibuf: [24]u8 = undefined;
    var ebuf: [24]u8 = undefined;

    const m = &sched.metrics;
    const cells_known: usize = if (sched.registry) |r| r.cellCount() else 0;

    var banner: []const u8 = "";
    if (err_msg) |msg| {
        const esc = try admin.escape(a, msg);
        banner = try std.fmt.allocPrint(a, "<div class=\"banner\">{s}</div>", .{esc});
    }

    const page = try admin.render(a, .{
        .uptime = try std.fmt.bufPrint(&ubuf, "{d}s", .{sched.uptimeSeconds()}),
        .cells = try std.fmt.bufPrint(&cbuf, "{d}", .{cells_known}),
        .resident = try std.fmt.bufPrint(&rbuf, "{d}", .{m.cells.load(.monotonic)}),
        .invocations = try std.fmt.bufPrint(&ibuf, "{d}", .{m.invocations.load(.monotonic)}),
        .errors = try std.fmt.bufPrint(&ebuf, "{d}", .{m.errors.load(.monotonic)}),
        .rows = try admin.cellRows(a, sched),
        .deploys = try admin.deployRows(a, sched),
        .error_banner = banner,
    });
    return respondHtml(req, .ok, page);
}

fn decodeForm(a: std.mem.Allocator, body: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (!std.mem.eql(u8, kv[0..eq], key)) continue;
        return urlDecode(a, kv[eq + 1 ..]) catch null;
    }
    return null;
}

fn urlDecode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '+') {
            try out.append(a, ' ');
            i += 1;
            continue;
        }
        if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(a, c);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(a, c);
                i += 1;
                continue;
            };
            try out.append(a, hi * 16 + lo);
            i += 3;
            continue;
        }
        try out.append(a, c);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

/// Wall clock nanoseconds, for comparing against file mtimes.
fn wallNs() i64 {
    return sys.realtimeNs();
}

/// Wall clock seconds.
fn wallSeconds() i64 {
    return sys.realtimeSec();
}

/// True for 127.0.0.0/8, localhost and ::1. Deliberately textual: the listener is a
/// string in the config, and this only decides whether admin *reads* need a token.
fn listenerIsLoopback(listen: []const u8) bool {
    if (std.mem.startsWith(u8, listen, "127.")) return true;
    if (std.mem.startsWith(u8, listen, "localhost:")) return true;
    if (std.mem.startsWith(u8, listen, "[::1]:")) return true;
    if (std.mem.startsWith(u8, listen, "::1")) return true;
    return false;
}

/// A read may proceed if the listener is loopback, the operator opted out, a valid
/// token arrived as a header/cookie, or the request carries `?token=` — that last case
/// is the dashboard unlock (`GET /admin?token=…`), which cannot send a header yet.
fn adminReadAllowed(req: *std.http.Server.Request, cfg: config.Config, target: []const u8) bool {
    if (listenerIsLoopback(cfg.limits.listen) or cfg.admin_open) return true;
    if (authorized(req, cfg.admin_token, true)) return true;
    if (cfg.admin_token) |want| {
        // Only the unlock endpoint may authenticate from the query string. Accepting
        // `?token=` on every admin read put the secret in browser history and in
        // every access log in front of the service.
        const unlock = std.mem.eql(u8, target, "/admin") or std.mem.startsWith(u8, target, "/admin?");
        if (unlock) {
            if (queryParam(target, "token")) |given| {
                return std.crypto.timing_safe.eql([32]u8, digestOf(given), digestOf(want));
            }
        }
    }
    return false;
}

fn digestOf(secret: []const u8) [32]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &d, .{});
    return d;
}

/// Constant-time token check.
///
/// Two things were wrong with the obvious version: `std.mem.eql` returns as soon as
/// a byte differs (a timing oracle on a secret), and returning from inside the loop
/// let the *order* of headers decide the result. Here every candidate is hashed and
/// compared in constant time, and all headers are examined. Cookies are accepted for
/// the dashboard and never for the data plane, where a browser-stored secret should
/// not be able to invoke cells.
/// True when the admin token in a *header* is what authenticated this request (as
/// opposed to the dashboard cookie). Presence of an Authorization header is not enough:
/// an SSO sidecar that injects `Authorization: Basic ...` must not switch the origin
/// check off for a cookie-authenticated request.
fn hasHeaderToken(req: *std.http.Server.Request, admin_token: ?[]const u8) bool {
    const want = admin_token orelse return false;
    if (want.len == 0) return false;
    return authorizedDigest(req, digestOf(want), false);
}

/// `Sec-Fetch-Site` when the browser sends it, otherwise an `Origin`/`Host` comparison.
/// A request with neither (curl, a script) is allowed: it is not a browser.
fn sameOrigin(req: *std.http.Server.Request) bool {
    var origin: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var fetch_site: ?[]const u8 = null;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) {
            // Repeated Origin/Host are legal as a comma list but a disagreement between
            // us and a front end about which one counts is exactly the kind of gap this
            // check exists to close, so refuse duplicates.
            if (origin != null) return false;
            origin = h.value;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "host")) {
            if (host != null) return false;
            host = h.value;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "sec-fetch-site")) fetch_site = h.value;
    }
    // Origin wins: a proxy or extension that rewrites Sec-Fetch-* must not be able to
    // make a foreign Origin look local.
    if (origin) |o| {
        const h = host orelse return false;
        const sep = std.mem.indexOf(u8, o, "://") orelse return false;
        return std.mem.eql(u8, o[sep + 3 ..], h);
    }
    if (fetch_site) |v| {
        if (std.mem.eql(u8, v, "same-origin")) return true;
        // "none" means a user-initiated navigation, i.e. a GET from the address bar. A
        // mutating request has no business claiming it.
        return std.mem.eql(u8, v, "none") and
            (req.head.method == .GET or req.head.method == .HEAD);
    }
    return true;
}

fn authorized(req: *std.http.Server.Request, token: ?[]const u8, allow_cookie: bool) bool {
    const want = token orelse return false;
    if (want.len == 0) return false;
    return authorizedDigest(req, digestOf(want), allow_cookie);
}

fn authorizedDigest(req: *std.http.Server.Request, want_digest: [32]u8, allow_cookie: bool) bool {
    var ok = false;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        var cand: ?[]const u8 = null;
        if (std.ascii.eqlIgnoreCase(h.name, "x-cellar-token")) {
            cand = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            if (h.value.len > 7 and std.ascii.startsWithIgnoreCase(h.value, "bearer "))
                cand = h.value[7..];
        } else if (allow_cookie and std.ascii.eqlIgnoreCase(h.name, "cookie")) {
            var parts = std.mem.splitScalar(u8, h.value, ';');
            while (parts.next()) |p| {
                const kv = std.mem.trim(u8, p, " ");
                if (std.mem.startsWith(u8, kv, "cellar_token=")) cand = kv["cellar_token=".len..];
            }
        }
        if (cand) |c| ok = ok or std.crypto.timing_safe.eql([32]u8, digestOf(c), want_digest);
    }
    return ok;
}

fn queryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
    }
    return null;
}

/// True once the current request's body has been read by a handler. Threadlocal
/// because it is per connection thread and reset at the top of every `handle`.
threadlocal var body_consumed: bool = false;

/// An early response on a request whose body was never read must not keep the
/// connection: std would drain that body to keep the stream in sync, with no cap and no
/// read timeout, so a client dribbling a huge body parks the connection thread for as
/// long as it likes. Closing is the only bounded answer, and it has to apply to *every*
/// responder — the direct `req.respond` sites as well as this one.
fn guardKeepAlive(req: *std.http.Server.Request) void {
    if (!body_consumed and
        ((req.head.content_length orelse 0) > 0 or req.head.transfer_encoding != .none))
        req.head.keep_alive = false;
}

fn respond(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    guardKeepAlive(req);
    try req.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "server", .value = "cellar" },
        },
    });
}

test "loopback detection and raw TE scan" {
    try std.testing.expect(listenerIsLoopback("127.0.0.1:8080"));
    try std.testing.expect(listenerIsLoopback("localhost:8080"));
    try std.testing.expect(listenerIsLoopback("[::1]:8080"));
    try std.testing.expect(!listenerIsLoopback("0.0.0.0:8080"));
    try std.testing.expect(!listenerIsLoopback("192.168.1.5:8080"));
    try std.testing.expect(rawHasTransferEncoding("POST / HTTP/1.1\r\nTransfer-Encoding : chunked\r\n\r\n"));
    try std.testing.expect(!rawHasTransferEncoding("POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\n"));
    try std.testing.expectEqualStrings("K", queryParam("/admin/key?cell=K&x=1", "cell").?);
    try std.testing.expect(queryParam("/admin/key", "cell") == null);
}
