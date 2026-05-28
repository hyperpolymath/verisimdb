// SPDX-License-Identifier: MPL-2.0
// HTTP proxy helpers — forward GET/POST to backend services (Rust core, Elixir orch).

const std = @import("std");

pub const ProxyError = error{
    BackendUnreachable,
    BackendStatus,
    OutOfMemory,
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub fn get(allocator: std.mem.Allocator, url: []const u8) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body_buf = std.ArrayList(u8).init(allocator);
    errdefer body_buf.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_storage = .{ .dynamic = &body_buf },
    }) catch return ProxyError.BackendUnreachable;

    return .{
        .status = @intFromEnum(result.status),
        .body = try body_buf.toOwnedSlice(),
    };
}

pub fn postJson(allocator: std.mem.Allocator, url: []const u8, payload: []const u8) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body_buf = std.ArrayList(u8).init(allocator);
    errdefer body_buf.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .response_storage = .{ .dynamic = &body_buf },
    }) catch return ProxyError.BackendUnreachable;

    return .{
        .status = @intFromEnum(result.status),
        .body = try body_buf.toOwnedSlice(),
    };
}
