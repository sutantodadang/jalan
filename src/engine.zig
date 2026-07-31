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
const backend_mod = @import("backend.zig");
const runner = @import("actions/runner.zig");

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

test "spawn failure (unknown shell) respects continue-on-error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p_cont = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - run: echo unreachable
        \\        shell: nosuchshell
        \\        continue-on-error: true
        \\      - run: echo ok
    );
    const report = try run(a, p_cont, .{});
    try std.testing.expectEqual(StepStatus.failed, report.jobs[0].steps[0].status);
    try std.testing.expectEqual(StepStatus.success, report.jobs[0].steps[1].status);
    try std.testing.expectEqual(JobStatus.success, report.jobs[0].status);

    const p_fail = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - run: echo unreachable
        \\        shell: nosuchshell
        \\      - run: echo ok
    );
    const report2 = try run(a, p_fail, .{});
    try std.testing.expectEqual(StepStatus.failed, report2.jobs[0].steps[0].status);
    try std.testing.expectEqual(JobStatus.failed, report2.jobs[0].status);
}

test "independent jobs run concurrently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Relative bound instead of an absolute wall-clock cliff: measure one 300ms
    // sleep job alone, then two of them in parallel, and assert the parallel
    // run is well under 2x the single-job time. This proves concurrency
    // without flaking on slow/loaded CI runners (process spawn + AV scans).
    const single_p = try parseFixture(a,
        \\jobs:
        \\  a:
        \\    steps:
        \\      - run: sleep 0.3
        \\        shell: sh
    );
    const t0 = std.time.milliTimestamp();
    const single_report = try run(a, single_p, .{});
    const single_elapsed = std.time.milliTimestamp() - t0;
    try std.testing.expect(single_report.ok());

    const p = try parseFixture(a,
        \\jobs:
        \\  a:
        \\    steps:
        \\      - run: sleep 0.3
        \\        shell: sh
        \\  b:
        \\    steps:
        \\      - run: sleep 0.3
        \\        shell: sh
    );
    const t1 = std.time.milliTimestamp();
    const report = try run(a, p, .{ .max_parallel = 2 });
    const parallel_elapsed = std.time.milliTimestamp() - t1;
    try std.testing.expect(report.ok());

    // Floor guard: if the single-job baseline itself is too small to measure
    // meaningfully, skip the ratio assert rather than risk a divide-by-noise flake.
    if (single_elapsed >= 50) {
        try std.testing.expect(parallel_elapsed < 2 * single_elapsed);
    }
}

test "parallel spawn failures do not race: each job gets correctly attributed stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\jobs:
        \\  a:
        \\    steps:
        \\      - run: echo unreachable
        \\        shell: nosuchshell
        \\  b:
        \\    steps:
        \\      - run: echo unreachable
        \\        shell: nosuchshell
    );
    const report = try run(a, p, .{ .max_parallel = 2 });
    try std.testing.expect(!report.ok());
    for (report.jobs) |j| {
        try std.testing.expectEqual(JobStatus.failed, j.status);
        try std.testing.expectEqual(StepStatus.failed, j.steps[0].status);
        try std.testing.expect(std.mem.indexOf(u8, j.steps[0].stderr, "unknown shell 'nosuchshell'") != null);
    }
}

test "workflow-level env value interpolates matrix context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\env:
        \\  TAG: ${{ matrix.os }}
        \\jobs:
        \\  build:
        \\    strategy:
        \\      matrix:
        \\        os: [linux]
        \\    steps:
        \\      - run: echo "$TAG"
        \\        shell: sh
    );
    const report = try run(a, p, .{});
    try std.testing.expect(report.ok());
    try std.testing.expect(std.mem.indexOf(u8, report.jobs[0].steps[0].stdout, "linux") != null);
}

test "script interpolation failure fails the step without spawning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - run: echo ${{ format('{9}', 'x') }}
    );
    const report = try run(a, p, .{});
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(JobStatus.failed, report.jobs[0].status);
    try std.testing.expectEqual(StepStatus.failed, report.jobs[0].steps[0].status);
    try std.testing.expectEqual(@as(usize, 0), report.jobs[0].steps[0].stdout.len);
}

test "uses step runs end-to-end through the action runner (native backend)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - uses: ./testdata/actions/hello
        \\        with:
        \\          who: engine
    );
    const report = try run(a, p, .{});
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(StepStatus.success, report.jobs[0].steps[0].status);
    try std.testing.expect(std.mem.indexOf(u8, report.jobs[0].steps[0].stdout, "hello engine") != null);
}

test "job env and step env flow into uses actions and composite children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\env:
        \\  JOBVAR: hello
        \\jobs:
        \\  j:
        \\    steps:
        \\      - uses: ./testdata/actions/envcheck
        \\        env:
        \\          STEPVAR: world
    );
    const report = try run(a, p, .{});
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(StepStatus.success, report.jobs[0].steps[0].status);
    try std.testing.expect(std.mem.indexOf(u8, report.jobs[0].steps[0].stdout, "job=hello step=world") != null);
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
    // Called from worker threads under parallel job execution — must be thread-safe.
    log: ?*const fn (line: []const u8) void = null,
    // null -> backend_mod.native(). Lets callers swap in container/other backends
    // without touching runJob's step-loop logic.
    exec_backend: ?backend_mod.Backend = null,
    // Threaded to runUses's ref-resolution cache; forces a fresh fetch of
    // GitHub-hosted actions instead of reusing a cached checkout.
    force_pull: bool = false,
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
    var mutex = std.Thread.Mutex{};
    var completed: usize = 0;
    const max_par = @max(opts.max_parallel, 1);

    while (completed < p.jobs.len) {
        var ready: std.ArrayList(usize) = .empty;
        for (p.jobs, 0..) |job, i| {
            if (!done[i] and needsSatisfied(p, done, job)) try ready.append(alloc, i);
        }
        if (ready.items.len == 0) return error.InternalError; // cycle — validated upstream, defensive

        var batch_start: usize = 0;
        while (batch_start < ready.items.len) {
            const batch = ready.items[batch_start..@min(batch_start + max_par, ready.items.len)];
            const threads = try alloc.alloc(?std.Thread, batch.len);
            const Ctx = struct {
                fn work(
                    pi: ir.Pipeline,
                    ji: usize,
                    o: RunOptions,
                    sh: *Shared,
                    mx: *std.Thread.Mutex,
                    out: *JobResult,
                    res: []JobResult,
                    dn: []bool,
                ) void {
                    // Each worker thread gets its own arena off page_allocator: caller
                    // arenas are not thread-safe, so per-thread work cannot share one.
                    var thread_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer thread_arena.deinit();
                    const ta = thread_arena.allocator();
                    const r = runJob(ta, pi, pi.jobs[ji], ji, o, sh, res, dn, mx) catch |e| {
                        out.* = .{ .job_index = ji, .display_name = pi.jobs[ji].display_name, .status = .failed, .steps = &.{} };
                        std.debug.print("internal error in job: {s}\n", .{@errorName(e)});
                        return;
                    };
                    // Copy result out of the thread arena (which dies with this
                    // function) into the caller arena, guarded by the shared mutex.
                    mx.lock();
                    defer mx.unlock();
                    out.* = copyResult(sh.alloc, r) catch |e| blk: {
                        // Do NOT fall back to `r`: its strings live in the thread
                        // arena, which `defer thread_arena.deinit()` frees right
                        // after this function returns — aliasing it would be a
                        // use-after-free on every later read of this job's result.
                        // display_name comes from the pipeline (caller-arena memory)
                        // instead, so it stays valid; steps are lost but status is
                        // honest (.failed) rather than silently wrong.
                        std.debug.print("failed to copy job result: {s}\n", .{@errorName(e)});
                        break :blk .{ .job_index = ji, .display_name = pi.jobs[ji].display_name, .status = .failed, .steps = &.{} };
                    };
                }
            };
            for (batch, 0..) |ji, bi| {
                threads[bi] = std.Thread.spawn(.{}, Ctx.work, .{ p, ji, opts, &shared, &mutex, &results[ji], results, done }) catch null;
                if (threads[bi] == null) {
                    // Spawn failed (e.g. thread-limit exhaustion) — fall back to inline execution.
                    Ctx.work(p, ji, opts, &shared, &mutex, &results[ji], results, done);
                }
            }
            for (threads) |t| if (t) |th| th.join();
            for (batch) |ji| {
                done[ji] = true;
                completed += 1;
            }
            batch_start += batch.len;
        }
    }
    return .{ .jobs = results };
}

fn copyResult(alloc: std.mem.Allocator, r: JobResult) !JobResult {
    const steps = try alloc.alloc(StepResult, r.steps.len);
    for (steps, r.steps) |*d, s| d.* = .{
        .name = try alloc.dupe(u8, s.name),
        .status = s.status,
        .exit_code = s.exit_code,
        .duration_ms = s.duration_ms,
        .stdout = try alloc.dupe(u8, s.stdout),
        .stderr = try alloc.dupe(u8, s.stderr),
    };
    return .{
        .job_index = r.job_index,
        .display_name = try alloc.dupe(u8, r.display_name),
        .status = r.status,
        .steps = steps,
    };
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
    mutex: *std.Thread.Mutex,
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
    // Interpolate workflow/job-level env values against the github/matrix/secrets
    // context built above. NOTE: env entries cannot reference other env entries
    // (this is a single pass, not iterative resolution) — only github.*, matrix.*,
    // and secrets.* are available here.
    for (merged_env.items) |*e| {
        e.value = expr.interpolate(alloc, e.value, &env) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            logJob(opts, alloc, job, try std.fmt.allocPrint(alloc, "warning: expression error in env {s}, job failed", .{e.name}));
            return .{ .job_index = index, .display_name = job.display_name, .status = .failed, .steps = steps };
        };
    }
    for (merged_env.items) |e| try env.put(alloc, try key2(alloc, "env", e.name), e.value);
    {
        // shared.job_outputs is read here and written post-step below; other
        // worker threads may be doing either concurrently, so both are locked.
        // Key/value strings are duped into this job's own allocator (thread
        // arena under parallel execution) since the shared map's storage
        // lives in the caller arena and dies independently of any one thread.
        mutex.lock();
        defer mutex.unlock();
        var it = shared.job_outputs.iterator();
        while (it.next()) |e| {
            // stored as "jobid.outputs.key" -> expose as needs.jobid.outputs.key
            const path = try std.fmt.allocPrint(alloc, "needs.{s}", .{e.key_ptr.*});
            const val = try alloc.dupe(u8, e.value_ptr.*);
            try env.put(alloc, path, val);
        }
    }

    const b = opts.exec_backend orelse backend_mod.native();
    var handle = b.setupJob(alloc, job, cwd, opts.log) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        // infra failure: whole job fails before any step runs
        logJob(opts, alloc, job, "backend setup failed for job");
        return .{ .job_index = index, .display_name = job.display_name, .status = .failed, .steps = steps };
    };
    defer b.teardownJob(alloc, &handle);

    var job_status: JobStatus = .success;
    step_loop: for (job.steps, 0..) |step, si| {
        if (opts.step_filter) |f| if (!std.mem.eql(u8, f, step.id)) continue;
        if (job_status == .failed) break;
        const t0 = std.time.milliTimestamp();

        if (step.cond) |cond| {
            const ast = expr.parseExpr(alloc, cond) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                logLine(opts, alloc, job, step, "warning: bad if expression, step skipped");
                continue;
            };
            const v = expr.eval(alloc, ast, &env) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                logLine(opts, alloc, job, step, "warning: if evaluation failed, step skipped");
                continue;
            };
            if (!v.truthy()) continue; // stays .skipped
        }
        if (opts.dry_run) {
            logLine(opts, alloc, job, step, "[dry-run] would run step");
            steps[si].status = .success;
            continue;
        }

        if (step.kind == .uses) {
            // Interpolate each `with:` value against the step's expr Env — same
            // policy as step.env below: an expression error fails the step
            // loudly (never runs the action un-interpolated), OOM propagates.
            var with_list: std.ArrayList(ir.EnvPair) = .empty;
            for (step.with) |w| {
                const val = expr.interpolate(alloc, w.value, &env) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    const msg = try std.fmt.allocPrint(alloc, "warning: expression error in with {s}, step failed", .{w.name});
                    logLine(opts, alloc, job, step, msg);
                    steps[si] = .{ .name = step.name, .status = .failed, .exit_code = -1, .duration_ms = 0, .stdout = "", .stderr = msg };
                    if (!step.continue_on_error) job_status = .failed;
                    continue :step_loop;
                };
                try with_list.append(alloc, .{ .name = w.name, .value = val });
            }
            // Job env plus this step's `env:` map flow into the action — for
            // composite children they are the child process environment, and
            // for node/docker actions they join the INPUT_* entries. Same
            // interpolation/failure policy as the `.run` branch below.
            var step_env: std.ArrayList(ir.EnvPair) = .empty;
            try step_env.appendSlice(alloc, merged_env.items);
            for (step.env) |e| {
                const val = expr.interpolate(alloc, e.value, &env) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    const msg = try std.fmt.allocPrint(alloc, "warning: expression error in env {s}, step failed", .{e.name});
                    logLine(opts, alloc, job, step, msg);
                    steps[si] = .{ .name = step.name, .status = .failed, .exit_code = -1, .duration_ms = 0, .stdout = "", .stderr = msg };
                    if (!step.continue_on_error) job_status = .failed;
                    continue :step_loop;
                };
                try step_env.append(alloc, .{ .name = e.name, .value = val });
                try env.put(alloc, try key2(alloc, "env", e.name), val);
            }
            var err_msg: ?[]const u8 = null;
            const outcome = runner.runUses(alloc, step, with_list.items, step_env.items, b, &handle, &env, opts.log, opts.force_pull, &err_msg) catch {
                steps[si] = .{ .name = step.name, .status = .failed, .exit_code = -1, .duration_ms = 0, .stdout = "", .stderr = err_msg orelse "spawn failed" };
                if (!step.continue_on_error) job_status = .failed;
                continue;
            };
            const ok = try applyStepOutcome(alloc, step, si, t0, outcome, steps, job, shared, mutex, &env);
            if (!ok and !step.continue_on_error) job_status = .failed;
            continue;
        }

        // Interpolate script, env values, workdir. Any expression error here means
        // the step would otherwise run un-interpolated (raw `${{ ... }}` text) —
        // instead we fail the step loudly and never spawn it.
        const script = expr.interpolate(alloc, step.script, &env) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const msg = "warning: expression error in script, step failed";
            logLine(opts, alloc, job, step, msg);
            steps[si] = .{ .name = step.name, .status = .failed, .exit_code = -1, .duration_ms = 0, .stdout = "", .stderr = msg };
            if (!step.continue_on_error) job_status = .failed;
            continue;
        };
        var spawn_env: std.ArrayList(ir.EnvPair) = .empty;
        try spawn_env.appendSlice(alloc, merged_env.items);
        for (step.env) |e| {
            const val = expr.interpolate(alloc, e.value, &env) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                const msg = try std.fmt.allocPrint(alloc, "warning: expression error in env {s}, step failed", .{e.name});
                logLine(opts, alloc, job, step, msg);
                steps[si] = .{ .name = step.name, .status = .failed, .exit_code = -1, .duration_ms = 0, .stdout = "", .stderr = msg };
                if (!step.continue_on_error) job_status = .failed;
                continue :step_loop;
            };
            try spawn_env.append(alloc, .{ .name = e.name, .value = val });
            try env.put(alloc, try key2(alloc, "env", e.name), val);
        }
        var patched = step;
        patched.script = script;
        const workdir = if (step.workdir) |w| expr.interpolate(alloc, w, &env) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const msg = "warning: expression error in working-directory, step failed";
            logLine(opts, alloc, job, step, msg);
            steps[si] = .{ .name = step.name, .status = .failed, .exit_code = -1, .duration_ms = 0, .stdout = "", .stderr = msg };
            if (!step.continue_on_error) job_status = .failed;
            continue;
        } else null;

        var err_msg: ?[]const u8 = null;
        const outcome = b.runStep(alloc, &handle, patched, spawn_env.items, workdir, &err_msg) catch {
            steps[si] = .{ .name = step.name, .status = .failed, .exit_code = -1, .duration_ms = 0, .stdout = "", .stderr = err_msg orelse "spawn failed" };
            if (!step.continue_on_error) job_status = .failed;
            continue;
        };
        const ok = try applyStepOutcome(alloc, step, si, t0, outcome, steps, job, shared, mutex, &env);
        if (!ok and !step.continue_on_error) job_status = .failed;
    }
    return .{ .job_index = index, .display_name = job.display_name, .status = job_status, .steps = steps };
}

/// Shared `.run`/`.uses` outcome plumbing: fills in the step's `StepResult`
/// (status/exit_code/duration/stdout/stderr) and publishes its outputs into
/// both the job-local expr Env (`steps.<id>.outputs.<name>`) and the
/// cross-job shared map (`needs.<jobid>.outputs.<name>` for dependents).
/// Returns whether the step succeeded (exit_code == 0); callers decide what
/// that means for `job_status` (continue-on-error is a per-branch concern).
fn applyStepOutcome(
    alloc: std.mem.Allocator,
    step: ir.Step,
    si: usize,
    t0: i64,
    outcome: backend_mod.StepOutcome,
    steps: []StepResult,
    job: ir.Job,
    shared: *Shared,
    mutex: *std.Thread.Mutex,
    env: *expr.Env,
) !bool {
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
        // Values put INTO the shared map must be duped with shared.alloc (caller
        // arena) under the lock — the thread arena that owns jk/o.value dies at
        // job end, but the map itself lives for the whole run.
        mutex.lock();
        defer mutex.unlock();
        const jk_dup = try shared.alloc.dupe(u8, jk);
        const val_dup = try shared.alloc.dupe(u8, o.value);
        try shared.job_outputs.put(shared.alloc, jk_dup, val_dup);
    }
    return ok;
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

fn logJob(opts: RunOptions, alloc: std.mem.Allocator, job: ir.Job, msg: []const u8) void {
    if (opts.log) |f| {
        const line = std.fmt.allocPrint(alloc, "[{s}] {s}", .{ job.display_name, msg }) catch return;
        f(line);
    }
}
