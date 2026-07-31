//! Transport layer for the Docker Engine API: connects to the daemon's
//! Unix socket (or Windows named pipe) and drives src/docker/http.zig's
//! request writer / response parser over it.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const backend = @import("../backend.zig");
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

/// Extracts a human-readable message from a Docker daemon error body
/// (`{"message":"..."}`); falls back to the raw body if it doesn't parse.
fn daemonErrorMessage(alloc: std.mem.Allocator, body: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(struct { message: []const u8 }, alloc, body, .{ .ignore_unknown_fields = true }) catch return body;
    return parsed.message;
}

/// Sends `req` and treats any non-2xx status as a Docker API error, capturing
/// the daemon's message into `err`. Callers that need to treat a specific
/// non-2xx status as a non-error case (e.g. `imageExists`'s 404) should call
/// `request` directly instead.
fn apiCall(alloc: std.mem.Allocator, c: Client, req: http.Request, err: *?[]const u8) !http.Response {
    const resp = try request(alloc, c, req);
    if (resp.status >= 300) {
        err.* = daemonErrorMessage(alloc, resp.body);
        return error.DockerApi;
    }
    return resp;
}

/// Minimal percent-encoding for a URL query-string value: keeps
/// alphanumerics and a handful of safe punctuation marks (including `/`,
/// since container paths are usually multi-segment), escapes everything
/// else as `%XX`.
fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        const safe = std.ascii.isAlphanumeric(ch) or switch (ch) {
            '-', '_', '.', '~', '/' => true,
            else => false,
        };
        if (safe) {
            try out.append(alloc, ch);
        } else {
            try out.print(alloc, "%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Splits an image reference like `busybox:latest` into name/tag. A `:` is
/// only treated as the tag separator when nothing after it contains a `/`,
/// so registry host:port prefixes (`myregistry:5000/image`) aren't
/// misparsed. Defaults to `latest` when no tag is present.
fn splitImageRef(image: []const u8) struct { name: []const u8, tag: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, image, ':')) |i| {
        const after = image[i + 1 ..];
        if (std.mem.indexOfScalar(u8, after, '/') == null) {
            return .{ .name = image[0..i], .tag = after };
        }
    }
    return .{ .name = image, .tag = "latest" };
}

/// `GET {prefix}/images/{name}/json`: true on 200, false on 404, error on
/// anything else (404 is an expected outcome here, not an API error).
pub fn imageExists(alloc: std.mem.Allocator, c: Client, image: []const u8, err: *?[]const u8) !bool {
    const path = try std.fmt.allocPrint(alloc, "{s}/images/{s}/json", .{ api_prefix, image });
    const resp = try request(alloc, c, .{ .method = "GET", .path = path });
    if (resp.status == 200) return true;
    if (resp.status == 404) return false;
    err.* = daemonErrorMessage(alloc, resp.body);
    return error.DockerApi;
}

/// `POST {prefix}/images/create?fromImage=<name>&tag=<tag>`: body is a
/// stream of JSON-lines progress events. Reads the full body, then emits one
/// log line per unique `status` string (in first-seen order).
pub fn imagePull(alloc: std.mem.Allocator, c: Client, image: []const u8, log: ?backend.LogFn, err: *?[]const u8) !void {
    const ref = splitImageRef(image);
    const path = try std.fmt.allocPrint(alloc, "{s}/images/create?fromImage={s}&tag={s}", .{ api_prefix, ref.name, ref.tag });
    const resp = try apiCall(alloc, c, .{ .method = "POST", .path = path }, err);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, resp.body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(struct { status: ?[]const u8 = null }, alloc, line, .{ .ignore_unknown_fields = true }) catch continue;
        const status = parsed.status orelse continue;
        if (seen.contains(status)) continue;
        try seen.put(alloc, status, {});
        if (log) |l| l(status);
    }
}

/// `POST {prefix}/containers/create[?name=<name>]`: returns the new
/// container's id, parsed from `{"Id":"..."}`.
pub fn containerCreate(alloc: std.mem.Allocator, c: Client, spec_json: []const u8, name: ?[]const u8, err: *?[]const u8) ![]const u8 {
    const path = if (name) |n|
        try std.fmt.allocPrint(alloc, "{s}/containers/create?name={s}", .{ api_prefix, n })
    else
        try std.fmt.allocPrint(alloc, "{s}/containers/create", .{api_prefix});
    const resp = try apiCall(alloc, c, .{
        .method = "POST",
        .path = path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = spec_json,
    }, err);
    const parsed = std.json.parseFromSliceLeaky(struct { Id: []const u8 }, alloc, resp.body, .{ .ignore_unknown_fields = true }) catch return error.DockerApi;
    return parsed.Id;
}

/// `POST {prefix}/containers/{id}/start`.
pub fn containerStart(alloc: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}/start", .{ api_prefix, id });
    _ = try apiCall(alloc, c, .{ .method = "POST", .path = path }, err);
}

/// `DELETE {prefix}/containers/{id}?force=true`.
pub fn containerRemove(alloc: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}?force=true", .{ api_prefix, id });
    _ = try apiCall(alloc, c, .{ .method = "DELETE", .path = path }, err);
}

/// `POST {prefix}/containers/{id}/wait`: returns the container's exit code,
/// parsed from `{"StatusCode":...}`.
pub fn containerWait(alloc: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) !i32 {
    const path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}/wait", .{ api_prefix, id });
    const resp = try apiCall(alloc, c, .{ .method = "POST", .path = path }, err);
    const parsed = std.json.parseFromSliceLeaky(struct { StatusCode: i32 }, alloc, resp.body, .{ .ignore_unknown_fields = true }) catch return error.DockerApi;
    return parsed.StatusCode;
}

/// `POST {prefix}/networks/create`: returns the new network's id.
pub fn networkCreate(alloc: std.mem.Allocator, c: Client, name: []const u8, err: *?[]const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/networks/create", .{api_prefix});
    const body = try std.fmt.allocPrint(alloc, "{{\"Name\":\"{s}\"}}", .{name});
    const resp = try apiCall(alloc, c, .{
        .method = "POST",
        .path = path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = body,
    }, err);
    const parsed = std.json.parseFromSliceLeaky(struct { Id: []const u8 }, alloc, resp.body, .{ .ignore_unknown_fields = true }) catch return error.DockerApi;
    return parsed.Id;
}

/// `DELETE {prefix}/networks/{id}`.
pub fn networkRemove(alloc: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/networks/{s}", .{ api_prefix, id });
    _ = try apiCall(alloc, c, .{ .method = "DELETE", .path = path }, err);
}

/// `PUT {prefix}/containers/{id}/archive?path=<url-encoded>`: uploads a tar
/// stream (see `tarSingleFile`) to be extracted at `path_in_container`.
pub fn putArchive(alloc: std.mem.Allocator, c: Client, id: []const u8, path_in_container: []const u8, tar_bytes: []const u8, err: *?[]const u8) !void {
    const encoded_path = try urlEncode(alloc, path_in_container);
    const path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}/archive?path={s}", .{ api_prefix, id, encoded_path });
    _ = try apiCall(alloc, c, .{
        .method = "PUT",
        .path = path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/x-tar" }},
        .body = tar_bytes,
    }, err);
}

/// Builds a minimal ustar archive containing a single file: a 512-byte
/// header (name, octal mode/uid/gid/size/mtime, checksum, typeflag '0' for
/// regular file, ustar magic), the content padded to a 512-byte boundary,
/// and two trailing 512-byte zero blocks (end-of-archive marker).
pub fn tarSingleFile(alloc: std.mem.Allocator, name: []const u8, contents: []const u8, mode: u32) ![]u8 {
    const n_blocks = (contents.len + 511) / 512;
    const total = 512 + n_blocks * 512 + 1024;
    const buf = try alloc.alloc(u8, total);
    @memset(buf, 0);
    const hdr = buf[0..512];
    @memcpy(hdr[0..name.len], name);
    _ = std.fmt.bufPrint(hdr[100..108], "{o:0>7}", .{mode}) catch unreachable;
    _ = std.fmt.bufPrint(hdr[108..116], "{o:0>7}", .{0}) catch unreachable; // uid
    _ = std.fmt.bufPrint(hdr[116..124], "{o:0>7}", .{0}) catch unreachable; // gid
    _ = std.fmt.bufPrint(hdr[124..136], "{o:0>11}", .{contents.len}) catch unreachable;
    _ = std.fmt.bufPrint(hdr[136..148], "{o:0>11}", .{0}) catch unreachable; // mtime
    @memset(hdr[148..156], ' '); // checksum placeholder
    hdr[156] = '0'; // typeflag: regular file
    @memcpy(hdr[257..263], "ustar\x00");
    @memcpy(hdr[263..265], "00");
    var sum: usize = 0;
    for (hdr) |b| sum += b;
    _ = std.fmt.bufPrint(hdr[148..155], "{o:0>6}\x00", .{sum}) catch unreachable;
    @memcpy(buf[512 .. 512 + contents.len], contents);
    return buf;
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

test "tarSingleFile produces valid ustar header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try tarSingleFile(a, "script.sh", "echo hi\n", 0o755);
    try std.testing.expectEqual(@as(usize, 512 * 4), tar.len); // header + 1 content block + 2 zero blocks
    try std.testing.expectEqualStrings("script.sh", std.mem.sliceTo(tar[0..100], 0));
    // size field (octal, offset 124, 12 bytes)
    try std.testing.expectEqualStrings("00000000010", std.mem.sliceTo(tar[124..136], 0)[0..11]);
    // checksum validates: recompute with checksum field as spaces
    var sum: usize = 0;
    for (tar[0..512], 0..) |b, i| sum += if (i >= 148 and i < 156) @as(usize, ' ') else b;
    const stored = try std.fmt.parseInt(usize, std.mem.trim(u8, std.mem.sliceTo(tar[148..156], 0), " "), 8);
    try std.testing.expectEqual(sum, stored);
}

test "docker end-to-end: pull tiny image, create, start, wait, remove (skips without daemon)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Client{ .socket_path = detectSocket(a, .{}).? };
    if (!ping(a, c)) return error.SkipZigTest;
    var err: ?[]const u8 = null;
    if (!try imageExists(a, c, "busybox:latest", &err)) try imagePull(a, c, "busybox:latest", null, &err);
    const id = try containerCreate(a, c,
        \\{"Image":"busybox:latest","Cmd":["true"]}
    , null, &err);
    defer containerRemove(a, c, id, &err) catch {};
    try containerStart(a, c, id, &err);
    const code = try containerWait(a, c, id, &err);
    try std.testing.expectEqual(@as(i32, 0), code);
}
