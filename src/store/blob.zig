const std = @import("std");

pub const BlobError = error{ NotFound, OutOfMemory, WriteFailed, Corrupt, SyncFailed };

/// Distinguishes concurrent writers' temporary files.
var tmp_seq = std.atomic.Value(u64).init(0);

/// Content-addressed module store: `data/blobs/<sha256 hex>.bin`.
///
/// Immutable by construction and shared between cells, which is what lets a
/// deploy be a pointer swap and lets two nodes share a module without
/// coordinating (ADR-0009, ADR-0016).
pub fn put(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    const dir = try std.fmt.allocPrint(gpa, "{s}/blobs", .{data_dir});
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.bin", .{ dir, hex });
    defer gpa.free(path);

    // Write to a temporary name, fsync, then rename. A crash or ENOSPC halfway
    // through used to leave a short file at the final name — a blob whose name
    // claims content it does not have. That file then gets pinned into a cell
    // row by a deploy, and every restart fails to load it.
    //
    // The temp name carries a counter: two processes (or two schedulers over one
    // data_dir) deploying identical bytes would otherwise stream into the same
    // temp file and publish a mixture under a valid content address.
    const seq = tmp_seq.fetchAdd(1, .monotonic);
    const tmp = try std.fmt.allocPrint(gpa, "{s}/{s}.{d}.tmp", .{ dir, hex, seq });
    defer gpa.free(tmp);
    // Every failure path removes the temp file: a full disk that failed the write is
    // exactly when unreferenced max_source-sized junk must not accumulate.
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
        errdefer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
        file.close(io);
    }
    // Rename within one directory is atomic; replacing an identical blob with
    // identical bytes is harmless.
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);

    // The rename is only durable once the *directory* is: `file.sync` above makes
    // the bytes durable, not the new name. Without this, a power cut can leave
    // state.db holding a pin to a blob the filesystem never recorded — and the cell
    // then silently boots the built-in fixture. SIGKILL-based crash tests cannot see
    // this gap because SIGKILL drops no page cache.
    // `.iterate = true` matters: without it the directory is opened O_PATH, and
    // fsync on an O_PATH fd fails with EBADF — which the first version discarded, so
    // the "durability fix" was a no-op.
    if (std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true })) |d| {
        const ok = @import("../util/sys.zig").fsyncFd(d.handle);
        d.close(io);
        if (!ok) return BlobError.SyncFailed;
    } else |_| {}

    return gpa.dupe(u8, &hex);
}

/// Rejects a blob whose bytes do not hash to the name it was stored under.
fn verify(got: []const u8, sha: []const u8) !void {
    if (sha.len != 64) return BlobError.Corrupt;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(got, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, sha)) return BlobError.Corrupt;
}

pub fn get(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, sha: []const u8, buf: []u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}/blobs/{s}.bin", .{ data_dir, sha });
    defer gpa.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return BlobError.NotFound;
    defer file.close(io);
    const n = try file.readPositionalAll(io, buf, 0);
    const got = buf[0..n];
    // Verification also catches silent truncation into a too-small buffer.
    try verify(got, sha);
    return got;
}

/// Loads a blob into an exactly-sized, caller-owned buffer.
///
/// `get` needs the caller to know the length; a cell rehydrating from the
/// registry does not, so this reads into a `max` scratch buffer and shrinks. The
/// extra copy only happens on a cold start, never on the hot path.
pub fn getAlloc(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, sha: []const u8, max: usize) ![]u8 {
    const scratch = try gpa.alloc(u8, max);
    defer gpa.free(scratch);
    const got = try get(gpa, io, data_dir, sha, scratch);
    return gpa.dupe(u8, got);
}

test "a corrupted or truncated blob is rejected, not loaded" {
    const testIo = @import("../util/test_io.zig").testIo;
    const io = testIo();
    const dir = "./.blobtest2";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const a = try put(std.testing.allocator, io, dir, "module one");
    defer std.testing.allocator.free(a);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/blobs/{s}.bin", .{ dir, a });
    defer std.testing.allocator.free(path);

    // Overwrite the bytes but keep the content-addressed name: exactly what a
    // torn write or a wiped disk produces.
    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "module one, corrupted");
    }

    var buf: [64]u8 = undefined;
    try std.testing.expectError(BlobError.Corrupt, get(std.testing.allocator, io, dir, a, &buf));

    // A buffer too small for the blob truncates the read; the hash catches it.
    var small: [4]u8 = undefined;
    const b = try put(std.testing.allocator, io, dir, "module two");
    defer std.testing.allocator.free(b);
    try std.testing.expectError(BlobError.Corrupt, get(std.testing.allocator, io, dir, b, &small));

    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "blobs are content-addressed and idempotent" {
    const testIo = @import("../util/test_io.zig").testIo;
    const io = testIo();
    const dir = "./.blobtest";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const a = try put(std.testing.allocator, io, dir, "module one");
    defer std.testing.allocator.free(a);
    const b = try put(std.testing.allocator, io, dir, "module one");
    defer std.testing.allocator.free(b);
    const c = try put(std.testing.allocator, io, dir, "module two");
    defer std.testing.allocator.free(c);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(!std.mem.eql(u8, a, c));
    try std.testing.expectEqual(@as(usize, 64), a.len);

    var buf: [64]u8 = undefined;
    const got = try get(std.testing.allocator, io, dir, a, &buf);
    try std.testing.expectEqualStrings("module one", got);

    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}
