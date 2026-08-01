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
const safe_path = @import("path.zig");

pub const Error = error{ OutOfMemory, StoreIo, RestoreFailed };

fn excluded(path: []const u8) bool {
    return std.mem.eql(u8, path, ".git") or std.mem.startsWith(u8, path, ".git/") or
        std.mem.eql(u8, path, ".jalan") or std.mem.startsWith(u8, path, ".jalan/");
}

fn hashFile(alloc: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ![]u8 {
    const f = try dir.openFile(name, .{});
    defer f.close();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

fn copySymlinkTarget(alloc: std.mem.Allocator, workspace_abs: []const u8, path: []const u8, target: []const u8) !void {
    const link_dir = std.fs.path.dirname(path) orelse "";
    const target_abs = try std.fs.path.resolve(alloc, &.{ workspace_abs, link_dir, target });
    const target_real = try std.fs.cwd().realpathAlloc(alloc, target_abs);
    const rel = try std.fs.path.relative(alloc, workspace_abs, target_real);
    if (!safe_path.isSafeRelative(rel)) return error.UnsafePath;

    const src = try std.fs.openFileAbsolute(target_real, .{});
    defer src.close();
    var parent = try safe_path.openParent(workspace_abs, path, true);
    defer parent.close();
    var dst = try parent.dir.createFile(parent.basename, .{});
    defer dst.close();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
    }
}

fn restoreLink(alloc: std.mem.Allocator, workspace_abs: []const u8, path: []const u8, target: []const u8, log: ?backend.LogFn, force_fallback: bool) !bool {
    var parent = try safe_path.openParent(workspace_abs, path, true);
    parent.dir.deleteFile(parent.basename) catch {};
    parent.dir.deleteTree(parent.basename) catch {};
    if (!force_fallback) {
        if (parent.dir.symLink(target, parent.basename, .{})) |_| {
            parent.close();
            return true;
        } else |_| {}
    }
    parent.close();
    copySymlinkTarget(alloc, workspace_abs, path, target) catch {
        if (log) |l| l(try std.fmt.allocPrint(alloc, "restore: cannot recreate symlink {s} or copy its target", .{path}));
        return error.UnsafePath;
    };
    if (log) |l| l(try std.fmt.allocPrint(alloc, "restore: symlink {s} restored as target content", .{path}));
    return false;
}

pub fn restoreSymlink(alloc: std.mem.Allocator, workspace_abs: []const u8, path: []const u8, target: []const u8, log: ?backend.LogFn) Error!void {
    _ = restoreLink(alloc, workspace_abs, path, target, log, false) catch return error.RestoreFailed;
}

pub fn restore(
    alloc: std.mem.Allocator,
    root: []const u8,
    workspace_abs: []const u8,
    m: manifest_mod.Manifest,
    log: ?backend.LogFn,
) Error!void {
    var wanted: std.StringHashMapUnmanaged(manifest_mod.FileEntry) = .empty;
    for (m.files) |f| {
        if (!safe_path.isSafeRelative(f.path)) return error.RestoreFailed;
        if (f.mode > 0o777 or (f.is_dir and f.link_target != null)) return error.RestoreFailed;
        if (!f.is_dir and f.link_target == null and !store.isValidHex(f.blob)) return error.RestoreFailed;
        try wanted.put(alloc, f.path, f);
    }
    if (!store.isValidHex(m.tree_hash)) return error.RestoreFailed;
    const declared_hash = manifest_mod.treeHash(alloc, m.files) catch return error.RestoreFailed;
    if (!std.mem.eql(u8, declared_hash, m.tree_hash)) return error.RestoreFailed;

    // Prove every required regular-file blob exists and matches its digest
    // before deleting or overwriting anything in the workspace.
    for (m.files) |f| {
        if (!f.is_dir and f.link_target == null)
            store.verifyBlob(alloc, root, f.blob) catch return error.RestoreFailed;
    }

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
                .directory => if (!wanted.contains(norm)) try dirs.append(alloc, norm),
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

    // Pass 2: materialize recorded directories before their children.
    for (m.files) |f| {
        if (!f.is_dir) continue;
        var parent = safe_path.openParent(workspace_abs, f.path, true) catch return error.RestoreFailed;
        defer parent.close();
        parent.dir.makeDir(parent.basename) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                parent.dir.deleteFile(parent.basename) catch {};
                parent.dir.makeDir(parent.basename) catch return error.RestoreFailed;
            },
        };
        if (builtin.os.tag != .windows) {
            if (parent.dir.openDir(parent.basename, .{})) |opened| {
                var restored = opened;
                defer restored.close();
                restored.chmod(@intCast(f.mode)) catch {};
            } else |_| {}
        }
    }

    // Pass 3: write back changed/missing regular files first. This ensures a
    // symlink fallback can copy the restored target's contents afterward.
    for (m.files) |f| {
        if (f.is_dir or f.link_target != null) continue;
        var parent = safe_path.openParent(workspace_abs, f.path, true) catch return error.RestoreFailed;
        defer parent.close();
        var need_write = true;
        if (parent.dir.access(parent.basename, .{})) |_| {
            const cur = hashFile(alloc, parent.dir, parent.basename) catch "";
            need_write = !std.mem.eql(u8, cur, f.blob);
        } else |_| {}
        if (need_write)
            store.copyBlobToFile(alloc, root, f.blob, parent.dir, parent.basename) catch return error.RestoreFailed;
        if (builtin.os.tag != .windows) {
            // File.chmod uses Zig's platform layer directly; std.c.chmod
            // would make otherwise-standalone cross builds require libc.
            if (parent.dir.openFile(parent.basename, .{ .mode = .read_write })) |restored| {
                defer restored.close();
                restored.chmod(@intCast(f.mode)) catch {};
            } else |_| {}
        }
    }

    // Pass 4: links after regular files so fallback copies see their target.
    var exact_links = true;
    for (m.files) |f| {
        if (f.link_target) |target| {
            const exact = restoreLink(alloc, workspace_abs, f.path, target, log, false) catch return error.RestoreFailed;
            exact_links = exact_links and exact;
        }
    }
    if (exact_links) {
        const restored = manifest_mod.scanTree(alloc, root, workspace_abs, false) catch return error.RestoreFailed;
        const restored_hash = manifest_mod.treeHash(alloc, restored) catch return error.RestoreFailed;
        if (!std.mem.eql(u8, restored_hash, m.tree_hash)) return error.RestoreFailed;
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

test "symlink fallback copies target content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/restore-link-fallback";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    try std.fs.cwd().makePath(base);
    try std.fs.cwd().writeFile(.{ .sub_path = base ++ "/target.txt", .data = "target bytes" });
    const ws_abs = try std.fs.cwd().realpathAlloc(a, base);
    try std.testing.expect(!(try restoreLink(a, ws_abs, "copy.txt", "target.txt", null, true)));
    try std.testing.expectEqualStrings("target bytes", try std.fs.cwd().readFileAlloc(a, base ++ "/copy.txt", 1024));
}

test "restore rejects persisted path traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/restore-traversal";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    try std.fs.cwd().makePath(base);
    const ws_abs = try std.fs.cwd().realpathAlloc(a, base);
    var files = [_]manifest_mod.FileEntry{.{ .path = "../outside.txt", .blob = "0000000000000000000000000000000000000000000000000000000000000000" }};
    const m = manifest_mod.Manifest{ .run_id = "r", .job_id = "j", .step_index = 0, .step_id = "s", .created_unix = 0, .tree_hash = "x", .files = &files };
    try std.testing.expectError(error.RestoreFailed, restore(a, ".jalan/store", ws_abs, m, null));
}
