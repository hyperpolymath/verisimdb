// SPDX-License-Identifier: MPL-2.0
// VeriSimDB Zig Client — wire types matching the JSON schema.
//
// Each type is decoded directly from the server's JSON payload via std.json.
// Octad fields that are optional on the wire are modelled as ?T.

const std = @import("std");

pub const Modality = enum {
    graph,
    vector,
    tensor,
    semantic,
    document,
    temporal,
    provenance,
    spatial,

    pub fn toString(m: Modality) []const u8 {
        return @tagName(m);
    }
};

pub const ModalityStatus = struct {
    graph: bool = false,
    vector: bool = false,
    tensor: bool = false,
    semantic: bool = false,
    document: bool = false,
    temporal: bool = false,
    provenance: bool = false,
    spatial: bool = false,
};

pub const OctadStatus = enum {
    active,
    archived,
    draft,
    deleted,

    pub fn toString(s: OctadStatus) []const u8 {
        return @tagName(s);
    }
};

pub const GraphEdge = struct {
    source: []const u8,
    target: []const u8,
    rel_type: []const u8,
    weight: f64 = 0.0,
};

pub const GraphData = struct {
    edges: []const GraphEdge = &.{},
};

pub const VectorData = struct {
    embedding: []const f64,
    model: []const u8 = "",
    dimensions: u32 = 0,
};

pub const TensorData = struct {
    shape: []const i32,
    dtype: []const u8 = "float32",
    data_ref: []const u8 = "",
};

pub const DocumentContent = struct {
    text: []const u8 = "",
    format: []const u8 = "plain",
    language: []const u8 = "en",
};

pub const SpatialData = struct {
    latitude: f64,
    longitude: f64,
    altitude: ?f64 = null,
    geometry: ?[]const u8 = null,
    crs: []const u8 = "EPSG:4326",
};

pub const Octad = struct {
    id: []const u8,
    status: []const u8 = "active",
    modalities: ModalityStatus = .{},
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    graph_data: ?GraphData = null,
    vector_data: ?VectorData = null,
    tensor_data: ?TensorData = null,
    content: ?DocumentContent = null,
    spatial_data: ?SpatialData = null,
};

pub const OctadInput = struct {
    graph_data: ?GraphData = null,
    vector_data: ?VectorData = null,
    tensor_data: ?TensorData = null,
    content: ?DocumentContent = null,
    spatial_data: ?SpatialData = null,
    modalities: []const Modality = &.{},
};

pub const DriftScore = struct {
    octad_id: []const u8,
    score: f64,
    measured_at: []const u8 = "",
    baseline_at: []const u8 = "",
};

pub const DriftLevel = enum {
    stable,
    low,
    moderate,
    high,
    critical,
};

pub const DriftStatusReport = struct {
    octad_id: []const u8,
    level: []const u8, // decoded as string then mapped
    score: DriftScore,
    message: []const u8 = "",
};

pub const ProvenanceEvent = struct {
    event_id: []const u8,
    octad_id: []const u8,
    event_type: []const u8,
    actor: []const u8,
    timestamp: []const u8,
    parent_id: ?[]const u8 = null,
};

pub const ProvenanceChain = struct {
    octad_id: []const u8,
    events: []const ProvenanceEvent,
    verified: bool = false,
};

pub const PaginatedResponse = struct {
    items: []const Octad,
    total: u64 = 0,
    page: u32 = 1,
    per_page: u32 = 20,
    total_pages: u32 = 0,
};

pub const SearchResult = struct {
    octad: Octad,
    score: f64 = 0.0,
};

pub const VqlResult = struct {
    columns: []const []const u8,
    rows: []const []const []const u8,
    count: u64 = 0,
    elapsed_ms: f64 = 0.0,
};

pub const VqlExplanation = struct {
    query: []const u8,
    plan: []const u8,
    cost: f64 = 0.0,
    warnings: []const []const u8 = &.{},
};

pub const FederationPeer = struct {
    peer_id: []const u8,
    name: []const u8,
    url: []const u8,
    status: []const u8 = "active",
    last_seen: []const u8 = "",
};

test "Modality.toString" {
    try std.testing.expectEqualStrings("graph", Modality.graph.toString());
    try std.testing.expectEqualStrings("vector", Modality.vector.toString());
}
