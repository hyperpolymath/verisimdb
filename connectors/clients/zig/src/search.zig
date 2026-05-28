// SPDX-License-Identifier: MPL-2.0
// VeriSimDB Zig Client — Multi-modal search operations.

const std = @import("std");
const Client = @import("client.zig").Client;
const types = @import("types.zig");
const errors = @import("error.zig");

pub const ParsedResults = std.json.Parsed([]types.SearchResult);

pub const TextParams = struct {
    query: []const u8,
    modalities: []const types.Modality = &.{},
    limit: u32 = 20,
    offset: u32 = 0,
};

pub const VectorParams = struct {
    vector: []const f64,
    model: []const u8 = "",
    top_k: u32 = 10,
    threshold: f64 = 0.0,
};

pub const SpatialRadiusParams = struct {
    latitude: f64,
    longitude: f64,
    radius_km: f64,
    limit: u32 = 20,
};

pub const SpatialBoundsParams = struct {
    min_lat: f64,
    min_lon: f64,
    max_lat: f64,
    max_lon: f64,
    limit: u32 = 20,
};

pub const NearestParams = struct {
    octad_id: []const u8,
    top_k: u32 = 10,
    modality: types.Modality = .vector,
};

pub const RelatedParams = struct {
    octad_id: []const u8,
    rel_type: ?[]const u8 = null,
    depth: u32 = 1,
    limit: u32 = 20,
};

fn postSearch(
    client: *Client,
    path: []const u8,
    payload: anytype,
) !ParsedResults {
    const body = try std.json.stringifyAlloc(client.allocator, payload, .{});
    defer client.allocator.free(body);
    const resp = try client.doPost(path, body);
    defer resp.deinit(client.allocator);
    if (resp.status != 200) {
        const err = try errors.parseServerError(client.allocator, resp.body, resp.status);
        err.deinit(client.allocator);
        return errors.ClientError.HttpError;
    }
    return std.json.parseFromSlice(
        []types.SearchResult,
        client.allocator,
        resp.body,
        .{ .ignore_unknown_fields = true },
    ) catch errors.ClientError.DecodeFailed;
}

pub fn text(client: *Client, params: TextParams) !ParsedResults {
    return postSearch(client, "/api/v1/search/text", params);
}

pub fn vector(client: *Client, params: VectorParams) !ParsedResults {
    return postSearch(client, "/api/v1/search/vector", params);
}

pub fn spatialRadius(client: *Client, params: SpatialRadiusParams) !ParsedResults {
    return postSearch(client, "/api/v1/search/spatial/radius", params);
}

pub fn spatialBounds(client: *Client, params: SpatialBoundsParams) !ParsedResults {
    return postSearch(client, "/api/v1/search/spatial/bounds", params);
}

pub fn nearest(client: *Client, params: NearestParams) !ParsedResults {
    return postSearch(client, "/api/v1/search/nearest", params);
}

pub fn related(client: *Client, params: RelatedParams) !ParsedResults {
    return postSearch(client, "/api/v1/search/related", params);
}
