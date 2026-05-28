// SPDX-License-Identifier: MPL-2.0
// VeriSimDB Zig Client — Drift detection operations.

const std = @import("std");
const Client = @import("client.zig").Client;
const types = @import("types.zig");
const errors = @import("error.zig");

pub const ParsedScore = std.json.Parsed(types.DriftScore);
pub const ParsedReport = std.json.Parsed(types.DriftStatusReport);

fn decodeOk(
    comptime T: type,
    allocator: std.mem.Allocator,
    body: []const u8,
    status: u16,
) !std.json.Parsed(T) {
    if (status == 200) {
        return std.json.parseFromSlice(T, allocator, body, .{ .ignore_unknown_fields = true }) catch
            errors.ClientError.DecodeFailed;
    }
    const err = errors.parseServerError(allocator, body, status) catch
        return errors.ClientError.HttpError;
    err.deinit(allocator);
    return errors.ClientError.HttpError;
}

pub fn score(client: *Client, octad_id: []const u8) !ParsedScore {
    const path = try std.fmt.allocPrint(
        client.allocator,
        "/api/v1/octads/{s}/drift",
        .{octad_id},
    );
    defer client.allocator.free(path);
    const resp = try client.doGet(path);
    defer resp.deinit(client.allocator);
    return decodeOk(types.DriftScore, client.allocator, resp.body, resp.status);
}

pub fn status(client: *Client, octad_id: []const u8) !ParsedReport {
    const path = try std.fmt.allocPrint(
        client.allocator,
        "/api/v1/octads/{s}/drift/status",
        .{octad_id},
    );
    defer client.allocator.free(path);
    const resp = try client.doGet(path);
    defer resp.deinit(client.allocator);
    return decodeOk(types.DriftStatusReport, client.allocator, resp.body, resp.status);
}

pub fn normalize(client: *Client, octad_id: []const u8) !ParsedScore {
    const path = try std.fmt.allocPrint(
        client.allocator,
        "/api/v1/octads/{s}/drift/normalize",
        .{octad_id},
    );
    defer client.allocator.free(path);
    const resp = try client.doPost(path, "{}");
    defer resp.deinit(client.allocator);
    return decodeOk(types.DriftScore, client.allocator, resp.body, resp.status);
}
