const std = @import("std");
const config = @import("../config.zig");
const Scheduler = @import("../runtime/scheduler.zig").Scheduler;

const index_html = @embedFile("admin/index.html");

/// Escapes text for HTML. Guest- and operator-controlled strings both pass
/// through here; there is no other way into a template.
pub fn escape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    for (s) |c| {
        switch (c) {
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '&' => try out.appendSlice(a, "&amp;"),
            '"' => try out.appendSlice(a, "&quot;"),
            '\'' => try out.appendSlice(a, "&#39;"),
            else => try out.append(a, c),
        }
    }
    return out.toOwnedSlice(a);
}

fn substitute(a: std.mem.Allocator, tpl: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < tpl.len) {
        if (std.mem.startsWith(u8, tpl[i..], "{{")) {
            if (std.mem.indexOfPos(u8, tpl, i, "}}")) |close| {
                const name = std.mem.trim(u8, tpl[i + 2 .. close], " ");
                if (std.mem.eql(u8, name, key)) {
                    try out.appendSlice(a, value);
                    i = close + 2;
                    continue;
                }
            }
        }
        try out.append(a, tpl[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

pub const Vars = struct {
    uptime: []const u8,
    cells: []const u8,
    resident: []const u8,
    invocations: []const u8,
    errors: []const u8,
    rows: []const u8 = "",
    deploys: []const u8 = "",
    error_banner: []const u8 = "",
};

pub fn render(a: std.mem.Allocator, v: Vars) ![]u8 {
    var page = try a.dupe(u8, index_html);
    const pairs = [_][2][]const u8{
        .{ "uptime", v.uptime },
        .{ "cells", v.cells },
        .{ "resident", v.resident },
        .{ "invocations", v.invocations },
        .{ "errors", v.errors },
        .{ "rows", v.rows },
        .{ "deploys", v.deploys },
        .{ "error_banner", v.error_banner },
    };
    for (pairs) |p| {
        const replaced = try substitute(a, page, p[0], p[1]);
        a.free(page);
        page = replaced;
    }
    return page;
}

/// UTC civil date/time from a Unix timestamp: `2026-11-04 03:15`.
///
/// Howard Hinnant's `civil_from_days` inverse — no libc, no timezone database,
/// no allocation, and it turns the raw epoch seconds the table used to show into
/// something a human can read.
pub fn formatUtc(ts: i64, out: []u8) []const u8 {
    const days = @divFloor(ts, 86400);
    var secs = ts - days * 86400;
    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    const hh = @divFloor(secs, 3600);
    secs -= hh * 3600;
    const mm = @divFloor(secs, 60);
    // Zero-padding is done by hand. The cause is not the format spec: on this Zig,
    // `Io/Writer.zig` appends a `+` to any *signed* positive integer when a width
    // is set, so `{d:0>4}` on an i64 emits "+2026" with no padding. Casting to an
    // unsigned type first would make `{d:0>4}` behave, but pad2 is already here and
    // is not worth churning.
    var mbuf: [2]u8 = undefined;
    var dbuf: [2]u8 = undefined;
    var hbuf: [2]u8 = undefined;
    var nbuf: [2]u8 = undefined;
    return std.fmt.bufPrint(out, "{d}-{s}-{s} {s}:{s}", .{
        year,
        pad2(m, &mbuf),
        pad2(d, &dbuf),
        pad2(hh, &hbuf),
        pad2(mm, &nbuf),
    }) catch "";
}

fn pad2(n: anytype, buf: *[2]u8) []const u8 {
    const v: u32 = @intCast(@mod(n, 100));
    buf[0] = '0' + @as(u8, @intCast(v / 10));
    buf[1] = '0' + @as(u8, @intCast(v % 10));
    return buf[0..2];
}

/// Builds the cell table body straight from the published catalog plus the live
/// resident count. The host loops; the template engine has no loops on purpose.
pub fn cellRows(a: std.mem.Allocator, sched: *const Scheduler) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);

    if (sched.registry) |reg| {
        const cat = reg.lock();
        defer reg.unlock();
        for (cat.cells) |c| {
            const key = try escape(a, c.key);
            defer a.free(key);
            var tbuf: [24]u8 = undefined;
            const when = formatUtc(c.created_at, &tbuf);
            const row = try std.fmt.allocPrint(
                a,
                "<tr data-cell-row><td><code>{s}</code></td><td>{d}</td><td>{s}</td></tr>",
                .{ key, c.version, when },
            );
            defer a.free(row);
            try out.appendSlice(a, row);
        }
    }
    if (out.items.len == 0) try out.appendSlice(a, "<tr><td colspan=\"4\">no cells yet — deploy one below</td></tr>");
    return out.toOwnedSlice(a);
}

pub fn deployRows(a: std.mem.Allocator, sched: *const Scheduler) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    if (sched.registry) |reg| {
        const cat = reg.lock();
        defer reg.unlock();
        for (cat.deploys) |d| {
            const m = try escape(a, d.module);
            defer a.free(m);
            const s = try escape(a, d.blob_sha);
            defer a.free(s);
            const row = try std.fmt.allocPrint(
                a,
                "<tr><td>{s}</td><td>{d}</td><td><code>{s}</code></td></tr>",
                .{ m, d.version, s },
            );
            defer a.free(row);
            try out.appendSlice(a, row);
        }
    }
    if (out.items.len == 0) try out.appendSlice(a, "<tr><td colspan=\"3\">none</td></tr>");
    return out.toOwnedSlice(a);
}

test "timestamps render as UTC dates, not epoch seconds" {
    var buf: [24]u8 = undefined;
    // 1793798588 = 2026-11-04 13:23 UTC
    try std.testing.expectEqualStrings("2026-11-04 13:23", formatUtc(1793798588, &buf));
    try std.testing.expectEqualStrings("1970-01-01 00:00", formatUtc(0, &buf));
    try std.testing.expectEqualStrings("2000-02-29 12:34", formatUtc(951827640, &buf));
}

test "escaping keeps markup out" {
    const a = std.testing.allocator;
    const got = try escape(a, "<script>\"x\" & 'y'");
    defer a.free(got);
    try std.testing.expectEqualStrings("&lt;script&gt;&quot;x&quot; &amp; &#39;y&#39;", got);
}

test "substitution replaces only whole markers" {
    const a = std.testing.allocator;
    const got = try substitute(a, "a {{x}} b {{xy}} c", "x", "1");
    defer a.free(got);
    try std.testing.expectEqualStrings("a 1 b {{xy}} c", got);
}
