//! HTTP/1.1 codec for talking to the Docker Engine API over a raw socket/pipe.
//! Pure byte-level request writer + response parser — no transport here.
//!
//! Zig 0.15.2 note: `std.io.fixedBufferStream` and `Reader.readByte` are gone.
//! Readers are `std.Io.Reader` (byte-at-a-time via `takeByte`), constructed in
//! tests with `std.Io.Reader.fixed(bytes)`. `parseResponse` takes `reader:
//! anytype` so it accepts `*std.Io.Reader` from any source (fixed buffer here,
//! a File-backed reader in Task 4) without pinning the concrete type.
const std = @import("std");

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub fn writeRequest(alloc: std.mem.Allocator, req: Request) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, req.method);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, req.path);
    try out.appendSlice(alloc, " HTTP/1.1\r\nHost: docker\r\n");
    for (req.headers) |h| {
        try out.appendSlice(alloc, h.name);
        try out.appendSlice(alloc, ": ");
        try out.appendSlice(alloc, h.value);
        try out.appendSlice(alloc, "\r\n");
    }
    if (req.body.len > 0) {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n", .{req.body.len}));
    }
    try out.appendSlice(alloc, "\r\n");
    try out.appendSlice(alloc, req.body);
    return out.toOwnedSlice(alloc);
}

pub const Response = struct {
    status: u16,
    headers: []Header,
    body: []u8,

    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

/// Reads one CRLF- (or bare LF-) terminated line, stripping the terminator.
fn readLine(alloc: std.mem.Allocator, reader: anytype) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        const b = try reader.takeByte();
        if (b == '\n') break;
        if (b != '\r') try line.append(alloc, b);
    }
    return line.toOwnedSlice(alloc);
}

pub fn parseResponse(alloc: std.mem.Allocator, reader: anytype) !Response {
    const status_line = try readLine(alloc, reader);
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ") or status_line.len < 12) return error.BadResponse;
    const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.BadResponse;

    var headers: std.ArrayList(Header) = .empty;
    var content_length: ?usize = null;
    var chunked = false;
    while (true) {
        const line = try readLine(alloc, reader);
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        try headers.append(alloc, .{ .name = name, .value = value });
        if (std.ascii.eqlIgnoreCase(name, "content-length"))
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and
            std.ascii.indexOfIgnoreCase(value, "chunked") != null) chunked = true;
    }

    var body: std.ArrayList(u8) = .empty;
    if (chunked) {
        while (true) {
            const size_line = try readLine(alloc, reader);
            const size = std.fmt.parseInt(usize, size_line, 16) catch return error.BadResponse;
            if (size == 0) {
                _ = try readLine(alloc, reader); // trailing CRLF (possibly trailers — none expected)
                break;
            }
            var i: usize = 0;
            while (i < size) : (i += 1) try body.append(alloc, try reader.takeByte());
            _ = try readLine(alloc, reader); // chunk CRLF
        }
    } else if (content_length) |n| {
        var i: usize = 0;
        while (i < n) : (i += 1) try body.append(alloc, try reader.takeByte());
    } else {
        while (true) {
            const b = reader.takeByte() catch break;
            try body.append(alloc, b);
        }
    }
    return .{ .status = status, .headers = try headers.toOwnedSlice(alloc), .body = try body.toOwnedSlice(alloc) };
}

test "writeRequest serializes POST with body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try writeRequest(a, .{
        .method = "POST",
        .path = "/v1.43/containers/create?name=x",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"Image\":\"alpine\"}",
    });
    try std.testing.expect(std.mem.startsWith(u8, out, "POST /v1.43/containers/create?name=x HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Host: docker\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 18\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n{\"Image\":\"alpine\"}"));
}

test "parseResponse handles content-length body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\nhello world";
    var reader = std.Io.Reader.fixed(raw);
    const resp = try parseResponse(a, &reader);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("hello world", resp.body);
    try std.testing.expectEqualStrings("application/json", resp.header("content-type").?);
}

test "parseResponse dechunks transfer-encoding chunked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
    var reader = std.Io.Reader.fixed(raw);
    const resp = try parseResponse(a, &reader);
    try std.testing.expectEqualStrings("hello world", resp.body);
}
