const std = @import("std");
const config = @import("config.zig");

fn envGet(name: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name.ptr) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

fn readTokenFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        std.debug.print("cellar: cannot open token file {s}\n", .{path});
        return null;
    };
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch {
        std.debug.print("cellar: cannot read token file {s}\n", .{path});
        return null;
    };
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return null;
    return gpa.dupe(u8, trimmed) catch null;
}

/// Minimal client for the runtime: deploy, invoke, cells. It speaks the same
/// HTTP API the dashboard will, so there is exactly one control surface.
pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    var server: []const u8 = "http://127.0.0.1:8080";
    var token: ?[]const u8 = null;
    var token_file: ?[]const u8 = null;
    var cell_flag: ?[]const u8 = null;
    var positional: [8][]const u8 = undefined;
    var n: usize = 0;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--server")) {
            i += 1;
            if (i >= argv.len) return usage("--server needs a value");
            server = argv[i];
        } else if (std.mem.eql(u8, a, "--token")) {
            i += 1;
            if (i >= argv.len) return usage("--token needs a value");
            token = argv[i];
        } else if (std.mem.eql(u8, a, "--token-file")) {
            i += 1;
            if (i >= argv.len) return usage("--token-file needs a value");
            token_file = argv[i];
        } else if (std.mem.eql(u8, a, "--cell")) {
            i += 1;
            if (i >= argv.len) return usage("--cell needs a value");
            cell_flag = argv[i];
        } else if (n < positional.len) {
            positional[n] = a;
            n += 1;
        } else return usage("too many arguments");
    }

    // Token precedence: --token-file > --token > CELLAR_TOKEN >
    // CELLAR_ADMIN_TOKEN. File and env keep the secret out of `ps`.
    if (token_file) |path| {
        token = readTokenFile(gpa, io, path) orelse return 2;
    } else if (token == null) {
        token = envGet("CELLAR_TOKEN") orelse envGet("CELLAR_ADMIN_TOKEN");
    }
    if (envGet("CELLAR_SERVER")) |s| {
        // Explicit --server already overwrote `server` above only when the
        // flag was present; env is the fallback for the default.
        var saw_server = false;
        for (argv) |a| if (std.mem.eql(u8, a, "--server")) {
            saw_server = true;
            break;
        };
        if (!saw_server) server = s;
    }

    if (n == 0) return usage("missing command");
    const cmd = positional[0];

    if (std.mem.eql(u8, cmd, "deploy")) {
        if (n < 2) return usage("usage: cellar deploy <file> --cell <key>");
        const cell = cell_flag orelse return usage("--cell is required");
        return doDeploy(gpa, io, server, token, positional[1], cell);
    }
    if (std.mem.eql(u8, cmd, "invoke")) {
        if (n < 3) return usage("usage: cellar invoke <cell> <fn> [body]");
        const body: []const u8 = if (n >= 4) positional[3] else "";
        return doInvoke(gpa, io, server, token, positional[1], positional[2], body);
    }
    if (std.mem.eql(u8, cmd, "cells")) {
        return doCells(gpa, io, server, token);
    }

    return usage("unknown command");
}

fn usage(msg: []const u8) !u8 {
    std.debug.print("cellar: {s}\n", .{msg});
    std.debug.print(
        \\usage:
        \\  cellar deploy <file> --cell <key> [--server URL] [--token-file F | --token T]
        \\  cellar invoke <cell> <fn> [body] [--server URL] [--token-file F | --token T]
        \\  cellar cells [--server URL] [--token-file F | --token T]
        \\
        \\environment: CELLAR_TOKEN / CELLAR_ADMIN_TOKEN, CELLAR_SERVER
        \\
    , .{});
    return 2;
}

fn emit(io: std.Io, s: []const u8) void {
    // Results go to stdout: `$(cellar invoke …)` has to capture them.
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
    std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};
}

/// Percent-encodes a path segment. Cell keys may contain `. _ : -` and those are
/// the only characters that are safe unescaped in a URL path.
fn encodeSegment(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const hexdig = "0123456789ABCDEF";
    for (s) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':';
        if (safe) {
            try out.append(a, c);
        } else {
            try out.appendSlice(a, &[_]u8{ '%', hexdig[c >> 4], hexdig[c & 0xf] });
        }
    }
}

const Resp = struct { status: std.http.Status, body: []const u8 };

fn call(
    gpa: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    token: ?[]const u8,
    out_buf: []u8,
) !Resp {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var w: std.Io.Writer = .fixed(out_buf);
    const auth: std.http.Client.Request.Headers.Value = if (token) |t| blk: {
        const v = try std.fmt.allocPrint(gpa, "Bearer {s}", .{t});
        break :blk .{ .override = v };
    } else .omit;

    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .headers = .{ .authorization = auth },
        .response_writer = &w,
    }) catch |err| {
        std.debug.print("cellar: request failed: {s}\n", .{@errorName(err)});
        return error.RequestFailed;
    };
    return .{ .status = res.status, .body = w.buffered() };
}

fn doDeploy(gpa: std.mem.Allocator, io: std.Io, server: []const u8, token: ?[]const u8, file: []const u8, cell: []const u8) !u8 {
    const f = std.Io.Dir.cwd().openFile(io, file, .{}) catch {
        std.debug.print("cellar: cannot open {s}\n", .{file});
        return 1;
    };
    defer f.close(io);

    var src_buf: [512 * 1024]u8 = undefined;
    const src = f.readPositionalAll(io, &src_buf, 0) catch {
        std.debug.print("cellar: cannot read {s}\n", .{file});
        return 1;
    };

    var url_buf = std.ArrayList(u8).empty;
    try url_buf.appendSlice(gpa, server);
    try url_buf.appendSlice(gpa, "/admin/deploy?cell=");
    try encodeSegment(gpa, &url_buf, cell);
    const url = url_buf.items;

    var out: [8 * 1024]u8 = undefined;
    const res = try call(gpa, io, .POST, url, src_buf[0..src], token, &out);
    emit(io, res.body);
    return if (@backingInt(res.status) < 300) 0 else 1;
}

fn doInvoke(gpa: std.mem.Allocator, io: std.Io, server: []const u8, token: ?[]const u8, cell: []const u8, fn_name: []const u8, body: []const u8) !u8 {
    var url_buf = std.ArrayList(u8).empty;
    try url_buf.appendSlice(gpa, server);
    try url_buf.appendSlice(gpa, "/c/");
    try encodeSegment(gpa, &url_buf, cell);
    try url_buf.append(gpa, '/');
    try encodeSegment(gpa, &url_buf, fn_name);
    const url = url_buf.items;

    var out: [64 * 1024]u8 = undefined;
    const res = try call(gpa, io, .POST, url, body, token, &out);
    if (@backingInt(res.status) < 300) {
        emit(io, res.body);
        return 0;
    }
    std.debug.print("error {d}: {s}\n", .{ @backingInt(res.status), res.body });
    return 1;
}

fn doCells(gpa: std.mem.Allocator, io: std.Io, server: []const u8, token: ?[]const u8) !u8 {
    // The cell list is HTML rows; `cells` prints the health summary plus that
    // list, which is what an operator actually wants from the command.
    const health_url = try std.fmt.allocPrint(gpa, "{s}/healthz", .{server});
    defer gpa.free(health_url);
    const list_url = try std.fmt.allocPrint(gpa, "{s}/admin/cells", .{server});
    defer gpa.free(list_url);

    var out: [8 * 1024]u8 = undefined;
    const res = try call(gpa, io, .GET, health_url, null, token, &out);
    if (@backingInt(res.status) >= 300) {
        std.debug.print("error {d}: {s}\n", .{ @backingInt(res.status), res.body });
        return 1;
    }
    emit(io, res.body);

    var rows: [64 * 1024]u8 = undefined;
    const r2 = try call(gpa, io, .GET, list_url, null, token, &rows);
    if (@backingInt(r2.status) < 300) {
        // Strip tags so the CLI output stays line-oriented and grep-able.
        var in_tag = false;
        var line: [256]u8 = undefined;
        var n: usize = 0;
        for (r2.body) |ch| {
            switch (ch) {
                '<' => {
                    in_tag = true;
                    if (n > 0) {
                        emit(io, std.mem.trimEnd(u8, line[0..n], " "));
                        n = 0;
                    }
                },
                '>' => in_tag = false,
                else => if (!in_tag and n < line.len) {
                    line[n] = ch;
                    n += 1;
                },
            }
        }
        if (n > 0) emit(io, std.mem.trimEnd(u8, line[0..n], " "));
    }
    return 0;
}

test "cli usage errors are exit code 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u8, 2), try run(arena.allocator(), undefined, &.{}));
}
