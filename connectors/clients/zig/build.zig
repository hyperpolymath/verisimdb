// VeriSimDB Zig Client SDK build
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module — consumers add this via `b.dependency("verisimdb_client", ...)`
    _ = b.addModule("verisimdb_client", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run client SDK tests");
    test_step.dependOn(&run_tests.step);
}
