//! Safe workspace-relative path handling for persisted snapshot/cache data.
//!
//! Store JSON is treated as untrusted. Paths must be portable normalized
//! relative paths, and every parent directory is opened with `no_follow` so
//! a poisoned symlink/junction cannot redirect replay outside the workspace.
const std = @import("std");

pub fn isSafeRelative(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return false;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub const Parent = struct {
    dir: std.fs.Dir,
    basename: []const u8,

    pub fn close(self: *Parent) void {
        self.dir.close();
    }
};

/// Open the parent of `rel` beneath `workspace_abs`. Existing intermediate
/// symlinks/junctions are rejected. Missing directories are optionally made
/// one component at a time without ever following an intermediate link.
pub fn openParent(workspace_abs: []const u8, rel: []const u8, create: bool) !Parent {
    if (!isSafeRelative(rel)) return error.UnsafePath;
    var current = try std.fs.openDirAbsolute(workspace_abs, .{});
    errdefer current.close();

    var parts = std.mem.splitScalar(u8, rel, '/');
    var component = parts.next().?;
    while (parts.next()) |next_component| {
        const next = current.openDir(component, .{ .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => if (create) blk: {
                try current.makeDir(component);
                break :blk try current.openDir(component, .{ .no_follow = true });
            } else return error.FileNotFound,
            else => return err,
        };
        current.close();
        current = next;
        component = next_component;
    }
    return .{ .dir = current, .basename = component };
}

pub fn deleteFile(workspace_abs: []const u8, rel: []const u8) !void {
    var parent = try openParent(workspace_abs, rel, false);
    defer parent.close();
    try parent.dir.deleteFile(parent.basename);
}

pub fn deleteTree(workspace_abs: []const u8, rel: []const u8) !void {
    var parent = try openParent(workspace_abs, rel, false);
    defer parent.close();
    try parent.dir.deleteTree(parent.basename);
}

test "safe relative paths reject traversal roots and foreign separators" {
    try std.testing.expect(isSafeRelative("dist/bin/app"));
    try std.testing.expect(isSafeRelative("one.txt"));
    try std.testing.expect(!isSafeRelative("../outside"));
    try std.testing.expect(!isSafeRelative("a/../outside"));
    try std.testing.expect(!isSafeRelative("a//b"));
    try std.testing.expect(!isSafeRelative("/absolute"));
    try std.testing.expect(!isSafeRelative("C:/absolute"));
    try std.testing.expect(!isSafeRelative("a\\b"));
}
