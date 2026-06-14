// SPDX-License-Identifier: MPL-2.0
// REST route dispatch. Mirrors the V gateway endpoints:
//   /api/v1/health          combined gateway+rust+elixir health
//   /api/v1/octads*         → Rust core /octads*
//   /api/v1/vcl/execute     → Rust core /vcl/execute
//   /api/v1/drift/*         → Rust core /drift/*
//   /api/v1/search/*        → Rust core /search/*
//   /api/v1/provenance/*    → Rust core /provenance/*
//   /api/v1/spatial/*       → Rust core /spatial/*
//   /api/v1/telemetry*      → Elixir orch  /telemetry*
//   /api/v1/status          → Elixir orch  /status
//   /graphql                local GraphQL routing

const std = @import("std");
const Config = @import("config.zig").Config;
const proxy = @import("proxy.zig");
const graphql = @import("graphql.zig");

const api_prefix = "/api/v1";

pub const Outcome = struct {
    status: u16,
    body: []u8, // owned by caller; caller must free
};

pub fn route(
    allocator: std.mem.Allocator,
    cfg: Config,
    method: std.http.Method,
    target: []const u8,
    request_body: []const u8,
) !Outcome {
    // OPTIONS preflight
    if (method == .OPTIONS) {
        return .{ .status = 204, .body = try allocator.dupe(u8, "") };
    }

    if (std.mem.eql(u8, target, "/graphql") and method == .POST) {
        return graphql.handle(allocator, cfg, request_body);
    }

    if (std.mem.eql(u8, target, "/api/v1/health") and method == .GET) {
        return handleHealth(allocator, cfg);
    }

    if (!std.mem.startsWith(u8, target, api_prefix)) {
        return notFound(allocator, target);
    }

    const subpath = target[api_prefix.len..];

    // ----- Rust-core routes -----
    if (std.mem.startsWith(u8, subpath, "/octads")) {
        return forward(allocator, cfg.rust_url, subpath, method, request_body);
    }
    if (std.mem.eql(u8, subpath, "/vcl/execute") and method == .POST) {
        return forward(allocator, cfg.rust_url, subpath, method, request_body);
    }
    if (std.mem.startsWith(u8, subpath, "/drift/") and method == .GET) {
        return forward(allocator, cfg.rust_url, subpath, method, request_body);
    }
    if (std.mem.startsWith(u8, subpath, "/search/")) {
        return forward(allocator, cfg.rust_url, subpath, method, request_body);
    }
    if (std.mem.startsWith(u8, subpath, "/provenance/") and method == .GET) {
        return forward(allocator, cfg.rust_url, subpath, method, request_body);
    }
    if (std.mem.startsWith(u8, subpath, "/spatial/") and method == .POST) {
        return forward(allocator, cfg.rust_url, subpath, method, request_body);
    }

    // ----- Elixir orchestration routes -----
    if (std.mem.startsWith(u8, subpath, "/telemetry") and method == .GET) {
        const tail = subpath["/telemetry".len..];
        const orch_path = try std.fmt.allocPrint(
            allocator,
            "/telemetry{s}",
            .{tail},
        );
        defer allocator.free(orch_path);
        return forward(allocator, cfg.orch_url, orch_path, method, request_body);
    }
    if (std.mem.eql(u8, subpath, "/status") and method == .GET) {
        return forward(allocator, cfg.orch_url, "/status", method, request_body);
    }

    return notFound(allocator, target);
}

fn forward(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    subpath: []const u8,
    method: std.http.Method,
    body: []const u8,
) !Outcome {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, subpath });
    defer allocator.free(url);

    const resp = switch (method) {
        .GET => proxy.get(allocator, url) catch |err| return backendUnavailable(allocator, err),
        .POST => proxy.postJson(allocator, url, body) catch |err| return backendUnavailable(allocator, err),
        else => return .{
            .status = 405,
            .body = try allocator.dupe(u8, "{\"error\":\"method_not_allowed\"}"),
        },
    };
    return .{ .status = resp.status, .body = resp.body };
}

fn handleHealth(allocator: std.mem.Allocator, cfg: Config) !Outcome {
    const rust_url = try std.fmt.allocPrint(allocator, "{s}/health", .{cfg.rust_url});
    defer allocator.free(rust_url);
    const orch_url = try std.fmt.allocPrint(allocator, "{s}/health", .{cfg.orch_url});
    defer allocator.free(orch_url);

    var rust_ok = false;
    if (proxy.get(allocator, rust_url)) |r| {
        rust_ok = r.status >= 200 and r.status < 400;
        r.deinit(allocator);
    } else |_| {}

    var orch_ok = false;
    if (proxy.get(allocator, orch_url)) |r| {
        orch_ok = r.status >= 200 and r.status < 400;
        r.deinit(allocator);
    } else |_| {}

    const overall: []const u8 = if (rust_ok and orch_ok)
        "healthy"
    else if (rust_ok or orch_ok)
        "degraded"
    else
        "unhealthy";

    const rust_status = if (rust_ok) "ok" else "unreachable";
    const orch_status = if (orch_ok) "ok" else "unreachable";

    const ts = std.time.timestamp();
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"{s}\",\"gateway\":\"ok\",\"rust_core\":\"{s}\",\"orchestration\":\"{s}\",\"timestamp_unix\":{d}}}",
        .{ overall, rust_status, orch_status, ts },
    );
    return .{ .status = 200, .body = body };
}

fn notFound(allocator: std.mem.Allocator, target: []const u8) !Outcome {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"not_found\",\"message\":\"Unknown endpoint: {s}\"}}",
        .{target},
    );
    return .{ .status = 404, .body = body };
}

fn backendUnavailable(allocator: std.mem.Allocator, err: anyerror) !Outcome {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"backend_unavailable\",\"message\":\"{s}\"}}",
        .{@errorName(err)},
    );
    return .{ .status = 502, .body = body };
}

test "OPTIONS returns 204" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .gateway_port = 9090,
        .rust_url = "http://localhost:8080/api/v1",
        .orch_url = "http://localhost:4080",
    };
    const outcome = try route(allocator, cfg, .OPTIONS, "/whatever", "");
    defer allocator.free(outcome.body);
    try std.testing.expectEqual(@as(u16, 204), outcome.status);
}

test "unknown path returns 404" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .gateway_port = 9090,
        .rust_url = "http://localhost:8080/api/v1",
        .orch_url = "http://localhost:4080",
    };
    const outcome = try route(allocator, cfg, .GET, "/no-such-path", "");
    defer allocator.free(outcome.body);
    try std.testing.expectEqual(@as(u16, 404), outcome.status);
}
