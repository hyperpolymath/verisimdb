// VeriSimDB FFI Integration Tests
//
// Verifies that the Zig-implemented FFI matches the Idris2 ABI surface declared
// in src/abi/Foreign.idr.
//
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const testing = std.testing;

const Handle = opaque {};

extern fn verisimdb_init() ?*Handle;
extern fn verisimdb_free(?*Handle) void;
extern fn verisimdb_is_initialized(?*Handle) c_int;
extern fn verisimdb_version() [*:0]const u8;
extern fn verisimdb_last_error() ?[*:0]u8;
extern fn verisimdb_free_string(?[*:0]u8) void;

test "create and destroy handle" {
    const handle = verisimdb_init() orelse return error.InitFailed;
    defer verisimdb_free(handle);
    try testing.expect(@intFromPtr(handle) != 0);
}

test "handle is initialised after init" {
    const handle = verisimdb_init() orelse return error.InitFailed;
    defer verisimdb_free(handle);
    try testing.expectEqual(@as(c_int, 1), verisimdb_is_initialized(handle));
}

test "null handle reports not initialised" {
    try testing.expectEqual(@as(c_int, 0), verisimdb_is_initialized(null));
}

test "free(null) is safe" {
    verisimdb_free(null);
}

test "version is a non-empty semver string" {
    const ver_str = std.mem.span(verisimdb_version());
    try testing.expect(ver_str.len > 0);
    try testing.expect(std.mem.count(u8, ver_str, ".") >= 1);
}

test "multiple handles are independent" {
    const h1 = verisimdb_init() orelse return error.InitFailed;
    defer verisimdb_free(h1);
    const h2 = verisimdb_init() orelse return error.InitFailed;
    defer verisimdb_free(h2);
    try testing.expect(h1 != h2);
}
