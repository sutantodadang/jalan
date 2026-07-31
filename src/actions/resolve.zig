//! Action ref resolution + fetch/cache for GitHub Actions `uses:` steps.
//!
//! `parseRef` turns a `uses:` string into a `Ref` (github/local/docker_image).
//! `fetch` resolves a github `Ref` to a local directory: a per-`owner/repo/ref`
//! cache under `cacheRoot()`, downloaded on first use from
//! `codeload.github.com` as a tarball, gunzipped and untarred in place. The
//! runner (not this file) is responsible for reading `action.yml` out of the
//! returned directory.
//!
//! Zig 0.15.2 notes:
//! - `std.http.Client` request flow: `client.request(...)` ->
//!   `req.sendBodiless()` -> `req.receiveHead(redirect_buffer)` ->
//!   `response.reader(transfer_buffer)`. `response.reader` returns the body
//!   *without* undoing `Content-Encoding` (unlike `readerDecompressing`),
//!   which is what we want here since the body itself is a gzip tarball, not
//!   a negotiated-compressed plain body.
//! - Bounded read into memory: `std.Io.Reader.allocRemaining(gpa, limit)`
//!   with `std.Io.Limit.limited(n)`; returns `error.StreamTooLong` past the
//!   cap.
//! - Gunzip: `std.compress.flate.Decompress.init(input_reader, .gzip,
//!   window_buffer)` (`window_buffer.len` must be >=
//!   `std.compress.flate.max_window_len`); `.reader` field is the decompressed
//!   `*std.Io.Reader`.
//! - Untar: `std.tar.pipeToFileSystem(dir, reader, .{ .strip_components = 1
//!   })` strips the tarball's top-level `<repo>-<ref>/` directory.
const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");

pub const Ref = union(enum) {
    github: Github,
    local: []const u8,
    docker_image: []const u8,

    pub const Github = struct {
        owner: []const u8,
        repo: []const u8,
        subpath: []const u8,
        ref: []const u8,
    };
};

/// True if any `/`-separated segment of `s` is empty, `.`, or `..` — the
/// shapes that let a path component escape the directory it's joined into.
fn hasTraversalSegment(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

/// Parses a `uses:` value into a `Ref`.
///
/// - `./local/path` -> `.local`
/// - `docker://image:tag` -> `.docker_image`
/// - `owner/repo[/subpath]@ref` -> `.github`
///
/// `owner`, `repo`, `ref`, and `subpath` all end up as path segments under
/// `cacheRoot()` (see `fetch`), so this is also the traversal choke point:
/// missing `@ref`, empty/`.`/`..` owner or repo, an empty ref, or any
/// `.`/`..`/empty segment within `ref` or `subpath` (e.g. `a/b/../c@v1`,
/// `a/b@..`) is `error.BadRef`. Multi-segment branch refs like
/// `a/b@feature/foo` remain legal — only literal `.`/`..` segments are
/// rejected.
pub fn parseRef(uses: []const u8) !Ref {
    if (std.mem.startsWith(u8, uses, "./")) return .{ .local = uses };
    if (std.mem.startsWith(u8, uses, "docker://")) return .{ .docker_image = uses["docker://".len..] };
    const at = std.mem.lastIndexOfScalar(u8, uses, '@') orelse return error.BadRef;
    const path = uses[0..at];
    const ref = uses[at + 1 ..];
    var it = std.mem.splitScalar(u8, path, '/');
    const owner = it.next() orelse return error.BadRef;
    const repo = it.next() orelse return error.BadRef;
    if (owner.len == 0 or repo.len == 0 or ref.len == 0) return error.BadRef;
    if (std.mem.eql(u8, owner, ".") or std.mem.eql(u8, owner, "..")) return error.BadRef;
    if (std.mem.eql(u8, repo, ".") or std.mem.eql(u8, repo, "..")) return error.BadRef;
    const subpath = it.rest();
    if (hasTraversalSegment(ref)) return error.BadRef;
    if (subpath.len != 0 and hasTraversalSegment(subpath)) return error.BadRef;
    return .{ .github = .{ .owner = owner, .repo = repo, .subpath = subpath, .ref = ref } };
}

/// Root directory for cached actions: `%LOCALAPPDATA%\jalan\actions` on
/// Windows, `$HOME/.cache/jalan/actions` elsewhere.
pub fn cacheRoot(alloc: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const local_appdata = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
        return std.fs.path.join(alloc, &.{ local_appdata, "jalan", "actions" });
    }
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    return std.fs.path.join(alloc, &.{ home, ".cache", "jalan", "actions" });
}

/// Joins `dir` with `subpath` when `subpath` is non-empty; otherwise returns
/// `dir` unchanged.
fn withSubpath(alloc: std.mem.Allocator, dir: []const u8, subpath: []const u8) ![]const u8 {
    if (subpath.len == 0) return dir;
    return std.fs.path.join(alloc, &.{ dir, subpath });
}

fn dirExists(path: []const u8) bool {
    var d = std.fs.openDirAbsolute(path, .{}) catch return false;
    d.close();
    return true;
}

const max_download_bytes: usize = 100 * 1024 * 1024;

/// Resolves a github `Ref` to a local directory, downloading + caching on
/// first use (or whenever `force_pull` is set). `err_msg` is populated with a
/// human-readable message on any failure path (network, HTTP status,
/// decompression, or extraction).
pub fn fetch(alloc: std.mem.Allocator, gh: Ref.Github, force_pull: bool, log: ?backend.LogFn, err_msg: *?[]const u8) ![]const u8 {
    const root = try cacheRoot(alloc);
    const dir = try std.fs.path.join(alloc, &.{ root, gh.owner, gh.repo, gh.ref });

    if (!force_pull and dirExists(dir)) {
        return withSubpath(alloc, dir, gh.subpath);
    }

    if (log) |l| l(try std.fmt.allocPrint(alloc, "fetching {s}/{s}@{s}", .{ gh.owner, gh.repo, gh.ref }));

    const url = try std.fmt.allocPrint(alloc, "https://codeload.github.com/{s}/{s}/tar.gz/{s}", .{ gh.owner, gh.repo, gh.ref });
    const uri = std.Uri.parse(url) catch {
        err_msg.* = try std.fmt.allocPrint(alloc, "invalid action download URL: {s}", .{url});
        return error.FetchFailed;
    };

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var req = client.request(.GET, uri, .{}) catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "connecting to codeload.github.com failed: {s}", .{@errorName(e)});
        return e;
    };
    defer req.deinit();

    req.sendBodiless() catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "sending request to codeload.github.com failed: {s}", .{@errorName(e)});
        return e;
    };

    var redirect_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "receiving response from codeload.github.com failed: {s}", .{@errorName(e)});
        return e;
    };

    if (response.head.status != .ok) {
        err_msg.* = try std.fmt.allocPrint(alloc, "downloading {s}/{s}@{s} failed: HTTP {d}", .{ gh.owner, gh.repo, gh.ref, @intFromEnum(response.head.status) });
        return error.FetchFailed;
    }

    var transfer_buffer: [8192]u8 = undefined;
    const body_reader = response.reader(&transfer_buffer);

    const gz_bytes = body_reader.allocRemaining(alloc, std.Io.Limit.limited(max_download_bytes)) catch |e| switch (e) {
        error.StreamTooLong => {
            err_msg.* = try std.fmt.allocPrint(alloc, "{s}/{s}@{s} exceeds the 100MB download cap", .{ gh.owner, gh.repo, gh.ref });
            return error.FetchFailed;
        },
        else => {
            err_msg.* = try std.fmt.allocPrint(alloc, "reading download body failed: {s}", .{@errorName(e)});
            return e;
        },
    };

    var gz_source: std.Io.Reader = .fixed(gz_bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&gz_source, .gzip, &window);

    // Forced re-pull, or a leftover from a prior attempt that failed partway
    // through extraction (see the deleteTree below on the failure path),
    // may leave stale files that the new tarball no longer contains; start
    // from a clean dir so extraction reflects exactly what's in the tarball.
    if (dirExists(dir)) {
        std.fs.cwd().deleteTree(dir) catch |e| {
            err_msg.* = try std.fmt.allocPrint(alloc, "clearing stale cache dir {s} failed: {s}", .{ dir, @errorName(e) });
            return e;
        };
    }
    std.fs.cwd().makePath(dir) catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "creating cache dir {s} failed: {s}", .{ dir, @errorName(e) });
        return e;
    };
    var out_dir = std.fs.openDirAbsolute(dir, .{}) catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "opening cache dir {s} failed: {s}", .{ dir, @errorName(e) });
        return e;
    };
    // Not a `defer`: on the failure branch below the dir handle must be
    // closed *before* `deleteTree` runs (an open handle can block deletion),
    // so both branches close it explicitly instead.
    if (std.tar.pipeToFileSystem(out_dir, &decompress.reader, .{ .strip_components = 1 })) |_| {
        out_dir.close();
    } else |e| {
        out_dir.close();
        // Don't leave a partially-extracted dir behind: a later `fetch` with
        // `force_pull = false` treats any existing dir as a cache hit and
        // would silently hand back a broken action.
        std.fs.cwd().deleteTree(dir) catch {};
        err_msg.* = try std.fmt.allocPrint(alloc, "extracting {s}/{s}@{s} failed: {s}", .{ gh.owner, gh.repo, gh.ref, @errorName(e) });
        return e;
    }

    return withSubpath(alloc, dir, gh.subpath);
}

test "parseRef: github short form" {
    const r = try parseRef("actions/checkout@v4");
    try std.testing.expectEqualStrings("actions", r.github.owner);
    try std.testing.expectEqualStrings("checkout", r.github.repo);
    try std.testing.expectEqualStrings("", r.github.subpath);
    try std.testing.expectEqualStrings("v4", r.github.ref);
}

test "parseRef: github with subpath" {
    const r = try parseRef("owner/repo/sub/dir@main");
    try std.testing.expectEqualStrings("owner", r.github.owner);
    try std.testing.expectEqualStrings("repo", r.github.repo);
    try std.testing.expectEqualStrings("sub/dir", r.github.subpath);
    try std.testing.expectEqualStrings("main", r.github.ref);
}

test "parseRef: local path" {
    const r = try parseRef("./local/action");
    try std.testing.expectEqualStrings("./local/action", r.local);
}

test "parseRef: docker image" {
    const r = try parseRef("docker://alpine:3");
    try std.testing.expectEqualStrings("alpine:3", r.docker_image);
}

test "parseRef: missing @ is BadRef" {
    try std.testing.expectError(error.BadRef, parseRef("owner/repo"));
}

test "parseRef: traversal in owner is BadRef" {
    try std.testing.expectError(error.BadRef, parseRef("../../x@main"));
}

test "parseRef: traversal in ref is BadRef" {
    try std.testing.expectError(error.BadRef, parseRef("a/b@.."));
}

test "parseRef: traversal in subpath is BadRef" {
    try std.testing.expectError(error.BadRef, parseRef("a/b/../c@v1"));
}

test "parseRef: multi-segment branch ref stays legal" {
    const r = try parseRef("a/b@feature/foo");
    try std.testing.expectEqualStrings("a", r.github.owner);
    try std.testing.expectEqualStrings("b", r.github.repo);
    try std.testing.expectEqualStrings("", r.github.subpath);
    try std.testing.expectEqualStrings("feature/foo", r.github.ref);
}

fn networkAvailable(alloc: std.mem.Allocator) bool {
    const stream = std.net.tcpConnectToHost(alloc, "codeload.github.com", 443) catch return false;
    stream.close();
    return true;
}

test "fetch: downloads and caches actions/checkout@v4 (network-gated)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (!networkAvailable(a)) return error.SkipZigTest;

    const gh = (try parseRef("actions/checkout@v4")).github;

    var err_msg: ?[]const u8 = null;
    const dir1 = fetch(a, gh, false, null, &err_msg) catch |e| {
        std.debug.print("fetch failed: {s}\n", .{err_msg orelse @errorName(e)});
        return e;
    };

    const action_yml = try std.fs.path.join(a, &.{ dir1, "action.yml" });
    var f = try std.fs.openFileAbsolute(action_yml, .{});
    f.close();

    // Second call should hit the cache: no network needed, same directory.
    var err_msg2: ?[]const u8 = null;
    const dir2 = try fetch(a, gh, false, null, &err_msg2);
    try std.testing.expectEqualStrings(dir1, dir2);
}
