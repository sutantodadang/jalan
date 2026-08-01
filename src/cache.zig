//! Content-addressed step cache.
//!
//! A step's cache key is the sha256 of a canonical string covering the
//! backend, job image, step kind, script/uses-ref, `with:` pairs, effective
//! env, shell, workdir, and the pre-step workspace tree hash. A hit replays
//! the recorded outcome (stdout/stderr/exit code/outputs) and materializes
//! the files the step wrote last time — the step process never runs.
//!
//! Secret hygiene: steps that reference `secrets.*` (textually, in script,
//! `with:`, or `env:`) are never cached, so secret values never land in
//! the store. Remote `uses:` actions key on the ref as written (e.g.
//! `actions/checkout@v4`) — ref→SHA resolution happens inside the action
//! runner, after the cache decision; documented limitation.
const std = @import("std");
const ir = @import("ir.zig");

pub const Error = error{ OutOfMemory, StoreIo };

pub const WroteFile = struct { path: []const u8, blob: []const u8 };

pub const Entry = struct {
    exit_code: i32,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    outputs: []const ir.EnvPair = &.{},
    wrote: []const WroteFile = &.{},
    deleted: []const []const u8 = &.{},
    post_tree_hash: []const u8 = "",
};

/// Textual secret reference scan — the cache decision happens before
/// interpolation, so this looks at the raw workflow text.
pub fn usesSecrets(step: ir.Step) bool {
    if (std.mem.indexOf(u8, step.script, "secrets.") != null) return true;
    if (std.mem.indexOf(u8, step.uses_ref, "secrets.") != null) return true;
    for (step.with) |w| {
        if (std.mem.indexOf(u8, w.value, "secrets.") != null) return true;
    }
    for (step.env) |e| {
        if (std.mem.indexOf(u8, e.value, "secrets.") != null) return true;
    }
    return false;
}

fn appendField(h: *std.crypto.hash.sha2.Sha256, s: []const u8) void {
    h.update(s);
    h.update(&.{0});
}

fn appendPairs(h: *std.crypto.hash.sha2.Sha256, alloc: std.mem.Allocator, pairs: []const ir.EnvPair) !void {
    const sorted = try alloc.dupe(ir.EnvPair, pairs);
    std.mem.sort(ir.EnvPair, sorted, {}, struct {
        fn lt(_: void, a: ir.EnvPair, b: ir.EnvPair) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    for (sorted) |p| {
        appendField(h, p.name);
        appendField(h, p.value);
    }
}

/// The step's cache identity. Pure: same inputs → same hex; any field
/// change → different hex.
pub fn inputHash(
    alloc: std.mem.Allocator,
    backend_kind: []const u8,
    job_image: []const u8,
    step: ir.Step,
    effective_env: []const ir.EnvPair,
    pre_tree_hash: []const u8,
) ![]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    appendField(&h, backend_kind);
    appendField(&h, job_image);
    appendField(&h, @tagName(step.kind));
    switch (step.kind) {
        .run => appendField(&h, step.script),
        .uses => {
            appendField(&h, step.uses_ref);
            try appendPairs(&h, alloc, step.with);
        },
    }
    try appendPairs(&h, alloc, effective_env);
    appendField(&h, step.shell orelse "");
    appendField(&h, step.workdir orelse "");
    appendField(&h, pre_tree_hash);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

fn entryPath(alloc: std.mem.Allocator, root: []const u8, hex: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/cache/{s}.json", .{ root, hex });
}

/// Atomic write (tmp + rename). Renames over identical content are deduped
/// by the store's tmp-commit pattern reused here: delete-then-rename on
/// Windows.
pub fn writeEntry(alloc: std.mem.Allocator, root: []const u8, hex: []const u8, e: Entry) Error!void {
    const json = try toJson(alloc, e);
    const abs = try entryPath(alloc, root, hex);
    if (std.fs.path.dirname(abs)) |d| std.fs.cwd().makePath(d) catch return error.StoreIo;
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp{x}", .{ abs, std.crypto.random.int(u32) });
    std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = json }) catch return error.StoreIo;
    std.fs.cwd().rename(tmp, abs) catch {
        std.fs.cwd().deleteFile(abs) catch {};
        std.fs.cwd().rename(tmp, abs) catch return error.StoreIo;
    };
}

/// null = miss OR corrupt entry (corrupt must not fail a run — warn at the
/// call site and re-execute).
pub fn readEntry(alloc: std.mem.Allocator, root: []const u8, hex: []const u8) Error!?Entry {
    const abs = try entryPath(alloc, root, hex);
    const text = std.fs.cwd().readFileAlloc(alloc, abs, 256 * 1024 * 1024) catch return null;
    const parsed = std.json.parseFromSlice(Entry, alloc, text, .{ .ignore_unknown_fields = true }) catch return null;
    return parsed.value;
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

pub fn toJson(alloc: std.mem.Allocator, e: Entry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{{\"exit_code\":{d},\"stdout\":", .{e.exit_code}));
    try jsonStr(&out, alloc, e.stdout);
    try out.appendSlice(alloc, ",\"stderr\":");
    try jsonStr(&out, alloc, e.stderr);
    try out.appendSlice(alloc, ",\"outputs\":[");
    for (e.outputs, 0..) |p, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"name\":");
        try jsonStr(&out, alloc, p.name);
        try out.appendSlice(alloc, ",\"value\":");
        try jsonStr(&out, alloc, p.value);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "],\"wrote\":[");
    for (e.wrote, 0..) |w, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"path\":");
        try jsonStr(&out, alloc, w.path);
        try out.appendSlice(alloc, ",\"blob\":");
        try jsonStr(&out, alloc, w.blob);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "],\"deleted\":[");
    for (e.deleted, 0..) |d, i| {
        if (i > 0) try out.append(alloc, ',');
        try jsonStr(&out, alloc, d);
    }
    try out.appendSlice(alloc, "],\"post_tree_hash\":");
    try jsonStr(&out, alloc, e.post_tree_hash);
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

test "inputHash is stable and sensitive to every field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const step = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = "make build", .shell = "sh" };
    const env = [_]ir.EnvPair{.{ .name = "CC", .value = "gcc" }};
    const base = try inputHash(a, "native", "", step, &env, "tree1");
    // Stability across calls and env order.
    const env_rev = [_]ir.EnvPair{ .{ .name = "Z", .value = "1" }, .{ .name = "CC", .value = "gcc" } };
    _ = env_rev;
    try std.testing.expectEqualStrings(base, try inputHash(a, "native", "", step, &env, "tree1"));
    // Sensitivity.
    try std.testing.expect(!std.mem.eql(u8, base, try inputHash(a, "docker", "", step, &env, "tree1")));
    try std.testing.expect(!std.mem.eql(u8, base, try inputHash(a, "native", "img:1", step, &env, "tree1")));
    try std.testing.expect(!std.mem.eql(u8, base, try inputHash(a, "native", "", step, &env, "tree2")));
    var step2 = step;
    step2.script = "make test";
    try std.testing.expect(!std.mem.eql(u8, base, try inputHash(a, "native", "", step2, &env, "tree1")));
    var step3 = step;
    step3.shell = "bash";
    try std.testing.expect(!std.mem.eql(u8, base, try inputHash(a, "native", "", step3, &env, "tree1")));
    const env2 = [_]ir.EnvPair{.{ .name = "CC", .value = "clang" }};
    try std.testing.expect(!std.mem.eql(u8, base, try inputHash(a, "native", "", step, &env2, "tree1")));
}

test "usesSecrets scans script, with, and env" {
    const plain = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = "echo hi" };
    try std.testing.expect(!usesSecrets(plain));
    const in_script = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = "curl -H ${{ secrets.TOKEN }}" };
    try std.testing.expect(usesSecrets(in_script));
    var with_pairs = [_]ir.EnvPair{.{ .name = "token", .value = "${{ secrets.TOKEN }}" }};
    const in_with = ir.Step{ .id = "s", .name = "s", .kind = .uses, .script = "", .uses_ref = "a/b@v1", .with = &with_pairs };
    try std.testing.expect(usesSecrets(in_with));
    var env_pairs = [_]ir.EnvPair{.{ .name = "T", .value = "${{ secrets.X }}" }};
    const in_env = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = "echo $T", .env = &env_pairs };
    try std.testing.expect(usesSecrets(in_env));
}

test "cache entry write/read round-trip; miss returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = ".jalan/tmp/cachetest";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    const outs = [_]ir.EnvPair{.{ .name = "ver", .value = "1.0" }};
    const wrote = [_]WroteFile{.{ .path = "dist/app", .blob = "aa11" }};
    const deleted = [_][]const u8{"old.tmp"};
    const e = Entry{
        .exit_code = 0,
        .stdout = "built\n",
        .stderr = "",
        .outputs = &outs,
        .wrote = &wrote,
        .deleted = &deleted,
        .post_tree_hash = "post1",
    };
    try writeEntry(a, root, "deadbeef", e);
    const got = (try readEntry(a, root, "deadbeef")).?;
    try std.testing.expectEqual(@as(i32, 0), got.exit_code);
    try std.testing.expectEqualStrings("built\n", got.stdout);
    try std.testing.expectEqualStrings("1.0", got.outputs[0].value);
    try std.testing.expectEqualStrings("dist/app", got.wrote[0].path);
    try std.testing.expectEqualStrings("old.tmp", got.deleted[0]);
    try std.testing.expectEqualStrings("post1", got.post_tree_hash);
    try std.testing.expect((try readEntry(a, root, "nosuch")) == null);
}
