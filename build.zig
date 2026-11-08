const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "only run tests whose name contains this substring");

    const lua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });

    const sqlite_tc = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite3/sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_tc.addIncludePath(b.path("vendor/sqlite3"));

    const opts = b.addOptions();
    opts.addOption([]const u8, "vm", "lua");
    opts.addOption([]const u8, "version", "0.1.0");

    var one_filter: [1][]const u8 = undefined;
    var filters: []const []const u8 = &.{};
    if (test_filter) |f| {
        one_filter[0] = f;
        filters = &one_filter;
    }

    // ---- executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wire(b, exe_mod, lua_dep, sqlite_tc, opts);

    const exe = b.addExecutable(.{ .name = "cellar", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run cellar");
    run_step.dependOn(&run_cmd.step);

    // ---- tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wire(b, test_mod, lua_dep, sqlite_tc, opts);

    const t = b.addTest(.{ .root_module = test_mod, .filters = filters });
    const run_tests = b.addRunArtifact(t);
    // Run the test binary directly instead of in the build system's protocol
    // mode: the scheduler leaves long-lived threads behind, and protocol mode
    // aborts with "internal test runner failure" once they outlive a test.
    run_tests.stdio = .inherit;
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // ---- bench (ReleaseFast copy of the same sources)
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("test/bench/invoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wire(b, bench_mod, lua_dep, sqlite_tc, opts);
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the invoke benchmark");
    bench_step.dependOn(&bench_run.step);

    // ---- gates
    const gates = b.addSystemCommand(&.{ "bash", "gates/run.sh" });
    if (b.option([]const u8, "phase", "run gates whose first phase <= N")) |p| gates.addArg(p);
    const gates_step = b.step("gates", "Run gate scripts");
    gates_step.dependOn(&gates.step);
}

fn wire(
    b: *std.Build,
    mod: *std.Build.Module,
    lua_dep: *std.Build.Dependency,
    sqlite_tc: *std.Build.Step.TranslateC,
    opts: *std.Build.Step.Options,
) void {
    mod.addImport("zlua", lua_dep.module("zlua"));
    mod.addImport("sqlite", sqlite_tc.createModule());
    mod.addOptions("build_options", opts);
    mod.addIncludePath(b.path("vendor/sqlite3"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite3/sqlite3.c"),
        .flags = &.{
            "-std=c99",
            "-O2",
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        },
    });
}
