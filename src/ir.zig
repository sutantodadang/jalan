//! Pipeline IR types and JSON emitter.
const std = @import("std");

pub const EnvPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const StepKind = enum {
    run,
    uses,
};

pub const Step = struct {
    id: []const u8,
    name: []const u8,
    kind: StepKind,
    script: []const u8,
    uses_ref: []const u8 = "",
    shell: ?[]const u8 = null,
    env: []EnvPair = &.{},
    workdir: ?[]const u8 = null,
    cond: ?[]const u8 = null,
    continue_on_error: bool = false,
    timeout_minutes: ?u32 = null,
    input_hash: ?[]const u8 = null,
    src_line: u32 = 0,
};

pub const Job = struct {
    id: []const u8,
    display_name: []const u8,
    runs_on: []const u8 = "",
    needs: [][]const u8 = &.{},
    env: []EnvPair = &.{},
    matrix: []EnvPair = &.{},
    steps: []Step,
    src_line: u32 = 0,
};

pub const Pipeline = struct {
    name: []const u8,
    source_path: []const u8,
    jobs: []Job,
};

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

pub fn toJson(alloc: std.mem.Allocator, p: Pipeline) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn kv(o: *std.ArrayList(u8), al: std.mem.Allocator, key: []const u8, val: []const u8, comma: bool) !void {
            if (comma) try o.append(al, ',');
            try jsonStr(o, al, key);
            try o.append(al, ':');
            try jsonStr(o, al, val);
        }
    };
    try out.append(alloc, '{');
    try w.kv(&out, alloc, "name", p.name, false);
    try w.kv(&out, alloc, "source_path", p.source_path, true);
    try out.appendSlice(alloc, ",\"jobs\":[");
    for (p.jobs, 0..) |job, ji| {
        if (ji > 0) try out.append(alloc, ',');
        try out.append(alloc, '{');
        try w.kv(&out, alloc, "id", job.id, false);
        try w.kv(&out, alloc, "display_name", job.display_name, true);
        try w.kv(&out, alloc, "runs_on", job.runs_on, true);
        try out.appendSlice(alloc, ",\"needs\":[");
        for (job.needs, 0..) |n, i| {
            if (i > 0) try out.append(alloc, ',');
            try jsonStr(&out, alloc, n);
        }
        try out.appendSlice(alloc, "],\"matrix\":");
        try envPairsJson(&out, alloc, job.matrix);
        try out.appendSlice(alloc, ",\"env\":");
        try envPairsJson(&out, alloc, job.env);
        try out.appendSlice(alloc, ",\"steps\":[");
        for (job.steps, 0..) |s, si| {
            if (si > 0) try out.append(alloc, ',');
            try out.append(alloc, '{');
            try w.kv(&out, alloc, "id", s.id, false);
            try w.kv(&out, alloc, "name", s.name, true);
            try w.kv(&out, alloc, "kind", @tagName(s.kind), true);
            try w.kv(&out, alloc, "script", s.script, true);
            try w.kv(&out, alloc, "shell", s.shell orelse "", true);
            try w.kv(&out, alloc, "if", s.cond orelse "", true);
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]}");
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

fn envPairsJson(out: *std.ArrayList(u8), alloc: std.mem.Allocator, pairs: []const EnvPair) !void {
    try out.append(alloc, '{');
    for (pairs, 0..) |p, i| {
        if (i > 0) try out.append(alloc, ',');
        try jsonStr(out, alloc, p.name);
        try out.append(alloc, ':');
        try jsonStr(out, alloc, p.value);
    }
    try out.append(alloc, '}');
}

test "pipeline serializes to json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]Step{.{ .id = "s1", .name = "hello", .kind = .run, .script = "echo \"hi\"" }};
    var jobs = [_]Job{.{ .id = "build", .display_name = "build", .steps = &steps }};
    const p = Pipeline{ .name = "CI", .source_path = "x.yml", .jobs = &jobs };
    const json = try toJson(a, p);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"CI\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"hi\\\"") != null);
}
