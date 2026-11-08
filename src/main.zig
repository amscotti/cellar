const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const http_server = @import("http/server.zig");

pub const version = build_options.version;

const fixture = @embedFile("fixtures/echo.lua");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var it = std.process.Args.Iterator.init(init.args);
    defer it.deinit();
    _ = it.next(); // argv[0]

    const cmd = it.next() orelse {
        try usage();
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "version")) {
        try versionLine();
        return;
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help")) {
        try usage();
        return;
    }

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(arena);
    while (it.next()) |a| try rest.append(arena, a);

    // Client commands: deploy / invoke / cells. These talk to a running server
    // over the same HTTP API the dashboard uses, so there is one control surface.
    if (std.mem.eql(u8, cmd, "deploy") or std.mem.eql(u8, cmd, "invoke") or std.mem.eql(u8, cmd, "cells")) {
        const cli = @import("cli.zig");
        var threaded = std.Io.Threaded.init(arena, .{});
        defer threaded.deinit();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, cmd);
        for (rest.items) |a| try argv.append(arena, a);
        const code = try cli.run(arena, threaded.io(), argv.items);
        std.process.exit(code);
    }

    const cfg = config.parse(arena, rest.items) catch |err| {
        std.debug.print("config error: {s}\n", .{@errorName(err)});
        return err;
    };

    if (std.mem.eql(u8, cmd, "serve")) {
        try http_server.serve(std.heap.page_allocator, cfg, fixture);
        return;
    }
    if (std.mem.eql(u8, cmd, "doctor")) {
        try doctor(arena, cfg);
        return;
    }

    std.debug.print("unknown command: {s}\n", .{cmd});
    try usage();
    return error.UnknownCommand;
}

/// Read-only sanity report: config parses, the listen address is well
/// formed, the data directory looks like a cellar data directory, and the
/// operator has a durable admin credential. Never creates or writes state.
fn doctor(gpa: std.mem.Allocator, cfg: config.Config) !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var problems: usize = 0;

    try versionLine();

    // Listen address.
    const listen = cfg.limits.listen;
    if (std.mem.lastIndexOfScalar(u8, listen, ':')) |colon| {
        const host = listen[0..colon];
        const port = std.fmt.parseInt(u16, listen[colon + 1 ..], 10) catch 0;
        if (port == 0) {
            std.debug.print("doctor: FAIL listen {s}: bad port\n", .{listen});
            problems += 1;
        } else if (std.Io.net.IpAddress.parse(host, port)) |_| {
            std.debug.print("doctor: ok   listen {s}\n", .{listen});
        } else |_| {
            std.debug.print("doctor: FAIL listen {s}: unparseable host\n", .{listen});
            problems += 1;
        }
    } else {
        std.debug.print("doctor: FAIL listen {s}: expected host:port\n", .{listen});
        problems += 1;
    }

    // Data directory (report only; `serve` creates it).
    const data_dir = cfg.limits.data_dir;
    var data_exists = true;
    if (std.Io.Dir.cwd().statFile(io, data_dir, .{})) |_| {} else |_| {
        data_exists = false;
    }
    if (!data_exists) {
        // statFile on a directory may fail where openDir succeeds; probe properly.
        if (std.Io.Dir.cwd().openDir(io, data_dir, .{})) |d| {
            var dd = d;
            dd.close(io);
            data_exists = true;
        } else |_| {}
    }
    if (!data_exists) {
        std.debug.print("doctor: ok   data dir {s} (absent; created by serve)\n", .{data_dir});
    } else {
        std.debug.print("doctor: ok   data dir {s} (present)\n", .{data_dir});
        const state_path = std.fmt.allocPrint(gpa, "{s}/state.db", .{data_dir}) catch "";
        if (state_path.len > 0) {
            if (std.Io.Dir.cwd().statFile(io, state_path, .{})) |st| {
                std.debug.print("doctor: ok   state.db present ({d} bytes)\n", .{st.size});
            } else |_| {
                std.debug.print("doctor: ok   state.db absent (fresh install; cells recover from meta.json)\n", .{});
            }
        }
        const cells_path = std.fmt.allocPrint(gpa, "{s}/cells", .{data_dir}) catch "";
        if (cells_path.len > 0) {
            var n_cells: usize = 0;
            if (std.Io.Dir.cwd().openDir(io, cells_path, .{ .iterate = true })) |opened| {
                var dir = opened;
                defer dir.close(io);
                var it = dir.iterate();
                while (it.next(io) catch null) |_| n_cells += 1;
            } else |_| {}
            std.debug.print("doctor: ok   cell directories: {d}\n", .{n_cells});
        }
    }

    // Admin credential durability (never print the secret).
    if (cfg.admin_token_file) |path| {
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
            if (st.size == 0) {
                std.debug.print("doctor: FAIL admin token file {s} is empty\n", .{path});
                problems += 1;
            } else {
                std.debug.print("doctor: ok   admin token from file {s}\n", .{path});
            }
        } else |_| {
            std.debug.print("doctor: FAIL admin token file {s} not readable\n", .{path});
            problems += 1;
        }
    } else if (cfg.admin_token) |t| {
        if (t.len == 0) {
            std.debug.print("doctor: WARN empty --admin-token; a random token is generated per start\n", .{});
        } else {
            std.debug.print("doctor: ok   admin token from flag (prefer --admin-token-file: flags show in ps)\n", .{});
        }
    } else if (std.c.getenv("CELLAR_ADMIN_TOKEN")) |_| {
        std.debug.print("doctor: ok   admin token from CELLAR_ADMIN_TOKEN\n", .{});
    } else {
        std.debug.print("doctor: WARN no durable admin token; serve generates one per start (set --admin-token-file)\n", .{});
    }

    // Peers must be `node_id@host:port` for the Locator to use them.
    for (cfg.peers) |p| {
        if (std.mem.indexOfScalar(u8, p, '@') == null) {
            std.debug.print("doctor: FAIL peer '{s}' is not node_id@host:port (ignored by placement)\n", .{p});
            problems += 1;
        }
    }
    if (cfg.peers.len > 0 and problems == 0)
        std.debug.print("doctor: ok   peers: {d} (placement only; no cluster transport yet)\n", .{cfg.peers.len});

    // Fetch posture.
    if (!cfg.allow_fetch) {
        std.debug.print("doctor: ok   http.fetch disabled (default)\n", .{});
    } else if (cfg.fetch_allow_private) {
        std.debug.print("doctor: WARN http.fetch may reach private/loopback addresses (--fetch-allow-private)\n", .{});
    } else if (cfg.fetch_allow_hosts.len > 0) {
        std.debug.print("doctor: ok   http.fetch restricted to {d} allowlisted host(s)\n", .{cfg.fetch_allow_hosts.len});
    } else {
        std.debug.print("doctor: ok   http.fetch public hosts only (private/metadata blocked, redirects not followed)\n", .{});
    }

    std.debug.print("doctor: shards={d} max_conns={d} max_cells(per shard)={d} deadline_ms={d}\n", .{
        cfg.limits.shards, cfg.limits.max_conns, cfg.limits.max_cells, cfg.limits.deadline_ms,
    });
    if (problems > 0) {
        std.debug.print("doctor: {d} problem(s) found\n", .{problems});
        return error.DoctorFailed;
    }
    std.debug.print("doctor: all checks passed\n", .{});
}

fn versionLine() !void {
    std.debug.print("cellar {s} (vm={s}, zig {s}, caps: preempt=true memcap=true catchable_oom=true)\n", .{
        version,
        build_options.vm,
        "0.17.0",
    });
}

fn usage() !void {
    std.debug.print(
        \\cellar — function runtime with a database per cell
        \\
        \\usage:
        \\  cellar serve [--listen addr:port] [--data dir] [--shards N] [--admin-token-file F] [--cell-token-file F]
        \\  cellar deploy <file> --cell <key> [--server URL] [--token-file F]
        \\  cellar invoke <cell> <fn> [body] [--server URL] [--token-file F]
        \\  cellar cells [--server URL] [--token-file F]
        \\  cellar version
        \\  cellar doctor [serve flags]
        \\
        \\flags: --listen --data --shards --max-conns --max-cells --deadline-ms
        \\       --queue-timeout-ms --vm-budget-mb --db-max-mb --admin-token(-file) --cell-token(-file)
        \\       --allow-fetch --fetch-allow-host --fetch-allow-private --cookie-secure
        \\       --rate-per-s --rate-burst --drain-ms --fetch-workers --gc-min-age-s
        \\       --admin-open --node-id --advertise --peers
        \\
        \\environment: CELLAR_ADMIN_TOKEN, CELLAR_CELL_TOKEN (serve); CELLAR_TOKEN, CELLAR_SERVER (client)
        \\
    , .{});
}
