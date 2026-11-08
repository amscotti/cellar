const std = @import("std");
const paths = @import("paths.zig");
const testIo = @import("../util/test_io.zig").testIo;

/// Per-cell metadata. Written next to the database so a cell directory is
/// self-describing and relocatable: losing `state.db` must lose no pins and no
/// placement information (ADR-0007, ADR-0016).
pub const Meta = struct {
    key: []const u8,
    module: []const u8 = "default",
    version: u32 = 1,
    blob_sha: []const u8 = "",
    schema_version: u32 = 0,
    created_at: i64 = 0,
    last_seen: i64 = 0,
    owner_node: []const u8 = "local",
    epoch: u64 = 1,
};

/// Hand-written JSON: eight fields, no dependency, and the shape is asserted by
/// a round-trip test so it cannot drift silently.
pub fn write(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, meta: Meta) !void {
    const p = try paths.cellPaths(gpa, io, data_dir, meta.key);
    defer p.deinit(gpa);

    const body = try std.fmt.allocPrint(gpa,
        \\{{"key":"{s}","module":"{s}","version":{d},"blob_sha":"{s}",
        \\"schema_version":{d},"created_at":{d},"last_seen":{d},"owner_node":"{s}","epoch":{d}}}
    , .{ meta.key, meta.module, meta.version, meta.blob_sha, meta.schema_version, meta.created_at, meta.last_seen, meta.owner_node, meta.epoch });
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "{s}/meta.json", .{p.dir});
    defer gpa.free(path);

    // Temp + rename: a crash between the truncate and the completed write leaves an
    // *empty* meta.json, and an empty pin is indistinguishable from "never deployed" —
    // which then runs the built-in fixture against the cell's real data. Synced
    // because this file is the recovery pin when state.db is lost.
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
        errdefer file.close(io);
        try file.writeStreamingAll(io, body);
        try file.sync(io);
        file.close(io);
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
    if (std.Io.Dir.cwd().openDir(io, p.dir, .{ .iterate = true })) |d| {
        _ = @import("../util/sys.zig").fsyncFd(d.handle);
        d.close(io);
    } else |_| {}
}

pub fn read(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, key: []const u8, out_buf: []u8) ![]u8 {
    const p = try paths.cellPaths(gpa, io, data_dir, key);
    defer p.deinit(gpa);
    const path = try std.fmt.allocPrint(gpa, "{s}/meta.json", .{p.dir});
    defer gpa.free(path);
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, out_buf, 0);
    return out_buf[0..n];
}

/// Extracts a string field's value from the hand-written JSON above.
///
/// Deliberately not a JSON parser: `meta.json` is written by this file with a
/// fixed shape, and the only consumer needs one string. A real parser here would
/// be a second thing to keep correct.
pub fn field(json: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    if (end - start > out.len) return null;
    @memcpy(out[0 .. end - start], json[start..end]);
    return out[0 .. end - start];
}

test "meta round-trips and carries the cluster fields" {
    const io = testIo();

    const dir = "./.metatest";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = Meta{
        .key = "room-42",
        .module = "chat",
        .version = 3,
        .blob_sha = "abc123",
        .schema_version = 2,
        .created_at = 100,
        .last_seen = 200,
        .owner_node = "n1",
        .epoch = 7,
    };
    try write(std.testing.allocator, io, dir, m);

    var buf: [512]u8 = undefined;
    const got = try read(std.testing.allocator, io, dir, "room-42", &buf);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"key\":\"room-42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"blob_sha\":\"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"owner_node\":\"n1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"epoch\":7") != null);

    // The fallback path reads one field out of that text.
    var vbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abc123", field(got, "blob_sha", &vbuf).?);
    try std.testing.expectEqualStrings("room-42", field(got, "key", &vbuf).?);
    try std.testing.expect(field(got, "nope", &vbuf) == null);

    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}
