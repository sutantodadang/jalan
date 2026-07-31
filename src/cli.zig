//! CLI: lint command and provider detection.
const std = @import("std");
const yaml = @import("yaml.zig");
const ir = @import("ir.zig");
const gha = @import("frontend/gha.zig");
const engine = @import("engine.zig");

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

const LintArgs = struct { json: bool = false, strict: bool = false, file: ?[]const u8 = null };

/// Bad-args detection for `jalan lint`: any `-`/`--`-prefixed token that
/// isn't a recognized flag is rejected rather than silently treated as a
/// (nonexistent) positional file path — mirrors parseRunArgs.
fn parseLintArgs(args: []const []const u8) error{BadArgs}!LintArgs {
    var r = LintArgs{};
    for (args) |a2| {
        if (std.mem.eql(u8, a2, "--json")) {
            r.json = true;
        } else if (std.mem.eql(u8, a2, "--strict")) {
            r.strict = true;
        } else if (std.mem.startsWith(u8, a2, "-") and a2.len > 1) {
            return error.BadArgs;
        } else {
            r.file = a2;
        }
    }
    return r;
}

fn printDiags(alloc: std.mem.Allocator, path: []const u8, diags: *const yaml.Diags, out: *std.ArrayList(u8)) !void {
    for (diags.list.items) |d|
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}:{d}: {s}\n", .{ path, d.line, d.col, d.msg }));
}

pub const RunArgs = struct {
    file: ?[]const u8 = null,
    job: ?[]const u8 = null,
    step: ?[]const u8 = null,
    dry_run: bool = false,
    strict: bool = false,
    no_color: bool = false,
    max_parallel: usize = 4,
    env: []ir.EnvPair = &.{},
    matrix: []ir.EnvPair = &.{},
    secret_file: ?[]const u8 = null,
};

test "parse run args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_][]const u8{ "wf.yml", "-j", "build", "--dry-run", "--env", "A=1", "--matrix", "os=linux", "--max-parallel", "2" };
    const r = try parseRunArgs(a, &args);
    try std.testing.expectEqualStrings("wf.yml", r.file.?);
    try std.testing.expectEqualStrings("build", r.job.?);
    try std.testing.expect(r.dry_run);
    try std.testing.expectEqualStrings("A", r.env[0].name);
    try std.testing.expectEqualStrings("linux", r.matrix[0].value);
    try std.testing.expectEqual(@as(usize, 2), r.max_parallel);
}

test "unknown flag is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadArgs, parseRunArgs(arena.allocator(), &[_][]const u8{"--bogus"}));
}

test "unknown single-dash flag is an error, not a positional file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadArgs, parseRunArgs(arena.allocator(), &[_][]const u8{"-x"}));
}

test "secrets file parses k=v with comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pairs = try parseSecretsText(a, "# comment\nTOKEN=abc\nEMPTY=\n");
    try std.testing.expectEqual(@as(usize, 2), pairs.len);
    try std.testing.expectEqualStrings("TOKEN", pairs[0].name);
    try std.testing.expectEqualStrings("abc", pairs[0].value);
}

pub fn parseRunArgs(alloc: std.mem.Allocator, args: []const []const u8) !RunArgs {
    var r = RunArgs{};
    var env: std.ArrayList(ir.EnvPair) = .empty;
    var matrix: std.ArrayList(ir.EnvPair) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--job")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            r.job = args[i];
        } else if (std.mem.eql(u8, arg, "--step")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            r.step = args[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            r.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            r.strict = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            r.no_color = true;
        } else if (std.mem.eql(u8, arg, "--max-parallel")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            r.max_parallel = std.fmt.parseInt(usize, args[i], 10) catch return error.BadArgs;
        } else if (std.mem.eql(u8, arg, "--env")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            try env.append(alloc, splitPair(args[i]) orelse return error.BadArgs);
        } else if (std.mem.eql(u8, arg, "--matrix")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            try matrix.append(alloc, splitPair(args[i]) orelse return error.BadArgs);
        } else if (std.mem.eql(u8, arg, "--secret-file")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            r.secret_file = args[i];
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // Any other `-`/`--`-prefixed token (single-dash unknowns included,
            // e.g. `-x`) is an unrecognized flag, not a positional file path.
            return error.BadArgs;
        } else if (r.file == null) {
            r.file = arg;
        } else return error.BadArgs;
    }
    r.env = try env.toOwnedSlice(alloc);
    r.matrix = try matrix.toOwnedSlice(alloc);
    return r;
}

fn anyJobRan(jobs: []const engine.JobResult) bool {
    for (jobs) |j| if (j.status != .skipped) return true;
    return false;
}

fn anyStepRan(jobs: []const engine.JobResult) bool {
    for (jobs) |j| for (j.steps) |s| if (s.status != .skipped) return true;
    return false;
}

fn formatMatrixFilter(alloc: std.mem.Allocator, matrix: []const ir.EnvPair) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (matrix) |m| try parts.append(alloc, try std.fmt.allocPrint(alloc, "{s}={s}", .{ m.name, m.value }));
    return std.mem.join(alloc, ",", parts.items);
}

fn splitPair(s: []const u8) ?ir.EnvPair {
    const eq = std.mem.indexOfScalar(u8, s, '=') orelse return null;
    if (eq == 0) return null;
    return .{ .name = s[0..eq], .value = s[eq + 1 ..] };
}

pub fn parseSecretsText(alloc: std.mem.Allocator, text: []const u8) ![]ir.EnvPair {
    var out: std.ArrayList(ir.EnvPair) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \r");
        if (l.len == 0 or l[0] == '#') continue;
        if (splitPair(l)) |p| try out.append(alloc, p);
    }
    return out.toOwnedSlice(alloc);
}

pub fn main(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) return help();
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help")) return help();
    if (std.mem.eql(u8, cmd, "version")) return print("jalan 0.1.0\n");
    if (std.mem.eql(u8, cmd, "lint")) {
        const la = parseLintArgs(args[1..]) catch {
            _ = try print("error: bad arguments (see 'jalan help')\n");
            return 2;
        };
        const path = la.file orelse (try findDefaultWorkflow(alloc)) orelse {
            _ = try print("error: no workflow found in .github/workflows\n");
            return 2;
        };
        var out: std.ArrayList(u8) = .empty;
        const code = try lintMain(alloc, path, la.json, la.strict, &out);
        _ = try print(out.items);
        return code;
    }
    if (std.mem.eql(u8, cmd, "run")) {
        const ra = parseRunArgs(alloc, args[1..]) catch {
            _ = try print("error: bad arguments (see 'jalan help')\n");
            return 2;
        };
        return runMain(alloc, ra);
    }
    _ = try print("error: unknown command\n");
    return 2;
}

fn print(s: []const u8) !u8 {
    try std.fs.File.stdout().writeAll(s);
    return 0;
}

var stderr_log_mutex: std.Thread.Mutex = .{};

// Thread-safe per RunOptions.log contract: called from worker threads under
// parallel job execution.
fn logToStderr(line: []const u8) void {
    stderr_log_mutex.lock();
    defer stderr_log_mutex.unlock();
    std.fs.File.stderr().writeAll(line) catch return;
    std.fs.File.stderr().writeAll("\n") catch return;
}

fn help() !u8 {
    return print(
        \\jalan — local CI simulator
        \\
        \\usage:
        \\  jalan lint [file] [--json] [--strict]
        \\  jalan run [file] [-j <job>] [--step <id>] [--dry-run] [--env K=V]...
        \\            [--secret-file <path>] [--matrix k=v]... [--max-parallel N]
        \\            [--strict] [--no-color]
        \\  jalan version
        \\  jalan help
        \\
    );
}

const ansi_green = "\x1b[32m";
const ansi_red = "\x1b[31m";
const ansi_dim_yellow = "\x1b[2;33m";
const ansi_reset = "\x1b[0m";

fn colorsEnabled(alloc: std.mem.Allocator, ra: RunArgs) bool {
    if (ra.no_color) return false;
    const has = std.process.hasEnvVar(alloc, "NO_COLOR") catch false;
    return !has;
}

pub fn runMain(alloc: std.mem.Allocator, ra: RunArgs) !u8 {
    const path = ra.file orelse (try findDefaultWorkflow(alloc)) orelse {
        _ = try print("error: no workflow found in .github/workflows\n");
        return 2;
    };
    const source = std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024) catch {
        _ = try print(try std.fmt.allocPrint(alloc, "error: cannot read '{s}'\n", .{path}));
        return 3;
    };
    if (detectProvider(path, source) == .unknown) {
        _ = try print("error: could not detect CI provider (phase 1 supports GitHub Actions only)\n");
        return 2;
    }
    var diags = yaml.Diags.init(alloc);
    const pipeline = gha.parseWorkflow(alloc, path, source, &diags) catch |e| switch (e) {
        error.ParseFailed => {
            var out: std.ArrayList(u8) = .empty;
            try printDiags(alloc, path, &diags, &out);
            _ = try print(out.items);
            return 2;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    {
        var out: std.ArrayList(u8) = .empty;
        try printDiags(alloc, path, &diags, &out);
        if (out.items.len > 0) _ = try print(out.items);
    }
    if (ra.strict and diags.list.items.len > 0) return 2;

    var secrets: []ir.EnvPair = &.{};
    if (ra.secret_file) |sf| {
        const text = std.fs.cwd().readFileAlloc(alloc, sf, 1024 * 1024) catch {
            _ = try print(try std.fmt.allocPrint(alloc, "error: cannot read secret file '{s}'\n", .{sf}));
            return 3;
        };
        secrets = try parseSecretsText(alloc, text);
    } else {
        const default_path = ".jalan/secrets.env";
        if (std.fs.cwd().readFileAlloc(alloc, default_path, 1024 * 1024)) |text| {
            secrets = try parseSecretsText(alloc, text);
        } else |_| {}
    }

    const report = engine.run(alloc, pipeline, .{
        .job_filter = ra.job,
        .step_filter = ra.step,
        .dry_run = ra.dry_run,
        .max_parallel = ra.max_parallel,
        .extra_env = ra.env,
        .secrets = secrets,
        .matrix_filter = ra.matrix,
        .log = &logToStderr,
    }) catch |e| switch (e) {
        error.InternalError => {
            _ = try print("internal error: engine failed\n");
            return 3;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (ra.job != null or ra.matrix.len > 0) {
        if (!anyJobRan(report.jobs)) {
            if (ra.job) |jf| {
                _ = try print(try std.fmt.allocPrint(alloc, "error: no job matching '{s}'\n", .{jf}));
            } else {
                _ = try print(try std.fmt.allocPrint(alloc, "error: no job matching '{s}'\n", .{try formatMatrixFilter(alloc, ra.matrix)}));
            }
            return 2;
        }
    }
    if (ra.step) |sf| {
        if (!anyStepRan(report.jobs)) {
            _ = try print(try std.fmt.allocPrint(alloc, "error: no step matching '{s}'\n", .{sf}));
            return 2;
        }
    }

    const use_color = colorsEnabled(alloc, ra);
    var out: std.ArrayList(u8) = .empty;
    for (report.jobs) |j| {
        for (j.steps) |s| {
            if (s.status == .skipped) continue;
            var lines = std.mem.splitScalar(u8, s.stdout, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "[{s}/{s}] {s}\n", .{ j.display_name, s.name, line }));
            }
            var elines = std.mem.splitScalar(u8, s.stderr, '\n');
            while (elines.next()) |line| {
                if (line.len == 0) continue;
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "[{s}/{s}] {s} (stderr)\n", .{ j.display_name, s.name, line }));
            }
        }
    }

    try out.appendSlice(alloc, "── summary ──────────────────────\n");
    for (report.jobs) |j| {
        switch (j.status) {
            .success => {
                var total_ms: u64 = 0;
                for (j.steps) |s| total_ms += s.duration_ms;
                const mark = if (use_color) ansi_green ++ "\xe2\x9c\x93" ++ ansi_reset else "\xe2\x9c\x93";
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s}   {d} steps   {d}ms\n", .{ mark, j.display_name, j.steps.len, total_ms }));
            },
            .failed => {
                // A job can have multiple `.failed` steps if earlier ones were
                // `continue-on-error: true` (they fail but don't stop the job).
                // The engine's step loop (see engine.zig runJob) breaks
                // immediately after the first non-continue-on-error failure,
                // so that fatal step is always the LAST `.failed` entry in
                // `j.steps` — keep overwriting instead of breaking on first
                // match, or an earlier continue-on-error failure gets blamed
                // instead of the step that actually failed the job.
                var failed_step: ?engine.StepResult = null;
                for (j.steps) |s| if (s.status == .failed) {
                    failed_step = s;
                };
                const mark = if (use_color) ansi_red ++ "\xe2\x9c\x97" ++ ansi_reset else "\xe2\x9c\x97";
                if (failed_step) |fs| {
                    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s}   failed at '{s}' (exit {d})\n", .{ mark, j.display_name, fs.name, fs.exit_code }));
                } else {
                    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s}   failed\n", .{ mark, j.display_name }));
                }
            },
            .skipped => {
                const mark = if (use_color) ansi_dim_yellow ++ "\xe2\x97\x8b" ++ ansi_reset else "\xe2\x97\x8b";
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s}   skipped\n", .{ mark, j.display_name }));
            },
        }
    }

    // Log tail: last 20 lines of the failing step's stdout+stderr, for each failed job.
    for (report.jobs) |j| {
        if (j.status != .failed) continue;
        for (j.steps) |s| {
            if (s.status != .failed) continue;
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\n── log tail: {s}/{s} ──\n", .{ j.display_name, s.name }));
            var combined: std.ArrayList(u8) = .empty;
            try combined.appendSlice(alloc, s.stdout);
            if (s.stdout.len > 0 and !std.mem.endsWith(u8, s.stdout, "\n")) try combined.append(alloc, '\n');
            try combined.appendSlice(alloc, s.stderr);
            var all_lines: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, combined.items, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                try all_lines.append(alloc, line);
            }
            const start = if (all_lines.items.len > 20) all_lines.items.len - 20 else 0;
            for (all_lines.items[start..]) |line|
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}\n", .{line}));
        }
    }

    _ = try print(out.items);
    return if (report.ok()) 0 else 1;
}

// NOTE: runMain()/main() write directly to real process stdout via print().
// Under `zig build test`'s --listen=- IPC protocol, stdout IS the test-result
// channel — calling these from a test corrupts the protocol and aborts the
// whole test binary (observed: "the following command exited with code 1"
// instead of a normal per-test failure). So I5/M2 are covered here only at
// the pure-logic level (anyJobRan/anyStepRan/parseLintArgs); the full
// runMain/main CLI behavior is verified by the manual smoke tests in the
// fix-wave report instead.
test "anyJobRan / anyStepRan: false when every job or step is skipped" {
    var steps_a = [_]engine.StepResult{.{ .name = "s", .status = .skipped, .exit_code = 0, .duration_ms = 0, .stdout = "", .stderr = "" }};
    var jobs_all_skipped = [_]engine.JobResult{.{ .job_index = 0, .display_name = "a", .status = .skipped, .steps = &steps_a }};
    try std.testing.expect(!anyJobRan(&jobs_all_skipped));
    try std.testing.expect(!anyStepRan(&jobs_all_skipped));

    var steps_b = [_]engine.StepResult{.{ .name = "s", .status = .success, .exit_code = 0, .duration_ms = 0, .stdout = "", .stderr = "" }};
    var jobs_ran = [_]engine.JobResult{.{ .job_index = 0, .display_name = "a", .status = .success, .steps = &steps_b }};
    try std.testing.expect(anyJobRan(&jobs_ran));
    try std.testing.expect(anyStepRan(&jobs_ran));
}

test "parseLintArgs rejects unrecognized flags but accepts known flags and file" {
    try std.testing.expectError(error.BadArgs, parseLintArgs(&[_][]const u8{"--bogus"}));
    const la = try parseLintArgs(&[_][]const u8{ "--json", "--strict", "wf.yml" });
    try std.testing.expect(la.json);
    try std.testing.expect(la.strict);
    try std.testing.expectEqualStrings("wf.yml", la.file.?);
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
