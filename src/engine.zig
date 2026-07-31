//! Engine: sequential DAG execution over pipeline jobs.
//!
//! Kahn-style topological execution over job `needs` edges (acyclic — validated
//! upstream by the frontend). Task 12 will replace the sequential scan in `run`
//! with parallel batches; `runJob` stays a clean, self-contained unit so that
//! swap is a small diff.
const std = @import("std");
const ir = @import("ir.zig");
const gha = @import("frontend/gha.zig");
const yaml = @import("yaml.zig");
const expr = @import("expr.zig");
const native = @import("backend/native.zig");

fn parseFixture(a: std.mem.Allocator, src: []const u8) !ir.Pipeline {
    var diags = yaml.Diags.init(a);
    return gha.parseWorkflow(a, "t.yml", src, &diags);
}

test "jobs run in dependency order and outputs flow through needs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // NOTE: the `>> "$GITHUB_OUTPUT"` syntax below is sh syntax. On Windows the
    // engine's default shell resolves to pwsh, where redirection/`$VAR` behave
    // differently, so the fixture forces `shell: sh` on the producer step. This
    // assumes Git-Bash `sh` is on PATH — true on this dev machine, and jalan's
    // own CI runners for Windows are expected to have it too (see task-11 brief).
    const p = try parseFixture(a,
        \\jobs:
        \\  producer:
        \\    steps:
        \\      - id: emit
        \\        run: echo "ver=42" >> "$GITHUB_OUTPUT"
        \\        shell: sh
        \\  consumer:
        \\    needs: producer
        \\    steps:
        \\      - run: echo "got ${{ needs.producer.outputs.ver }}"
    );
    const report = try run(a, p, .{});
    try std.testing.expect(report.ok());
    const consumer = report.jobs[1];
    try std.testing.expect(std.mem.indexOf(u8, consumer.steps[0].stdout, "got 42") != null);
}

test "failed job skips dependents, continue-on-error does not fail job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\jobs:
        \\  flaky:
        \\    steps:
        \\      - run: exit 1
        \\        continue-on-error: true
        \\      - run: exit 1
        \\  after:
        \\    needs: flaky
        \\    steps:
        \\      - run: echo never
    );
    const report = try run(a, p, .{});
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(JobStatus.failed, report.jobs[0].status);
    try std.testing.expectEqual(JobStatus.skipped, report.jobs[1].status);
    try std.testing.expectEqual(StepStatus.failed, report.jobs[0].steps[0].status);
}

test "if condition false skips step; dry run executes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - run: echo skipme
        \\        if: github.ref == 'refs/heads/other'
        \\      - run: echo runme
    );
    const report = try run(a, p, .{});
    try std.testing.expectEqual(StepStatus.skipped, report.jobs[0].steps[0].status);
    try std.testing.expectEqual(StepStatus.success, report.jobs[0].steps[1].status);

    const dry = try run(a, p, .{ .dry_run = true });
    try std.testing.expect(dry.ok());
    try std.testing.expectEqual(@as(usize, 0), dry.jobs[0].steps[1].stdout.len);
}

pub const StepStatus = enum { success, failed, skipped };
pub const JobStatus = enum { success, failed, skipped };

pub const StepResult = struct {
    name: []const u8,
    status: StepStatus,
    exit_code: i32,
    duration_ms: u64,
    stdout: []const u8,
    stderr: []const u8,
};

pub const JobResult = struct {
    job_index: usize,
    display_name: []const u8,
    status: JobStatus,
    steps: []StepResult,
};

pub const Report = struct {
    jobs: []JobResult,

    pub fn ok(self: Report) bool {
        for (self.jobs) |j| if (j.status == .failed) return false;
        return true;
    }
};

pub const RunOptions = struct {
    job_filter: ?[]const u8 = null,
    step_filter: ?[]const u8 = null,
    dry_run: bool = false,
    max_parallel: usize = 4,
    extra_env: []const ir.EnvPair = &.{},
    secrets: []const ir.EnvPair = &.{},
    matrix_filter: []const ir.EnvPair = &.{},
    log: ?*const fn (line: []const u8) void = null,
};

const Shared = struct {
    alloc: std.mem.Allocator,
    // "jobid.outputs.key" -> value, merged across matrix copies (last writer wins).
    job_outputs: std.StringHashMapUnmanaged([]const u8) = .empty,
};

pub fn run(alloc: std.mem.Allocator, p: ir.Pipeline, opts: RunOptions) error{ OutOfMemory, InternalError }!Report {
    const results = try alloc.alloc(JobResult, p.jobs.len);
    const done = try alloc.alloc(bool, p.jobs.len);
    @memset(done, false);
    var shared = Shared{ .alloc = alloc };
    var completed: usize = 0;

    while (completed < p.jobs.len) {
        var progressed = false;
        for (p.jobs, 0..) |job, i| {
            if (done[i]) continue;
            if (!needsSatisfied(p, done, job)) continue;
            results[i] = runJob(alloc, p, job, i, opts, &shared, results, done) catch return error.OutOfMemory;
            done[i] = true;
            completed += 1;
            progressed = true;
        }
        if (!progressed) return error.InternalError; // cycle — validated upstream, defensive
    }
    return .{ .jobs = results };
}

fn needsSatisfied(p: ir.Pipeline, done: []bool, job: ir.Job) bool {
    for (job.needs) |n| {
        var all_done = true;
        for (p.jobs, 0..) |other, oi| {
            if (std.mem.eql(u8, other.id, n) and !done[oi]) all_done = false;
        }
        if (!all_done) return false;
    }
    return true;
}

fn needsFailed(p: ir.Pipeline, results: []JobResult, done: []bool, job: ir.Job) bool {
    for (job.needs) |n| {
        for (p.jobs, 0..) |other, oi| {
            if (std.mem.eql(u8, other.id, n) and done[oi] and results[oi].status != .success)
                return true;
        }
    }
    return false;
}

fn runJob(
    alloc: std.mem.Allocator,
    p: ir.Pipeline,
    job: ir.Job,
    index: usize,
    opts: RunOptions,
    shared: *Shared,
    results: []JobResult,
    done: []bool,
) !JobResult {
    var steps = try alloc.alloc(StepResult, job.steps.len);
    for (steps, job.steps) |*r, s|
        r.* = .{ .name = s.name, .status = .skipped, .exit_code = 0, .duration_ms = 0, .stdout = "", .stderr = "" };
    const skipped = JobResult{ .job_index = index, .display_name = job.display_name, .status = .skipped, .steps = steps };

    if (opts.job_filter) |f| if (!std.mem.eql(u8, f, job.id)) return skipped;
    if (!gha.matrixMatches(job, opts.matrix_filter)) return skipped;
    if (needsFailed(p, results, done, job)) return skipped;

    // Build base expression environment for this job.
    var env = expr.Env{};
    const cwd = std.fs.cwd().realpathAlloc(alloc, ".") catch ".";
    try env.put(alloc, "github.ref", "refs/heads/main");
    try env.put(alloc, "github.event_name", "workflow_dispatch");
    try env.put(alloc, "github.sha", "0000000000000000000000000000000000000000");
    try env.put(alloc, "github.actor", "jalan");
    try env.put(alloc, "github.workspace", cwd);
    for (job.matrix) |m| try env.put(alloc, try key2(alloc, "matrix", m.name), m.value);
    for (opts.secrets) |s| try env.put(alloc, try key2(alloc, "secrets", s.name), s.value);
    var merged_env: std.ArrayList(ir.EnvPair) = .empty;
    try merged_env.appendSlice(alloc, job.env);
    try merged_env.appendSlice(alloc, opts.extra_env);
    for (merged_env.items) |e| try env.put(alloc, try key2(alloc, "env", e.name), e.value);
    var it = shared.job_outputs.iterator();
    while (it.next()) |e| {
        // stored as "jobid.outputs.key" -> expose as needs.jobid.outputs.key
        const path = try std.fmt.allocPrint(alloc, "needs.{s}", .{e.key_ptr.*});
        try env.put(alloc, path, e.value_ptr.*);
    }

    var job_status: JobStatus = .success;
    for (job.steps, 0..) |step, si| {
        if (opts.step_filter) |f| if (!std.mem.eql(u8, f, step.id)) continue;
        if (job_status == .failed) break;
        const t0 = std.time.milliTimestamp();

        if (step.cond) |cond| {
            const ast = expr.parseExpr(alloc, cond) catch {
                logLine(opts, alloc, job, step, "warning: bad if expression, step skipped");
                continue;
            };
            const v = expr.eval(alloc, ast, &env) catch {
                logLine(opts, alloc, job, step, "warning: if evaluation failed, step skipped");
                continue;
            };
            if (!v.truthy()) continue; // stays .skipped
        }
        if (step.kind == .uses) {
            logLine(opts, alloc, job, step, "skipped 'uses' step (phase 1)");
            continue;
        }
        if (opts.dry_run) {
            logLine(opts, alloc, job, step, "[dry-run] would run step");
            steps[si].status = .success;
            continue;
        }

        // Interpolate script, env values, workdir.
        const script = expr.interpolate(alloc, step.script, &env) catch step.script;
        var spawn_env: std.ArrayList(ir.EnvPair) = .empty;
        try spawn_env.appendSlice(alloc, merged_env.items);
        for (step.env) |e| {
            const val = expr.interpolate(alloc, e.value, &env) catch e.value;
            try spawn_env.append(alloc, .{ .name = e.name, .value = val });
            try env.put(alloc, try key2(alloc, "env", e.name), val);
        }
        var patched = step;
        patched.script = script;
        const workdir = if (step.workdir) |w| expr.interpolate(alloc, w, &env) catch w else null;

        const outcome = native.runStep(alloc, patched, spawn_env.items, workdir) catch {
            steps[si] = .{ .name = step.name, .status = .failed, .exit_code = -1, .duration_ms = 0, .stdout = "", .stderr = native.last_spawn_error_msg orelse "spawn failed" };
            job_status = .failed;
            continue;
        };
        const dur: u64 = @intCast(@max(std.time.milliTimestamp() - t0, 0));
        const ok = outcome.exit_code == 0;
        steps[si] = .{
            .name = step.name,
            .status = if (ok) .success else .failed,
            .exit_code = outcome.exit_code,
            .duration_ms = dur,
            .stdout = outcome.stdout,
            .stderr = outcome.stderr,
        };
        for (outcome.outputs) |o| {
            try env.put(alloc, try std.fmt.allocPrint(alloc, "steps.{s}.outputs.{s}", .{ step.id, o.name }), o.value);
            const jk = try std.fmt.allocPrint(alloc, "{s}.outputs.{s}", .{ job.id, o.name });
            try shared.job_outputs.put(alloc, jk, o.value);
        }
        if (!ok and !step.continue_on_error) job_status = .failed;
    }
    return .{ .job_index = index, .display_name = job.display_name, .status = job_status, .steps = steps };
}

fn key2(alloc: std.mem.Allocator, root: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ root, name });
}

fn logLine(opts: RunOptions, alloc: std.mem.Allocator, job: ir.Job, step: ir.Step, msg: []const u8) void {
    if (opts.log) |f| {
        const line = std.fmt.allocPrint(alloc, "[{s}/{s}] {s}", .{ job.display_name, step.name, msg }) catch return;
        f(line);
    }
}
