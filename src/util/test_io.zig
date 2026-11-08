const std = @import("std");

/// One `std.Io.Threaded` for the whole test process.
///
/// Creating and deiniting a Threaded per test breaks the Zig test runner: in
/// `--listen=-` mode the runner talks to the build system over stdin/stdout, and
/// tearing an Io implementation down mid-process closes file descriptors the
/// runner still needs, which surfaces as `internal test runner failure` and an
/// abort. Sharing one instance avoids it and is also what the real binary does.
var threaded: std.Io.Threaded = undefined;
var ready: bool = false;

pub fn testIo() std.Io {
    if (!ready) {
        threaded = .init(std.heap.page_allocator, .{});
        ready = true;
    }
    return threaded.io();
}
