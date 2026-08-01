const std = @import("std");

pub const ImagePair = struct { runs_on: []const u8, image: []const u8 };

pub const Config = struct {
    backend: []const u8 = "auto",
    docker_socket: ?[]const u8 = null,
    nix_packages: []const []const u8 = &.{},
    image_map: []ImagePair = &.{},
    snapshot: bool = true,
    cache: bool = false,

    pub fn imageFor(self: Config, runs_on: []const u8) ?[]const u8 {
        for (self.image_map) |p| {
            if (std.mem.eql(u8, p.runs_on, runs_on)) return p.image;
        }
        return null;
    }
};

pub fn parse(alloc: std.mem.Allocator, text: []const u8) !Config {
    var c = Config{};
    var images: std.ArrayList(ImagePair) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len == 0) continue;
        if (std.mem.eql(u8, key, "backend")) {
            c.backend = val;
        } else if (std.mem.eql(u8, key, "snapshot")) {
            c.snapshot = parseBool(val) orelse c.snapshot;
        } else if (std.mem.eql(u8, key, "cache")) {
            c.cache = parseBool(val) orelse c.cache;
        } else if (std.mem.eql(u8, key, "docker.socket")) {
            c.docker_socket = val;
        } else if (std.mem.eql(u8, key, "nix.packages")) {
            var pkgs: std.ArrayList([]const u8) = .empty;
            var pit = std.mem.splitScalar(u8, val, ',');
            while (pit.next()) |p| {
                const t = std.mem.trim(u8, p, " ");
                if (t.len > 0) try pkgs.append(alloc, t);
            }
            c.nix_packages = try pkgs.toOwnedSlice(alloc);
        } else if (std.mem.startsWith(u8, key, "image.")) {
            try images.append(alloc, .{ .runs_on = key["image.".len..], .image = val });
        }
    }
    c.image_map = try images.toOwnedSlice(alloc);
    return c;
}

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return null;
}

pub fn load(alloc: std.mem.Allocator) !Config {
    const text = std.fs.cwd().readFileAlloc(alloc, ".jalan/config", 1 << 20) catch return Config{};
    return parse(alloc, text);
}

test "parse config keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parse(a,
        \\# comment
        \\backend=docker
        \\docker.socket=/run/user/1000/podman/podman.sock
        \\nix.packages=nodejs_20,git
        \\image.ubuntu-latest=node:20-bookworm-slim
        \\image.ubuntu-22.04=ubuntu:22.04
        \\snapshot=false
        \\cache=true
    );
    try std.testing.expectEqualStrings("docker", c.backend);
    try std.testing.expectEqualStrings("/run/user/1000/podman/podman.sock", c.docker_socket.?);
    try std.testing.expectEqual(@as(usize, 2), c.nix_packages.len);
    try std.testing.expectEqualStrings("git", c.nix_packages[1]);
    try std.testing.expectEqualStrings("ubuntu:22.04", c.imageFor("ubuntu-22.04").?);
    try std.testing.expect(!c.snapshot);
    try std.testing.expect(c.cache);
    try std.testing.expect(c.imageFor("windows-latest") == null);
}

test "empty text yields defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), "");
    try std.testing.expectEqualStrings("auto", c.backend);
    try std.testing.expect(c.docker_socket == null);
    try std.testing.expect(c.snapshot);
    try std.testing.expect(!c.cache);
}

test "invalid booleans leave phase 3 defaults unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), "snapshot=maybe\ncache=yes\n");
    try std.testing.expect(c.snapshot);
    try std.testing.expect(!c.cache);
}

test "empty value leaves field unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), "docker.socket=\n");
    try std.testing.expect(c.docker_socket == null);
}

test "whitespace around key and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), "backend = docker");
    try std.testing.expectEqualStrings("docker", c.backend);
}

test "load defaults when file missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Attempt to delete the file to ensure it doesn't exist.
    std.fs.cwd().deleteFile(".jalan/config") catch {};
    const c = try load(arena.allocator());
    try std.testing.expectEqualStrings("auto", c.backend);
    try std.testing.expect(c.docker_socket == null);
}
