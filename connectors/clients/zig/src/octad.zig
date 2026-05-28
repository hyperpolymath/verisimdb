// SPDX-License-Identifier: MPL-2.0
// VeriSimDB Zig Client — Octad CRUD operations.

const std = @import("std");
const Client = @import("client.zig").Client;
const types = @import("types.zig");
const errors = @import("error.zig");

pub const ParsedOctad = std.json.Parsed(types.Octad);
pub const ParsedPage = std.json.Parsed(types.PaginatedResponse);

fn decodeOrError(
    comptime T: type,
    allocator: std.mem.Allocator,
    body: []const u8,
    status: u16,
    expected: []const u16,
) !std.json.Parsed(T) {
    for (expected) |s| if (s == status) {
        return std.json.parseFromSlice(T, allocator, body, .{ .ignore_unknown_fields = true }) catch
            return errors.ClientError.DecodeFailed;
    };
    const err = errors.parseServerError(allocator, body, status) catch
        return errors.ClientError.HttpError;
    err.deinit(allocator);
    return errors.ClientError.HttpError;
}

pub fn create(client: *Client, input: types.OctadInput) !ParsedOctad {
    const body = try std.json.stringifyAlloc(client.allocator, input, .{});
    defer client.allocator.free(body);
    const resp = try client.doPost("/api/v1/octads", body);
    defer resp.deinit(client.allocator);
    return decodeOrError(types.Octad, client.allocator, resp.body, resp.status, &.{201});
}

pub fn get(client: *Client, id: []const u8) !ParsedOctad {
    const path = try std.fmt.allocPrint(client.allocator, "/api/v1/octads/{s}", .{id});
    defer client.allocator.free(path);
    const resp = try client.doGet(path);
    defer resp.deinit(client.allocator);
    return decodeOrError(types.Octad, client.allocator, resp.body, resp.status, &.{200});
}

pub fn update(client: *Client, id: []const u8, input: types.OctadInput) !ParsedOctad {
    const body = try std.json.stringifyAlloc(client.allocator, input, .{});
    defer client.allocator.free(body);
    const path = try std.fmt.allocPrint(client.allocator, "/api/v1/octads/{s}", .{id});
    defer client.allocator.free(path);
    const resp = try client.doPut(path, body);
    defer resp.deinit(client.allocator);
    return decodeOrError(types.Octad, client.allocator, resp.body, resp.status, &.{200});
}

pub fn delete(client: *Client, id: []const u8) !void {
    const path = try std.fmt.allocPrint(client.allocator, "/api/v1/octads/{s}", .{id});
    defer client.allocator.free(path);
    const resp = try client.doDelete(path);
    defer resp.deinit(client.allocator);
    if (resp.status != 200 and resp.status != 204) {
        const err = try errors.parseServerError(client.allocator, resp.body, resp.status);
        err.deinit(client.allocator);
        return errors.ClientError.HttpError;
    }
}

pub fn list(client: *Client, page: u32, per_page: u32) !ParsedPage {
    const path = try std.fmt.allocPrint(
        client.allocator,
        "/api/v1/octads?page={d}&per_page={d}",
        .{ page, per_page },
    );
    defer client.allocator.free(path);
    const resp = try client.doGet(path);
    defer resp.deinit(client.allocator);
    return decodeOrError(types.PaginatedResponse, client.allocator, resp.body, resp.status, &.{200});
}
