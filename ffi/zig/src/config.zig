// SPDX-License-Identifier: MPL-2.0
// Gateway configuration loaded from environment variables.

const std = @import("std");

pub const Config = struct {
    gateway_port: u16,
    rust_url: []const u8,
    orch_url: []const u8,

    pub const default_gateway_port: u16 = 9090;
    pub const default_rust_url: []const u8 = "http://localhost:8080/api/v1";
    pub const default_orch_url: []const u8 = "http://localhost:4080";
};

fn envOrDefault(allocator: std.mem.Allocator, key: []const u8, default: []const u8) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, default),
        else => err,
    };
}

pub fn load(allocator: std.mem.Allocator) !Config {
    const port_str = std.process.getEnvVarOwned(allocator, "VERISIM_GATEWAY_PORT") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (port_str) |s| allocator.free(s);

    const port: u16 = if (port_str) |s|
        std.fmt.parseInt(u16, s, 10) catch Config.default_gateway_port
    else
        Config.default_gateway_port;

    return .{
        .gateway_port = port,
        .rust_url = try envOrDefault(allocator, "VERISIM_RUST_URL", Config.default_rust_url),
        .orch_url = try envOrDefault(allocator, "VERISIM_ORCH_URL", Config.default_orch_url),
    };
}

pub fn free(allocator: std.mem.Allocator, cfg: Config) void {
    allocator.free(cfg.rust_url);
    allocator.free(cfg.orch_url);
}

test "load uses defaults when env unset" {
    const allocator = std.testing.allocator;
    const cfg = try load(allocator);
    defer free(allocator, cfg);
    try std.testing.expect(cfg.gateway_port > 0);
}
