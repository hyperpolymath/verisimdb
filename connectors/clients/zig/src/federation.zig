// SPDX-License-Identifier: MPL-2.0
// VeriSimDB Zig Client — Federation operations.

const std = @import("std");
const Client = @import("client.zig").Client;
const types = @import("types.zig");
const errors = @import("error.zig");

pub const PeerRegistration = struct {
    name: []const u8,
    url: []const u8,
};

pub const FederatedQueryRequest = struct {
    query: []const u8,
    peer_ids: []const []const u8 = &.{},
    timeout_ms: u32 = 30_000,
};

pub const PeerQueryResult = struct {
    peer_id: []const u8,
    peer_name: []const u8,
    result: types.VqlResult,
    elapsed_ms: f64 = 0.0,
    @"error": ?[]const u8 = null,
};

pub const FederatedQueryResult = struct {
    results: []const PeerQueryResult,
    total: u32 = 0,
    elapsed_ms: f64 = 0.0,
};

pub const ParsedPeer = std.json.Parsed(types.FederationPeer);
pub const ParsedPeerList = std.json.Parsed([]types.FederationPeer);
pub const ParsedFedResult = std.json.Parsed(FederatedQueryResult);

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

pub fn registerPeer(client: *Client, input: PeerRegistration) !ParsedPeer {
    const body = try std.json.stringifyAlloc(client.allocator, input, .{});
    defer client.allocator.free(body);
    const resp = try client.doPost("/api/v1/federation/peers", body);
    defer resp.deinit(client.allocator);
    return decode(types.FederationPeer, client.allocator, resp.body, resp.status, &.{201});
}

pub fn listPeers(client: *Client) !ParsedPeerList {
    const resp = try client.doGet("/api/v1/federation/peers");
    defer resp.deinit(client.allocator);
    return decode([]types.FederationPeer, client.allocator, resp.body, resp.status, &.{200});
}

pub fn query(client: *Client, input: FederatedQueryRequest) !ParsedFedResult {
    const body = try std.json.stringifyAlloc(client.allocator, input, .{});
    defer client.allocator.free(body);
    const resp = try client.doPost("/api/v1/federation/query", body);
    defer resp.deinit(client.allocator);
    return decode(FederatedQueryResult, client.allocator, resp.body, resp.status, &.{200});
}
