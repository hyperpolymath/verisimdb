// VeriSimDB FFI — C-ABI surface for the Idris2 ABI declared in src/abi/Foreign.idr.
//
// ABI ownership: per estate policy (2026-05-28 owner directive), Idris2 is the
// canonical source-of-truth for ABI types and layouts. This file is the Zig-side
// implementation of those declarations — types and signatures must remain in sync
// with the Idris2 module.
//
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

pub const VERSION = "0.1.0";

threadlocal var last_error: ?[]const u8 = null;

fn setError(msg: []const u8) void {
    last_error = msg;
}

fn clearError() void {
    last_error = null;
}

/// Result codes (must match the Idris2 Result type in src/abi/Foreign.idr).
pub const Result = enum(c_int) {
    ok = 0,
    @"error" = 1,
    invalid_param = 2,
    out_of_memory = 3,
    null_pointer = 4,
};

/// Opaque handle exposed to C / Idris2.
pub const Handle = extern struct {
    initialized: c_int,
};

/// Initialise a new VeriSimDB FFI handle.
export fn verisimdb_init() ?*Handle {
    const allocator = std.heap.c_allocator;
    const handle = allocator.create(Handle) catch {
        setError("Failed to allocate handle");
        return null;
    };
    handle.* = .{ .initialized = 1 };
    clearError();
    return handle;
}

/// Free a handle previously returned by verisimdb_init.
export fn verisimdb_free(handle: ?*Handle) void {
    const h = handle orelse return;
    h.initialized = 0;
    std.heap.c_allocator.destroy(h);
    clearError();
}

/// Returns 1 if the handle is initialised, 0 otherwise.
export fn verisimdb_is_initialized(handle: ?*Handle) c_int {
    const h = handle orelse return 0;
    return h.initialized;
}

/// Get the library version as a NUL-terminated C string.
export fn verisimdb_version() [*:0]const u8 {
    return VERSION.ptr;
}

/// Get the last error message as a malloc'd C string, or null.
/// Caller must free using verisimdb_free_string.
export fn verisimdb_last_error() ?[*:0]u8 {
    const err = last_error orelse return null;
    const allocator = std.heap.c_allocator;
    const c_str = allocator.dupeZ(u8, err) catch return null;
    return c_str.ptr;
}

/// Free a string allocated by the library.
export fn verisimdb_free_string(str: ?[*:0]u8) void {
    const s = str orelse return;
    const slice = std.mem.span(s);
    std.heap.c_allocator.free(slice);
}

test "handle lifecycle" {
    const handle = verisimdb_init() orelse return error.InitFailed;
    defer verisimdb_free(handle);
    try std.testing.expectEqual(@as(c_int, 1), verisimdb_is_initialized(handle));
}

test "version is a non-empty string" {
    const ver = std.mem.span(verisimdb_version());
    try std.testing.expectEqualStrings(VERSION, ver);
}

test "last_error returns null when clear" {
    clearError();
    try std.testing.expect(verisimdb_last_error() == null);
}
