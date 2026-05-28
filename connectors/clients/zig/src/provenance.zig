// SPDX-License-Identifier: MPL-2.0
// VeriSimDB Zig Client — Provenance operations.

const std = @import("std");
const Client = @import("client.zig").Client;
const types = @import("types.zig");
const errors = @import("error.zig");

pub const ParsedChain = std.json.Parsed(types.ProvenanceChain);
pub const ParsedEvent = std.json.Parsed(types.ProvenanceEvent);

pub const EventInput = struct {
    event_type: []const u8,
    actor: []const u8,
};

fn decode(
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

pub fn chain(client: *Client, octad_id: []const u8) !ParsedChain {
    const path = try std.fmt.allocPrint(
        client.allocator,
        "/api/v1/octads/{s}/provenance",
        .{octad_id},
    );
    defer client.allocator.free(path);
    const resp = try client.doGet(path);
    defer resp.deinit(client.allocator);
    return decode(types.ProvenanceChain, client.allocator, resp.body, resp.status, &.{200});
}

pub fn record(client: *Client, octad_id: []const u8, input: EventInput) !ParsedEvent {
    const body = try std.json.stringifyAlloc(client.allocator, input, .{});
    defer client.allocator.free(body);
    const path = try std.fmt.allocPrint(
        client.allocator,
        "/api/v1/octads/{s}/provenance",
        .{octad_id},
    );
    defer client.allocator.free(path);
    const resp = try client.doPost(path, body);
    defer resp.deinit(client.allocator);
    return decode(types.ProvenanceEvent, client.allocator, resp.body, resp.status, &.{201});
}

pub fn verify(client: *Client, octad_id: []const u8) !bool {
    const path = try std.fmt.allocPrint(
        client.allocator,
        "/api/v1/octads/{s}/provenance/verify",
        .{octad_id},
    );
    defer client.allocator.free(path);
    const resp = try client.doPost(path, "{}");
    defer resp.deinit(client.allocator);
    const parsed = try decode(types.ProvenanceChain, client.allocator, resp.body, resp.status, &.{200});
    defer parsed.deinit();
    return parsed.value.verified;
}
