// VeriSimDB Zig Client SDK — public module root.
//
// Replaces the legacy V-lang client at connectors/clients/vlang/. Mirrors the
// API surface of the V SDK while remaining idiomatic Zig.
//
// Usage:
//   const verisim = @import("verisimdb_client");
//   var client = verisim.Client.init(allocator, "http://localhost:8080");
//   defer client.deinit();
//   const healthy = try client.health();
//
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

pub const errors = @import("error.zig");
pub const types = @import("types.zig");
pub const octad = @import("octad.zig");
pub const drift = @import("drift.zig");
pub const provenance = @import("provenance.zig");
pub const search = @import("search.zig");
pub const vql = @import("vql.zig");
pub const federation = @import("federation.zig");

pub const Client = @import("client.zig").Client;
pub const Auth = @import("client.zig").Auth;

pub const VeriSimError = errors.VeriSimError;
pub const VeriSimErrorCode = errors.VeriSimErrorCode;

pub const Modality = types.Modality;
pub const ModalityStatus = types.ModalityStatus;
pub const Octad = types.Octad;
pub const OctadStatus = types.OctadStatus;
pub const OctadInput = types.OctadInput;
pub const DriftScore = types.DriftScore;
pub const DriftLevel = types.DriftLevel;
pub const DriftStatusReport = types.DriftStatusReport;
pub const ProvenanceEvent = types.ProvenanceEvent;
pub const ProvenanceChain = types.ProvenanceChain;
pub const PaginatedResponse = types.PaginatedResponse;
pub const SearchResult = types.SearchResult;
pub const VqlResult = types.VqlResult;
pub const VqlExplanation = types.VqlExplanation;
pub const FederationPeer = types.FederationPeer;

test {
    std.testing.refAllDecls(@This());
    _ = @import("client.zig");
    _ = @import("types.zig");
    _ = @import("error.zig");
    _ = @import("octad.zig");
    _ = @import("drift.zig");
    _ = @import("provenance.zig");
    _ = @import("search.zig");
    _ = @import("vql.zig");
    _ = @import("federation.zig");
}
