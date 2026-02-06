const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zuckdb_dep = b.dependency("zuckdb", .{
        .target = target,
        .optimize = optimize,
        .system_libduckdb = true,
    });
    const zuckdb_mod = zuckdb_dep.module("zuckdb");

    // DuckDB static lib from duckdb-static/ (built via `just setup-duckdb`)
    const duckdb_lib_path = b.path("../duckdb-static/lib");

    // Create root module for executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zuckdb", zuckdb_mod);
    exe_mod.addLibraryPath(duckdb_lib_path);

    const exe = b.addExecutable(.{
        .name = "ccq",
        .root_module = exe_mod,
        .use_llvm = true, // Required: self-hosted backend can't link external .o/.a
    });
    // DuckDB built with zig c++ (libc++ ABI)
    exe.linkLibCpp();

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run ccq");
    run_step.dependOn(&run_cmd.step);

    // Test step
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zuckdb", zuckdb_mod);
    test_mod.addLibraryPath(duckdb_lib_path);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .use_llvm = true,
    });
    unit_tests.linkLibCpp();

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
