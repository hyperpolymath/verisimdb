// SPDX-License-Identifier: MPL-2.0
// VeriSimDB Zig Client — Connection, authentication, and HTTP transport.

const std = @import("std");
const errors = @import("error.zig");

pub const Auth = union(enum) {
    none,
    api_key: []const u8,
    bearer: []const u8,
    basic: struct { username: []const u8, password: []const u8 },
};

pub const HttpResponse = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []u8, // owned (with trailing slash trimmed)
    auth: Auth,
    timeout_ms: u32 = 30_000,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) !Client {
        return initWithAuth(allocator, base_url, .none);
    }

    pub fn initWithAuth(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        auth: Auth,
    ) !Client {
        const trimmed = std.mem.trimRight(u8, base_url, "/");
        return .{
            .allocator = allocator,
            .base_url = try allocator.dupe(u8, trimmed),
            .auth = auth,
        };
    }

    pub fn initWithApiKey(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        key: []const u8,
    ) !Client {
        return initWithAuth(allocator, base_url, .{ .api_key = key });
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.base_url);
    }

    pub fn health(self: *Client) !bool {
        const resp = try self.doGet("/health");
        defer resp.deinit(self.allocator);
        return resp.status == 200;
    }

    pub fn doGet(self: *Client, path: []const u8) !HttpResponse {
        return self.fetch(.GET, path, null);
    }

    pub fn doPost(self: *Client, path: []const u8, body: []const u8) !HttpResponse {
        return self.fetch(.POST, path, body);
    }

    pub fn doPut(self: *Client, path: []const u8, body: []const u8) !HttpResponse {
        return self.fetch(.PUT, path, body);
    }

    pub fn doDelete(self: *Client, path: []const u8) !HttpResponse {
        return self.fetch(.DELETE, path, null);
    }

    fn fetch(
        self: *Client,
        method: std.http.Method,
        path: []const u8,
        body: ?[]const u8,
    ) !HttpResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
        defer self.allocator.free(url);

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var body_buf = std.ArrayList(u8).init(self.allocator);
        errdefer body_buf.deinit();

        // Build auth headers
        var extra_headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer extra_headers.deinit();
        var auth_value_storage: ?[]u8 = null;
        defer if (auth_value_storage) |v| self.allocator.free(v);

        switch (self.auth) {
            .none => {},
            .api_key => |k| try extra_headers.append(.{ .name = "X-API-Key", .value = k }),
            .bearer => |tok| {
                const v = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{tok});
                auth_value_storage = v;
                try extra_headers.append(.{ .name = "Authorization", .value = v });
            },
            .basic => |creds| {
                const raw = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}:{s}",
                    .{ creds.username, creds.password },
                );
                defer self.allocator.free(raw);
                const enc_len = std.base64.standard.Encoder.calcSize(raw.len);
                const encoded = try self.allocator.alloc(u8, enc_len);
                _ = std.base64.standard.Encoder.encode(encoded, raw);
                const v = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{encoded});
                self.allocator.free(encoded);
                auth_value_storage = v;
                try extra_headers.append(.{ .name = "Authorization", .value = v });
            },
        }

        var fetch_opts = std.http.Client.FetchOptions{
            .location = .{ .url = url },
            .method = method,
            .response_storage = .{ .dynamic = &body_buf },
            .extra_headers = extra_headers.items,
        };

        if (body) |b| {
            fetch_opts.payload = b;
            fetch_opts.headers = .{ .content_type = .{ .override = "application/json" } };
        }

        const result = http_client.fetch(fetch_opts) catch return errors.ClientError.BackendUnreachable;

        return .{
            .status = @intFromEnum(result.status),
            .body = try body_buf.toOwnedSlice(),
        };
    }
};

test "Client.init dupes and trims base_url" {
    var c = try Client.init(std.testing.allocator, "http://localhost:8080/");
    defer c.deinit();
    try std.testing.expectEqualStrings("http://localhost:8080", c.base_url);
}
