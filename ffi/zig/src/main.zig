// VeriSimDB Unified API Gateway (Zig)
//
// Replaces the legacy V-lang gateway. Unified REST + GraphQL gateway proxying to:
//   - Rust core         (port 8080)  for data operations
//   - Elixir orchestration (port 4080)  for telemetry/status
//
// Architecture:
//   Client → Zig gateway (:9090) → Rust core (:8080)
//                                → Elixir orchestration (:4080)
//
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const config = @import("config.zig");
const router = @import("router.zig");

const banner =
    \\VeriSimDB Zig API Gateway
    \\  REST + GraphQL on port {d}
    \\  Rust core backend:     {s}
    \\  Elixir orchestration:  {s}
    \\
    \\Endpoints:
    \\  REST:    http://localhost:{d}/api/v1/
    \\  GraphQL: http://localhost:{d}/graphql
    \\
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try config.load(allocator);
    defer config.free(allocator, cfg);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.io.fixedBufferStream(&stdout_buf);
    try stdout.writer().print(banner, .{
        cfg.gateway_port,
        cfg.rust_url,
        cfg.orch_url,
        cfg.gateway_port,
        cfg.gateway_port,
    });
    try std.io.getStdOut().writeAll(stdout.getWritten());

    const address = try std.net.Address.parseIp("0.0.0.0", cfg.gateway_port);
    var net_server = try address.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    while (true) {
        const connection = net_server.accept() catch |err| {
            std.log.warn("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        handleConnection(allocator, cfg, connection) catch |err| {
            std.log.warn("connection failed: {s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    connection: std.net.Server.Connection,
) !void {
    defer connection.stream.close();

    var recv_buffer: [16 * 1024]u8 = undefined;
    var server = std.http.Server.init(connection, &recv_buffer);

    var request = server.receiveHead() catch |err| {
        std.log.warn("receiveHead failed: {s}", .{@errorName(err)});
        return;
    };

    const target = request.head.target;
    const method = request.head.method;

    // Read body if present (for POST/PUT). reader() returns a Reader for the request body.
    const body = if (method == .POST or method == .PUT) blk: {
        var body_buf = std.ArrayList(u8).init(allocator);
        defer body_buf.deinit();
        const reader = try request.reader();
        reader.readAllArrayList(&body_buf, 16 * 1024 * 1024) catch |err| {
            std.log.warn("body read failed: {s}", .{@errorName(err)});
            try request.respond("{\"error\":\"bad_request\"}", .{ .status = .bad_request });
            return;
        };
        break :blk try body_buf.toOwnedSlice();
    } else &[_]u8{};
    defer if (body.len > 0) allocator.free(body);

    const outcome = router.route(allocator, cfg, method, target, body) catch |err| {
        std.log.warn("route failed: {s}", .{@errorName(err)});
        try request.respond("{\"error\":\"internal_error\"}", .{ .status = .internal_server_error });
        return;
    };
    defer allocator.free(outcome.body);

    const status: std.http.Status = @enumFromInt(outcome.status);
    try request.respond(outcome.body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Access-Control-Allow-Origin", .value = "*" },
            .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
            .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization, X-API-Key" },
        },
    });
}

test {
    // Pull in module tests
    std.testing.refAllDecls(@This());
    _ = @import("config.zig");
    _ = @import("proxy.zig");
    _ = @import("router.zig");
    _ = @import("graphql.zig");
}
