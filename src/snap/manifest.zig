//! Step-boundary workspace manifests: walk the workspace, hash every file
//! into the blob store, and record the result as JSON under
//! `<root>/snapshots/<run_id>/<job>/<NNN>-<step_id>.json`.
//!
//! `.git/` and `.jalan/` are always excluded from the walk (VCS metadata is
//! not pipeline state, and the store itself must not capture itself).
//! Symlinks are recorded as `{path, link_target}` entries with no blob.
const std = @import("std");
const ir = @import("../ir.zig");
const expr = @import("../expr.zig");
const store = @import("store.zig");

pub const Error = error{ OutOfMemory, StoreIo };

pub const FileEntry = struct {
    path: []const u8,
    blob: []const u8 = "",
    size: u64 = 0,
    mode: u32 = 0o644,
    link_target: ?[]const u8 = null,
};

pub const Manifest = struct {
    run_id: []const u8,
    job_id: []const u8,
    step_index: u32,
    step_id: []const u8,
    created_unix: i64,
    tree_hash: []const u8,
    env: []const ir.EnvPair = &.{},
    files: []FileEntry = &.{},
};

/// True when a workspace-relative path (forward slashes) is inside an
/// excluded top-level directory.
fn excluded(path: []const u8) bool {
    return std.mem.eql(u8, path, ".git") or std.mem.startsWith(u8, path, ".git/") or
        std.mem.eql(u8, path, ".jalan") or std.mem.startsWith(u8, path, ".jalan/");
}

fn sortEntries(files: []FileEntry) void {
    std.mem.sort(FileEntry, files, {}, struct {
        fn lt(_: void, a: FileEntry, b: FileEntry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
}

/// sha256 over the canonical concatenation `path\0blob\0mode\n` of sorted
/// file entries. Symlink entries contribute `path\0->target\n`. Pure.
pub fn treeHash(alloc: std.mem.Allocator, files: []FileEntry) ![]u8 {
    const sorted = try alloc.dupe(FileEntry, files);
    sortEntries(sorted);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (sorted) |f| {
        h.update(f.path);
        h.update(&.{0});
        if (f.link_target) |t| {
            h.update("->");
            h.update(t);
        } else {
            h.update(f.blob);
            var mode_buf: [16]u8 = undefined;
            const mode_str = std.fmt.bufPrint(&mode_buf, "{o}", .{f.mode}) catch "0";
            h.update(mode_str);
        }
        h.update(&.{'\n'});
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

/// Walk `workspace_abs` and produce sorted file entries. When
/// `write_blobs` is true each file's contents are copied into the store;
/// otherwise files are only hashed (the cache pre-scan doesn't want to
/// dirty the store on a lookup miss).
pub fn scanTree(alloc: std.mem.Allocator, root: []const u8, workspace_abs: []const u8, write_blobs: bool) Error![]FileEntry {
    var out: std.ArrayList(FileEntry) = .empty;
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
            .file => {
                const abs = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ workspace_abs, norm });
                var blob: []const u8 = "";
                var size: u64 = 0;
                if (write_blobs) {
                    const c = try store.copyFileToBlob(alloc, root, abs);
                    blob = c.hex;
                    size = c.size;
                } else {
                    blob = try store.sha256FileHex(alloc, abs);
                    const st = dir.statFile(e.path) catch return error.StoreIo;
                    size = st.size;
                }
                const st = dir.statFile(e.path) catch return error.StoreIo;
                try out.append(alloc, .{ .path = norm, .blob = blob, .size = size, .mode = @intCast(st.mode & 0o777) });
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = dir.readLink(e.path, &buf) catch continue;
                try out.append(alloc, .{ .path = norm, .link_target = try alloc.dupe(u8, target) });
            },
            else => {},
        }
    }
    sortEntries(out.items);
    return out.toOwnedSlice(alloc);
}

/// Replaces path-unsafe characters so a step id is safe inside a file name.
fn sanitize(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    const out = try alloc.dupe(u8, id);
    for (out) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '-' and c.* != '_') c.* = '-';
    }
    return out;
}

/// Manifest path relative to the store root:
/// `snapshots/<run_id>/<job>/<NNN>-<step_id>.json`.
pub fn relPath(alloc: std.mem.Allocator, run_id: []const u8, job_id: []const u8, step_index: u32, step_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "snapshots/{s}/{s}/{d:0>3}-{s}.json", .{
        run_id, try sanitize(alloc, job_id), step_index, try sanitize(alloc, step_id),
    });
}

/// Capture the workspace at a step boundary and write the manifest JSON.
/// Returns the manifest (its `relPath` goes into the run record / cache).
pub const CaptureResult = struct { m: Manifest, rel_path: []const u8 };

pub fn capture(
    alloc: std.mem.Allocator,
    root: []const u8,
    workspace_abs: []const u8,
    run_id: []const u8,
    job_id: []const u8,
    step_index: u32,
    step_id: []const u8,
    env_pairs: []const ir.EnvPair,
) Error!CaptureResult {
    const files = try scanTree(alloc, root, workspace_abs, true);
    const th = try treeHash(alloc, files);
    const rel = try relPath(alloc, run_id, job_id, step_index, step_id);
    const m = Manifest{
        .run_id = run_id,
        .job_id = job_id,
        .step_index = step_index,
        .step_id = step_id,
        .created_unix = std.time.timestamp(),
        .tree_hash = th,
        .env = env_pairs,
        .files = files,
    };
    const json = try toJson(alloc, m);
    const abs = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, rel });
    if (std.fs.path.dirname(abs)) |d| std.fs.cwd().makePath(d) catch return error.StoreIo;
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp{x}", .{ abs, std.crypto.random.int(u32) });
    std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = json }) catch return error.StoreIo;
    std.fs.cwd().rename(tmp, abs) catch {
        std.fs.cwd().deleteFile(abs) catch {};
        std.fs.cwd().rename(tmp, abs) catch return error.StoreIo;
    };
    return .{ .m = m, .rel_path = rel };
}

fn jsonStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (c < 0x20) {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c}));
        } else try out.append(alloc, c),
    };
    try out.append(alloc, '"');
}

pub fn toJson(alloc: std.mem.Allocator, m: Manifest) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "{\"run_id\":");
    try jsonStr(&out, alloc, m.run_id);
    try out.appendSlice(alloc, ",\"job_id\":");
    try jsonStr(&out, alloc, m.job_id);
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"step_index\":{d},\"step_id\":", .{m.step_index}));
    try jsonStr(&out, alloc, m.step_id);
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"created_unix\":{d},\"tree_hash\":", .{m.created_unix}));
    try jsonStr(&out, alloc, m.tree_hash);
    try out.appendSlice(alloc, ",\"env\":[");
    for (m.env, 0..) |p, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"name\":");
        try jsonStr(&out, alloc, p.name);
        try out.appendSlice(alloc, ",\"value\":");
        try jsonStr(&out, alloc, p.value);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "],\"files\":[");
    for (m.files, 0..) |f, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"path\":");
        try jsonStr(&out, alloc, f.path);
        try out.appendSlice(alloc, ",\"blob\":");
        try jsonStr(&out, alloc, f.blob);
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"size\":{d},\"mode\":{d}", .{ f.size, f.mode }));
        if (f.link_target) |t| {
            try out.appendSlice(alloc, ",\"link_target\":");
            try jsonStr(&out, alloc, t);
        }
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

/// Parse manifest JSON. Slices borrow from the arena-backed parse result.
pub fn parse(alloc: std.mem.Allocator, text: []const u8) Error!Manifest {
    const parsed = std.json.parseFromSlice(Manifest, alloc, text, .{ .ignore_unknown_fields = true }) catch return error.StoreIo;
    return parsed.value;
}

/// Load a manifest from a store-root-relative path.
pub fn load(alloc: std.mem.Allocator, root: []const u8, rel: []const u8) Error!Manifest {
    const abs = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, rel });
    const text = std.fs.cwd().readFileAlloc(alloc, abs, 64 * 1024 * 1024) catch return error.StoreIo;
    return parse(alloc, text);
}

test "treeHash is order-independent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f1 = [_]FileEntry{
        .{ .path = "a.txt", .blob = "aa" },
        .{ .path = "b/c.txt", .blob = "bb" },
    };
    var f2 = [_]FileEntry{
        .{ .path = "b/c.txt", .blob = "bb" },
        .{ .path = "a.txt", .blob = "aa" },
    };
    try std.testing.expectEqualStrings(try treeHash(a, &f1), try treeHash(a, &f2));
    var f3 = [_]FileEntry{
        .{ .path = "a.txt", .blob = "CHANGED" },
        .{ .path = "b/c.txt", .blob = "bb" },
    };
    try std.testing.expect(!std.mem.eql(u8, try treeHash(a, &f1), try treeHash(a, &f3)));
}

test "capture writes manifest, excludes .git and .jalan, json round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/captest";
    std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(try std.fmt.allocPrint(a, "{s}/src", .{ws}));
    try std.fs.cwd().makePath(try std.fmt.allocPrint(a, "{s}/.git/objects", .{ws}));
    try std.fs.cwd().makePath(try std.fmt.allocPrint(a, "{s}/.jalan/tmp", .{ws}));
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/src/main.zig", .{ws}), .data = "pub fn main() void {}" });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/README", .{ws}), .data = "hi" });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/.git/objects/xx", .{ws}), .data = "vcs" });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/.jalan/tmp/y", .{ws}), .data = "self" });
    const root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);

    const env_pairs = [_]ir.EnvPair{.{ .name = "github.ref", .value = "refs/heads/main" }};
    const cap = try capture(a, root, ws_abs, "run-1", "build", 2, "compile", &env_pairs);
    try std.testing.expectEqualStrings("snapshots/run-1/build/002-compile.json", cap.rel_path);
    try std.testing.expectEqual(@as(usize, 2), cap.m.files.len);
    try std.testing.expectEqualStrings("README", cap.m.files[0].path);
    try std.testing.expectEqualStrings("src/main.zig", cap.m.files[1].path);

    const loaded = try load(a, root, cap.rel_path);
    try std.testing.expectEqualStrings("run-1", loaded.run_id);
    try std.testing.expectEqualStrings("compile", loaded.step_id);
    try std.testing.expectEqual(@as(u32, 2), loaded.step_index);
    try std.testing.expectEqualStrings(cap.m.tree_hash, loaded.tree_hash);
    try std.testing.expectEqual(@as(usize, 1), loaded.env.len);
    try std.testing.expectEqualStrings("refs/heads/main", loaded.env[0].value);
    try std.testing.expectEqual(@as(usize, 2), loaded.files.len);
    try std.testing.expectEqualStrings("src/main.zig", loaded.files[1].path);
    std.fs.cwd().deleteTree(base) catch {};
}

test "env pairs round-trip through expr helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = expr.Env{};
    try env.put(a, "GitHub.Ref", "refs/heads/main");
    try env.put(a, "env.BUILD", "42");
    const pairs = try expr.envToPairs(a, &env);
    try std.testing.expectEqual(@as(usize, 2), pairs.len);
    try std.testing.expect(std.mem.lessThan(u8, pairs[0].name, pairs[1].name));
    var env2 = try expr.envFromPairs(a, pairs);
    try std.testing.expectEqualStrings("refs/heads/main", (try env2.lookup(a, "github.ref")).?);
    try std.testing.expectEqualStrings("42", (try env2.lookup(a, "env.build")).?);
}
