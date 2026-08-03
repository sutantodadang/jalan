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
const action_resolve = @import("actions/resolve.zig");
const snap_manifest = @import("snap/manifest.zig");
const snap_store = @import("snap/store.zig");
const snap_restore = @import("snap/restore.zig");
const safe_path = @import("snap/path.zig");
const runrecord = @import("snap/runrecord.zig");
const cache = @import("cache.zig");
const debug_mod = @import("debug.zig");

fn parseFixture(a: std.mem.Allocator, src: []const u8) !ir.Pipeline {
    var diags = yaml.Diags.init(a);
    return gha.parseWorkflow(a, "t.yml", src, &diags);
}

const TestPromptScript = struct {
    commands: []const debug_mod.PromptCmd,
    index: usize = 0,
    saw_state: bool = false,
    saw_masked_secret: bool = false,
    saw_env_foo: bool = false,
    last_kind: ?debug_mod.PromptKind = null,
    last_job_index: usize = 0,
    last_job_id: []const u8 = "",
    last_step_id: []const u8 = "",
    last_step_index: usize = 0,

    fn next(ctx: ?*anyopaque, state: debug_mod.PromptState) debug_mod.PromptCmd {
        const self: *TestPromptScript = @ptrCast(@alignCast(ctx.?));
        self.saw_state = true;
        self.last_kind = state.kind;
        self.last_job_index = state.job_index;
        self.last_job_id = state.job_id;
        self.last_step_id = state.step_id;
        self.last_step_index = state.step_index;
        for (state.effective_env) |pair| {
            if (std.mem.eql(u8, pair.value, "***")) self.saw_masked_secret = true;
            if (std.mem.eql(u8, pair.name, "env.FOO") and std.mem.eql(u8, pair.value, "bar")) self.saw_env_foo = true;
        }
        if (self.index >= self.commands.len) return .continue_;
        defer self.index += 1;
        return self.commands[self.index];
    }
};

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

test "manual job is skipped without --job (dependent skipped, not failed); --job runs it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var man_steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo hi" }};
    var dep_steps = [_]ir.Step{.{ .id = "s2", .name = "s2", .kind = .run, .script = "echo dep" }};
    var needs = [_][]const u8{"man"};
    var jobs = [_]ir.Job{
        .{ .id = "man", .display_name = "man", .steps = &man_steps, .manual = true },
        .{ .id = "dep", .display_name = "dep", .needs = &needs, .steps = &dep_steps },
    };
    const p = ir.Pipeline{ .name = "p", .source_path = "x.yml", .jobs = &jobs };

    const report = try run(a, p, .{});
    try std.testing.expectEqual(JobStatus.skipped, report.jobs[0].status);
    try std.testing.expectEqual(JobStatus.skipped, report.jobs[1].status);

    const report2 = try run(a, p, .{ .job_filter = "man" });
    try std.testing.expectEqual(JobStatus.success, report2.jobs[0].status);
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

test "always() step runs after a prior step fails; without it stays skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - run: exit 1
        \\      - run: echo cleanup
        \\        if: always()
    );
    const report = try run(a, p, .{});
    try std.testing.expectEqual(JobStatus.failed, report.jobs[0].status);
    try std.testing.expectEqual(StepStatus.failed, report.jobs[0].steps[0].status);
    try std.testing.expectEqual(StepStatus.success, report.jobs[0].steps[1].status);

    const p2 = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - run: exit 1
        \\      - run: echo cleanup
    );
    const report2 = try run(a, p2, .{});
    try std.testing.expectEqual(JobStatus.failed, report2.jobs[0].status);
    try std.testing.expectEqual(StepStatus.skipped, report2.jobs[0].steps[1].status);
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

test "snapshots: step boundaries captured and run record written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/engsnap";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(ws);
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/f.txt", .{ws}), .data = "workspace-content" });
    const store_root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);

    const p = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: s1
        \\        run: echo one
        \\      - id: s2
        \\        run: echo two
    );
    const report = try run(a, p, .{
        .snapshot = true,
        .store_root = store_root,
        .workspace_abs = ws_abs,
        .run_id = "test-run-1",
    });
    try std.testing.expect(report.ok());

    // Both step-boundary manifests exist and carry the expr env.
    const m0 = try snap_manifest.load(a, store_root, "snapshots/test-run-1/j/000-s1.json");
    try std.testing.expectEqualStrings("s1", m0.step_id);
    try std.testing.expectEqual(@as(u32, 0), m0.step_index);
    var found_ref = false;
    for (m0.env) |e| {
        if (std.mem.eql(u8, e.name, "github.ref")) found_ref = true;
    }
    try std.testing.expect(found_ref);
    try std.testing.expectEqual(@as(usize, 1), m0.files.len);
    _ = try snap_manifest.load(a, store_root, "snapshots/test-run-1/j/001-s2.json");

    // Run record: job + both steps success, snapshot paths recorded.
    const rec = try runrecord.load(a, store_root, "test-run-1");
    try std.testing.expectEqualStrings("test-run-1", rec.run_id);
    try std.testing.expectEqualStrings("success", rec.jobs[0].status);
    try std.testing.expectEqualStrings("success", rec.jobs[0].steps[0].status);
    try std.testing.expect(std.mem.indexOf(u8, rec.jobs[0].steps[0].snapshot, "000-s1.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, rec.jobs[0].steps[1].snapshot, "001-s2.json") != null);
}

test "snapshots off by default: no store writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/engsnap-off";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const store_root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const p = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: s1
        \\        run: echo one
    );
    const report = try run(a, p, .{ .store_root = store_root, .workspace_abs = a.dupe(u8, base) catch unreachable });
    try std.testing.expect(report.ok());
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(store_root, .{}));
}

test "cache: second run replays without re-executing, outputs still flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/engcache";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(ws);
    const store_root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);

    // s1 leaves proof of execution OUTSIDE the walked workspace (../execs.txt),
    // writes a deterministic file inside it (made.txt), and publishes an
    // output; s2 consumes the output. sh syntax (Git-Bash on this machine).
    const wf = try std.fmt.allocPrint(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: s1
        \\        run: echo exec >> ../execs.txt && echo made > made.txt && echo "ver=7" >> "$GITHUB_OUTPUT"
        \\        shell: sh
        \\        working-directory: {s}
        \\      - id: s2
        \\        run: echo "got ${{{{ steps.s1.outputs.ver }}}}"
        \\        shell: sh
        \\        working-directory: {s}
        \\
    , .{ ws, ws });
    const p = try parseFixture(a, wf);
    const opts = RunOptions{ .cache = true, .store_root = store_root, .workspace_abs = ws_abs };

    const r1 = try run(a, p, opts);
    try std.testing.expect(r1.ok());
    try std.testing.expect(std.mem.indexOf(u8, r1.jobs[0].steps[1].stdout, "got 7") != null);

    // Restore the workspace to run 1's starting state (empty) — the cache
    // key covers the pre-step tree, so identical inputs are required for a
    // hit. A non-idempotent step (e.g. appending in-workspace) correctly
    // misses because its input state changed.
    std.fs.cwd().deleteFile(try std.fmt.allocPrint(a, "{s}/made.txt", .{ws})) catch {};

    const r2 = try run(a, p, opts);
    try std.testing.expect(r2.ok());
    // Cache hit: s1 never re-executed (execs.txt still one line), but its
    // workspace write was materialized from the blob store and its outputs
    // were replayed so s2 still printed got 7.
    const execs = try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/execs.txt", .{base}), 1 << 20);
    try std.testing.expectEqualStrings("exec\n", execs);
    const made = try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/made.txt", .{ws}), 1 << 20);
    try std.testing.expectEqualStrings("made\n", made);
    try std.testing.expect(std.mem.indexOf(u8, r2.jobs[0].steps[1].stdout, "got 7") != null);
}

test "cache: secret-referencing steps are never cached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/engcache-sec";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(ws);
    const store_root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);

    const wf = try std.fmt.allocPrint(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: s1
        \\        run: echo exec >> count.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\        env:
        \\          T: ${{{{ secrets.TOKEN }}}}
        \\
    , .{ws});
    const p = try parseFixture(a, wf);
    const secrets = [_]ir.EnvPair{.{ .name = "TOKEN", .value = "abc" }};
    const opts = RunOptions{ .cache = true, .store_root = store_root, .workspace_abs = ws_abs, .secrets = &secrets };

    _ = try run(a, p, opts);
    _ = try run(a, p, opts);
    const count = try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/count.txt", .{ws}), 1 << 20);
    try std.testing.expectEqualStrings("exec\nexec\n", count);
}

test "cache: secret-derived job env is never persisted or replayed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/engcache-job-secret";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(ws);
    const store_root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);
    const wf = try std.fmt.allocPrint(a,
        \\env:
        \\  TOKEN: ${{{{ Secrets.TOKEN }}}}
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: s1
        \\        run: echo "$TOKEN" >> ../executions.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\
    , .{ws});
    const p = try parseFixture(a, wf);
    const secrets = [_]ir.EnvPair{.{ .name = "TOKEN", .value = "top-secret" }};
    const opts = RunOptions{ .cache = true, .store_root = store_root, .workspace_abs = ws_abs, .secrets = &secrets };
    _ = try run(a, p, opts);
    _ = try run(a, p, opts);
    const executions = try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/executions.txt", .{base}), 1024);
    try std.testing.expectEqualStrings("top-secret\ntop-secret\n", executions);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(try std.fmt.allocPrint(a, "{s}/cache", .{store_root}), .{}));
}

test "persisted environment secret placeholders round-trip without plaintext" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const secrets = [_]ir.EnvPair{.{ .name = "TOKEN", .value = "hunter2" }};
    const pairs = [_]ir.EnvPair{
        .{ .name = "secrets.TOKEN", .value = "hunter2" },
        .{ .name = "env.AUTH", .value = "Bearer hunter2" },
    };
    const protected = try protectPairs(a, &pairs, &secrets);
    for (protected) |pair| try std.testing.expect(std.mem.indexOf(u8, pair.value, "hunter2") == null);
    const restored = try rehydratePairs(a, protected, &secrets);
    try std.testing.expectEqualStrings("hunter2", restored[0].value);
    try std.testing.expectEqualStrings("Bearer hunter2", restored[1].value);
    try std.testing.expectError(error.MissingSecret, rehydrateSecretValue(a, protected[0].value, &.{}));
    try std.testing.expect(isSecretValue(.{ .secrets = &secrets }, "Bearer hunter2"));
}

test "cache materialization preflights all blobs before changing workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/cache-preflight";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    const root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    try std.fs.cwd().makePath(ws);
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/first.txt", .{ws}), .data = "original" });
    const good = try snap_store.writeBlob(a, root, "cached");
    const missing = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    const wrote = [_]cache.WroteFile{
        .{ .path = "first.txt", .blob = good },
        .{ .path = "second.txt", .blob = missing },
    };
    try std.testing.expectError(error.StoreIo, materializeEntry(a, root, try std.fs.cwd().realpathAlloc(a, ws), .{ .exit_code = 0, .wrote = &wrote }));
    try std.testing.expectEqualStrings("original", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/first.txt", .{ws}), 1024));
}

test "cache materialization recreates and deletes empty directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/cache-empty-dir";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(try std.fmt.allocPrint(a, "{s}/old-empty", .{ws}));
    const wrote = [_]cache.WroteFile{.{ .path = "new-empty", .mode = 0o755, .is_dir = true }};
    try materializeEntry(a, try std.fmt.allocPrint(a, "{s}/store", .{base}), try std.fs.cwd().realpathAlloc(a, ws), .{
        .exit_code = 0,
        .wrote = &wrote,
        .deleted = &.{"old-empty"},
    });
    var dir = try std.fs.cwd().openDir(try std.fmt.allocPrint(a, "{s}/new-empty", .{ws}), .{});
    dir.close();
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(try std.fmt.allocPrint(a, "{s}/old-empty", .{ws}), .{}));
}

test "resume: failed run resumes at the fixed step with restored workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/engresume";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(ws);
    const store_root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);

    // Run 1: s2 fails. sh syntax (Git-Bash on this machine).
    const wf_v1 = try std.fmt.allocPrint(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: s1
        \\        run: echo one > one.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\      - id: s2
        \\        run: echo two > two.txt; exit 1
        \\        shell: sh
        \\        working-directory: {s}
        \\      - id: s3
        \\        run: echo three > three.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\
    , .{ ws, ws, ws });
    const p1 = try parseFixture(a, wf_v1);
    const r1 = try run(a, p1, .{ .snapshot = true, .store_root = store_root, .workspace_abs = ws_abs, .run_id = "resume-1" });
    try std.testing.expect(!r1.ok());
    try std.testing.expectEqual(StepStatus.failed, r1.jobs[0].steps[1].status);
    try std.testing.expectEqual(StepStatus.skipped, r1.jobs[0].steps[2].status);

    // Workspace drift after the failure: junk the restore must remove.
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}/junk.txt", .{ws}), .data = "drift" });

    // Run 2: user fixed s2's script; resume at j/s2 under the same run id.
    const wf_v2 = try std.fmt.allocPrint(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: s1
        \\        run: echo one > one.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\      - id: s2
        \\        run: echo two > two.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\      - id: s3
        \\        run: echo three > three.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\
    , .{ ws, ws, ws });
    const p2 = try parseFixture(a, wf_v2);
    const r2 = try run(a, p2, .{
        .store_root = store_root,
        .workspace_abs = ws_abs,
        .run_id = "resume-1",
        .resume_from = .{ .run_id = "resume-1", .job_id = "j", .step = "s2" },
    });
    try std.testing.expect(r2.ok());
    // s1 skipped (already ran), s2+s3 executed.
    try std.testing.expectEqual(StepStatus.skipped, r2.jobs[0].steps[0].status);
    try std.testing.expectEqual(StepStatus.success, r2.jobs[0].steps[1].status);
    try std.testing.expectEqual(StepStatus.success, r2.jobs[0].steps[2].status);
    // Workspace: junk removed by restore, all step outputs present.
    std.fs.cwd().access(try std.fmt.allocPrint(a, "{s}/junk.txt", .{ws}), .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
    try std.testing.expectEqualStrings("one\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/one.txt", .{ws}), 1 << 20));
    try std.testing.expectEqualStrings("two\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/two.txt", .{ws}), 1 << 20));
    try std.testing.expectEqualStrings("three\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/three.txt", .{ws}), 1 << 20));

    // The record's timeline was overwritten: job now success.
    const rec = try runrecord.load(a, store_root, "resume-1");
    try std.testing.expectEqualStrings("success", rec.jobs[0].status);
}

test "resume: recorded job outputs feed the target and later jobs run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/engresume-chain";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(ws);
    const store_root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);

    const wf_v1 = try std.fmt.allocPrint(a,
        \\jobs:
        \\  producer:
        \\    steps:
        \\      - id: emit
        \\        run: echo "ver=42" >> "$GITHUB_OUTPUT"
        \\        shell: sh
        \\        working-directory: {s}
        \\  sibling:
        \\    steps:
        \\      - id: emit
        \\        run: echo "side=branch" >> "$GITHUB_OUTPUT"
        \\        shell: sh
        \\        working-directory: {s}
        \\  target:
        \\    needs: producer
        \\    steps:
        \\      - id: prepare
        \\        run: echo prepared > prepared.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\      - id: fixme
        \\        run: echo "stale=bad" >> "$GITHUB_OUTPUT"; exit 1
        \\        shell: sh
        \\        working-directory: {s}
        \\  later:
        \\    needs: [target, sibling]
        \\    steps:
        \\      - id: consume
        \\        run: echo never > later.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\  unrelated:
        \\    steps:
        \\      - run: echo ran >> ../unrelated-count.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\
    , .{ ws, ws, ws, ws, ws, ws });
    const first = try run(a, try parseFixture(a, wf_v1), .{
        .snapshot = true,
        .store_root = store_root,
        .workspace_abs = ws_abs,
        .run_id = "resume-chain",
    });
    try std.testing.expect(!first.ok());
    try std.testing.expectEqual(JobStatus.skipped, first.jobs[3].status);

    const wf_v2 = try std.fmt.allocPrint(a,
        \\jobs:
        \\  producer:
        \\    steps:
        \\      - id: emit
        \\        run: echo "ver=42" >> "$GITHUB_OUTPUT"
        \\        shell: sh
        \\        working-directory: {s}
        \\  sibling:
        \\    steps:
        \\      - id: emit
        \\        run: echo "side=branch" >> "$GITHUB_OUTPUT"
        \\        shell: sh
        \\        working-directory: {s}
        \\  target:
        \\    needs: producer
        \\    steps:
        \\      - id: prepare
        \\        run: echo prepared > prepared.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\      - id: fixme
        \\        run: echo "${{{{ needs.producer.outputs.ver }}}}" > resumed.txt; echo "answer=ok" >> "$GITHUB_OUTPUT"
        \\        shell: sh
        \\        working-directory: {s}
        \\  later:
        \\    needs: [target, sibling]
        \\    steps:
        \\      - id: consume
        \\        run: echo "${{{{ needs.target.outputs.answer }}}}" > later.txt; echo "<${{{{ needs.target.outputs.stale }}}}>" > stale.txt; echo "${{{{ needs.sibling.outputs.side }}}}" > sibling.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\  unrelated:
        \\    steps:
        \\      - run: echo ran >> ../unrelated-count.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\
    , .{ ws, ws, ws, ws, ws, ws });
    const resumed = try run(a, try parseFixture(a, wf_v2), .{
        .store_root = store_root,
        .workspace_abs = ws_abs,
        .resume_from = .{ .run_id = "resume-chain", .job_id = "target", .step = "fixme" },
    });
    try std.testing.expect(resumed.ok());
    try std.testing.expectEqual(JobStatus.skipped, resumed.jobs[0].status);
    try std.testing.expectEqual(JobStatus.skipped, resumed.jobs[1].status);
    try std.testing.expectEqual(StepStatus.skipped, resumed.jobs[2].steps[0].status);
    try std.testing.expectEqual(JobStatus.success, resumed.jobs[3].status);
    try std.testing.expectEqual(JobStatus.skipped, resumed.jobs[4].status);
    try std.testing.expectEqualStrings("42\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/resumed.txt", .{ws}), 1 << 20));
    try std.testing.expectEqualStrings("ok\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/later.txt", .{ws}), 1 << 20));
    try std.testing.expectEqualStrings("<>\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/stale.txt", .{ws}), 1 << 20));
    try std.testing.expectEqualStrings("branch\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/sibling.txt", .{ws}), 1 << 20));
    try std.testing.expectEqualStrings("ran\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/unrelated-count.txt", .{base}), 1 << 20));
}

test "resume: structural workflow edit rebuilds the same run timeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/engresume-edit";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(ws);
    const store_root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);
    const first_pipeline = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: start
        \\        run: echo unreachable
        \\        shell: nosuchshell
    );
    _ = try run(a, first_pipeline, .{
        .snapshot = true,
        .store_root = store_root,
        .workspace_abs = ws_abs,
        .run_id = "resume-edit",
    });

    const edited_pipeline = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: start
        \\        run: echo fixed
        \\      - id: added
        \\        run: echo added
    );
    const resumed = try run(a, edited_pipeline, .{
        .dry_run = true,
        .store_root = store_root,
        .workspace_abs = ws_abs,
        .resume_from = .{ .run_id = "resume-edit", .job_id = "j", .step = "start" },
    });
    try std.testing.expect(resumed.ok());
    const rec = try runrecord.load(a, store_root, "resume-edit");
    try std.testing.expectEqualStrings("resume-edit", rec.run_id);
    try std.testing.expectEqual(@as(usize, 2), rec.jobs[0].steps.len);
}

test "resume: stable step id survives reorder while numeric selector rejects it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/engresume-reorder";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const ws = try std.fmt.allocPrint(a, "{s}/ws", .{base});
    try std.fs.cwd().makePath(ws);
    const store_root = try std.fmt.allocPrint(a, "{s}/store", .{base});
    const ws_abs = try std.fs.cwd().realpathAlloc(a, ws);
    const before = try std.fmt.allocPrint(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: prepare
        \\        run: echo from-prepare > marker.txt; echo "value=old" >> "$GITHUB_OUTPUT"
        \\        shell: sh
        \\        working-directory: {s}
        \\      - id: retry
        \\        run: unreachable
        \\        shell: nosuchshell
        \\        working-directory: {s}
        \\
    , .{ ws, ws });
    _ = try run(a, try parseFixture(a, before), .{
        .snapshot = true,
        .store_root = store_root,
        .workspace_abs = ws_abs,
        .run_id = "resume-reorder",
    });

    const reordered = try std.fmt.allocPrint(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: retry
        \\        run: echo "<${{{{ steps.prepare.outputs.value }}}}>" > seen.txt
        \\        shell: sh
        \\        working-directory: {s}
        \\      - id: prepare
        \\        run: true
        \\        shell: sh
        \\        working-directory: {s}
        \\
    , .{ ws, ws });
    const edited = try parseFixture(a, reordered);
    try std.testing.expectError(error.ResumeInvalid, run(a, edited, .{
        .store_root = store_root,
        .workspace_abs = ws_abs,
        .resume_from = .{ .run_id = "resume-reorder", .job_id = "j", .step = "0" },
    }));
    const resumed = try run(a, edited, .{
        .store_root = store_root,
        .workspace_abs = ws_abs,
        .resume_from = .{ .run_id = "resume-reorder", .job_id = "j", .step = "retry" },
    });
    try std.testing.expect(resumed.ok());
    try std.testing.expectEqualStrings("<>\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/seen.txt", .{ws}), 1024));
}

test "resume: unknown run id is ResumeInvalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".jalan/tmp/engresume-bad";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const p = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - run: echo x
    );
    try std.testing.expectError(error.ResumeInvalid, run(a, p, .{
        .store_root = try std.fmt.allocPrint(a, "{s}/store", .{base}),
        .workspace_abs = a.dupe(u8, base) catch unreachable,
        .resume_from = .{ .run_id = "nosuch-run", .job_id = "j", .step = "0" },
    }));
}

test "breakpoint: injected prompt can inspect, continue, skip, or abort" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: s
        \\        run: echo breakpoint-ran
        \\        shell: sh
    );
    const breakpoints = [_]debug_mod.Breakpoint{.{ .job_id = "j", .step = "s" }};

    const inspect_commands = [_]debug_mod.PromptCmd{ .env, .workdir, .continue_ };
    var inspect_script = TestPromptScript{ .commands = &inspect_commands };
    const continued = try run(a, p, .{
        .breakpoints = &breakpoints,
        .prompt_fn = &TestPromptScript.next,
        .prompt_ctx = &inspect_script,
    });
    try std.testing.expect(continued.ok());
    try std.testing.expectEqual(StepStatus.success, continued.jobs[0].steps[0].status);

    const skip_commands = [_]debug_mod.PromptCmd{.skip};
    var skip_script = TestPromptScript{ .commands = &skip_commands };
    const skipped = try run(a, p, .{
        .breakpoints = &breakpoints,
        .prompt_fn = &TestPromptScript.next,
        .prompt_ctx = &skip_script,
    });
    try std.testing.expect(skipped.ok());
    try std.testing.expectEqual(StepStatus.skipped, skipped.jobs[0].steps[0].status);

    const abort_commands = [_]debug_mod.PromptCmd{.abort};
    var abort_script = TestPromptScript{ .commands = &abort_commands };
    const aborted = try run(a, p, .{
        .breakpoints = &breakpoints,
        .prompt_fn = &TestPromptScript.next,
        .prompt_ctx = &abort_script,
    });
    try std.testing.expect(!aborted.ok());
    try std.testing.expectEqual(StepStatus.failed, aborted.jobs[0].steps[0].status);
    try std.testing.expectEqualStrings("aborted at breakpoint", aborted.jobs[0].steps[0].stderr);
}

test "debug_all_steps prompts with resolved masked state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: s
        \\        name: inspect
        \\        run: echo ok
    );
    const secrets = [_]ir.EnvPair{.{ .name = "TOKEN", .value = "hidden" }};
    const commands = [_]debug_mod.PromptCmd{.continue_};
    var script = TestPromptScript{ .commands = &commands };
    const report = try run(a, p, .{
        .debug_all_steps = true,
        .secrets = &secrets,
        .prompt_fn = &TestPromptScript.next,
        .prompt_ctx = &script,
    });
    try std.testing.expect(report.ok());
    try std.testing.expect(script.saw_state);
    try std.testing.expectEqual(debug_mod.PromptKind.breakpoint, script.last_kind.?);
    try std.testing.expectEqualStrings("j", script.last_job_id);
    try std.testing.expectEqualStrings("s", script.last_step_id);
    try std.testing.expectEqual(@as(usize, 0), script.last_step_index);
    try std.testing.expect(script.saw_masked_secret);
}

test "prompt state masks a secret-derived workdir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const secrets = [_]ir.EnvPair{.{ .name = "TOKEN", .value = "hidden" }};
    const job = ir.Job{ .id = "j", .display_name = "job", .steps = &.{} };
    const step = ir.Step{ .id = "s", .name = "step", .kind = .run, .script = "true" };
    const state = try makePromptState(arena.allocator(), .{ .secrets = &secrets }, .breakpoint, "workspace", 0, job, step, 0, &.{}, "workspace/hidden");
    try std.testing.expectEqualStrings("***", state.workdir.?);
}

test "on-failure stop skips jobs that have not started" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseFixture(a,
        \\jobs:
        \\  first:
        \\    steps:
        \\      - run: echo unreachable
        \\        shell: nosuchshell
        \\  second:
        \\    steps:
        \\      - run: echo must-not-run
        \\        shell: sh
    );
    const report = try run(a, p, .{ .max_parallel = 1, .on_failure = .stop });
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(JobStatus.failed, report.jobs[0].status);
    try std.testing.expectEqual(JobStatus.skipped, report.jobs[1].status);
}

test "on-failure shell dispatches through backend and retries once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fake = struct {
        runs: usize = 0,
        shells: usize = 0,
        saw_stale_retry_output: bool = false,

        fn setup(_: *anyopaque, _: std.mem.Allocator, _: ir.Job, workspace: []const u8, _: ?backend_mod.LogFn) anyerror!backend_mod.JobHandle {
            return .{ .workspace = workspace };
        }
        fn runStep(ctx: *anyopaque, _: std.mem.Allocator, _: *backend_mod.JobHandle, step: ir.Step, _: []const ir.EnvPair, _: ?[]const u8, _: *?[]const u8) anyerror!backend_mod.StepOutcome {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.runs += 1;
            if (self.runs >= 3 and std.mem.indexOf(u8, step.script, "bad") != null) self.saw_stale_retry_output = true;
            return .{
                .exit_code = if (self.runs == 1) 1 else 0,
                .stdout = if (self.runs == 1) "failed" else "retried",
                .stderr = "",
                .outputs = if (self.runs == 1) &.{.{ .name = "stale", .value = "bad" }} else &.{},
            };
        }
        fn teardown(_: *anyopaque, _: std.mem.Allocator, _: *backend_mod.JobHandle) void {}
        fn openShell(ctx: *anyopaque, _: std.mem.Allocator, _: *backend_mod.JobHandle, _: ?[]const u8, _: []const ir.EnvPair) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.shells += 1;
        }
    };
    const fake_vtable = backend_mod.Backend.VTable{
        .setupJob = Fake.setup,
        .runStep = Fake.runStep,
        .teardownJob = Fake.teardown,
        .openShell = Fake.openShell,
    };
    var fake = Fake{};
    const fake_backend = backend_mod.Backend{ .ctx = @ptrCast(&fake), .vtable = &fake_vtable, .kind = .native };
    const p = try parseFixture(a,
        \\jobs:
        \\  j:
        \\    steps:
        \\      - id: flaky
        \\        run: fake
        \\  later:
        \\    needs: j
        \\    steps:
        \\      - run: echo "${{ needs.j.outputs.stale }}"
    );
    const commands = [_]debug_mod.PromptCmd{.retry};
    const extra_env = [_]ir.EnvPair{.{ .name = "FOO", .value = "bar" }};
    var script = TestPromptScript{ .commands = &commands };
    const report = try run(a, p, .{
        .exec_backend = fake_backend,
        .on_failure = .shell,
        .extra_env = &extra_env,
        .prompt_fn = &TestPromptScript.next,
        .prompt_ctx = &script,
    });
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 3), fake.runs);
    try std.testing.expectEqual(@as(usize, 1), fake.shells);
    try std.testing.expect(script.saw_state);
    try std.testing.expectEqual(debug_mod.PromptKind.failure, script.last_kind.?);
    try std.testing.expectEqual(@as(usize, 0), script.last_job_index);
    try std.testing.expectEqualStrings("j", script.last_job_id);
    try std.testing.expectEqualStrings("flaky", script.last_step_id);
    try std.testing.expectEqual(@as(usize, 0), script.last_step_index);
    try std.testing.expect(script.saw_env_foo);
    try std.testing.expectEqualStrings("retried", report.jobs[0].steps[0].stdout);
    try std.testing.expect(!fake.saw_stale_retry_output);
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
    // Phase 3: capture workspace+env snapshots at every step boundary and
    // write a run record under `store_root`. Store failures degrade to a
    // warning + snapshots off for the rest of the run — never exit 3.
    snapshot: bool = false,
    // Phase 3: content-addressed step cache. Hit = replay outcome without
    // executing; successful executions write entries. Secret-referencing
    // steps are never cached.
    cache: bool = false,
    store_root: []const u8 = ".jalan/store",
    // Explicit run id (resume reuses the original); null -> generate one.
    run_id: ?[]const u8 = null,
    // Snapshot/cache walk root. null -> process cwd (the CLI's behavior);
    // tests point this at a temp fixture so the walk doesn't scan the repo.
    workspace_abs: ?[]const u8 = null,
    // Phase 3 time-travel: resume a recorded run at a step boundary.
    // Implies snapshot behavior (the resumed run keeps writing its record).
    resume_from: ?ResumePoint = null,
    // Line-oriented debugger. prompt_fn/prompt_ctx make interaction injectable
    // for tests; a real TTY falls back to debug.promptOnce.
    breakpoints: []const debug_mod.Breakpoint = &.{},
    debug_all_steps: bool = false,
    prompt_fn: ?debug_mod.PromptFn = null,
    prompt_ctx: ?*anyopaque = null,
    on_failure: OnFailure = .continue_,
};

pub const OnFailure = enum { continue_, stop, shell };

pub const ResumePoint = struct {
    run_id: []const u8,
    job_id: []const u8,
    /// Step id or decimal step index within the job.
    step: []const u8,
};

const secret_marker_prefix = "__JALAN_SECRET[";

fn secretMarker(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, secret_marker_prefix ++ "{s}]__", .{name});
}

/// Replace configured secret bytes with named placeholders before persisted
/// metadata is serialized. Longest values are replaced first so overlapping
/// secrets cannot leave a suffix behind.
fn protectSecretValue(alloc: std.mem.Allocator, value: []const u8, secrets: []const ir.EnvPair) ![]const u8 {
    const sorted = try alloc.dupe(ir.EnvPair, secrets);
    std.mem.sort(ir.EnvPair, sorted, {}, struct {
        fn longer(_: void, a: ir.EnvPair, b: ir.EnvPair) bool {
            return a.value.len > b.value.len;
        }
    }.longer);
    var out = try alloc.dupe(u8, value);
    for (sorted) |secret| {
        if (secret.value.len == 0 or std.mem.indexOf(u8, out, secret.value) == null) continue;
        out = try std.mem.replaceOwned(u8, alloc, out, secret.value, try secretMarker(alloc, secret.name));
    }
    return out;
}

fn rehydrateSecretValue(alloc: std.mem.Allocator, value: []const u8, secrets: []const ir.EnvPair) ![]const u8 {
    var out = try alloc.dupe(u8, value);
    for (secrets) |secret| {
        const marker = try secretMarker(alloc, secret.name);
        if (std.mem.indexOf(u8, out, marker) != null)
            out = try std.mem.replaceOwned(u8, alloc, out, marker, secret.value);
    }
    if (std.mem.indexOf(u8, out, secret_marker_prefix) != null) return error.MissingSecret;
    return out;
}

fn protectPairs(alloc: std.mem.Allocator, pairs: []const ir.EnvPair, secrets: []const ir.EnvPair) ![]ir.EnvPair {
    const out = try alloc.alloc(ir.EnvPair, pairs.len);
    for (pairs, out) |pair, *dst| dst.* = .{ .name = pair.name, .value = try protectSecretValue(alloc, pair.value, secrets) };
    return out;
}

fn rehydratePairs(alloc: std.mem.Allocator, pairs: []const ir.EnvPair, secrets: []const ir.EnvPair) ![]ir.EnvPair {
    const out = try alloc.alloc(ir.EnvPair, pairs.len);
    for (pairs, out) |pair, *dst| dst.* = .{ .name = pair.name, .value = try rehydrateSecretValue(alloc, pair.value, secrets) };
    return out;
}

fn filterResumePairs(alloc: std.mem.Allocator, pairs: []const ir.EnvPair, job: ir.Job, target_index: usize) ![]ir.EnvPair {
    var out: std.ArrayList(ir.EnvPair) = .empty;
    pair_loop: for (pairs) |pair| {
        // needs.* is rebuilt from the current graph's recorded prerequisite
        // outputs below, never trusted from an older snapshot shape.
        if (std.mem.startsWith(u8, pair.name, "needs.")) continue;
        if (std.mem.startsWith(u8, pair.name, "steps.")) {
            for (job.steps[0..target_index]) |prior| {
                const prefix = try std.fmt.allocPrint(alloc, "steps.{s}.", .{prior.id});
                if (std.mem.startsWith(u8, pair.name, prefix)) {
                    try out.append(alloc, pair);
                    continue :pair_loop;
                }
            }
            continue;
        }
        try out.append(alloc, pair);
    }
    return out.toOwnedSlice(alloc);
}

/// Resolve a resume selector against the current job. Explicit ids win over
/// decimal indexes so a step whose id is "0" remains addressable by id.
fn resumeStepIndex(job: ir.Job, selector: []const u8) ?usize {
    for (job.steps, 0..) |step, i| {
        if (std.mem.eql(u8, step.id, selector)) return i;
    }
    const index = std.fmt.parseUnsigned(usize, selector, 10) catch return null;
    return if (index < job.steps.len) index else null;
}

/// Matrix copies deliberately share the workflow job id. Persistence needs a
/// stable per-copy selector so parallel copies cannot overwrite each other's
/// snapshots or run-record entries.
fn jobInstanceId(alloc: std.mem.Allocator, job: ir.Job) ![]const u8 {
    if (job.matrix.len == 0) return job.id;
    const matrix = try alloc.dupe(ir.EnvPair, job.matrix);
    std.mem.sort(ir.EnvPair, matrix, {}, struct {
        fn less(_: void, a: ir.EnvPair, b: ir.EnvPair) bool {
            const by_name = std.mem.order(u8, a.name, b.name);
            return if (by_name == .eq) std.mem.lessThan(u8, a.value, b.value) else by_name == .lt;
        }
    }.less);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (matrix) |pair| {
        hash.update(pair.name);
        hash.update(&.{0});
        hash.update(pair.value);
        hash.update(&.{0});
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(alloc, "{s}-{s}", .{ job.id, &hex });
}

test "matrix job instance ids are stable unique persistence selectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var first = [_]ir.EnvPair{ .{ .name = "os", .value = "linux" }, .{ .name = "node", .value = "20" } };
    var reordered = [_]ir.EnvPair{ .{ .name = "node", .value = "20" }, .{ .name = "os", .value = "linux" } };
    var second = [_]ir.EnvPair{ .{ .name = "os", .value = "windows" }, .{ .name = "node", .value = "20" } };
    const j1 = ir.Job{ .id = "build", .display_name = "build (linux, 20)", .matrix = &first, .steps = &.{} };
    const j1_reordered = ir.Job{ .id = "build", .display_name = "build (20, linux)", .matrix = &reordered, .steps = &.{} };
    const j2 = ir.Job{ .id = "build", .display_name = "build (windows, 20)", .matrix = &second, .steps = &.{} };
    try std.testing.expectEqualStrings(try jobInstanceId(a, j1), try jobInstanceId(a, j1_reordered));
    try std.testing.expect(!std.mem.eql(u8, try jobInstanceId(a, j1), try jobInstanceId(a, j2)));
    try std.testing.expectEqualStrings("plain", try jobInstanceId(a, .{ .id = "plain", .display_name = "plain", .steps = &.{} }));
}

test "resume rejects a run recorded by another backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = ".jalan/tmp/resume-backend-mismatch";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    const rec = runrecord.RunRecord{
        .run_id = "foreign-backend",
        .workflow = "ci.yml",
        .backend = "docker",
        .started_unix = 1,
    };
    try runrecord.write(a, root, &rec);
    var jobs = [_]ir.Job{.{ .id = "j", .display_name = "j", .steps = &.{} }};
    const pipeline = ir.Pipeline{ .name = "x", .source_path = "ci.yml", .jobs = &jobs };
    try std.testing.expectError(error.ResumeInvalid, run(a, pipeline, .{
        .store_root = root,
        .resume_from = .{ .run_id = "foreign-backend", .job_id = "j", .step = "0" },
    }));
}

const Shared = struct {
    alloc: std.mem.Allocator,
    // "jobid.outputs.key" -> value, merged across matrix copies (last writer wins).
    job_outputs: std.StringHashMapUnmanaged([]const u8) = .empty,
    // Phase 3 run record, non-null when snapshots are on. Guarded by
    // record_mutex (a SEPARATE mutex from `mutex`: workers hold `mutex`
    // while copying results and may also update the record, but nothing
    // ever takes `mutex` while holding record_mutex — no lock-order cycle).
    record: ?*runrecord.RunRecord = null,
    record_mutex: std.Thread.Mutex = .{},
    snapshot_ok: bool = true,
    workspace_abs: []const u8 = "",
    // Resume state: the target step's pre-step manifest (env + workspace
    // tree), loaded once in run() before any job starts.
    resume_manifest: ?snap_manifest.Manifest = null,
    // Only one worker may own stdin/the interactive prompt at a time.
    prompt_mutex: std.Thread.Mutex = .{},
    // Snapshots/cache observe one shared checkout. Hold this across the
    // complete step transaction so parallel jobs cannot contaminate another
    // step's pre/post trees or persisted boundary.
    workspace_mutex: std.Thread.Mutex = .{},
    non_tty_break_warned: bool = false,
    halt: std.atomic.Value(bool) = .init(false),
};

pub fn run(alloc: std.mem.Allocator, p: ir.Pipeline, opts: RunOptions) error{ OutOfMemory, InternalError, ResumeInvalid, RestoreFailed, StoreIo }!Report {
    // Resume implies snapshot behavior (record + step-boundary captures
    // keep updating the same timeline).
    var eff_opts = opts;
    if (opts.resume_from != null) eff_opts.snapshot = true;

    const results = try alloc.alloc(JobResult, p.jobs.len);
    const done = try alloc.alloc(bool, p.jobs.len);
    @memset(done, false);
    var shared = Shared{ .alloc = alloc };
    var mutex = std.Thread.Mutex{};
    var completed: usize = 0;
    const max_par = @max(eff_opts.max_parallel, 1);
    if ((eff_opts.snapshot or eff_opts.cache) and max_par > 1) {
        if (eff_opts.log) |l| l("warning: snapshots/cache serialize step execution because jobs share one workspace");
    }

    // Phase 3: workspace walk root for snapshots and/or cache.
    if (eff_opts.snapshot or eff_opts.cache or eff_opts.breakpoints.len > 0 or eff_opts.debug_all_steps or eff_opts.workspace_abs != null) {
        shared.workspace_abs = eff_opts.workspace_abs orelse (std.fs.cwd().realpathAlloc(alloc, ".") catch ".");
    }

    // Phase 3 resume: load the record, validate the target, restore the
    // workspace from the target step's pre-step manifest, seed job outputs,
    // and mark non-participating jobs done+skipped up front. Only the
    // target job and its transitive dependents actually execute.
    var record: runrecord.RunRecord = undefined;
    if (eff_opts.resume_from) |rp| {
        // A resumed run always continues the original timeline, including
        // when an edited workflow forces us to rebuild the record skeleton.
        eff_opts.run_id = rp.run_id;
        const rec = runrecord.load(alloc, eff_opts.store_root, rp.run_id) catch return error.ResumeInvalid;
        const current_backend = if (eff_opts.exec_backend) |b| @tagName(b.kind) else "native";
        if (!std.mem.eql(u8, rec.backend, current_backend)) return error.ResumeInvalid;
        var target: ?usize = null;
        for (p.jobs, 0..) |j, i| {
            if (std.mem.eql(u8, try jobInstanceId(alloc, j), rp.job_id)) target = i;
        }
        const tji = target orelse return error.ResumeInvalid;
        const tsi = resumeStepIndex(p.jobs[tji], rp.step) orelse return error.ResumeInvalid;
        var rec_job: ?runrecord.JobEntry = null;
        for (rec.jobs) |je| {
            if (std.mem.eql(u8, je.id, rp.job_id)) rec_job = je;
        }
        const rje = rec_job orelse return error.ResumeInvalid;
        const selector_is_id = for (p.jobs[tji].steps) |step| {
            if (std.mem.eql(u8, step.id, rp.step)) break true;
        } else false;
        var recorded_si: ?usize = null;
        if (selector_is_id) {
            for (rje.steps, 0..) |step, i| if (std.mem.eql(u8, step.id, p.jobs[tji].steps[tsi].id)) {
                recorded_si = i;
                break;
            };
        } else if (tsi < rje.steps.len and std.mem.eql(u8, rje.steps[tsi].id, p.jobs[tji].steps[tsi].id)) {
            // Numeric selectors are positional and therefore only safe when
            // the recorded and current step at that index have the same id.
            recorded_si = tsi;
        }
        const rsi = recorded_si orelse return error.ResumeInvalid;
        const snap_rel = rje.steps[rsi].snapshot;
        if (snap_rel.len == 0) return error.ResumeInvalid;
        var m = snap_manifest.load(alloc, eff_opts.store_root, snap_rel) catch return error.ResumeInvalid;
        if (!std.mem.eql(u8, m.run_id, rp.run_id) or
            !std.mem.eql(u8, m.job_id, rp.job_id) or
            !std.mem.eql(u8, m.step_id, rje.steps[rsi].id) or
            m.step_index != rsi) return error.ResumeInvalid;
        m.env = rehydratePairs(alloc, m.env, eff_opts.secrets) catch return error.ResumeInvalid;
        m.env = try filterResumePairs(alloc, m.env, p.jobs[tji], tsi);
        try snap_restore.restore(alloc, eff_opts.store_root, shared.workspace_abs, m, eff_opts.log);
        shared.resume_manifest = m;

        // Rebuild target-job outputs that were produced strictly before the
        // selected boundary from the snapshot's step environment. Outputs at
        // or after the boundary are intentionally absent and must be emitted
        // again by the rerun.
        for (p.jobs[tji].steps[0..tsi]) |prior_step| {
            const step_prefix = try std.fmt.allocPrint(alloc, "steps.{s}.outputs.", .{prior_step.id});
            for (m.env) |pair| {
                if (!std.mem.startsWith(u8, pair.name, step_prefix)) continue;
                const job_key = try std.fmt.allocPrint(alloc, "{s}.outputs.{s}", .{ p.jobs[tji].id, pair.name[step_prefix.len..] });
                try shared.job_outputs.put(alloc, job_key, pair.value);
            }
        }

        // Execute only the target and its transitive dependents. Separately
        // identify the target's transitive prerequisites so only outputs that
        // existed before this boundary are seeded; target/later outputs are
        // deliberately cleared to prevent values from the future leaking in.
        const active = try alloc.alloc(bool, p.jobs.len);
        const upstream = try alloc.alloc(bool, p.jobs.len);
        @memset(active, false);
        @memset(upstream, false);
        active[tji] = true;
        var changed = true;
        while (changed) {
            changed = false;
            for (p.jobs, 0..) |job, i| {
                if (active[i]) continue;
                for (job.needs) |need| {
                    for (p.jobs, 0..) |dep, di| if (std.mem.eql(u8, dep.id, need) and active[di]) {
                        active[i] = true;
                        changed = true;
                    };
                }
            }
        }
        upstream[tji] = true;
        changed = true;
        while (changed) {
            changed = false;
            for (p.jobs, 0..) |job, i| {
                if (!upstream[i]) continue;
                for (job.needs) |need| {
                    for (p.jobs, 0..) |dep, di| if (std.mem.eql(u8, dep.id, need) and !upstream[di]) {
                        upstream[di] = true;
                        changed = true;
                    };
                }
            }
        }
        upstream[tji] = false;
        // An active dependent may also need a sibling branch that is not a
        // prerequisite of the resume target itself. That branch stays
        // skipped, so its recorded outputs must be seeded as well.
        for (p.jobs, 0..) |job, i| {
            if (!active[i]) continue;
            for (job.needs) |need| {
                for (p.jobs, 0..) |dep, di| {
                    if (!active[di] and std.mem.eql(u8, dep.id, need)) upstream[di] = true;
                }
            }
        }
        for (rec.job_outputs) |po| {
            for (p.jobs, 0..) |job, i| {
                if (!upstream[i]) continue;
                const prefix = try std.fmt.allocPrint(alloc, "{s}.outputs.", .{job.id});
                if (std.mem.startsWith(u8, po.name, prefix))
                    try shared.job_outputs.put(alloc, po.name, rehydrateSecretValue(alloc, po.value, eff_opts.secrets) catch return error.ResumeInvalid);
            }
        }

        // Reuse the loaded record as the live one only when its job/step
        // structure still aligns by index (script edits are fine; structural
        // edits rebuild the skeleton while keeping the original run id).
        var aligned = rec.jobs.len == p.jobs.len;
        if (aligned) {
            for (rec.jobs, 0..) |je, i| {
                if (!std.mem.eql(u8, je.id, try jobInstanceId(alloc, p.jobs[i])) or je.steps.len != p.jobs[i].steps.len) {
                    aligned = false;
                    break;
                }
                for (je.steps, 0..) |se, k| {
                    if (!std.mem.eql(u8, se.id, p.jobs[i].steps[k].id)) {
                        aligned = false;
                        break;
                    }
                }
                if (!aligned) break;
            }
        }
        if (aligned) {
            record = rec;
            shared.record = &record;
        } else if (eff_opts.log) |l| l("warning: workflow changed since the recorded run — run record history resets");

        // All non-participating jobs stay skipped. Recorded prerequisite
        // outputs satisfy the target's dependencies.
        for (p.jobs, 0..) |j, i| {
            if (active[i]) continue;
            results[i] = try skippedResult(alloc, j, i);
            done[i] = true;
            completed += 1;
        }
    }

    // Phase 3: run record skeleton (all steps "pending") when snapshots on
    // (skipped when resume already installed the aligned loaded record).
    if (eff_opts.snapshot and shared.record == null) {
        const rid = eff_opts.run_id orelse (runrecord.newId(alloc) catch blk: {
            if (eff_opts.log) |l| l("warning: cannot allocate run id — snapshots disabled");
            shared.snapshot_ok = false;
            break :blk "";
        });
        if (shared.snapshot_ok) {
            const jobs = try alloc.alloc(runrecord.JobEntry, p.jobs.len);
            for (p.jobs, 0..) |j, i| {
                const step_entries = try alloc.alloc(runrecord.StepEntry, j.steps.len);
                for (j.steps, 0..) |s, k| step_entries[k] = .{ .id = s.id };
                jobs[i] = .{ .id = try jobInstanceId(alloc, j), .steps = step_entries };
            }
            const kind = if (eff_opts.exec_backend) |b| @tagName(b.kind) else "native";
            record = .{
                .run_id = rid,
                .workflow = p.source_path,
                .backend = kind,
                .started_unix = std.time.timestamp(),
                .jobs = jobs,
            };
            shared.record = &record;
            runrecord.write(alloc, eff_opts.store_root, &record) catch {
                if (eff_opts.log) |l| l("warning: cannot write run record — snapshots disabled");
                shared.snapshot_ok = false;
            };
        }
    }

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
                        mx.lock();
                        defer mx.unlock();
                        out.* = .{ .job_index = ji, .display_name = pi.jobs[ji].display_name, .status = .failed, .steps = &.{} };
                        std.debug.print("internal error in job: {s}\n", .{@errorName(e)});
                        syncRecordAfterJob(sh, o, ji, out.*);
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
                    syncRecordAfterJob(sh, o, ji, out.*);
                }
            };
            for (batch, 0..) |ji, bi| {
                threads[bi] = std.Thread.spawn(.{}, Ctx.work, .{ p, ji, eff_opts, &shared, &mutex, &results[ji], results, done }) catch null;
                if (threads[bi] == null) {
                    // Spawn failed (e.g. thread-limit exhaustion) — fall back to inline execution.
                    Ctx.work(p, ji, eff_opts, &shared, &mutex, &results[ji], results, done);
                }
            }
            for (threads) |t| if (t) |th| th.join();
            for (batch) |ji| {
                done[ji] = true;
                completed += 1;
            }
            batch_start += batch.len;
            if (shared.halt.load(.acquire)) {
                for (p.jobs, 0..) |job, ji| {
                    if (done[ji]) continue;
                    results[ji] = try skippedResult(alloc, job, ji);
                    done[ji] = true;
                    completed += 1;
                }
                break;
            }
        }
    }
    return .{ .jobs = results };
}

/// After a job finishes: fold its status + step statuses + the current
/// job_outputs into the run record and rewrite it (tmp+rename inside
/// runrecord.write). Called from worker threads; takes record_mutex.
fn syncRecordAfterJob(sh: *Shared, opts: RunOptions, ji: usize, r: JobResult) void {
    const rec = sh.record orelse return;
    sh.record_mutex.lock();
    defer sh.record_mutex.unlock();
    if (!sh.snapshot_ok) return;
    const je = &rec.jobs[ji];
    je.status = @tagName(r.status);
    for (r.steps, 0..) |s, k| {
        if (k < je.steps.len) je.steps[k].status = @tagName(s.status);
    }
    // Refresh the flat job_outputs so a later --resume can rebuild the
    // needs.* context without re-running completed jobs.
    var pairs: std.ArrayList(ir.EnvPair) = .empty;
    var it = sh.job_outputs.iterator();
    while (it.next()) |e| pairs.append(sh.alloc, .{
        .name = e.key_ptr.*,
        .value = protectSecretValue(sh.alloc, e.value_ptr.*, opts.secrets) catch return,
    }) catch return;
    rec.job_outputs = pairs.toOwnedSlice(sh.alloc) catch return;
    runrecord.write(sh.alloc, opts.store_root, rec) catch {
        if (opts.log) |l| l("warning: cannot write run record — snapshots disabled");
        sh.snapshot_ok = false;
    };
}

/// Pre-step snapshot: workspace tree + serialized expr env at the step
/// boundary. Failures degrade to a warning + snapshots off for the rest of
/// the run (the store is an accelerator, never a hard dependency).
fn captureStep(alloc: std.mem.Allocator, opts: RunOptions, sh: *Shared, job: ir.Job, ji: usize, step: ir.Step, si: usize, env: *expr.Env, alloc_mutex: *std.Thread.Mutex) ?snap_manifest.CaptureResult {
    sh.record_mutex.lock();
    const ok = sh.snapshot_ok;
    sh.record_mutex.unlock();
    if (!ok) return null;
    const rec = sh.record.?;
    const raw_pairs = expr.envToPairs(alloc, env) catch return null;
    const pairs = protectPairs(alloc, raw_pairs, opts.secrets) catch return null;
    const cap = snap_manifest.capture(alloc, opts.store_root, sh.workspace_abs, rec.run_id, rec.jobs[ji].id, @intCast(si), step.id, pairs) catch {
        logJob(opts, alloc, job, "warning: snapshot capture failed — snapshots disabled for this run");
        sh.record_mutex.lock();
        sh.snapshot_ok = false;
        sh.record_mutex.unlock();
        return null;
    };
    // cap.rel_path belongs to this worker's short-lived arena. Copy it into
    // the caller arena before recording it so later jobs can safely rewrite
    // the record. All caller-arena allocations share alloc_mutex.
    alloc_mutex.lock();
    const rel_path = sh.alloc.dupe(u8, cap.rel_path) catch {
        alloc_mutex.unlock();
        logJob(opts, alloc, job, "warning: snapshot path allocation failed — snapshots disabled for this run");
        sh.record_mutex.lock();
        sh.snapshot_ok = false;
        sh.record_mutex.unlock();
        return null;
    };
    alloc_mutex.unlock();
    sh.record_mutex.lock();
    rec.jobs[ji].steps[si].snapshot = rel_path;
    sh.record_mutex.unlock();
    return cap;
}

const CacheBegin = struct {
    /// Non-null when caching is active for this step (commit allowed).
    hex: ?[]const u8 = null,
    /// Pre-step workspace entries, needed by cacheCommit's diff.
    pre: []snap_manifest.FileEntry = &.{},
    /// Non-null on a cache hit: replay instead of executing.
    hit: ?cache.Entry = null,
};

fn rawPairsUseSecrets(pairs: []const ir.EnvPair) bool {
    for (pairs) |pair| if (std.ascii.indexOfIgnoreCase(pair.value, "secrets.") != null) return true;
    return false;
}

fn valueContainsConfiguredSecret(value: []const u8, secrets: []const ir.EnvPair) bool {
    for (secrets) |secret| {
        if (secret.value.len > 0 and std.mem.indexOf(u8, value, secret.value) != null) return true;
    }
    return false;
}

fn interpolatedInputsContainSecret(step: ir.Step, env: []const ir.EnvPair, secrets: []const ir.EnvPair) bool {
    if (valueContainsConfiguredSecret(step.script, secrets) or valueContainsConfiguredSecret(step.uses_ref, secrets)) return true;
    if (step.shell) |value| if (valueContainsConfiguredSecret(value, secrets)) return true;
    if (step.workdir) |value| if (valueContainsConfiguredSecret(value, secrets)) return true;
    for (step.with) |pair| if (valueContainsConfiguredSecret(pair.value, secrets)) return true;
    for (step.env) |pair| if (valueContainsConfiguredSecret(pair.value, secrets)) return true;
    for (env) |pair| if (valueContainsConfiguredSecret(pair.value, secrets)) return true;
    return false;
}

fn resolvedUsesIdentity(alloc: std.mem.Allocator, opts: RunOptions, step: ir.Step) ?[]const u8 {
    const ref = action_resolve.parseRef(step.uses_ref) catch return null;
    return switch (ref) {
        .github => |gh| blk: {
            var err_msg: ?[]const u8 = null;
            const dir = action_resolve.fetch(alloc, gh, opts.force_pull, opts.log, &err_msg) catch {
                if (opts.log) |log| log(err_msg orelse "warning: action ref resolution failed — cache disabled for this step");
                break :blk null;
            };
            const files = snap_manifest.scanTree(alloc, opts.store_root, dir, false) catch break :blk null;
            const tree = snap_manifest.treeHash(alloc, files) catch break :blk null;
            break :blk std.fmt.allocPrint(alloc, "{s}#tree={s}", .{ step.uses_ref, tree }) catch null;
        },
        .local, .docker_image => step.uses_ref,
    };
}

fn nixSetupSideEffect(kind: backend_mod.Kind, uses_ref: []const u8) bool {
    if (kind != .nix) return false;
    const at = std.mem.indexOfScalar(u8, uses_ref, '@') orelse uses_ref.len;
    const name = uses_ref[0..at];
    return std.mem.eql(u8, name, "actions/setup-node") or
        std.mem.eql(u8, name, "actions/setup-python") or
        std.mem.eql(u8, name, "actions/setup-go");
}

fn gitWorkspaceIdentity(alloc: std.mem.Allocator, workspace: []const u8) ![]const u8 {
    const head_path = try std.fmt.allocPrint(alloc, "{s}/.git/HEAD", .{workspace});
    const head = std.fs.cwd().readFileAlloc(alloc, head_path, 1024 * 1024) catch return "no-git";
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(head);
    const trimmed = std.mem.trim(u8, head, " \r\n");
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref = trimmed["ref: ".len..];
        if (safe_path.isSafeRelative(ref)) {
            const ref_path = try std.fmt.allocPrint(alloc, "{s}/.git/{s}", .{ workspace, ref });
            if (std.fs.cwd().readFileAlloc(alloc, ref_path, 1024 * 1024)) |contents| hash.update(contents) else |_| {}
        }
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

/// Compute the step's cache key and look it up. On hit, materializes the
/// recorded file writes into the workspace (a blob failure demotes the hit
/// to a miss-with-warning and re-executes). `raw_step` is the
/// pre-interpolation step (secret scan); `key_step` carries interpolated
/// script/with values (cache identity).
fn cacheBegin(
    alloc: std.mem.Allocator,
    opts: RunOptions,
    job: ir.Job,
    exec_backend: backend_mod.Backend,
    handle: *backend_mod.JobHandle,
    raw_step: ir.Step,
    key_step: ir.Step,
    eff_env: []const ir.EnvPair,
    workspace: []const u8,
    snapshot: ?snap_manifest.CaptureResult,
    eligible: bool,
) CacheBegin {
    if (!opts.cache or !eligible or cache.usesSecrets(raw_step) or rawPairsUseSecrets(job.env) or
        interpolatedInputsContainSecret(key_step, eff_env, opts.secrets)) return .{};
    const pre = if (snapshot) |cap| cap.m.files else snap_manifest.scanTree(alloc, opts.store_root, workspace, false) catch {
        logLine(opts, alloc, job, key_step, "warning: workspace scan failed — cache disabled for this step");
        return .{};
    };
    const pre_hash = if (snapshot) |cap| cap.m.tree_hash else snap_manifest.treeHash(alloc, pre) catch return .{};
    const backend_identity = exec_backend.cacheIdentity(alloc, job, handle, key_step) catch return .{};
    const execution_identity = std.fmt.allocPrint(alloc, "{s};git:{s}", .{ backend_identity, gitWorkspaceIdentity(alloc, workspace) catch "unknown" }) catch return .{};
    const hex = cache.inputHash(alloc, @tagName(exec_backend.kind), execution_identity, key_step, eff_env, pre_hash) catch return .{};
    const entry = (cache.readEntry(alloc, opts.store_root, hex) catch null) orelse
        return .{ .hex = hex, .pre = pre };
    materializeEntry(alloc, opts.store_root, workspace, entry) catch {
        logLine(opts, alloc, job, key_step, "warning: cache entry blobs missing — re-executing");
        return .{ .hex = hex, .pre = pre };
    };
    return .{ .hit = entry };
}

fn materializeEntry(alloc: std.mem.Allocator, root: []const u8, workspace: []const u8, entry: cache.Entry) !void {
    // Windows symlink privilege/fallback behavior is not transactional. Treat
    // such entries as a miss before changing any regular file.
    if (@import("builtin").os.tag == .windows)
        for (entry.wrote) |w| if (w.link_target != null) return error.UnsupportedSymlink;
    for (entry.wrote) |w| if (!w.is_dir and w.link_target == null) try snap_store.verifyBlob(alloc, root, w.blob);
    for (entry.wrote) |w| {
        if (!w.is_dir) continue;
        var parent = try safe_path.openParent(workspace, w.path, true);
        defer parent.close();
        parent.dir.makeDir(parent.basename) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                parent.dir.deleteFile(parent.basename) catch {};
                try parent.dir.makeDir(parent.basename);
            },
        };
        if (@import("builtin").os.tag != .windows) {
            var dir = try parent.dir.openDir(parent.basename, .{ .iterate = true });
            defer dir.close();
            dir.chmod(@intCast(w.mode)) catch {};
        }
    }
    for (entry.wrote) |w| {
        if (w.is_dir or w.link_target != null) continue;
        var parent = try safe_path.openParent(workspace, w.path, true);
        defer parent.close();
        parent.dir.deleteTree(parent.basename) catch {};
        try snap_store.copyBlobToFile(alloc, root, w.blob, parent.dir, parent.basename);
        if (@import("builtin").os.tag != .windows) {
            if (parent.dir.openFile(parent.basename, .{ .mode = .read_write })) |file| {
                defer file.close();
                file.chmod(@intCast(w.mode)) catch {};
            } else |_| {}
        }
    }
    for (entry.wrote) |w| {
        if (w.link_target) |target| try snap_restore.restoreSymlink(alloc, workspace, w.path, target, null);
    }
    const deleted = try alloc.dupe([]const u8, entry.deleted);
    std.mem.sort([]const u8, deleted, {}, struct {
        fn deeper(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.deeper);
    for (deleted) |d| {
        safe_path.deleteFile(workspace, d) catch safe_path.deleteTree(workspace, d) catch {};
    }
}

/// After a successful execution: diff pre/post workspace trees, store
/// changed files as blobs, and write the cache entry. Best-effort — a
/// commit failure only means the next run misses.
fn cacheCommit(
    alloc: std.mem.Allocator,
    opts: RunOptions,
    workspace: []const u8,
    hex: []const u8,
    pre: []snap_manifest.FileEntry,
    outcome: backend_mod.StepOutcome,
) void {
    const post = snap_manifest.scanTree(alloc, opts.store_root, workspace, false) catch return;
    var pre_map: std.StringHashMapUnmanaged(snap_manifest.FileEntry) = .empty;
    for (pre) |f| pre_map.put(alloc, f.path, f) catch return;
    var post_paths: std.StringHashMapUnmanaged(void) = .empty;
    var wrote: std.ArrayList(cache.WroteFile) = .empty;
    for (post) |f| {
        post_paths.put(alloc, f.path, {}) catch return;
        const prev = pre_map.get(f.path);
        if (prev) |old| {
            const same_link = if (old.link_target) |old_target|
                if (f.link_target) |new_target| std.mem.eql(u8, old_target, new_target) else false
            else
                f.link_target == null;
            if (same_link and old.is_dir == f.is_dir and std.mem.eql(u8, old.blob, f.blob) and old.mode == f.mode) continue;
        }
        if (f.is_dir) {
            wrote.append(alloc, .{ .path = f.path, .mode = f.mode, .is_dir = true }) catch return;
            continue;
        }
        if (f.link_target) |target| {
            wrote.append(alloc, .{ .path = f.path, .mode = f.mode, .link_target = target }) catch return;
            continue;
        }
        const abs = std.fmt.allocPrint(alloc, "{s}/{s}", .{ workspace, f.path }) catch return;
        const c = snap_store.copyFileToBlob(alloc, opts.store_root, abs) catch return;
        wrote.append(alloc, .{ .path = f.path, .blob = c.hex, .mode = f.mode }) catch return;
    }
    var deleted: std.ArrayList([]const u8) = .empty;
    for (pre) |f| {
        if (!post_paths.contains(f.path)) deleted.append(alloc, f.path) catch return;
    }
    const post_hash = snap_manifest.treeHash(alloc, post) catch return;
    cache.writeEntry(alloc, opts.store_root, hex, .{
        .exit_code = outcome.exit_code,
        .stdout = outcome.stdout,
        .stderr = outcome.stderr,
        .outputs = outcome.outputs,
        .wrote = wrote.items,
        .deleted = deleted.items,
        .post_tree_hash = post_hash,
    }) catch {};
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

/// All-steps-skipped JobResult, used for jobs filtered out or excluded
/// from a resume (non-participating jobs are pre-marked done with this).
fn skippedResult(alloc: std.mem.Allocator, job: ir.Job, index: usize) !JobResult {
    const steps = try alloc.alloc(StepResult, job.steps.len);
    for (steps, job.steps) |*r, s|
        r.* = .{ .name = s.name, .status = .skipped, .exit_code = 0, .duration_ms = 0, .stdout = "", .stderr = "" };
    return .{ .job_index = index, .display_name = job.display_name, .status = .skipped, .steps = steps };
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

const BreakAction = enum { continue_, skip, abort };

fn hasBreakpoint(opts: RunOptions, job: ir.Job, step: ir.Step, index: usize) bool {
    for (opts.breakpoints) |bp| {
        if (debug_mod.matches(bp, job.id, step.id, index)) return true;
    }
    return false;
}

fn isSecretValue(opts: RunOptions, value: []const u8) bool {
    for (opts.secrets) |secret| {
        if (secret.value.len > 0 and std.mem.indexOf(u8, value, secret.value) != null) return true;
    }
    return false;
}

fn makePromptState(
    alloc: std.mem.Allocator,
    opts: RunOptions,
    kind: debug_mod.PromptKind,
    workspace: []const u8,
    job_index: usize,
    job: ir.Job,
    step: ir.Step,
    step_index: usize,
    env: []const ir.EnvPair,
    workdir: ?[]const u8,
) !debug_mod.PromptState {
    var effective: std.ArrayList(ir.EnvPair) = .empty;
    for (env) |pair| {
        const value = if (std.mem.startsWith(u8, pair.name, "secrets.") or isSecretValue(opts, pair.value)) "***" else pair.value;
        try effective.append(alloc, .{ .name = pair.name, .value = value });
    }
    return .{
        .kind = kind,
        .job_index = job_index,
        .job_id = job.id,
        .job_name = job.display_name,
        .step_id = step.id,
        .step_name = step.name,
        .step_index = step_index,
        .workspace = workspace,
        .workdir = if (workdir) |value| if (isSecretValue(opts, value)) "***" else value else null,
        .effective_env = effective.items,
    };
}

fn putPromptEnv(alloc: std.mem.Allocator, pairs: *std.ArrayList(ir.EnvPair), pair: ir.EnvPair) !void {
    const name = try std.fmt.allocPrint(alloc, "env.{s}", .{pair.name});
    for (pairs.items) |*existing| {
        if (!std.mem.eql(u8, existing.name, name)) continue;
        existing.value = pair.value;
        return;
    }
    try pairs.append(alloc, .{ .name = name, .value = pair.value });
}

/// Own the global prompt until this breakpoint is resolved. Informational
/// commands re-prompt; injected prompt functions bypass the TTY guard.
fn handleBreakpoint(
    alloc: std.mem.Allocator,
    opts: RunOptions,
    shared: *Shared,
    job_index: usize,
    job: ir.Job,
    step: ir.Step,
    step_index: usize,
    env: *expr.Env,
    backend: backend_mod.Backend,
    handle: *backend_mod.JobHandle,
    base_env: []const ir.EnvPair,
) BreakAction {
    shared.prompt_mutex.lock();
    defer shared.prompt_mutex.unlock();

    if (opts.prompt_fn == null and !debug_mod.isTty()) {
        if (!shared.non_tty_break_warned) {
            logLine(opts, alloc, job, step, "warning: breakpoint ignored because stdin is not a TTY");
            shared.non_tty_break_warned = true;
        }
        return .continue_;
    }

    var state_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer state_arena.deinit();
    const state_alloc = state_arena.allocator();
    const prompt_workdir = if (step.workdir) |raw| expr.interpolate(state_alloc, raw, env) catch raw else shared.workspace_abs;
    const prompt_pairs = expr.envToPairs(state_alloc, env) catch base_env;
    var prompt_env: std.ArrayList(ir.EnvPair) = .empty;
    prompt_env.appendSlice(state_alloc, prompt_pairs) catch return .continue_;
    for (step.env) |pair| {
        const value = expr.interpolate(state_alloc, pair.value, env) catch pair.value;
        putPromptEnv(state_alloc, &prompt_env, .{ .name = pair.name, .value = value }) catch return .continue_;
    }
    const state = makePromptState(state_alloc, opts, .breakpoint, shared.workspace_abs, job_index, job, step, step_index, prompt_env.items, prompt_workdir) catch return .continue_;

    logLine(opts, alloc, job, step, "breakpoint — (c)ontinue (s)kip (e)nv (w)orkdir (sh)ell (a)bort");
    while (true) {
        const cmd = if (opts.prompt_fn) |prompt| prompt(opts.prompt_ctx, state) else debug_mod.promptOnce(null, state);
        switch (cmd) {
            .continue_ => return .continue_,
            .skip => return .skip,
            .abort => return .abort,
            .env => {
                const pairs = expr.envToPairs(alloc, env) catch {
                    logLine(opts, alloc, job, step, "warning: cannot format breakpoint environment");
                    continue;
                };
                for (pairs) |pair| {
                    const masked = std.mem.startsWith(u8, pair.name, "secrets.") or isSecretValue(opts, pair.value);
                    const line = std.fmt.allocPrint(alloc, "env {s}={s}", .{ pair.name, if (masked) "***" else pair.value }) catch continue;
                    logLine(opts, alloc, job, step, line);
                }
            },
            .workdir => {
                const wd = if (step.workdir) |raw| expr.interpolate(alloc, raw, env) catch raw else shared.workspace_abs;
                const line = std.fmt.allocPrint(alloc, "workspace={s} workdir={s}", .{ shared.workspace_abs, if (isSecretValue(opts, wd)) "***" else wd }) catch continue;
                logLine(opts, alloc, job, step, line);
            },
            .shell => {
                var shell_env: std.ArrayList(ir.EnvPair) = .empty;
                shell_env.appendSlice(alloc, base_env) catch {
                    logLine(opts, alloc, job, step, "warning: cannot build shell environment");
                    continue;
                };
                for (step.env) |pair| {
                    const value = expr.interpolate(alloc, pair.value, env) catch pair.value;
                    shell_env.append(alloc, .{ .name = pair.name, .value = value }) catch continue;
                }
                const workdir = if (step.workdir) |raw| expr.interpolate(alloc, raw, env) catch raw else null;
                const opened = debug_mod.shell(alloc, backend, handle, workdir, shell_env.items) catch {
                    logLine(opts, alloc, job, step, "warning: drop-to-shell failed");
                    continue;
                };
                if (!opened) logLine(opts, alloc, job, step, "drop-to-shell not supported on this backend");
            },
            .retry, .invalid => logLine(opts, alloc, job, step, "invalid command; choose c, s, e, w, sh, or a"),
        }
    }
}

const FailureAction = enum { continue_, retry, abort };

fn handleStepFailure(
    alloc: std.mem.Allocator,
    opts: RunOptions,
    shared: *Shared,
    job_index: usize,
    backend: backend_mod.Backend,
    handle: *backend_mod.JobHandle,
    job: ir.Job,
    step: ir.Step,
    step_index: usize,
    workdir: ?[]const u8,
    env: []const ir.EnvPair,
) FailureAction {
    switch (opts.on_failure) {
        .continue_ => return .continue_,
        .stop => {
            shared.halt.store(true, .release);
            return .abort;
        },
        .shell => {},
    }

    shared.prompt_mutex.lock();
    defer shared.prompt_mutex.unlock();
    if (opts.prompt_fn == null and !debug_mod.isTty()) {
        logLine(opts, alloc, job, step, "warning: --on-failure shell ignored because stdin is not a TTY");
        return .continue_;
    }

    const opened = debug_mod.shell(alloc, backend, handle, workdir, env) catch blk: {
        logLine(opts, alloc, job, step, "warning: drop-to-shell failed");
        break :blk false;
    };
    if (!opened) logLine(opts, alloc, job, step, "drop-to-shell not supported on this backend");
    logLine(opts, alloc, job, step, "failure shell exited — (c)ontinue (r)etry (a)bort");
    var state_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer state_arena.deinit();
    const state_alloc = state_arena.allocator();
    var prompt_env: std.ArrayList(ir.EnvPair) = .empty;
    for (env) |pair| putPromptEnv(state_alloc, &prompt_env, pair) catch return .continue_;
    const state = makePromptState(state_alloc, opts, .failure, shared.workspace_abs, job_index, job, step, step_index, prompt_env.items, workdir) catch return .continue_;
    while (true) {
        const cmd = if (opts.prompt_fn) |prompt| prompt(opts.prompt_ctx, state) else debug_mod.promptOnce(null, state);
        switch (cmd) {
            .continue_ => return .continue_,
            .retry => return .retry,
            .abort => {
                shared.halt.store(true, .release);
                return .abort;
            },
            else => logLine(opts, alloc, job, step, "invalid command; choose c, r, or a"),
        }
    }
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

    if (shared.halt.load(.acquire)) return skipped;

    if (opts.job_filter) |f| if (!std.mem.eql(u8, f, job.id)) return skipped;
    if (job.manual and opts.job_filter == null) {
        logJob(opts, alloc, job, "manual job skipped (run with --job)");
        return skipped;
    }
    if (!gha.matrixMatches(job, opts.matrix_filter)) return skipped;
    if (opts.resume_from == null) {
        if (needsFailed(p, results, done, job)) return skipped;
    } else {
        // Resume: skipped upstreams are expected (their outputs were seeded
        // from the record); only an explicit failure THIS run blocks a job.
        for (job.needs) |n| {
            for (p.jobs, 0..) |other, oi| {
                if (std.mem.eql(u8, other.id, n) and done[oi] and results[oi].status == .failed) return skipped;
            }
        }
    }

    // Resume target? Then the job env comes from the snapshot manifest
    // (verbatim, no re-evaluation) and earlier steps stay skipped.
    var resume_start: usize = 0;
    var resume_step: ?[]const u8 = null;
    var resume_m: ?snap_manifest.Manifest = null;
    if (opts.resume_from) |rp| {
        if (std.mem.eql(u8, rp.job_id, job.id) and shared.resume_manifest != null) {
            resume_m = shared.resume_manifest;
            resume_step = rp.step;
        }
    }

    // Build base expression environment for this job.
    var env = expr.Env{};
    const cwd = if (shared.workspace_abs.len > 0)
        shared.workspace_abs
    else
        (std.fs.cwd().realpathAlloc(alloc, ".") catch ".");
    var merged_env: std.ArrayList(ir.EnvPair) = .empty;
    if (resume_m) |m| {
        env = try expr.envFromPairs(alloc, m.env);
        try env.put(alloc, "github.workspace", cwd);
        // env.* keys flatten back into the merged env pairs the step
        // branches expect as the spawn-env base.
        for (m.env) |pr| {
            if (std.mem.startsWith(u8, pr.name, "env."))
                try merged_env.append(alloc, .{ .name = pr.name["env.".len..], .value = pr.value });
        }
        if (resume_step) |rs| resume_start = resumeStepIndex(job, rs).?;
    } else {
        try env.put(alloc, "github.ref", "refs/heads/main");
        try env.put(alloc, "github.event_name", "workflow_dispatch");
        try env.put(alloc, "github.sha", "0000000000000000000000000000000000000000");
        try env.put(alloc, "github.actor", "jalan");
        try env.put(alloc, "github.workspace", cwd);
        for (job.matrix) |m| try env.put(alloc, try key2(alloc, "matrix", m.name), m.value);
        for (opts.secrets) |s| try env.put(alloc, try key2(alloc, "secrets", s.name), s.value);
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
    }
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
        if (shared.halt.load(.acquire)) break;
        if (opts.step_filter) |f| if (!std.mem.eql(u8, f, step.id)) continue;
        if (si < resume_start) continue; // resume: steps before the target stay skipped
        if (job_status == .failed) {
            const cond = step.cond orelse continue;
            if (std.mem.indexOf(u8, cond, "always()") == null) continue; // stays .skipped
        }
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

        const lock_workspace = opts.snapshot or opts.cache;
        if (lock_workspace) shared.workspace_mutex.lock();
        defer if (lock_workspace) shared.workspace_mutex.unlock();

        if (opts.debug_all_steps or hasBreakpoint(opts, job, step, si)) switch (handleBreakpoint(alloc, opts, shared, index, job, step, si, &env, b, &handle, merged_env.items)) {
            .continue_ => {},
            .skip => continue,
            .abort => {
                steps[si] = .{ .name = step.name, .status = .failed, .exit_code = 1, .duration_ms = 0, .stdout = "", .stderr = "aborted at breakpoint" };
                job_status = .failed;
                shared.halt.store(true, .release);
                break :step_loop;
            },
        };

        const snapshot_cap = if (opts.snapshot)
            captureStep(alloc, opts, shared, job, index, step, si, &env, mutex)
        else
            null;

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
            var key_step = step;
            key_step.with = with_list.items;
            const uses_identity = if (opts.cache) resolvedUsesIdentity(alloc, opts, key_step) else key_step.uses_ref;
            if (uses_identity) |identity| key_step.uses_ref = identity;
            const cb = cacheBegin(
                alloc,
                opts,
                job,
                b,
                &handle,
                step,
                key_step,
                step_env.items,
                shared.workspace_abs,
                snapshot_cap,
                uses_identity != null and !nixSetupSideEffect(b.kind, step.uses_ref),
            );
            if (cb.hit) |entry| {
                const cached_outcome = backend_mod.StepOutcome{ .exit_code = entry.exit_code, .stdout = entry.stdout, .stderr = entry.stderr, .outputs = entry.outputs };
                const cok = try applyStepOutcome(alloc, step, si, t0, cached_outcome, steps, job, shared, mutex, &env);
                logLine(opts, alloc, job, step, "(cached)");
                if (!cok and !step.continue_on_error) job_status = .failed;
                continue;
            }

            var attempt: usize = 0;
            uses_attempt: while (true) {
                var err_msg: ?[]const u8 = null;
                const outcome = runner.runUses(alloc, step, with_list.items, step_env.items, b, &handle, &env, opts.log, opts.force_pull, &err_msg) catch {
                    steps[si] = .{ .name = step.name, .status = .failed, .exit_code = -1, .duration_ms = 0, .stdout = "", .stderr = err_msg orelse "spawn failed" };
                    if (!step.continue_on_error) {
                        const action = if (attempt == 0 or opts.on_failure == .stop)
                            handleStepFailure(alloc, opts, shared, index, b, &handle, job, step, si, null, step_env.items)
                        else
                            FailureAction.continue_;
                        if (action == .retry and attempt == 0) {
                            attempt += 1;
                            continue :uses_attempt;
                        }
                        job_status = .failed;
                    }
                    break :uses_attempt;
                };
                const ok = try applyStepOutcome(alloc, step, si, t0, outcome, steps, job, shared, mutex, &env);
                if (ok) {
                    if (cb.hex) |hex| cacheCommit(alloc, opts, shared.workspace_abs, hex, cb.pre, outcome);
                    break :uses_attempt;
                }
                if (step.continue_on_error) {
                    try publishStepOutputs(alloc, step, outcome.outputs, job, shared, mutex, &env);
                    break :uses_attempt;
                }
                const action = if (attempt == 0 or opts.on_failure == .stop)
                    handleStepFailure(alloc, opts, shared, index, b, &handle, job, step, si, null, step_env.items)
                else
                    FailureAction.continue_;
                if (action == .retry and attempt == 0) {
                    attempt += 1;
                    continue :uses_attempt;
                }
                try publishStepOutputs(alloc, step, outcome.outputs, job, shared, mutex, &env);
                job_status = .failed;
                break :uses_attempt;
            }
            continue :step_loop;
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

        const cb = cacheBegin(alloc, opts, job, b, &handle, step, patched, spawn_env.items, shared.workspace_abs, snapshot_cap, true);
        if (cb.hit) |entry| {
            const cached_outcome = backend_mod.StepOutcome{ .exit_code = entry.exit_code, .stdout = entry.stdout, .stderr = entry.stderr, .outputs = entry.outputs };
            const cok = try applyStepOutcome(alloc, step, si, t0, cached_outcome, steps, job, shared, mutex, &env);
            logLine(opts, alloc, job, step, "(cached)");
            if (!cok and !step.continue_on_error) job_status = .failed;
            continue;
        }
        if (cb.hex) |hex| patched.input_hash = hex;

        var attempt: usize = 0;
        run_attempt: while (true) {
            var err_msg: ?[]const u8 = null;
            const outcome = b.runStep(alloc, &handle, patched, spawn_env.items, workdir, &err_msg) catch {
                steps[si] = .{ .name = step.name, .status = .failed, .exit_code = -1, .duration_ms = 0, .stdout = "", .stderr = err_msg orelse "spawn failed" };
                if (!step.continue_on_error) {
                    const action = if (attempt == 0 or opts.on_failure == .stop)
                        handleStepFailure(alloc, opts, shared, index, b, &handle, job, step, si, workdir, spawn_env.items)
                    else
                        FailureAction.continue_;
                    if (action == .retry and attempt == 0) {
                        attempt += 1;
                        continue :run_attempt;
                    }
                    job_status = .failed;
                }
                break :run_attempt;
            };
            const ok = try applyStepOutcome(alloc, step, si, t0, outcome, steps, job, shared, mutex, &env);
            if (ok) {
                if (cb.hex) |hex| cacheCommit(alloc, opts, shared.workspace_abs, hex, cb.pre, outcome);
                break :run_attempt;
            }
            if (step.continue_on_error) {
                try publishStepOutputs(alloc, step, outcome.outputs, job, shared, mutex, &env);
                break :run_attempt;
            }
            const action = if (attempt == 0 or opts.on_failure == .stop)
                handleStepFailure(alloc, opts, shared, index, b, &handle, job, step, si, workdir, spawn_env.items)
            else
                FailureAction.continue_;
            if (action == .retry and attempt == 0) {
                attempt += 1;
                continue :run_attempt;
            }
            try publishStepOutputs(alloc, step, outcome.outputs, job, shared, mutex, &env);
            job_status = .failed;
            break :run_attempt;
        }
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
    if (ok) try publishStepOutputs(alloc, step, outcome.outputs, job, shared, mutex, env);
    return ok;
}

fn publishStepOutputs(
    alloc: std.mem.Allocator,
    step: ir.Step,
    outputs: []const ir.EnvPair,
    job: ir.Job,
    shared: *Shared,
    mutex: *std.Thread.Mutex,
    env: *expr.Env,
) !void {
    for (outputs) |o| {
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
