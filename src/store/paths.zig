const std = @import("std");

pub const CellPaths = struct {
    dir: []u8,
    db: []u8,

    pub fn deinit(self: CellPaths, gpa: std.mem.Allocator) void {
        gpa.free(self.dir);
        gpa.free(self.db);
    }
};

/// `data/cells/<sha256(key) hex>/db.sqlite`. The directory carries no reference
/// to anything outside `data_dir`, so a cell can be moved to another node
/// verbatim (I15).
///
/// The full 256-bit digest is used, not a prefix: a truncated digest is a
/// birthday attack away from two cell keys sharing one database, which would
/// break the isolation the scheduler promises.
pub fn cellPaths(gpa: std.mem.Allocator, io: ?std.Io, data_dir: []const u8, key: []const u8) !CellPaths {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const id = &hex;

    const dir = try std.fmt.allocPrint(gpa, "{s}/cells/{s}", .{ data_dir, id });
    errdefer gpa.free(dir);
    const db = try std.fmt.allocPrint(gpa, "{s}/db.sqlite", .{dir});
    errdefer gpa.free(db);

    if (io) |i| {
        std.Io.Dir.cwd().createDirPath(i, dir) catch {};
        chmod700(i, dir);
    }
    return .{ .dir = dir, .db = db };
}

/// Records the cell key inside its directory and refuses a directory whose key
/// does not match. The digest already makes collisions infeasible; this makes a
/// copied or hand-edited data directory fail loudly instead of serving another
/// tenant's rows.
///
/// Written tmp+fsync+rename for the same reason blobs are: a crash between
/// create and write would otherwise leave a permanently empty `key` file, and
/// every later open of that cell would fail with a mismatch.
pub fn claim(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, key: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/key", .{dir});
    defer gpa.free(path);

    if (std.Io.Dir.cwd().openFile(io, path, .{})) |f| {
        defer f.close(io);
        var buf: [256]u8 = undefined;
        const n = f.readPositionalAll(io, &buf, 0) catch return error.CellKeyUnreadable;
        // A zero-length file is a torn previous write, not a claim: treat it as
        // unclaimed and rewrite it.
        if (n > 0) {
            if (!std.mem.eql(u8, buf[0..n], key)) return error.CellKeyMismatch;
            return;
        }
    } else |_| {}

    const seq = claim_seq.fetchAdd(1, .monotonic);
    const tmp = try std.fmt.allocPrint(gpa, "{s}/key.{d}.tmp", .{ dir, seq });
    defer gpa.free(tmp);
    {
        const f = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
        errdefer f.close(io);
        try f.writeStreamingAll(io, key);
        try f.sync(io);
        f.close(io);
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
}

var claim_seq = std.atomic.Value(u64).init(0);

/// chmod 0700, best-effort. Has to *repair* a directory that may already
/// exist with looser permissions. A failure is not fatal — the cell still
/// opens, and the directory is re-chmodded on every open, so a data dir
/// created before this existed is fixed the first time it is touched.
fn chmod700(io: std.Io, path: []const u8) void {
    chmodPath(io, path, 0o700);
}

/// Best-effort chmod that refuses to follow a symlink. A plain chmod will
/// happily chmod — and later code will write through — a symlink planted at
/// the path, so the mode we think we set may be someone else's. Uses the Io
/// permissions API (`fchmodat` with no-follow where available); if the OS
/// refuses no-follow by path, falls back to chmod through an opened handle,
/// which cannot be redirected after the open.
pub fn chmodPath(io: std.Io, path: []const u8, mode: u32) void {
    const perms = std.Io.File.Permissions.fromMode(@intCast(mode));
    std.Io.Dir.cwd().setFilePermissions(io, path, perms, .{ .follow_symlinks = false }) catch {
        if (std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true })) |d0| {
            var d = d0;
            defer d.close(io);
            d.setPermissions(io, perms) catch {};
        } else |_| {
            if (std.Io.Dir.cwd().openFile(io, path, .{})) |f| {
                defer f.close(io);
                f.setPermissions(io, perms) catch {};
            } else |_| {}
        }
    };
}

/// Creates the data directory and makes it 0700.
///
/// Everything that matters lives under it: `state.db` (cell keys and credential
/// digests), `blobs/` (deployed module source), `snapshots/` (full database copies)
/// and the cell databases. The per-file modes were left at the umask default, which
/// made all of that world-readable; protecting the directory is what actually closes
/// it, because a non-owner cannot traverse a 0700 directory to reach any of it.
pub fn secureDataDir(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) void {
    _ = gpa;
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    chmodPath(io, data_dir, 0o700);
}

pub fn keyId(key: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    return digest;
}

test "a cell directory refuses a key it does not belong to" {
    const io = @import("../util/test_io.zig").testIo();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "./.claimtest";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const p = try cellPaths(a, io, dir, "cell-a");
    try claim(a, io, p.dir, "cell-a");
    try claim(a, io, p.dir, "cell-a"); // idempotent
    // Simulates a copied or hand-edited data directory.
    try std.testing.expectError(error.CellKeyMismatch, claim(a, io, p.dir, "cell-b"));

    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "cell paths are stable and contained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p1 = try cellPaths(a, null, "./data", "room-42");
    const p2 = try cellPaths(a, null, "./data", "room-42");
    try std.testing.expectEqualStrings(p1.dir, p2.dir);
    try std.testing.expect(std.mem.startsWith(u8, p1.db, "./data/cells/"));
    try std.testing.expect(std.mem.endsWith(u8, p1.db, "/db.sqlite"));

    const other = try cellPaths(a, null, "./data", "room-43");
    try std.testing.expect(!std.mem.eql(u8, p1.dir, other.dir));
}
