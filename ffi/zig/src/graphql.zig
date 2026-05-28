// SPDX-License-Identifier: MPL-2.0
// Minimal GraphQL routing — parses { "query": "...", "variables": {} } and
// dispatches by query-substring to backend HTTP calls. Matches the V gateway's
// field-routing approach: not a full GraphQL parser, but enough to expose
// health / telemetry / octads / driftScore / executeVql.

const std = @import("std");
const Config = @import("config.zig").Config;
const proxy = @import("proxy.zig");

pub const Outcome = @import("router.zig").Outcome;

pub fn handle(
    allocator: std.mem.Allocator,
    cfg: Config,
    body: []const u8,
) !Outcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return errorBody(allocator, 400, "Invalid JSON body");
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return errorBody(allocator, 400, "Body must be a JSON object");

    const query_val = root.object.get("query") orelse {
        return errorBody(allocator, 400, "Missing query field");
    };
    if (query_val != .string or query_val.string.len == 0) {
        return errorBody(allocator, 400, "Missing or empty query field");
    }
    const query = query_val.string;

    const variables = if (root.object.get("variables")) |v|
        if (v == .object) v.object else std.json.ObjectMap.init(allocator)
    else
        std.json.ObjectMap.init(allocator);

    // health
    if (std.mem.indexOf(u8, query, "health") != null) {
        const url = try std.fmt.allocPrint(allocator, "{s}/health", .{cfg.rust_url});
        defer allocator.free(url);
        if (proxy.get(allocator, url)) |r| {
            defer allocator.free(r.body);
            const out = try std.fmt.allocPrint(
                allocator,
                "{{\"data\":{{\"health\":{s}}}}}",
                .{r.body},
            );
            return .{ .status = 200, .body = out };
        } else |_| {
            return dataNull(allocator, "health", "Health backend unreachable");
        }
    }

    // telemetry
    if (std.mem.indexOf(u8, query, "telemetry") != null) {
        const url = try std.fmt.allocPrint(allocator, "{s}/telemetry", .{cfg.orch_url});
        defer allocator.free(url);
        if (proxy.get(allocator, url)) |r| {
            defer allocator.free(r.body);
            const out = try std.fmt.allocPrint(
                allocator,
                "{{\"data\":{{\"telemetry\":{s}}}}}",
                .{r.body},
            );
            return .{ .status = 200, .body = out };
        } else |_| {
            return dataNull(allocator, "telemetry", "Telemetry unavailable");
        }
    }

    // octads
    if (std.mem.indexOf(u8, query, "octads") != null or
        std.mem.indexOf(u8, query, "octad") != null)
    {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/octads?limit=20&offset=0",
            .{cfg.rust_url},
        );
        defer allocator.free(url);
        if (proxy.get(allocator, url)) |r| {
            defer allocator.free(r.body);
            const out = try std.fmt.allocPrint(
                allocator,
                "{{\"data\":{{\"octads\":{s}}}}}",
                .{r.body},
            );
            return .{ .status = 200, .body = out };
        } else |_| {
            return dataNull(allocator, "octads", "Octads unavailable");
        }
    }

    // executeVql mutation
    if (std.mem.indexOf(u8, query, "executeVql") != null or
        std.mem.indexOf(u8, query, "mutation") != null)
    {
        const vql_val = variables.get("query") orelse {
            return errorBody(allocator, 200, "VQL mutation requires variables.query");
        };
        if (vql_val != .string) {
            return errorBody(allocator, 200, "variables.query must be a string");
        }
        const payload = try std.fmt.allocPrint(allocator, "{{\"query\":\"{s}\"}}", .{vql_val.string});
        defer allocator.free(payload);
        const url = try std.fmt.allocPrint(allocator, "{s}/vql/execute", .{cfg.rust_url});
        defer allocator.free(url);
        if (proxy.postJson(allocator, url, payload)) |r| {
            defer allocator.free(r.body);
            const out = try std.fmt.allocPrint(
                allocator,
                "{{\"data\":{{\"executeVql\":{s}}}}}",
                .{r.body},
            );
            return .{ .status = 200, .body = out };
        } else |_| {
            return dataNull(allocator, "executeVql", "VQL execution failed");
        }
    }

    // driftScore
    if (std.mem.indexOf(u8, query, "driftScore") != null) {
        const entity_val = variables.get("entityId") orelse {
            return errorBody(allocator, 200, "driftScore requires variables.entityId");
        };
        if (entity_val != .string) {
            return errorBody(allocator, 200, "variables.entityId must be a string");
        }
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/drift/entity/{s}",
            .{ cfg.rust_url, entity_val.string },
        );
        defer allocator.free(url);
        if (proxy.get(allocator, url)) |r| {
            defer allocator.free(r.body);
            const out = try std.fmt.allocPrint(
                allocator,
                "{{\"data\":{{\"driftScore\":{s}}}}}",
                .{r.body},
            );
            return .{ .status = 200, .body = out };
        } else |_| {
            return dataNull(allocator, "driftScore", "Drift unavailable");
        }
    }

    return errorBody(
        allocator,
        200,
        "Unrecognised query. Supported: health, telemetry, octads, driftScore, executeVql",
    );
}

fn errorBody(allocator: std.mem.Allocator, status: u16, msg: []const u8) !Outcome {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"errors\":[{{\"message\":\"{s}\"}}]}}",
        .{msg},
    );
    return .{ .status = status, .body = body };
}

fn dataNull(allocator: std.mem.Allocator, field: []const u8, msg: []const u8) !Outcome {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"data\":{{\"{s}\":null}},\"errors\":[{{\"message\":\"{s}\"}}]}}",
        .{ field, msg },
    );
    return .{ .status = 200, .body = body };
}
