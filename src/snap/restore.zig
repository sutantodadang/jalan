//! Restore a workspace from a step-boundary manifest.
//!
//! Restore = delete workspace files absent from the manifest (never
//! touching `.git/` or `.jalan/`), then copy back every manifest file whose
//! current contents differ from its recorded blob. A missing blob is
//! `error.RestoreFailed` — the engine maps that to exit 3 on resume, since
//! a half-restored workspace is worse than no restore.
const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const manifest_mod = @import("manifest.zig");
const store = @import("store.zig");

pub const Error = error{ OutOfMemory, StoreIo, RestoreFailed };

fn excluded(path: []const u8) bool {
    return std.mem.eql(u8, path, ".git") or std.mem.startsWith(u8, path, ".git/") or
        std.mem.eql(u8, path, ".jalan") or std.mem.startsWith(u8, path, ".jalan/");
}

pub fn restore(
    alloc: std.mem.Allocator,
    root: []const u8,
    workspace_abs: []const u8,
    m: manifest_mod.Manifest,
    log: ?backend.LogFn,
) Error!void {
    var wanted: std.StringHashMapUnmanaged(manifest_mod.FileEntry) = .empty;
    for (m.files) |f| try wanted.put(alloc, f.path, f);

    // Pass 1: delete files the manifest doesn't know about.
    var dirs: std.ArrayList([]const u8) = .empty;
    {
        var dir = std.fs.openDirAbsolute(workspace_abs, .{ .iterate = true }) catch return error.StoreIo;
        defer dir.close();
        var walker = dir.walk(alloc) catch return error.StoreIo;
        defer walker.deinit();
        while (walker.next() catch return error.StoreIo) |e| {
            const norm = try alloc.dupe(u8, e.path);
            for (norm) |*c| {
                if (c.* == std.fs.path.sep) c.* = '/';
            }
            if (excluded(norm)) continue;
            switch (e.kind) {
                .file, .sym_link => {
                    if (!wanted.contains(norm)) dir.deleteFile(e.path) catch return error.StoreIo;
                },
                .directory => try dirs.append(alloc, norm),
                else => {},
            }
        }
        // Remove directories left empty by deletions, deepest first.
        // Non-empty ones (extra untracked dirs) stay, with one warning.
        std.mem.sort([]const u8, dirs.items, {}, struct {
            fn gt(_: void, a: []const u8, b: []const u8) bool {
                return a.len > b.len;
            }
        }.gt);
        var kept_nonempty = false;
        for (dirs.items) |d| {
            dir.deleteDir(d) catch |err| switch (err) {
                error.DirNotEmpty => kept_nonempty = true,
                else => {},
            };
        }
        if (kept_nonempty) {
            if (log) |l| l("restore: extra non-empty directories left in place");
        }
    }

    // Pass 2: write back changed/missing files.
    for (m.files) |f| {
        const abs = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ workspace_abs, f.path });
        if (f.link_target) |t| {
            // Symlink entry: recreate where permitted; otherwise warn.
            std.fs.cwd().deleteFile(abs) catch {};
            std.fs.cwd().symLink(t, abs, .{}) catch {
                if (log) |l| l(try std.fmt.allocPrint(alloc, "restore: cannot recreate symlink {s} — skipped", .{f.path}));
            };
            continue;
        }
        var need_write = true;
        if (std.fs.cwd().access(abs, .{})) |_| {
            const cur = store.sha256FileHex(alloc, abs) catch "";
            need_write = !std.mem.eql(u8, cur, f.blob);
        } else |_| {}
        if (!need_write) continue;
        const data = store.readBlob(alloc, root, f.blob) catch return error.RestoreFailed;
        if (std.fs.path.dirname(abs)) |d| std.fs.cwd().makePath(d) catch return error.StoreIo;
        std.fs.cwd().writeFile(.{ .sub_path = abs, .data = data }) catch return error.StoreIo;
        if (builtin.os.tag != .windows and f.mode & 0o111 != 0) {
            const abs_z = try alloc.dupeZ(u8, abs);
            _ = std.c.chmod(abs_z, @intCast(f.mode));
        }
    }
}

test "restore round-trips: mutate after capture, restore brings it back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/restoretest";
    std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(try std.fmt.allocPrint(a, "{s}/src", .{ws}));
    try std.fs.cwd().makePath(try std.fmt.allocPrint(a, "{s}/.git", .{ws}));
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/src/a.txt", .{ws}), .data = "alpha" });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/b.txt", .{ws}), .data = "bravo" });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/.git/HEAD", .{ws}), .data = "ref: main" });
    const root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);

    const cap = try manifest_mod.capture(a, root, ws_abs, "run-1", "j", 0, "s1", &.{});

    // Mutate: edit one file, delete another, add an extra, touch .git.
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/src/a.txt", .{ws}), .data = "EDITED" });
    std.fs.cwd().deleteFile(try std.fmt.allocPrint(a, "{s}/b.txt", .{ws})) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/extra.log", .{ws}), .data = "junk" });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/.git/HEAD", .{ws}), .data = "ref: other" });

    try restore(a, root, ws_abs, cap.m, null);

    try std.testing.expectEqualStrings("alpha", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/src/a.txt", .{ws}), 1 << 20));
    try std.testing.expectEqualStrings("bravo", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/b.txt", .{ws}), 1 << 20));
    std.fs.cwd().access(try std.fmt.allocPrint(a, "{s}/extra.log", .{ws}), .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
    // .git is never restored/deleted by us — the mutation stays.
    try std.testing.expectEqualStrings("ref: other", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/.git/HEAD", .{ws}), 1 << 20));
    // Tree now matches the manifest again.
    const now = try manifest_mod.scanTree(a, root, ws_abs, false);
    try std.testing.expectEqualStrings(cap.m.tree_hash, try manifest_mod.treeHash(a, now));
    std.fs.cwd().deleteTree(base) catch {};
}

test "restore fails with RestoreFailed when a blob is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/restoretest2";
    std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(ws);
    const root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);
    const files = [_]manifest_mod.FileEntry{.{ .path = "ghost.txt", .blob = "0000000000000000000000000000000000000000000000000000000000000000" }};
    const m = manifest_mod.Manifest{
        .run_id = "r",
        .job_id = "j",
        .step_index = 0,
        .step_id = "s",
        .created_unix = 0,
        .tree_hash = "x",
        .files = @constCast(&files),
    };
    try std.testing.expectError(error.RestoreFailed, restore(a, root, ws_abs, m, null));
    std.fs.cwd().deleteTree(base) catch {};
}
