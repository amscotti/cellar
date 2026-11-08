const std = @import("std");

pub const Route = struct {
    cell: []const u8,
    fn_name: []const u8,
};

pub const RouteError = error{NotFound};

/// `/c/{cell}/{fn}` → {cell, fn}. Rejects empty segments, extra segments, and
/// anything that is not a plain path.
pub fn parse(target: []const u8) RouteError!Route {
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    if (!std.mem.startsWith(u8, path, "/c/")) return error.NotFound;
    const rest = path[3..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NotFound;
    const cell = rest[0..slash];
    const fn_name = rest[slash + 1 ..];
    if (cell.len == 0 or fn_name.len == 0) return error.NotFound;
    if (std.mem.indexOfScalar(u8, fn_name, '/') != null) return error.NotFound;
    return .{ .cell = cell, .fn_name = fn_name };
}

/// Cell keys are 1..128 bytes of [A-Za-z0-9._:-]. Anything else is a bad request
/// (and never reaches a filesystem path).
pub fn validCellKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128) return false;
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == ':' or c == '-';
        if (!ok) return false;
    }
    return true;
}

test "routes" {
    const r = try parse("/c/room-42/echo");
    try std.testing.expectEqualStrings("room-42", r.cell);
    try std.testing.expectEqualStrings("echo", r.fn_name);

    const q = try parse("/c/a/b?x=1");
    try std.testing.expectEqualStrings("a", q.cell);
    try std.testing.expectEqualStrings("b", q.fn_name);

    try std.testing.expectError(error.NotFound, parse("/"));
    try std.testing.expectError(error.NotFound, parse("/c/"));
    try std.testing.expectError(error.NotFound, parse("/c/a"));
    try std.testing.expectError(error.NotFound, parse("/c/a/"));
    try std.testing.expectError(error.NotFound, parse("/c/a/b/c"));
    try std.testing.expectError(error.NotFound, parse("/healthz"));
}

test "cell keys" {
    try std.testing.expect(validCellKey("room-42"));
    try std.testing.expect(validCellKey("tenant:acme"));
    try std.testing.expect(validCellKey("a.b_c:d-1"));
    try std.testing.expect(!validCellKey(""));
    try std.testing.expect(!validCellKey("../etc"));
    try std.testing.expect(!validCellKey("a/b"));
    try std.testing.expect(!validCellKey("a b"));
    const long: [129]u8 = @splat('x');
    try std.testing.expect(!validCellKey(&long));
}
