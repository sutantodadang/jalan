const std = @import("std");
const yaml = @import("../yaml.zig");
const ir = @import("../ir.zig");
const expr = @import("../expr.zig");

const WF =
    \\name: CI
    \\env:
    \\  GLOBAL: g
    \\defaults:
    \\  run:
    \\    shell: bash
    \\jobs:
    \\  build:
    \\    runs-on: ubuntu-latest
    \\    env:
    \\      JOB_VAR: j
    \\    steps:
    \\      - name: hello
    \\        run: echo hi
    \\      - id: out
    \\        run: echo "v=1" >> "$GITHUB_OUTPUT"
    \\        shell: sh
    \\        if: github.ref == 'refs/heads/main'
    \\  test:
    \\    needs: build
    \\    steps:
    \\      - uses: actions/checkout@v4
    \\      - run: echo done
;

test "lower workflow to pipeline IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const p = try parseWorkflow(a, "ci.yml", WF, &diags);
    try std.testing.expectEqualStrings("CI", p.name);
    try std.testing.expectEqual(@as(usize, 2), p.jobs.len);
    const build = p.jobs[0];
    try std.testing.expectEqualStrings("ubuntu-latest", build.runs_on);
    // workflow env precedes job env in Job.env
    try std.testing.expectEqualStrings("GLOBAL", build.env[0].name);
    try std.testing.expectEqualStrings("JOB_VAR", build.env[1].name);
    // defaults.run.shell applied, explicit shell wins
    try std.testing.expectEqualStrings("bash", build.steps[0].shell.?);
    try std.testing.expectEqualStrings("sh", build.steps[1].shell.?);
    try std.testing.expectEqualStrings("github.ref == 'refs/heads/main'", build.steps[1].cond.?);
    // needs scalar form
    try std.testing.expectEqualStrings("build", p.jobs[1].needs[0]);
    // uses step lowered with warning
    try std.testing.expectEqual(ir.StepKind.uses, p.jobs[1].steps[0].kind);
    var warned = false;
    for (diags.list.items) |d| {
        if (std.mem.startsWith(u8, d.msg, "warning: ")) warned = true;
    }
    try std.testing.expect(warned);
}

test "bad if expression is a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src = "jobs:\n  j:\n    steps:\n      - run: echo x\n        if: (broken\n";
    try std.testing.expectError(error.ParseFailed, parseWorkflow(a, "x.yml", src, &diags));
}

test "unknown job key warns but does not fail parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    containerz: oops
        \\    steps:
        \\      - run: echo hi
    ;
    const p = try parseWorkflow(a, "x.yml", src, &diags);
    try std.testing.expectEqual(@as(usize, 1), p.jobs.len);
    var found = false;
    for (diags.list.items) |d| {
        if (std.mem.startsWith(u8, d.msg, "warning: ") and std.mem.indexOf(u8, d.msg, "containerz") != null) found = true;
    }
    try std.testing.expect(found);
}

test "unknown step key warns but does not fail parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    steps:
        \\      - run: echo hi
        \\        bogus-key: nope
    ;
    const p = try parseWorkflow(a, "x.yml", src, &diags);
    try std.testing.expectEqual(@as(usize, 1), p.jobs.len);
    var found = false;
    for (diags.list.items) |d| {
        if (std.mem.startsWith(u8, d.msg, "warning: ") and std.mem.indexOf(u8, d.msg, "bogus-key") != null) found = true;
    }
    try std.testing.expect(found);
}

test "known-but-unsupported keys (strategy, with) do not warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    strategy:
        \\      fail-fast: false
        \\    steps:
        \\      - uses: actions/checkout@v4
        \\        with:
        \\          ref: main
    ;
    _ = try parseWorkflow(a, "x.yml", src, &diags);
    for (diags.list.items) |d| {
        try std.testing.expect(std.mem.indexOf(u8, d.msg, "job key") == null);
        try std.testing.expect(std.mem.indexOf(u8, d.msg, "step key") == null);
    }
}

test "matrix expands cartesian product with display names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    strategy:
        \\      matrix:
        \\        os: [linux, windows]
        \\        node: [18, 20]
        \\    steps:
        \\      - run: echo ${{ matrix.os }}-${{ matrix.node }}
    ;
    const p = try parseWorkflow(a, "m.yml", src, &diags);
    try std.testing.expectEqual(@as(usize, 4), p.jobs.len);
    try std.testing.expectEqualStrings("build (linux, 18)", p.jobs[0].display_name);
    try std.testing.expectEqualStrings("build (windows, 20)", p.jobs[3].display_name);
    try std.testing.expectEqualStrings("os", p.jobs[0].matrix[0].name);
    try std.testing.expectEqualStrings("linux", p.jobs[0].matrix[0].value);
}

test "matrixMatches filters combos" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var combo = [_]ir.EnvPair{ .{ .name = "os", .value = "linux" }, .{ .name = "node", .value = "18" } };
    var steps = [_]ir.Step{};
    const job = ir.Job{ .id = "b", .display_name = "b", .matrix = &combo, .steps = &steps };
    var f_ok = [_]ir.EnvPair{.{ .name = "os", .value = "linux" }};
    var f_no = [_]ir.EnvPair{.{ .name = "node", .value = "20" }};
    try std.testing.expect(matrixMatches(job, &f_ok));
    try std.testing.expect(!matrixMatches(job, &f_no));
    _ = a;
}

pub const ParseError = error{ ParseFailed, OutOfMemory };

fn addWarn(diags: *yaml.Diags, line: u32, col: u32, comptime fmt: []const u8, args: anytype) !void {
    try diags.add(line, col, "warning: " ++ fmt, args);
}

fn hasHardError(diags: *const yaml.Diags) bool {
    for (diags.list.items) |d| {
        if (!std.mem.startsWith(u8, d.msg, "warning: ")) return true;
    }
    return false;
}

fn envPairs(alloc: std.mem.Allocator, node: ?yaml.Node) ![]ir.EnvPair {
    var out: std.ArrayList(ir.EnvPair) = .empty;
    if (node) |n| switch (n.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |e|
                try out.append(alloc, .{ .name = e.key_ptr.*, .value = e.value_ptr.*.scalarOr("") });
        },
        else => {},
    };
    return out.toOwnedSlice(alloc);
}

fn needsList(alloc: std.mem.Allocator, node: ?yaml.Node) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (node) |n| switch (n.data) {
        .scalar => |s| if (s.len > 0) try out.append(alloc, s),
        .seq => |items| for (items) |item| try out.append(alloc, item.scalarOr("")),
        .map => {},
    };
    return out.toOwnedSlice(alloc);
}

/// Strip optional `${{ ... }}` wrapper from an `if:` value; syntax-check the result.
fn condText(alloc: std.mem.Allocator, raw: []const u8, line: u32, diags: *yaml.Diags) !?[]const u8 {
    var t = std.mem.trim(u8, raw, " ");
    if (std.mem.startsWith(u8, t, "${{") and std.mem.endsWith(u8, t, "}}"))
        t = std.mem.trim(u8, t[3 .. t.len - 2], " ");
    if (t.len == 0) return null;
    _ = expr.parseExpr(alloc, t) catch {
        try diags.add(line, 1, "invalid expression in 'if': {s}", .{t});
        return t;
    };
    return t;
}

const workflow_known_keys = [_][]const u8{ "name", "on", "env", "defaults", "jobs", "permissions", "concurrency", "run-name" };
const job_known_keys = [_][]const u8{ "name", "runs-on", "needs", "env", "steps", "strategy", "defaults", "if", "outputs", "permissions", "timeout-minutes", "continue-on-error", "concurrency", "environment" };
const step_known_keys = [_][]const u8{ "name", "id", "run", "uses", "with", "shell", "env", "if", "working-directory", "continue-on-error", "timeout-minutes" };

/// Warn on any map key not present in `allowed`. Never a hard error —
/// unsupported-but-known GHA keys and genuinely unknown keys are both
/// reported the same way: explicit, never a silent skip.
fn warnUnknownKeys(diags: *yaml.Diags, node: ?yaml.Node, comptime kind: []const u8, allowed: []const []const u8) !void {
    const n = node orelse return;
    switch (n.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                var known = false;
                for (allowed) |ak| {
                    if (std.mem.eql(u8, ak, key)) {
                        known = true;
                        break;
                    }
                }
                if (!known) {
                    const v = e.value_ptr.*;
                    try addWarn(diags, v.line, v.col, kind ++ " key '{s}' is not supported in phase 1 (ignored)", .{key});
                }
            }
        },
        else => {},
    }
}

const Defaults = struct { shell: ?[]const u8 = null, workdir: ?[]const u8 = null };

fn readDefaults(node: ?yaml.Node) Defaults {
    var d = Defaults{};
    if (node) |n| if (n.get("run")) |run| {
        if (run.get("shell")) |s| d.shell = s.scalarOr("");
        if (run.get("working-directory")) |w| d.workdir = w.scalarOr("");
    };
    return d;
}

pub fn parseWorkflow(
    alloc: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    diags: *yaml.Diags,
) ParseError!ir.Pipeline {
    const root = yaml.parse(alloc, source, diags) catch |e| switch (e) {
        error.ParseFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    try warnUnknownKeys(diags, root, "workflow", &workflow_known_keys);
    const wf_env = try envPairs(alloc, root.get("env"));
    const wf_defaults = readDefaults(root.get("defaults"));
    const name = if (root.get("name")) |n| n.scalarOr(source_path) else source_path;

    var jobs: std.ArrayList(ir.Job) = .empty;
    const jobs_node = root.get("jobs") orelse {
        try diags.add(root.line, root.col, "workflow has no 'jobs' key", .{});
        return error.ParseFailed;
    };
    switch (jobs_node.data) {
        .map => |jm| {
            var it = jm.iterator();
            while (it.next()) |e| {
                const job_id = e.key_ptr.*;
                const jn = e.value_ptr.*;
                const base = try lowerJob(alloc, job_id, jn, wf_env, wf_defaults, diags);
                const axes = try readMatrix(alloc, jn, diags);
                try appendExpanded(alloc, &jobs, base, axes);
            }
        },
        else => {
            try diags.add(jobs_node.line, jobs_node.col, "'jobs' must be a mapping", .{});
            return error.ParseFailed;
        },
    }
    if (hasHardError(diags)) return error.ParseFailed;
    return .{ .name = name, .source_path = source_path, .jobs = try jobs.toOwnedSlice(alloc) };
}

fn lowerJob(
    alloc: std.mem.Allocator,
    job_id: []const u8,
    jn: yaml.Node,
    wf_env: []const ir.EnvPair,
    wf_defaults: Defaults,
    diags: *yaml.Diags,
) !ir.Job {
    const job_defaults = readDefaults(jn.get("defaults"));
    const shell_default = job_defaults.shell orelse wf_defaults.shell;
    const workdir_default = job_defaults.workdir orelse wf_defaults.workdir;

    var env: std.ArrayList(ir.EnvPair) = .empty;
    try env.appendSlice(alloc, wf_env);
    try env.appendSlice(alloc, try envPairs(alloc, jn.get("env")));

    var steps: std.ArrayList(ir.Step) = .empty;
    if (jn.get("steps")) |sn| switch (sn.data) {
        .seq => |items| for (items, 0..) |stepn, i| {
            try steps.append(alloc, try lowerStep(alloc, stepn, i, shell_default, workdir_default, diags));
        },
        else => try diags.add(sn.line, sn.col, "'steps' must be a sequence", .{}),
    } else try diags.add(jn.line, jn.col, "job '{s}' has no steps", .{job_id});

    try warnUnknownKeys(diags, jn, "job", &job_known_keys);

    return .{
        .id = job_id,
        .display_name = job_id,
        .runs_on = if (jn.get("runs-on")) |r| r.scalarOr("") else "",
        .needs = try needsList(alloc, jn.get("needs")),
        .env = try env.toOwnedSlice(alloc),
        .steps = try steps.toOwnedSlice(alloc),
    };
}

const Axis = struct { name: []const u8, values: [][]const u8 };

fn readMatrix(alloc: std.mem.Allocator, jn: yaml.Node, diags: *yaml.Diags) ![]Axis {
    var axes: std.ArrayList(Axis) = .empty;
    const strategy = jn.get("strategy") orelse return axes.toOwnedSlice(alloc);
    const matrix = strategy.get("matrix") orelse return axes.toOwnedSlice(alloc);
    switch (matrix.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                const axis_name = e.key_ptr.*;
                if (std.mem.eql(u8, axis_name, "include") or std.mem.eql(u8, axis_name, "exclude")) {
                    try addWarn(diags, e.value_ptr.line, e.value_ptr.col, "matrix {s} is not supported in phase 1 (ignored)", .{axis_name});
                    continue;
                }
                var vals: std.ArrayList([]const u8) = .empty;
                switch (e.value_ptr.data) {
                    .seq => |items| for (items) |v| try vals.append(alloc, v.scalarOr("")),
                    .scalar => |s| try vals.append(alloc, s),
                    .map => try diags.add(e.value_ptr.line, e.value_ptr.col, "matrix axis '{s}' must be a list", .{axis_name}),
                }
                try axes.append(alloc, .{ .name = axis_name, .values = try vals.toOwnedSlice(alloc) });
            }
        },
        else => try diags.add(matrix.line, matrix.col, "'matrix' must be a mapping", .{}),
    }
    return axes.toOwnedSlice(alloc);
}

fn appendExpanded(alloc: std.mem.Allocator, jobs: *std.ArrayList(ir.Job), base: ir.Job, axes: []Axis) !void {
    if (axes.len == 0) {
        try jobs.append(alloc, base);
        return;
    }
    var total: usize = 1;
    for (axes) |ax| total *= @max(ax.values.len, 1);
    var combo_idx: usize = 0;
    while (combo_idx < total) : (combo_idx += 1) {
        var combo: std.ArrayList(ir.EnvPair) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        var rem = combo_idx;
        var stride: usize = total;
        for (axes) |ax| {
            stride /= @max(ax.values.len, 1);
            const v = ax.values[(rem / @max(stride, 1)) % @max(ax.values.len, 1)];
            rem %= @max(stride, 1);
            try combo.append(alloc, .{ .name = ax.name, .value = v });
            try names.append(alloc, v);
        }
        var j = base;
        j.matrix = try combo.toOwnedSlice(alloc);
        j.display_name = try std.fmt.allocPrint(alloc, "{s} ({s})", .{ base.id, try std.mem.join(alloc, ", ", names.items) });
        try jobs.append(alloc, j);
    }
}

pub fn matrixMatches(job: ir.Job, filters: []const ir.EnvPair) bool {
    for (filters) |f| {
        var found = false;
        for (job.matrix) |m| {
            if (std.mem.eql(u8, m.name, f.name) and std.mem.eql(u8, m.value, f.value)) found = true;
        }
        if (!found) return false;
    }
    return true;
}

fn lowerStep(
    alloc: std.mem.Allocator,
    n: yaml.Node,
    index: usize,
    shell_default: ?[]const u8,
    workdir_default: ?[]const u8,
    diags: *yaml.Diags,
) !ir.Step {
    try warnUnknownKeys(diags, n, "step", &step_known_keys);
    const run_node = n.get("run");
    const uses_node = n.get("uses");
    if (run_node == null and uses_node == null)
        try diags.add(n.line, n.col, "step needs 'run' or 'uses'", .{});
    if (uses_node != null)
        try addWarn(diags, n.line, n.col, "'uses' actions are not executed in phase 1 (skipped at runtime)", .{});

    const script = if (run_node) |r| r.scalarOr("") else "";
    const uses_ref = if (uses_node) |u| u.scalarOr("") else "";
    const default_name = if (uses_node != null)
        uses_ref
    else blk: {
        const first_nl = std.mem.indexOfScalar(u8, script, '\n') orelse script.len;
        break :blk script[0..@min(first_nl, 60)];
    };
    var timeout: ?u32 = null;
    if (n.get("timeout-minutes")) |t| {
        timeout = std.fmt.parseInt(u32, t.scalarOr("0"), 10) catch null;
        try addWarn(diags, t.line, t.col, "timeout-minutes recorded but not enforced in phase 1", .{});
    }
    return .{
        .id = if (n.get("id")) |i| i.scalarOr("") else try std.fmt.allocPrint(alloc, "step-{d}", .{index + 1}),
        .name = if (n.get("name")) |nm| nm.scalarOr(default_name) else default_name,
        .kind = if (uses_node != null) .uses else .run,
        .script = script,
        .uses_ref = uses_ref,
        .shell = if (n.get("shell")) |s| s.scalarOr("") else shell_default,
        .env = try envPairs(alloc, n.get("env")),
        .workdir = if (n.get("working-directory")) |w| w.scalarOr("") else workdir_default,
        .cond = if (n.get("if")) |c| try condText(alloc, c.scalarOr(""), c.line, diags) else null,
        .continue_on_error = if (n.get("continue-on-error")) |c| std.mem.eql(u8, c.scalarOr(""), "true") else false,
        .timeout_minutes = timeout,
    };
}
