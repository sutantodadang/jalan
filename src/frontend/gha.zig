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

test "strategy is silent; outputs/if are recognized-but-not-simulated warnings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    strategy:
        \\      fail-fast: false
        \\    outputs:
        \\      foo: bar
        \\    if: true
        \\    steps:
        \\      - uses: actions/checkout@v4
        \\        with:
        \\          ref: main
    ;
    const p = try parseWorkflow(a, "x.yml", src, &diags);
    try std.testing.expectEqual(@as(usize, 1), p.jobs.len);
    var strategy_warned = false;
    var with_warned = false;
    var outputs_warned = false;
    var if_warned = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "'strategy'") != null) strategy_warned = true;
        if (std.mem.indexOf(u8, d.msg, "'with'") != null) with_warned = true;
        if (std.mem.indexOf(u8, d.msg, "'outputs'") != null) {
            outputs_warned = true;
            try std.testing.expect(std.mem.indexOf(u8, d.msg, "recognized but not simulated") != null);
        }
        if (std.mem.indexOf(u8, d.msg, "'if'") != null) {
            if_warned = true;
            try std.testing.expect(std.mem.indexOf(u8, d.msg, "recognized but not simulated") != null);
        }
    }
    try std.testing.expect(!strategy_warned);
    try std.testing.expect(!with_warned);
    try std.testing.expect(outputs_warned);
    try std.testing.expect(if_warned);
}

test "'with' on a run step is an unknown-key warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    steps:
        \\      - run: echo hi
        \\        with:
        \\          ref: main
    ;
    _ = try parseWorkflow(a, "x.yml", src, &diags);
    var found = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "'with'") != null) found = true;
    }
    try std.testing.expect(found);
}

test "container: scalar image lowers into container_image, no warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    container: node:20-bookworm-slim
        \\    steps:
        \\      - run: echo hi
    ;
    const p = try parseWorkflow(a, "x.yml", src, &diags);
    try std.testing.expectEqualStrings("node:20-bookworm-slim", p.jobs[0].container_image);
    for (diags.list.items) |d| {
        try std.testing.expect(std.mem.indexOf(u8, d.msg, "'container'") == null);
    }
}

test "container: map with image key lowers into container_image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    container:
        \\      image: ubuntu:22.04
        \\    steps:
        \\      - run: echo hi
    ;
    const p = try parseWorkflow(a, "x.yml", src, &diags);
    try std.testing.expectEqualStrings("ubuntu:22.04", p.jobs[0].container_image);
}

test "no container key leaves container_image empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    steps:
        \\      - run: echo hi
    ;
    const p = try parseWorkflow(a, "x.yml", src, &diags);
    try std.testing.expectEqualStrings("", p.jobs[0].container_image);
}

test "validation diagnostics carry real source line numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  a:
        \\    needs: ghost
        \\    steps:
        \\      - run: echo a
    ;
    _ = parseWorkflow(a, "v.yml", src, &diags) catch {};
    var found = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "needs unknown job 'ghost'") != null) {
            try std.testing.expect(d.line > 0);
            found = true;
        }
    }
    try std.testing.expect(found);
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

test "empty matrix axis is a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    strategy:
        \\      matrix:
        \\        os: []
        \\    steps:
        \\      - run: echo hi
    ;
    try std.testing.expectError(error.ParseFailed, parseWorkflow(a, "m.yml", src, &diags));
    var found = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "matrix axis 'os' has no values") != null) found = true;
    }
    try std.testing.expect(found);
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

test "dangling needs and cycle are hard errors, unknown shell warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  a:
        \\    needs: [b, ghost]
        \\    steps:
        \\      - run: echo a
        \\        shell: fish
        \\  b:
        \\    needs: a
        \\    steps:
        \\      - run: echo b
    ;
    try std.testing.expectError(error.ParseFailed, parseWorkflow(a, "v.yml", src, &diags));
    var dangling = false;
    var cycle = false;
    var shell_warn = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "unknown job 'ghost'") != null) dangling = true;
        if (std.mem.indexOf(u8, d.msg, "cycle") != null) cycle = true;
        if (std.mem.indexOf(u8, d.msg, "unknown shell 'fish'") != null) shell_warn = true;
    }
    try std.testing.expect(dangling);
    try std.testing.expect(cycle);
    try std.testing.expect(shell_warn);
}

test "duplicate step id within a job is a hard error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    steps:
        \\      - id: dup
        \\        run: echo one
        \\      - id: dup
        \\        run: echo two
    ;
    try std.testing.expectError(error.ParseFailed, parseWorkflow(a, "v.yml", src, &diags));
    var found = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "duplicate step id 'dup'") != null) found = true;
    }
    try std.testing.expect(found);
}

test "matrix expansion validates each base job once, not per combo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const src =
        \\jobs:
        \\  build:
        \\    needs: ghost
        \\    strategy:
        \\      matrix:
        \\        os: [linux, windows]
        \\    steps:
        \\      - run: echo hi
    ;
    try std.testing.expectError(error.ParseFailed, parseWorkflow(a, "v.yml", src, &diags));
    var count: usize = 0;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "needs unknown job 'ghost'") != null) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
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

// Keys split three ways per map:
//   supported          -> actually implemented, no warning.
//   known_unsupported   -> real GHA keys jalan recognizes but does not simulate
//                          in phase 1; explicit "recognized but not simulated" warning.
//   anything else        -> genuinely unknown key; "not supported in phase 1" warning.
const workflow_supported_keys = [_][]const u8{ "name", "on", "env", "defaults", "jobs" };
const workflow_known_unsupported_keys = [_][]const u8{ "permissions", "concurrency", "run-name" };
const job_supported_keys = [_][]const u8{ "name", "runs-on", "needs", "env", "steps", "strategy", "defaults", "container" };
const job_known_unsupported_keys = [_][]const u8{ "if", "outputs", "continue-on-error", "timeout-minutes", "environment", "concurrency", "permissions" };
// 'with' is added conditionally by lowerStep: supported on `uses` steps only.
const step_supported_keys = [_][]const u8{ "name", "id", "run", "uses", "shell", "env", "if", "working-directory", "continue-on-error", "timeout-minutes" };
const step_known_unsupported_keys = [_][]const u8{};

fn containsStr(list: []const []const u8, key: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// Warn on any map key not present in `supported`. Never a hard error —
/// known-but-unimplemented GHA keys and genuinely unknown keys are both
/// reported (with different wording), never silently skipped.
fn checkKeys(
    diags: *yaml.Diags,
    node: ?yaml.Node,
    comptime kind: []const u8,
    supported: []const []const u8,
    known_unsupported: []const []const u8,
) !void {
    const n = node orelse return;
    switch (n.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                if (containsStr(supported, key)) continue;
                const v = e.value_ptr.*;
                if (containsStr(known_unsupported, key)) {
                    try addWarn(diags, v.line, v.col, kind ++ " key '{s}' is recognized but not simulated in phase 1 (ignored)", .{key});
                } else {
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
    try checkKeys(diags, root, "workflow", &workflow_supported_keys, &workflow_known_unsupported_keys);
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
    const job_slice = try jobs.toOwnedSlice(alloc);
    try validate(alloc, job_slice, diags);
    if (hasHardError(diags)) return error.ParseFailed;
    return .{ .name = name, .source_path = source_path, .jobs = job_slice };
}

const known_shells = [_][]const u8{ "bash", "sh", "pwsh", "powershell", "cmd", "python" };

/// First job (in expansion order) matching a base id. Matrix copies share
/// id/needs/steps, so any copy is representative for per-job validation.
fn firstJobWithId(jobs: []const ir.Job, id: []const u8) ?ir.Job {
    for (jobs) |j| {
        if (std.mem.eql(u8, j.id, id)) return j;
    }
    return null;
}

fn validate(alloc: std.mem.Allocator, jobs: []const ir.Job, diags: *yaml.Diags) !void {
    // Unique base ids (matrix copies share id — dedupe first).
    var ids: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (jobs) |j| try ids.put(alloc, j.id, {});

    // Per-job checks (needs refs, step ids, shells) run once per BASE id —
    // matrix copies share id/needs/steps, so validating every expanded copy
    // would report the same diag N times for an N-combo matrix job.
    for (ids.keys()) |id| {
        const j = firstJobWithId(jobs, id) orelse continue;
        for (j.needs) |n| {
            if (!ids.contains(n))
                try diags.add(j.src_line, 1, "job '{s}' needs unknown job '{s}'", .{ j.id, n });
        }
        var step_ids: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (j.steps) |s| {
            if (step_ids.contains(s.id))
                try diags.add(s.src_line, 1, "duplicate step id '{s}' in job '{s}'", .{ s.id, j.id });
            try step_ids.put(alloc, s.id, {});
            if (s.shell) |sh| {
                var ok = false;
                for (known_shells) |k| {
                    if (std.mem.eql(u8, k, sh)) ok = true;
                }
                if (!ok) try addWarn(diags, s.src_line, 1, "unknown shell '{s}'", .{sh});
            }
        }
    }
    // Cycle detection over base ids.
    const Color = enum { white, grey, black };
    var color: std.StringArrayHashMapUnmanaged(Color) = .empty;
    for (ids.keys()) |id| try color.put(alloc, id, .white);
    const Ctx = struct {
        jobs: []const ir.Job,
        color: *std.StringArrayHashMapUnmanaged(Color),
        diags: *yaml.Diags,
        alloc: std.mem.Allocator,
        fn needsOf(self: @This(), id: []const u8) [][]const u8 {
            const j = firstJobWithId(self.jobs, id) orelse return &.{};
            return j.needs;
        }
        fn dfs(self: @This(), id: []const u8) !void {
            const c = self.color.get(id) orelse return;
            if (c == .grey) {
                const line = if (firstJobWithId(self.jobs, id)) |jj| jj.src_line else 0;
                try self.diags.add(line, 1, "dependency cycle involving job '{s}'", .{id});
                return;
            }
            if (c == .black) return;
            try self.color.put(self.alloc, id, .grey);
            for (self.needsOf(id)) |n| try self.dfs(n);
            try self.color.put(self.alloc, id, .black);
        }
    };
    const ctx = Ctx{ .jobs = jobs, .color = &color, .diags = diags, .alloc = alloc };
    for (ids.keys()) |id| try ctx.dfs(id);
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

    try checkKeys(diags, jn, "job", &job_supported_keys, &job_known_unsupported_keys);

    const container_image = if (jn.get("container")) |c| switch (c.data) {
        .scalar => |s| s,
        .map => if (c.get("image")) |img| img.scalarOr("") else "",
        .seq => "",
    } else "";

    return .{
        .id = job_id,
        .display_name = job_id,
        .runs_on = if (jn.get("runs-on")) |r| r.scalarOr("") else "",
        .needs = try needsList(alloc, jn.get("needs")),
        .env = try env.toOwnedSlice(alloc),
        .steps = try steps.toOwnedSlice(alloc),
        .src_line = jn.line,
        .container_image = container_image,
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
                if (vals.items.len == 0) {
                    try diags.add(e.value_ptr.line, e.value_ptr.col, "matrix axis '{s}' has no values", .{axis_name});
                    continue;
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
    // readMatrix never appends an axis with 0 values (empty axes are a hard
    // diagnostic), so plain lengths are safe here — no @max(...,1) needed.
    var total: usize = 1;
    for (axes) |ax| total *= ax.values.len;
    var combo_idx: usize = 0;
    while (combo_idx < total) : (combo_idx += 1) {
        var combo: std.ArrayList(ir.EnvPair) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        var rem = combo_idx;
        var stride: usize = total;
        for (axes) |ax| {
            stride /= ax.values.len;
            const v = ax.values[(rem / stride) % ax.values.len];
            rem %= stride;
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
    const run_node = n.get("run");
    const uses_node = n.get("uses");
    // 'with' is only meaningful (and only accepted silently) on `uses` steps;
    // on a `run` step it is an unknown key.
    if (uses_node != null) {
        var allowed: [step_supported_keys.len + 1][]const u8 = undefined;
        @memcpy(allowed[0..step_supported_keys.len], &step_supported_keys);
        allowed[step_supported_keys.len] = "with";
        try checkKeys(diags, n, "step", &allowed, &step_known_unsupported_keys);
    } else {
        try checkKeys(diags, n, "step", &step_supported_keys, &step_known_unsupported_keys);
    }
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
        .src_line = n.line,
    };
}
