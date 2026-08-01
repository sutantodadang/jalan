//! Run records: one JSON file per `jalan run` (with snapshots on) at
//! `.jalan/store/runs/<run_id>.json`. Records the pipeline identity, per-
//! step status + snapshot path, and the flat `jobid.outputs.key` pairs the
//! engine published — everything `--resume` needs to rebuild state.
//!
//! The record is rewritten (tmp + rename) after each job completes, so a
//! crashed run still resumes up to its last completed job.
const std = @import("std");
const ir = @import("../ir.zig");

pub const Error = error{ OutOfMemory, StoreIo };

pub const StepEntry = struct {
    id: []const u8,
    status: []const u8 = "pending",
    snapshot: []const u8 = "",
};

pub const JobEntry = struct {
    id: []const u8,
    status: []const u8 = "pending",
    steps: []StepEntry = &.{},
};

pub const RunRecord = struct {
    run_id: []const u8,
    workflow: []const u8,
    backend: []const u8 = "native",
    started_unix: i64,
    jobs: []JobEntry = &.{},
    job_outputs: []ir.EnvPair = &.{},
};

/// `<unix-seconds>-<8 random hex>` — sortable, collision-free.
pub fn newId(alloc: std.mem.Allocator) ![]u8 {
    var rand_buf: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    return std.fmt.allocPrint(alloc, "{d}-{s}", .{ std.time.timestamp(), std.fmt.bytesToHex(rand_buf, .lower) });
}

fn recordPath(alloc: std.mem.Allocator, root: []const u8, run_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/runs/{s}.json", .{ root, run_id });
}

/// Atomic write: tmp file + rename (delete-first on Windows, where rename
/// refuses to overwrite — the record is rewritten after every job).
pub fn write(alloc: std.mem.Allocator, root: []const u8, rec: *const RunRecord) Error!void {
    const json = try toJson(alloc, rec.*);
    const abs = try recordPath(alloc, root, rec.run_id);
    if (std.fs.path.dirname(abs)) |d| std.fs.cwd().makePath(d) catch return error.StoreIo;
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp{x}", .{ abs, std.crypto.random.int(u32) });
    std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = json }) catch return error.StoreIo;
    std.fs.cwd().rename(tmp, abs) catch {
        std.fs.cwd().deleteFile(abs) catch {};
        std.fs.cwd().rename(tmp, abs) catch return error.StoreIo;
    };
}

pub fn load(alloc: std.mem.Allocator, root: []const u8, run_id: []const u8) Error!RunRecord {
    const abs = try recordPath(alloc, root, run_id);
    const text = std.fs.cwd().readFileAlloc(alloc, abs, 64 * 1024 * 1024) catch return error.StoreIo;
    const parsed = std.json.parseFromSlice(RunRecord, alloc, text, .{ .ignore_unknown_fields = true }) catch return error.StoreIo;
    return parsed.value;
}

/// All run records, newest first by started_unix (ties broken by id).
/// Unparseable files are skipped — a corrupt record must not break listing.
pub fn list(alloc: std.mem.Allocator, root: []const u8) Error![]RunRecord {
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/runs", .{root});
    var out: std.ArrayList(RunRecord) = .empty;
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return out.toOwnedSlice(alloc),
        else => return error.StoreIo,
    };
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch return error.StoreIo) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, ".json")) continue;
        const id = e.name[0 .. e.name.len - ".json".len];
        const rec = load(alloc, root, id) catch continue;
        try out.append(alloc, rec);
    }
    const items = try out.toOwnedSlice(alloc);
    std.mem.sort(RunRecord, items, {}, struct {
        fn gt(_: void, x: RunRecord, y: RunRecord) bool {
            if (x.started_unix != y.started_unix) return x.started_unix > y.started_unix;
            return std.mem.lessThan(u8, y.run_id, x.run_id);
        }
    }.gt);
    return items;
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

pub fn toJson(alloc: std.mem.Allocator, rec: RunRecord) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "{\"run_id\":");
    try jsonStr(&out, alloc, rec.run_id);
    try out.appendSlice(alloc, ",\"workflow\":");
    try jsonStr(&out, alloc, rec.workflow);
    try out.appendSlice(alloc, ",\"backend\":");
    try jsonStr(&out, alloc, rec.backend);
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"started_unix\":{d}", .{rec.started_unix}));
    try out.appendSlice(alloc, ",\"jobs\":[");
    for (rec.jobs, 0..) |j, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"id\":");
        try jsonStr(&out, alloc, j.id);
        try out.appendSlice(alloc, ",\"status\":");
        try jsonStr(&out, alloc, j.status);
        try out.appendSlice(alloc, ",\"steps\":[");
        for (j.steps, 0..) |s, k| {
            if (k > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"id\":");
            try jsonStr(&out, alloc, s.id);
            try out.appendSlice(alloc, ",\"status\":");
            try jsonStr(&out, alloc, s.status);
            try out.appendSlice(alloc, ",\"snapshot\":");
            try jsonStr(&out, alloc, s.snapshot);
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]}");
    }
    try out.appendSlice(alloc, "],\"job_outputs\":[");
    for (rec.job_outputs, 0..) |p, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"name\":");
        try jsonStr(&out, alloc, p.name);
        try out.appendSlice(alloc, ",\"value\":");
        try jsonStr(&out, alloc, p.value);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

test "newId has <unix>-<hex8> shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const id = try newId(arena.allocator());
    const dash = std.mem.indexOfScalar(u8, id, '-').?;
    try std.testing.expect(dash > 0);
    try std.testing.expectEqual(@as(usize, 8), id.len - dash - 1);
}

test "write → load round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = ".jalan/tmp/rectest";
    std.fs.cwd().deleteTree(root) catch {};
    var steps = [_]StepEntry{
        .{ .id = "s1", .status = "success", .snapshot = "snapshots/r/j/000-s1.json" },
        .{ .id = "s2" },
    };
    var jobs = [_]JobEntry{.{ .id = "j", .status = "success", .steps = &steps }};
    var outs = [_]ir.EnvPair{.{ .name = "j.outputs.ver", .value = "42" }};
    const rec = RunRecord{ .run_id = "r-1", .workflow = "ci.yml", .backend = "docker", .started_unix = 1234, .jobs = &jobs, .job_outputs = &outs };
    try write(a, root, &rec);
    const got = try load(a, root, "r-1");
    try std.testing.expectEqualStrings("r-1", got.run_id);
    try std.testing.expectEqualStrings("docker", got.backend);
    try std.testing.expectEqual(@as(i64, 1234), got.started_unix);
    try std.testing.expectEqual(@as(usize, 1), got.jobs.len);
    try std.testing.expectEqual(@as(usize, 2), got.jobs[0].steps.len);
    try std.testing.expectEqualStrings("snapshots/r/j/000-s1.json", got.jobs[0].steps[0].snapshot);
    try std.testing.expectEqualStrings("pending", got.jobs[0].steps[1].status);
    try std.testing.expectEqualStrings("42", got.job_outputs[0].value);
    std.fs.cwd().deleteTree(root) catch {};
}

test "list sorts newest first and skips corrupt files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = ".jalan/tmp/rectest2";
    std.fs.cwd().deleteTree(root) catch {};
    const r1 = RunRecord{ .run_id = "a-old", .workflow = "ci.yml", .started_unix = 100 };
    const r2 = RunRecord{ .run_id = "b-new", .workflow = "ci.yml", .started_unix = 200 };
    try write(a, root, &r1);
    try write(a, root, &r2);
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/runs/broken.json", .{root}), .data = "{not json" });
    const recs = try list(a, root);
    try std.testing.expectEqual(@as(usize, 2), recs.len);
    try std.testing.expectEqualStrings("b-new", recs[0].run_id);
    try std.testing.expectEqualStrings("a-old", recs[1].run_id);
    // Missing store dir → empty list, not an error.
    try std.testing.expectEqual(@as(usize, 0), (try list(a, ".jalan/tmp/rectest-nonexistent")).len);
    std.fs.cwd().deleteTree(root) catch {};
}
