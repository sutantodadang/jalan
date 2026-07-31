//! Transport layer for the Docker Engine API: connects to the daemon's
//! Unix socket (or Windows named pipe) and drives src/docker/http.zig's
//! request writer / response parser over it.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const http = @import("http.zig");

pub const api_prefix = "/v1.43";

pub const Client = struct { socket_path: []const u8 };

pub const Conn = struct {
    file: std.fs.File,
    pub fn close(self: Conn) void {
        self.file.close();
    }
};

pub fn connect(c: Client) !Conn {
    if (builtin.os.tag == .windows) {
        const f = try std.fs.openFileAbsolute(c.socket_path, .{ .mode = .read_write });
        return .{ .file = f };
    } else {
        const stream = try std.net.connectUnixSocket(c.socket_path);
        return .{ .file = .{ .handle = stream.handle } };
    }
}

pub fn request(alloc: std.mem.Allocator, c: Client, req: http.Request) !http.Response {
    const conn = try connect(c);
    defer conn.close();
    const raw = try http.writeRequest(alloc, req);
    try conn.file.writeAll(raw);
    var buf: [4096]u8 = undefined;
    var file_reader = conn.file.reader(&buf);
    return http.parseResponse(alloc, &file_reader.interface);
}

pub fn ping(alloc: std.mem.Allocator, c: Client) bool {
    const resp = request(alloc, c, .{ .method = "GET", .path = "/_ping" }) catch return false;
    return resp.status == 200;
}

/// Parses a `DOCKER_HOST`-style value into a local socket/pipe path.
/// Supports `unix://` (Unix domain socket path, passed through as-is) and
/// `npipe://` (Windows named pipe; the `//./pipe/...` remainder uses forward
/// slashes, which get converted to backslashes to form a real pipe path like
/// `\\.\pipe\docker_engine`). Any other scheme (e.g. `tcp://`) is not a local
/// socket, so returns null. Needs an allocator because the npipe branch
/// builds a new backslash-converted string.
pub fn socketFromEnvValue(alloc: std.mem.Allocator, v: []const u8) ?[]const u8 {
    const unix_prefix = "unix://";
    const npipe_prefix = "npipe://";
    if (std.mem.startsWith(u8, v, unix_prefix)) {
        return v[unix_prefix.len..];
    }
    if (std.mem.startsWith(u8, v, npipe_prefix)) {
        const rest = v[npipe_prefix.len..];
        const buf = alloc.alloc(u8, rest.len) catch return null;
        for (rest, 0..) |ch, i| buf[i] = if (ch == '/') '\\' else ch;
        return buf;
    }
    return null;
}

pub fn detectSocket(alloc: std.mem.Allocator, cfg: config.Config) ?[]const u8 {
    if (cfg.docker_socket) |s| return s;
    if (std.process.getEnvVarOwned(alloc, "DOCKER_HOST") catch null) |v| {
        if (socketFromEnvValue(alloc, v)) |s| return s;
    }
    return if (builtin.os.tag == .windows) "\\\\.\\pipe\\docker_engine" else "/var/run/docker.sock";
}

test "detectSocket precedence: config over default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = config.Config{ .docker_socket = "/tmp/custom.sock" };
    try std.testing.expectEqualStrings("/tmp/custom.sock", detectSocket(a, cfg).?);

    const default_socket = detectSocket(a, config.Config{}).?;
    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, default_socket, "docker_engine") != null);
    } else {
        try std.testing.expectEqualStrings("/var/run/docker.sock", default_socket);
    }
}

test "ping against live daemon (skips when absent)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = Client{ .socket_path = detectSocket(a, config.Config{}).? };
    if (!ping(a, c)) return error.SkipZigTest;
}

test "socketFromEnvValue parses DOCKER_HOST schemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("/x/y.sock", socketFromEnvValue(a, "unix:///x/y.sock").?);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\p", socketFromEnvValue(a, "npipe:////./pipe/p").?);
    try std.testing.expect(socketFromEnvValue(a, "tcp://127.0.0.1:2375") == null);
}
