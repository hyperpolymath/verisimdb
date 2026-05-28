// SPDX-License-Identifier: MPL-2.0
// VeriSimDB Zig Client — VQL execution and explain.

const std = @import("std");
const Client = @import("client.zig").Client;
const types = @import("types.zig");
const errors = @import("error.zig");

pub const ParsedResult = std.json.Parsed(types.VqlResult);
pub const ParsedExplanation = std.json.Parsed(types.VqlExplanation);

pub const Request = struct {
    query: []const u8,
    params: ?std.json.Value = null,
};

fn decode(
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

pub fn execute(client: *Client, query: []const u8) !ParsedResult {
    const body = try std.fmt.allocPrint(client.allocator, "{{\"query\":\"{s}\"}}", .{query});
    defer client.allocator.free(body);
    const resp = try client.doPost("/api/v1/vql/execute", body);
    defer resp.deinit(client.allocator);
    return decode(types.VqlResult, client.allocator, resp.body, resp.status);
}

pub fn explain(client: *Client, query: []const u8) !ParsedExplanation {
    const body = try std.fmt.allocPrint(client.allocator, "{{\"query\":\"{s}\"}}", .{query});
    defer client.allocator.free(body);
    const resp = try client.doPost("/api/v1/vql/explain", body);
    defer resp.deinit(client.allocator);
    return decode(types.VqlExplanation, client.allocator, resp.body, resp.status);
}
