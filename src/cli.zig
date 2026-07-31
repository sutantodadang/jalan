//! CLI: lint command and provider detection.
const std = @import("std");
const yaml = @import("yaml.zig");
const ir = @import("ir.zig");
const gha = @import("frontend/gha.zig");

pub const Provider = enum { gha, unknown };

pub fn detectProvider(path: []const u8, source: []const u8) Provider {
    if (std.mem.indexOf(u8, path, ".github/workflows") != null or
        std.mem.indexOf(u8, path, ".github\\workflows") != null) return .gha;
    if (std.mem.indexOf(u8, source, "jobs:") != null and
        (std.mem.indexOf(u8, source, "runs-on") != null or
            std.mem.indexOf(u8, source, "steps:") != null)) return .gha;
    return .unknown;
}

pub fn findDefaultWorkflow(alloc: std.mem.Allocator) !?[]const u8 {
    var dir = std.fs.cwd().openDir(".github/workflows", .{ .iterate = true }) catch return null;
    defer dir.close();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file) continue;
        if (std.mem.endsWith(u8, e.name, ".yml") or std.mem.endsWith(u8, e.name, ".yaml"))
            try names.append(alloc, try std.fmt.allocPrint(alloc, ".github/workflows/{s}", .{e.name}));
    }
    if (names.items.len == 0) return null;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.items[0];
}

pub fn lintMain(alloc: std.mem.Allocator, path: []const u8, json: bool, strict: bool, out: *std.ArrayList(u8)) !u8 {
    const source = std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024) catch {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "error: cannot read '{s}'\n", .{path}));
        return 3;
    };
    if (detectProvider(path, source) == .unknown) {
        try out.appendSlice(alloc, "error: could not detect CI provider (phase 1 supports GitHub Actions only)\n");
        return 2;
    }
    var diags = yaml.Diags.init(alloc);
    const pipeline = gha.parseWorkflow(alloc, path, source, &diags) catch |e| switch (e) {
        error.ParseFailed => {
            try printDiags(alloc, path, &diags, out);
            return 2;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    try printDiags(alloc, path, &diags, out);
    const has_warnings = diags.list.items.len > 0;
    if (strict and has_warnings) return 2;
    if (json) {
        try out.appendSlice(alloc, try ir.toJson(alloc, pipeline));
        try out.append(alloc, '\n');
    } else {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "workflow: {s}\n", .{pipeline.name}));
        for (pipeline.jobs) |j| {
            const needs = try std.mem.join(alloc, ", ", j.needs);
            if (needs.len > 0)
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "job: {s} (needs: {s})\n", .{ j.display_name, needs }))
            else
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "job: {s}\n", .{j.display_name}));
        }
    }
    return 0;
}

fn printDiags(alloc: std.mem.Allocator, path: []const u8, diags: *const yaml.Diags, out: *std.ArrayList(u8)) !void {
    for (diags.list.items) |d|
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}:{d}: {s}\n", .{ path, d.line, d.col, d.msg }));
}

test "detect provider by path and content" {
    try std.testing.expectEqual(Provider.gha, detectProvider(".github/workflows/ci.yml", ""));
    try std.testing.expectEqual(Provider.gha, detectProvider("any.yml", "jobs:\n  a:\n    steps:\n      - run: x"));
    try std.testing.expectEqual(Provider.unknown, detectProvider("pipeline.yml", "stages:\n  - build"));
}

test "lint reports diagnostics with exit 2 and job graph on success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // failure case
    try std.fs.cwd().makePath(".jalan/tmp");
    try std.fs.cwd().writeFile(.{ .sub_path = ".jalan/tmp/bad.yml", .data = "jobs:\n  a:\n    needs: ghost\n    steps:\n      - run: x\n" });
    var out: std.ArrayList(u8) = .empty;
    const code = try lintMain(a, ".jalan/tmp/bad.yml", false, false, &out);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "unknown job 'ghost'") != null);
    // success case
    try std.fs.cwd().writeFile(.{ .sub_path = ".jalan/tmp/ok.yml", .data = "name: X\njobs:\n  a:\n    steps:\n      - run: echo hi\n" });
    var out2: std.ArrayList(u8) = .empty;
    const code2 = try lintMain(a, ".jalan/tmp/ok.yml", false, false, &out2);
    try std.testing.expectEqual(@as(u8, 0), code2);
    try std.testing.expect(std.mem.indexOf(u8, out2.items, "workflow: X") != null);
}
