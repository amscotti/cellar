const std = @import("std");
const builtin = @import("builtin");

/// Portable wrappers for the handful of OS primitives the runtime needs
/// directly: randomness, clocks, and fsync. Linux keeps the raw syscalls;
/// macOS uses the libc equivalents (`arc4random_buf`, `clock_gettime`).
/// Everything links libc, so the `std.c` spellings are available on both.
/// Fill `buf` with cryptographically secure random bytes.
/// Returns false only when the OS entropy source fails.
pub fn fillRandom(buf: []u8) bool {
    if (buf.len == 0) return true;
    switch (builtin.os.tag) {
        .linux => {
            var off: usize = 0;
            while (off < buf.len) {
                const n = std.os.linux.getrandom(buf.ptr + off, buf.len - off, 0);
                // Error returns come back as a huge unsigned (-errno).
                if (n == 0 or n > buf.len - off) return false;
                off += n;
            }
            return true;
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            // Never fails; the kernel always provides entropy.
            std.c.arc4random_buf(buf.ptr, buf.len);
            return true;
        },
        else => return false,
    }
}

fn clockNs(id: std.c.clockid_t) i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(id, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

/// Monotonic nanoseconds (deadlines, durations). Never goes backwards.
pub fn monotonicNs() u64 {
    return @intCast(@max(clockNs(std.c.CLOCK.MONOTONIC), 0));
}

/// Wall-clock nanoseconds since the epoch (timestamps a human reads).
pub fn realtimeNs() i64 {
    return clockNs(std.c.CLOCK.REALTIME);
}

pub fn realtimeSec() i64 {
    return @divTrunc(realtimeNs(), std.time.ns_per_s);
}

pub fn realtimeMs() i64 {
    return @divTrunc(realtimeNs(), std.time.ns_per_ms);
}

/// fsync a file descriptor (a directory handle counts). True on success.
pub fn fsyncFd(fd: c_int) bool {
    return std.c.fsync(fd) == 0;
}

test "random fills and clocks advance" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try std.testing.expect(fillRandom(&a));
    try std.testing.expect(fillRandom(&b));
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    const t0 = monotonicNs();
    const t1 = monotonicNs();
    try std.testing.expect(t1 >= t0);
    // Sanity: wall clock is past 2024-01-01.
    try std.testing.expect(realtimeSec() > 1_704_067_200);
}
