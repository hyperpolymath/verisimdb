// VeriSimDB Zig — unified gateway + FFI build
// SPDX-License-Identifier: MPL-2.0
//
// Two artifacts in one tree:
//   1. verisimdb-gateway  — HTTP/REST/GraphQL proxy (Rust core + Elixir orch)
//   2. libverisimdb_ffi   — C-ABI shared library matching the Idris2 ABI
//                           declared in src/abi/Foreign.idr
//
// Build:    zig build
// Test:     zig build test
// Gateway:  zig build run-gateway

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ----- Gateway executable -----
    const gateway = b.addExecutable(.{
        .name = "verisimdb-gateway",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(gateway);

    const run_gateway = b.addRunArtifact(gateway);
    run_gateway.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_gateway.addArgs(args);
    const run_gateway_step = b.step("run-gateway", "Run the VeriSimDB API gateway");
    run_gateway_step.dependOn(&run_gateway.step);

    // ----- FFI shared library (Idris2 ABI surface) -----
    const ffi_lib = b.addSharedLibrary(.{
        .name = "verisimdb_ffi",
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_lib.version = .{ .major = 0, .minor = 1, .patch = 0 };
    b.installArtifact(ffi_lib);

    const ffi_static = b.addStaticLibrary(.{
        .name = "verisimdb_ffi",
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(ffi_static);

    // ----- Unit tests -----
    const gateway_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ffi_tests = b.addTest(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_gateway_tests = b.addRunArtifact(gateway_tests);
    const run_ffi_tests = b.addRunArtifact(ffi_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_gateway_tests.step);
    test_step.dependOn(&run_ffi_tests.step);

    // ----- Integration tests -----
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.linkLibrary(ffi_lib);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests");
    integration_step.dependOn(&run_integration_tests.step);
}
