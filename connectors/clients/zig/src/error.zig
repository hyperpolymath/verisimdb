// SPDX-License-Identifier: MPL-2.0
// VeriSimDB Zig Client — typed error variants.
//
// Mirrors the V client's VeriSimError model: server-side codes plus client-side
// failure modes. The server returns errors in the envelope:
//   { "error": { "code": "...", "message": "...", "details": {...} } }

const std = @import("std");

pub const VeriSimErrorCode = enum {
    // Client errors (4xx)
    bad_request,
    unauthorized,
    forbidden,
    not_found,
    conflict,
    validation_failed,
    rate_limited,
    // Server errors (5xx)
    internal_error,
    service_unavailable,
    // Domain-specific
    octad_not_found,
    modality_unavailable,
    drift_computation,
    provenance_invalid,
    vcl_parse_error,
    vcl_execution_error,
    federation_error,
    // Client-side
    connection_error,
    timeout_error,
    serialization_error,
    unknown,

    pub fn fromString(s: []const u8) VeriSimErrorCode {
        const map = .{
            .{ "BAD_REQUEST", .bad_request },
            .{ "UNAUTHORIZED", .unauthorized },
            .{ "FORBIDDEN", .forbidden },
            .{ "NOT_FOUND", .not_found },
            .{ "CONFLICT", .conflict },
            .{ "VALIDATION_FAILED", .validation_failed },
            .{ "RATE_LIMITED", .rate_limited },
            .{ "INTERNAL_ERROR", .internal_error },
            .{ "SERVICE_UNAVAILABLE", .service_unavailable },
            .{ "HEXAD_NOT_FOUND", .octad_not_found },
            .{ "OCTAD_NOT_FOUND", .octad_not_found },
            .{ "MODALITY_UNAVAILABLE", .modality_unavailable },
            .{ "DRIFT_COMPUTATION", .drift_computation },
            .{ "PROVENANCE_INVALID", .provenance_invalid },
            .{ "VCL_PARSE_ERROR", .vcl_parse_error },
            .{ "VCL_EXECUTION_ERROR", .vcl_execution_error },
            .{ "FEDERATION_ERROR", .federation_error },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

pub const VeriSimError = struct {
    code: VeriSimErrorCode,
    message: []const u8, // owned
    status: u16,
    raw_body: []const u8, // owned

    pub fn deinit(self: VeriSimError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.raw_body);
    }
};

pub const ClientError = error{
    HttpError,
    BackendUnreachable,
    BadResponse,
    DecodeFailed,
    OutOfMemory,
};

pub fn parseServerError(
    allocator: std.mem.Allocator,
    body: []const u8,
    status: u16,
) !VeriSimError {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{
            .code = .unknown,
            .message = try allocator.dupe(u8, "Failed to parse error response"),
            .status = status,
            .raw_body = try allocator.dupe(u8, body),
        };
    };
    defer parsed.deinit();

    var code: VeriSimErrorCode = .unknown;
    var message: []const u8 = "Unknown error";

    const root = parsed.value;
    if (root == .object) {
        if (root.object.get("error")) |err_val| {
            if (err_val == .object) {
                if (err_val.object.get("code")) |c| {
                    if (c == .string) code = VeriSimErrorCode.fromString(c.string);
                }
                if (err_val.object.get("message")) |m| {
                    if (m == .string) message = m.string;
                }
            }
        }
    }

    return .{
        .code = code,
        .message = try allocator.dupe(u8, message),
        .status = status,
        .raw_body = try allocator.dupe(u8, body),
    };
}

test "fromString maps known codes" {
    try std.testing.expectEqual(VeriSimErrorCode.not_found, VeriSimErrorCode.fromString("NOT_FOUND"));
    try std.testing.expectEqual(VeriSimErrorCode.unknown, VeriSimErrorCode.fromString("ZZZ"));
}

test "parseServerError extracts code+message" {
    const body =
        \\{"error":{"code":"NOT_FOUND","message":"no such octad","details":{}}}
    ;
    const err = try parseServerError(std.testing.allocator, body, 404);
    defer err.deinit(std.testing.allocator);
    try std.testing.expectEqual(VeriSimErrorCode.not_found, err.code);
    try std.testing.expectEqualStrings("no such octad", err.message);
}
