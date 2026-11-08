const std = @import("std");

/// Latency buckets in seconds. Hand-picked rather than powers of two: a log2
/// histogram spends most of its resolution above 1 s, where invocations of a
/// database-per-cell runtime should never be, and lumps everything from 0 to 1 ms
/// into one bucket. These bounds bracket what the gates care about (G4: p50 ≤ 5 ms,
/// p99 ≤ 25 ms) and stay useful when something is badly wrong.
pub const BOUNDS_S = [_]f64{ 0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 7.5, 10 };

/// buckets = BOUNDS_S.len finite bounds + one overflow (+Inf) bucket.
const NB = BOUNDS_S.len + 1;

pub const Outcome = enum(u2) { ok, guest_error, timeout, internal };

fn newCounters() [NB]std.atomic.Value(u64) {
    var out: [NB]std.atomic.Value(u64) = undefined;
    for (&out) |*b| b.* = std.atomic.Value(u64).init(0);
    return out;
}

const Hist = struct {
    buckets: [NB]std.atomic.Value(u64) = newCounters(),
    sum_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn record(self: *Hist, dur_ns: u64) void {
        const secs = @as(f64, @floatFromInt(dur_ns)) / @as(f64, std.time.ns_per_s);
        var i: usize = 0;
        while (i < BOUNDS_S.len and secs > BOUNDS_S[i]) : (i += 1) {}
        _ = self.buckets[i].fetchAdd(1, .monotonic);
        _ = self.sum_ns.fetchAdd(dur_ns, .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);
    }
};

/// Atomic counters plus one latency histogram per outcome. Everything the
/// dashboard, /healthz and /metrics report is derived from this struct (ADR-0013).
/// Histograms are per outcome because "slow" and "failed" have different fixes.
pub const Metrics = struct {
    invocations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    timeouts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    inflight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    cells: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    bytes_out: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    hists: [4]Hist = .{ .{}, .{}, .{}, .{} },

    pub fn begin(self: *Metrics) void {
        _ = self.inflight.fetchAdd(1, .monotonic);
    }

    pub fn end(self: *Metrics, dur_ns: u64, outcome: Outcome) void {
        _ = self.inflight.fetchSub(1, .monotonic);
        _ = self.invocations.fetchAdd(1, .monotonic);
        switch (outcome) {
            .ok => {},
            .guest_error, .internal => _ = self.errors.fetchAdd(1, .monotonic),
            .timeout => _ = self.timeouts.fetchAdd(1, .monotonic),
        }
        self.hists[@backingInt(outcome)].record(dur_ns);
    }

    /// Upper bound (µs) of the bucket the q-quantile falls into, across all
    /// outcomes. Used by the gates; an observation in the +Inf bucket reports 0.
    fn quantile(self: *const Metrics, q: f64) u64 {
        var total: u64 = 0;
        for (&self.hists) |*h| total += h.count.load(.monotonic);
        if (total == 0) return 0;
        const want: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(total)) * q));
        var cum: [NB]u64 = @splat(0);
        for (&self.hists) |*h| {
            for (&h.buckets, 0..) |*b, i| cum[i] += b.load(.monotonic);
        }
        var seen: u64 = 0;
        for (cum, 0..) |c, i| {
            seen += c;
            if (seen >= want) {
                if (i >= BOUNDS_S.len) return 0;
                return @intFromFloat(BOUNDS_S[i] * 1e6);
            }
        }
        return 0;
    }

    pub fn p50(self: *const Metrics) u64 {
        return self.quantile(0.50);
    }
    pub fn p99(self: *const Metrics) u64 {
        return self.quantile(0.99);
    }

    pub const Meta = struct {
        version: []const u8,
        vm: []const u8,
        shards: u32,
        max_cells: u32,
        deadline_ms: u32,
        uptime_s: u64,
        cells_known: usize,
        cells_resident: u32,
    };

    /// Prometheus text exposition format, written by hand (no dependency, no
    /// build step). Histogram buckets are cumulative on the wire, non-cumulative
    /// in memory.
    pub fn renderText(self: *const Metrics, a: std.mem.Allocator, out: *std.ArrayList(u8), m: Meta) !void {
        try emit(a, out,
            \\# HELP cellar_build_info Build and configuration of this process; always 1.
            \\# TYPE cellar_build_info gauge
            \\cellar_build_info{{version="{s}",vm="{s}",shards="{d}",max_cells="{d}",deadline_ms="{d}"}} 1
            \\# HELP cellar_uptime_seconds Seconds since the scheduler started.
            \\# TYPE cellar_uptime_seconds gauge
            \\cellar_uptime_seconds {d}
            \\# HELP cellar_cells_known Cells in the registry catalog (may exceed resident).
            \\# TYPE cellar_cells_known gauge
            \\cellar_cells_known {d}
            \\# HELP cellar_cells_resident Cells currently held in memory across all shards.
            \\# TYPE cellar_cells_resident gauge
            \\cellar_cells_resident {d}
            \\# HELP cellar_invocations_inflight Invocations accepted but not yet complete.
            \\# TYPE cellar_invocations_inflight gauge
            \\cellar_invocations_inflight {d}
            \\# HELP cellar_invocations_total Invocations completed, by outcome.
            \\# TYPE cellar_invocations_total counter
            \\
        , .{ m.version, m.vm, m.shards, m.max_cells, m.deadline_ms, m.uptime_s, m.cells_known, m.cells_resident, self.inflight.load(.monotonic) });

        // All four outcomes are always present, so a dashboard query never breaks
        // on a missing series.
        for ([_]Outcome{ .ok, .guest_error, .timeout, .internal }) |o| {
            try emit(a, out, "cellar_invocations_total{{outcome=\"{s}\"}} {d}\n", .{ @tagName(o), self.hists[@backingInt(o)].count.load(.monotonic) });
        }

        try out.appendSlice(a,
            \\# HELP cellar_invocation_duration_seconds Execution time per invocation, dequeue to commit.
            \\# TYPE cellar_invocation_duration_seconds histogram
            \\
        );
        for ([_]Outcome{ .ok, .guest_error, .timeout, .internal }) |o| {
            const h = &self.hists[@backingInt(o)];
            var cum: u64 = 0;
            for (BOUNDS_S, 0..) |b, i| {
                cum += h.buckets[i].load(.monotonic);
                try emit(a, out, "cellar_invocation_duration_seconds_bucket{{outcome=\"{s}\",le=\"{d:.6}\"}} {d}\n", .{ @tagName(o), b, cum });
            }
            cum += h.buckets[BOUNDS_S.len].load(.monotonic);
            try emit(a, out, "cellar_invocation_duration_seconds_bucket{{outcome=\"{s}\",le=\"+Inf\"}} {d}\n", .{ @tagName(o), cum });
            const sum_s = @as(f64, @floatFromInt(h.sum_ns.load(.monotonic))) / @as(f64, std.time.ns_per_s);
            try emit(a, out, "cellar_invocation_duration_seconds_sum{{outcome=\"{s}\"}} {d:.6}\n", .{ @tagName(o), sum_s });
            try emit(a, out, "cellar_invocation_duration_seconds_count{{outcome=\"{s}\"}} {d}\n", .{ @tagName(o), h.count.load(.monotonic) });
        }
    }
};

fn emit(a: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(s);
    try out.appendSlice(a, s);
}

test "histogram quantiles land in the right bucket" {
    var m: Metrics = .{};
    m.end(500 * 1000, .ok); // 500us
    m.end(900 * 1000, .ok); // 900us
    m.end(2 * 1000 * 1000, .ok); // 2ms
    try std.testing.expect(m.p50() == 1000); // 900us observation lands in le=0.001
    try std.testing.expect(m.p99() == 2500); // 2ms observation lands in le=0.0025
    try std.testing.expect(m.invocations.load(.monotonic) == 3);
}

test "the rendered exposition is well formed and self-consistent" {
    const a = std.testing.allocator;
    var m: Metrics = .{};
    m.end(120 * 1000, .ok);
    m.end(300 * 1000, .ok);
    m.end(2 * std.time.ns_per_s, .guest_error);
    m.end(6 * std.time.ns_per_s, .timeout);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    try m.renderText(a, &out, .{
        .version = "0.1.0",
        .vm = "lua",
        .shards = 4,
        .max_cells = 64,
        .deadline_ms = 5000,
        .uptime_s = 812,
        .cells_known = 20,
        .cells_resident = 19,
    });

    var it = std.mem.splitScalar(u8, out.items, '\n');
    var lines: usize = 0;
    var inf_ok: ?u64 = null;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        if (std.mem.startsWith(u8, line, "#")) continue;
        // Every sample line ends in " <value>".
        const sp = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.MalformedLine;
        try std.testing.expect(sp + 1 < line.len);
        if (std.mem.indexOf(u8, line, "le=\"+Inf\"") != null) {
            const v = try std.fmt.parseInt(u64, line[sp + 1 ..], 10);
            if (std.mem.indexOf(u8, line, "outcome=\"ok\"") != null) inf_ok = v;
        }
    }
    try std.testing.expectEqual(@as(?u64, 2), inf_ok); // +Inf == _count for ok
    try std.testing.expect(lines > 40);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "cellar_invocations_total{outcome=\"timeout\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "cellar_build_info{version=\"0.1.0\"") != null);
    // 120µs lands in le=0.00025, not le=0.0001: buckets are upper bounds.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "le=\"0.000100\"} 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "le=\"0.000250\"} 1") != null);
}
