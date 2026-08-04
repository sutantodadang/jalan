//! CLI: lint command and provider detection.
const std = @import("std");
const builtin = @import("builtin");
const yaml = @import("yaml.zig");
const ir = @import("ir.zig");
const gha = @import("frontend/gha.zig");
const gitlab = @import("frontend/gitlab.zig");
const jenkins = @import("frontend/jenkins.zig");
const circleci = @import("frontend/circleci.zig");
const azure = @import("frontend/azure.zig");
const bitbucket = @import("frontend/bitbucket.zig");
const translate_mod = @import("translate.zig");
const engine = @import("engine.zig");
const config = @import("config.zig");
const backend = @import("backend.zig");
const docker_backend = @import("backend/docker.zig");
const nix_backend = @import("backend/nix.zig");
const client = @import("docker/client.zig");
const runrecord = @import("snap/runrecord.zig");
const debug_mod = @import("debug.zig");
const tui = @import("tui.zig");

pub const Provider = enum { gha, gitlab, jenkins, circleci, azure, bitbucket, unknown };

fn pathBasename(path: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| i + 1 else 0;
    return path[start..];
}

/// True when `key` appears at the start of any line in `source` — root-level
/// YAML keys sit at column 0, which keeps sniffs from matching nested keys.
fn hasRootKey(source: []const u8, key: []const u8) bool {
    if (std.mem.startsWith(u8, source, key)) return true;
    var rest = source;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        rest = rest[nl + 1 ..];
        if (std.mem.startsWith(u8, rest, key)) return true;
    }
    return false;
}

pub fn detectProvider(path: []const u8, source: []const u8) Provider {
    const basename = pathBasename(path);
    if (std.mem.eql(u8, basename, ".gitlab-ci.yml") or std.mem.eql(u8, basename, ".gitlab-ci.yaml")) return .gitlab;
    if (std.mem.endsWith(u8, basename, ".jenkinsfile") or std.mem.startsWith(u8, basename, "Jenkinsfile")) return .jenkins;
    if (std.mem.startsWith(u8, basename, "azure-pipelines.") or std.mem.startsWith(u8, basename, ".azure-pipelines.")) return .azure;
    if (std.mem.startsWith(u8, basename, "bitbucket-pipelines.")) return .bitbucket;
    if (std.mem.indexOf(u8, path, ".circleci/") != null or
        std.mem.indexOf(u8, path, ".circleci\\") != null) return .circleci;
    if (std.mem.indexOf(u8, path, ".github/workflows") != null or
        std.mem.indexOf(u8, path, ".github\\workflows") != null) return .gha;
    // Provider-distinctive content sniffs come before the loose GHA sniff:
    // CircleCI/Azure configs also contain `jobs:` + `steps:`.
    if (hasRootKey(source, "pipelines:")) return .bitbucket;
    if (std.mem.indexOf(u8, source, "vmImage") != null or
        hasRootKey(source, "pool:") or
        std.mem.indexOf(u8, source, "- task:") != null) return .azure;
    if (hasRootKey(source, "workflows:") and hasRootKey(source, "version:")) return .circleci;
    if (std.mem.indexOf(u8, source, "jobs:") != null and
        (std.mem.indexOf(u8, source, "runs-on") != null or
            std.mem.indexOf(u8, source, "steps:") != null)) return .gha;
    if (std.mem.indexOf(u8, source, "pipeline {") != null or std.mem.indexOf(u8, source, "pipeline{") != null) return .jenkins;
    if (std.mem.indexOf(u8, source, "node {") != null or std.mem.indexOf(u8, source, "node{") != null) return .jenkins;
    return .unknown;
}

fn parseProvider(
    alloc: std.mem.Allocator,
    provider: Provider,
    path: []const u8,
    source: []const u8,
    diags: *yaml.Diags,
) !ir.Pipeline {
    return switch (provider) {
        .gha => gha.parseWorkflow(alloc, path, source, diags),
        .gitlab => gitlab.parsePipeline(alloc, path, source, diags),
        .jenkins => jenkins.parsePipeline(alloc, path, source, diags),
        .circleci => circleci.parsePipeline(alloc, path, source, diags),
        .azure => azure.parsePipeline(alloc, path, source, diags),
        .bitbucket => bitbucket.parsePipeline(alloc, path, source, diags),
        .unknown => unreachable,
    };
}

pub fn findDefaultWorkflow(alloc: std.mem.Allocator) !?[]const u8 {
    if (std.fs.cwd().openDir(".github/workflows", .{ .iterate = true })) |dir_value| {
        var dir = dir_value;
        defer dir.close();
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next()) |e| {
            if (e.kind != .file) continue;
            if (std.mem.endsWith(u8, e.name, ".yml") or std.mem.endsWith(u8, e.name, ".yaml"))
                try names.append(alloc, try std.fmt.allocPrint(alloc, ".github/workflows/{s}", .{e.name}));
        }
        if (names.items.len > 0) {
            std.mem.sort([]const u8, names.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            return names.items[0];
        }
    } else |_| {}
    if (std.fs.cwd().access(".gitlab-ci.yml", .{})) |_| return ".gitlab-ci.yml" else |_| {}
    if (std.fs.cwd().access(".gitlab-ci.yaml", .{})) |_| return ".gitlab-ci.yaml" else |_| {}
    if (std.fs.cwd().access("Jenkinsfile", .{})) |_| return "Jenkinsfile" else |_| {}
    if (std.fs.cwd().access(".circleci/config.yml", .{})) |_| return ".circleci/config.yml" else |_| {}
    if (std.fs.cwd().access("azure-pipelines.yml", .{})) |_| return "azure-pipelines.yml" else |_| {}
    if (std.fs.cwd().access("bitbucket-pipelines.yml", .{})) |_| return "bitbucket-pipelines.yml" else |_| {}
    return null;
}

const TranslateArgs = struct { file: ?[]const u8 = null, to: ?[]const u8 = null, out_path: ?[]const u8 = null };

fn parseTranslateArgs(args: []const []const u8) !TranslateArgs {
    var t = TranslateArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--to")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            t.to = args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            t.out_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            return error.BadArgs;
        } else {
            if (t.file != null) return error.BadArgs;
            t.file = arg;
        }
    }
    if (t.to == null) return error.BadArgs;
    return t;
}

pub fn translateMain(alloc: std.mem.Allocator, path: []const u8, target: translate_mod.Target, out_path: ?[]const u8, out: *std.ArrayList(u8)) !u8 {
    const source = std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024) catch {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "error: cannot read '{s}'\n", .{path}));
        return 3;
    };
    const provider = detectProvider(path, source);
    if (provider == .unknown) {
        try out.appendSlice(alloc, "error: could not detect CI provider (supported providers: GitHub Actions, GitLab CI, Jenkins, CircleCI, Azure Pipelines, and Bitbucket Pipelines)\n");
        return 2;
    }
    var diags = yaml.Diags.init(alloc);
    const pipeline = parseProvider(alloc, provider, path, source, &diags) catch |e| switch (e) {
        error.ParseFailed => {
            try printDiags(alloc, path, &diags, out);
            return 2;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    try printDiags(alloc, path, &diags, out);
    const text = try translate_mod.emit(alloc, pipeline, target);
    if (out_path) |op| {
        std.fs.cwd().writeFile(.{ .sub_path = op, .data = text }) catch {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "error: cannot write '{s}'\n", .{op}));
            return 3;
        };
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "wrote {s}\n", .{op}));
    } else {
        try out.appendSlice(alloc, text);
    }
    return 0;
}

pub fn lintMain(alloc: std.mem.Allocator, path: []const u8, json: bool, strict: bool, out: *std.ArrayList(u8)) !u8 {
    const source = std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024) catch {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "error: cannot read '{s}'\n", .{path}));
        return 3;
    };
    const provider = detectProvider(path, source);
    if (provider == .unknown) {
        try out.appendSlice(alloc, "error: could not detect CI provider (supported providers: GitHub Actions, GitLab CI, Jenkins, CircleCI, Azure Pipelines, and Bitbucket Pipelines)\n");
        return 2;
    }
    var diags = yaml.Diags.init(alloc);
    const pipeline = parseProvider(alloc, provider, path, source, &diags) catch |e| switch (e) {
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

const LintArgs = struct { json: bool = false, strict: bool = false, file: ?[]const u8 = null, backend: []const u8 = "auto" };

/// Bad-args detection for `jalan lint`: any `-`/`--`-prefixed token that
/// isn't a recognized flag is rejected rather than silently treated as a
/// (nonexistent) positional file path — mirrors parseRunArgs.
///
/// `--backend` is parsed and validated but otherwise unused by lint itself:
/// the `container:`/`services:` diagnostics it might once have suppressed
/// were removed from the gha frontend in Tasks 7-8 (they're real features
/// now, not warnings), so there's no stale suppression logic to gate here.
fn parseLintArgs(args: []const []const u8) error{BadArgs}!LintArgs {
    var r = LintArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a2 = args[i];
        if (std.mem.eql(u8, a2, "--json")) {
            r.json = true;
        } else if (std.mem.eql(u8, a2, "--strict")) {
            r.strict = true;
        } else if (std.mem.eql(u8, a2, "--backend")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            if (!isValidBackendName(args[i])) return error.BadArgs;
            r.backend = args[i];
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
    backend: []const u8 = "auto",
    pull: bool = false,
    snapshot: ?bool = null,
    cache: ?bool = null,
    // `--isolate`/`--no-isolate`: force per-job workspace copies on/off.
    // null -> engine.RunOptions's auto rule (see there). Phase 3 modes
    // (snapshot/cache/breakpoints/step_all/resume) always force this off
    // regardless of what's passed here — the engine logs a warning if so.
    isolate: ?bool = null,
    breaks: []const []const u8 = &.{},
    on_failure: []const u8 = "continue",
    // True only when the user actually passed `--on-failure`; lets
    // `effectiveOnFailure` tell "explicitly continue" apart from "unset, so
    // pick a mode-appropriate default" (debug mode defaults to shell).
    on_failure_explicit: bool = false,
    resume_run: ?[]const u8 = null,
    resume_at: ?[]const u8 = null,
    tui: bool = false,
    // `--step-all`: break at every step (old `jalan debug` behavior). Off by
    // default so debug mode runs to the first failure instead of stopping at
    // every step.
    step_all: bool = false,
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

test "parseRunArgs accepts --backend nix and --pull" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_][]const u8{ "wf.yml", "--backend", "nix", "--pull" };
    const r = try parseRunArgs(a, &args);
    try std.testing.expectEqualStrings("nix", r.backend);
    try std.testing.expect(r.pull);
}

test "parseRunArgs defaults backend to auto and pull to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseRunArgs(arena.allocator(), &[_][]const u8{"wf.yml"});
    try std.testing.expectEqualStrings("auto", r.backend);
    try std.testing.expect(!r.pull);
}

test "parseRunArgs rejects an unknown --backend value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadArgs, parseRunArgs(arena.allocator(), &[_][]const u8{ "--backend", "bogus" }));
}

test "parseRunArgs rejects --backend with no value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadArgs, parseRunArgs(arena.allocator(), &[_][]const u8{"--backend"}));
}

test "parseRunArgs accepts phase 3 flags and repeated breakpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][]const u8{
        "wf.yml",       "--snapshot", "--cache",  "--break", "build/compile", "--break",       "test/0",
        "--on-failure", "stop",       "--resume", "run-1",   "--at",          "build/compile",
    };
    const parsed = try parseRunArgs(arena.allocator(), &args);
    try std.testing.expectEqual(true, parsed.snapshot.?);
    try std.testing.expectEqual(true, parsed.cache.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.breaks.len);
    try std.testing.expectEqualStrings("stop", parsed.on_failure);
    try std.testing.expectEqualStrings("run-1", parsed.resume_run.?);
    try std.testing.expectEqualStrings("build/compile", parsed.resume_at.?);
}

test "parseRunArgs validates phase 3 flag pairs and values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadArgs, parseRunArgs(a, &.{ "--resume", "r" }));
    try std.testing.expectError(error.BadArgs, parseRunArgs(a, &.{ "--at", "j/s" }));
    try std.testing.expectError(error.BadArgs, parseRunArgs(a, &.{ "--break", "missing-slash" }));
    try std.testing.expectError(error.BadArgs, parseRunArgs(a, &.{ "--on-failure", "explode" }));
    const toggles = try parseRunArgs(a, &.{ "--snapshot", "--no-snapshot", "--cache", "--no-cache" });
    try std.testing.expectEqual(false, toggles.snapshot.?);
    try std.testing.expectEqual(false, toggles.cache.?);
}

test "parseRunArgs accepts --step-all, off by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const default_r = try parseRunArgs(a, &[_][]const u8{"wf.yml"});
    try std.testing.expect(!default_r.step_all);
    try std.testing.expect(!default_r.on_failure_explicit);

    const r = try parseRunArgs(a, &[_][]const u8{ "wf.yml", "--step-all" });
    try std.testing.expect(r.step_all);
}

test "parseRunArgs marks on_failure_explicit only when --on-failure is passed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseRunArgs(a, &[_][]const u8{ "wf.yml", "--on-failure", "continue" });
    try std.testing.expect(r.on_failure_explicit);
    try std.testing.expectEqualStrings("continue", r.on_failure);
}

test "effectiveOnFailure: debug mode defaults to shell, run mode keeps continue, explicit always wins" {
    // jalan run, nothing passed -> unchanged "continue" default.
    try std.testing.expectEqual(engine.OnFailure.continue_, effectiveOnFailure(.{ .tui = false }));
    // jalan debug, nothing passed -> shell (that's what "debugging" means).
    try std.testing.expectEqual(engine.OnFailure.shell, effectiveOnFailure(.{ .tui = true }));
    // jalan debug --on-failure continue -> explicit wins over the debug default.
    try std.testing.expectEqual(engine.OnFailure.continue_, effectiveOnFailure(.{ .tui = true, .on_failure = "continue", .on_failure_explicit = true }));
    // jalan run --on-failure shell -> explicit wins (unchanged prior behavior).
    try std.testing.expectEqual(engine.OnFailure.shell, effectiveOnFailure(.{ .tui = false, .on_failure = "shell", .on_failure_explicit = true }));
}

test "resolveToggle applies CLI over config over defaults" {
    try std.testing.expect(resolveToggle(null, true));
    try std.testing.expect(!resolveToggle(null, false));
    try std.testing.expect(!resolveToggle(false, true));
    try std.testing.expect(resolveToggle(true, false));
}

test "resolveBackendChoice: explicit CLI non-auto beats config beats auto" {
    // 1. explicit CLI wins even when config also has an explicit value.
    try std.testing.expectEqualStrings("docker", resolveBackendChoice("docker", "nix"));
    // 2. explicit CLI wins when config is auto.
    try std.testing.expectEqualStrings("docker", resolveBackendChoice("docker", "auto"));
    // 3. CLI auto defers to a non-auto config value.
    try std.testing.expectEqualStrings("nix", resolveBackendChoice("auto", "nix"));
    // 4. both auto -> auto.
    try std.testing.expectEqualStrings("auto", resolveBackendChoice("auto", "auto"));
}

test "pickBackend(\"native\") returns a working backend through the vtable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const picked = try pickBackend(a, "native", .{}, null);
    try std.testing.expectEqualStrings("native", picked.desc);
    try std.testing.expectEqual(backend.Kind.native, picked.b.kind);

    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var handle = try picked.b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    defer picked.b.teardownJob(a, &handle);
    var err_msg: ?[]const u8 = null;
    const step = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = "echo via-pickbackend" };
    const out = try picked.b.runStep(a, &handle, step, &.{}, null, &err_msg);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "via-pickbackend") != null);
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
    var breaks: std.ArrayList([]const u8) = .empty;
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
        } else if (std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            if (!isValidBackendName(args[i])) return error.BadArgs;
            r.backend = args[i];
        } else if (std.mem.eql(u8, arg, "--pull")) {
            r.pull = true;
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            r.snapshot = true;
        } else if (std.mem.eql(u8, arg, "--no-snapshot")) {
            r.snapshot = false;
        } else if (std.mem.eql(u8, arg, "--cache")) {
            r.cache = true;
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            r.cache = false;
        } else if (std.mem.eql(u8, arg, "--isolate")) {
            r.isolate = true;
        } else if (std.mem.eql(u8, arg, "--no-isolate")) {
            r.isolate = false;
        } else if (std.mem.eql(u8, arg, "--break")) {
            i += 1;
            if (i >= args.len or splitSelector(args[i]) == null) return error.BadArgs;
            try breaks.append(alloc, args[i]);
        } else if (std.mem.eql(u8, arg, "--on-failure")) {
            i += 1;
            if (i >= args.len or !isValidOnFailure(args[i])) return error.BadArgs;
            r.on_failure = args[i];
            r.on_failure_explicit = true;
        } else if (std.mem.eql(u8, arg, "--step-all")) {
            r.step_all = true;
        } else if (std.mem.eql(u8, arg, "--resume")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            r.resume_run = args[i];
        } else if (std.mem.eql(u8, arg, "--at")) {
            i += 1;
            if (i >= args.len or splitSelector(args[i]) == null) return error.BadArgs;
            r.resume_at = args[i];
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
    r.breaks = try breaks.toOwnedSlice(alloc);
    if ((r.resume_run == null) != (r.resume_at == null)) return error.BadArgs;
    return r;
}

fn isValidOnFailure(value: []const u8) bool {
    return std.mem.eql(u8, value, "continue") or std.mem.eql(u8, value, "stop") or std.mem.eql(u8, value, "shell");
}

fn splitSelector(value: []const u8) ?struct { job: []const u8, step: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return null;
    if (slash == 0 or slash + 1 >= value.len or std.mem.indexOfScalar(u8, value[slash + 1 ..], '/') != null) return null;
    return .{ .job = value[0..slash], .step = value[slash + 1 ..] };
}

pub fn resolveToggle(cli_value: ?bool, config_value: bool) bool {
    return cli_value orelse config_value;
}

const backend_names = [_][]const u8{ "native", "docker", "podman", "nix", "auto" };

fn isValidBackendName(name: []const u8) bool {
    for (backend_names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Pure precedence for the effective `--backend` choice: an explicit
/// non-"auto" CLI flag always wins; otherwise a non-"auto" config value
/// wins; otherwise "auto" (pickBackend probes docker at run time).
pub fn resolveBackendChoice(cli_choice: []const u8, cfg_backend: []const u8) []const u8 {
    if (!std.mem.eql(u8, cli_choice, "auto")) return cli_choice;
    if (!std.mem.eql(u8, cfg_backend, "auto")) return cfg_backend;
    return "auto";
}

pub const PickedBackend = struct { b: backend.Backend, desc: []const u8 };

fn dockerDefaultSocket() []const u8 {
    return if (builtin.os.tag == .windows) "\\\\.\\pipe\\docker_engine" else "/var/run/docker.sock";
}

/// Ordered podman socket candidates: an explicit config override first, then
/// podman's own XDG-runtime-dir and system-wide sockets, then the plain
/// docker default as a last resort (podman also speaks the docker-compatible
/// API, sometimes exposed there).
fn podmanCandidates(alloc: std.mem.Allocator, cfg: config.Config) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (cfg.docker_socket) |s| try list.append(alloc, s);
    if (std.process.getEnvVarOwned(alloc, "XDG_RUNTIME_DIR") catch null) |xdg| {
        try list.append(alloc, try std.fmt.allocPrint(alloc, "{s}/podman/podman.sock", .{xdg}));
    }
    try list.append(alloc, "/run/podman/podman.sock");
    try list.append(alloc, dockerDefaultSocket());
    return list.toOwnedSlice(alloc);
}

/// Resolves `choice` ("native"|"docker"|"podman"|"nix"|"auto") into a live
/// `backend.Backend` plus a human-readable description for the "backend:
/// <desc>" line runMain prints. On failure (docker/podman socket
/// unreachable, nix missing) prints an actionable `error: ...` line itself
/// and returns `error.BackendUnavailable` — callers just map that to exit 3.
///
/// Docker/nix backend instances are allocated via `alloc.create` rather than
/// held on the stack, so the vtable's `ctx` pointer stays valid for the
/// whole run: `alloc` must be an arena (or otherwise outlive the returned
/// `Backend`), matching how `runMain` is invoked from `main()`.
pub fn pickBackend(alloc: std.mem.Allocator, choice: []const u8, cfg: config.Config, log: ?backend.LogFn) !PickedBackend {
    if (std.mem.eql(u8, choice, "native")) {
        return .{ .b = backend.native(), .desc = "native" };
    }
    if (std.mem.eql(u8, choice, "docker")) {
        const socket = client.detectSocket(alloc, cfg) orelse {
            _ = try print("error: no docker socket path could be determined\n");
            return error.BackendUnavailable;
        };
        const cl = client.Client{ .socket_path = socket };
        if (!client.ping(alloc, cl)) {
            _ = try print(try std.fmt.allocPrint(alloc, "error: docker socket not reachable at {s} \xe2\x80\x94 is Docker running? (or pass --backend native)\n", .{socket}));
            return error.BackendUnavailable;
        }
        const db = try alloc.create(docker_backend.DockerBackend);
        db.* = .{ .client = cl, .cfg = cfg };
        return .{ .b = db.backend(), .desc = try std.fmt.allocPrint(alloc, "docker ({s})", .{socket}) };
    }
    if (std.mem.eql(u8, choice, "podman")) {
        const candidates = try podmanCandidates(alloc, cfg);
        for (candidates) |socket| {
            const cl = client.Client{ .socket_path = socket };
            if (client.ping(alloc, cl)) {
                const db = try alloc.create(docker_backend.DockerBackend);
                db.* = .{ .client = cl, .cfg = cfg };
                return .{ .b = db.backend(), .desc = try std.fmt.allocPrint(alloc, "podman ({s})", .{socket}) };
            }
        }
        _ = try print("error: podman socket not reachable \xe2\x80\x94 is Podman running? (or pass --backend native)\n");
        return error.BackendUnavailable;
    }
    if (std.mem.eql(u8, choice, "nix")) {
        if (!nix_backend.nixAvailable(alloc)) {
            const wsl_hint = if (builtin.os.tag == .windows) " \xe2\x80\x94 Nix requires WSL2 on Windows" else "";
            _ = try print(try std.fmt.allocPrint(alloc, "error: nix not found on PATH \xe2\x80\x94 is Nix installed?{s} (or pass --backend native)\n", .{wsl_hint}));
            return error.BackendUnavailable;
        }
        const nb = try alloc.create(nix_backend.NixBackend);
        nb.* = .{ .cfg = cfg };
        return .{ .b = nb.backend(), .desc = "nix" };
    }
    if (std.mem.eql(u8, choice, "auto")) {
        // No socket path determinable is treated the same as "docker not
        // reachable" here: auto's whole point is graceful degradation, so it
        // falls back to native rather than erroring.
        if (client.detectSocket(alloc, cfg)) |socket| {
            const cl = client.Client{ .socket_path = socket };
            if (client.ping(alloc, cl)) {
                if (log) |l| l("auto: docker available, using docker");
                const db = try alloc.create(docker_backend.DockerBackend);
                db.* = .{ .client = cl, .cfg = cfg };
                return .{ .b = db.backend(), .desc = try std.fmt.allocPrint(alloc, "docker ({s})", .{socket}) };
            }
        }
        if (log) |l| l("auto: docker unavailable, using native");
        return .{ .b = backend.native(), .desc = "native" };
    }
    // Unreachable via the CLI — parseRunArgs/parseLintArgs validate
    // `--backend` before it ever gets here — but a `.jalan/config` file's
    // `backend=` value isn't validated on load, so a stray typo there must
    // fail safely rather than silently picking an unintended backend.
    _ = try print(try std.fmt.allocPrint(alloc, "error: unknown backend '{s}' (want native|docker|podman|nix|auto)\n", .{choice}));
    return error.BackendUnavailable;
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

const RunsArgs = struct { json: bool = false };

fn parseRunsArgs(args: []const []const u8) error{BadArgs}!RunsArgs {
    var result = RunsArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json") and !result.json) {
            result.json = true;
        } else return error.BadArgs;
    }
    return result;
}

pub fn formatRuns(alloc: std.mem.Allocator, records: []const runrecord.RunRecord, json: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (json) {
        try out.append(alloc, '[');
        for (records, 0..) |record, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, try runrecord.toJson(alloc, record));
        }
        try out.appendSlice(alloc, "]\n");
        return out.toOwnedSlice(alloc);
    }
    if (records.len == 0) {
        try out.appendSlice(alloc, "no recorded runs\n");
        return out.toOwnedSlice(alloc);
    }
    try out.appendSlice(alloc, "RUN ID\tSTARTED\tBACKEND\tWORKFLOW\tJOBS\n");
    for (records) |record| {
        var statuses: std.ArrayList([]const u8) = .empty;
        for (record.jobs) |job|
            try statuses.append(alloc, try std.fmt.allocPrint(alloc, "{s}={s}", .{ job.id, job.status }));
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}\t{d}\t{s}\t{s}\t{s}\n", .{
            record.run_id,
            record.started_unix,
            record.backend,
            record.workflow,
            try std.mem.join(alloc, ",", statuses.items),
        }));
    }
    return out.toOwnedSlice(alloc);
}

fn runsMain(alloc: std.mem.Allocator, args: RunsArgs) !u8 {
    const records = runrecord.list(alloc, ".jalan/store") catch {
        _ = try print("error: cannot read run store\n");
        return 3;
    };
    return print(try formatRuns(alloc, records, args.json));
}

pub fn main(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) return help();
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help")) return help();
    if (std.mem.eql(u8, cmd, "version")) return print("jalan 0.1.0\n");
    if (std.mem.eql(u8, cmd, "runs")) {
        const runs_args = parseRunsArgs(args[1..]) catch {
            _ = try print("error: bad arguments (see 'jalan help')\n");
            return 2;
        };
        return runsMain(alloc, runs_args);
    }
    if (std.mem.eql(u8, cmd, "translate")) {
        const ta = parseTranslateArgs(args[1..]) catch {
            _ = try print("error: bad arguments (see 'jalan help')\n");
            return 2;
        };
        const target = translate_mod.Target.fromName(ta.to.?) orelse {
            _ = try print("error: unknown target provider (use gha, gitlab, jenkins, circleci, azure, or bitbucket)\n");
            return 2;
        };
        const path = ta.file orelse (try findDefaultWorkflow(alloc)) orelse {
            _ = try print("error: no workflow found (.github/workflows, .gitlab-ci.yml, Jenkinsfile, .circleci/config.yml, azure-pipelines.yml, bitbucket-pipelines.yml)\n");
            return 2;
        };
        var out: std.ArrayList(u8) = .empty;
        const code = try translateMain(alloc, path, target, ta.out_path, &out);
        _ = try print(out.items);
        return code;
    }
    if (std.mem.eql(u8, cmd, "lint")) {
        const la = parseLintArgs(args[1..]) catch {
            _ = try print("error: bad arguments (see 'jalan help')\n");
            return 2;
        };
        const path = la.file orelse (try findDefaultWorkflow(alloc)) orelse {
            _ = try print("error: no workflow found (.github/workflows, .gitlab-ci.yml, Jenkinsfile, .circleci/config.yml, azure-pipelines.yml, bitbucket-pipelines.yml)\n");
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
    if (std.mem.eql(u8, cmd, "debug")) {
        if (!tui.isInteractive()) {
            _ = try print("error: 'jalan debug' requires an interactive stdin and stdout; use 'jalan run' or 'jalan runs' instead\n");
            return 2;
        }
        var ra = parseRunArgs(alloc, args[1..]) catch {
            _ = try print("error: bad arguments (see 'jalan help')\n");
            return 2;
        };
        ra.tui = true;
        return runMain(alloc, ra);
    }
    _ = try print("error: unknown command\n");
    return 2;
}

fn print(s: []const u8) !u8 {
    try std.fs.File.stdout().writeAll(s);
    return 0;
}

// Thread-safe per RunOptions.log contract: called from worker threads under
// parallel job execution. Shares `progress_mutex` with the status renderer
// below so a log line can never interleave with (and corrupt) a live status
// block: clear the block, print the line, repaint the block.
fn logToStderr(line: []const u8) void {
    progress_mutex.lock();
    defer progress_mutex.unlock();
    if (progress_active and progress_is_tty) progressClearLocked();
    std.fs.File.stderr().writeAll(line) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    if (progress_active and progress_is_tty) progressRedrawLocked();
}

// ---------------------------------------------------------------------
// Live progress renderer for plain `jalan run` (not `--tui`, which uses the
// full-screen TUI in tui.zig instead — this only activates on the plain
// path, see the wiring in `runMain`).
//
// `RunOptions.progress` is a bare `*const fn(engine.ProgressEvent) void`
// with no closure context — the same constraint `RunOptions.log` already
// lives with (see `logToStderr` above) — so all renderer state below is
// module-level and guarded by `progress_mutex`.
//
// On a TTY: a background thread redraws a status block every 500ms (header
// + one spinner line per running job); finished jobs print once as a
// permanent line above the block. Piped (non-TTY): no ANSI redraws, just a
// one-line start/finish per job plus a heartbeat at most every 30s while
// jobs are still running, so a long docker pull isn't silent for minutes.
// ---------------------------------------------------------------------

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

const ProgressJob = struct {
    name: []const u8 = "",
    state: enum { pending, running, done } = .pending,
    step: []const u8 = "",
    started_ms: i64 = 0,
    ok: bool = true,
    wall_ms: u64 = 0,
};

var progress_mutex: std.Thread.Mutex = .{};
var progress_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var progress_jobs: []ProgressJob = &.{};
var progress_total: usize = 0;
var progress_done: usize = 0;
var progress_run_started_ms: i64 = 0;
var progress_is_tty: bool = false;
var progress_use_color: bool = true;
var progress_active: bool = false;
var progress_lines_drawn: usize = 0;
var progress_cursor_hidden: bool = false;
var progress_spinner: usize = 0;
var progress_last_heartbeat_ms: i64 = 0;
var progress_stop_flag: std.atomic.Value(bool) = .init(false);
var progress_thread: ?std.Thread = null;

/// Start the renderer. Called from `runMain` right before `engine.run`, only
/// when not `--tui`. `total` seeds the header's job count; `is_tty` picks
/// spinner-block redraw vs. periodic heartbeat.
fn progressStart(total: usize, is_tty: bool, use_color: bool) void {
    progress_mutex.lock();
    _ = progress_arena.reset(.retain_capacity);
    const a = progress_arena.allocator();
    progress_jobs = a.alloc(ProgressJob, total) catch &.{};
    for (progress_jobs) |*j| j.* = .{};
    progress_total = total;
    progress_done = 0;
    progress_run_started_ms = std.time.milliTimestamp();
    progress_is_tty = is_tty;
    progress_use_color = use_color;
    progress_lines_drawn = 0;
    progress_cursor_hidden = false;
    progress_spinner = 0;
    progress_last_heartbeat_ms = progress_run_started_ms;
    progress_active = true;
    progress_stop_flag.store(false, .release);
    progress_mutex.unlock();
    progress_thread = std.Thread.spawn(.{}, progressLoop, .{}) catch null;
}

/// Stop the renderer: join the tick thread, clear any drawn status block,
/// and restore the cursor. Called via `defer` right after `progressStart` so
/// it always runs — including on every early error return from `runMain` —
/// never leaving the cursor hidden or a half-drawn block on screen.
fn progressStop() void {
    progress_stop_flag.store(true, .release);
    if (progress_thread) |t| t.join();
    progress_thread = null;
    progress_mutex.lock();
    defer progress_mutex.unlock();
    if (progress_is_tty) progressClearLocked();
    if (progress_cursor_hidden) {
        std.fs.File.stderr().writeAll("\x1b[?25h") catch {};
        progress_cursor_hidden = false;
    }
    progress_active = false;
    progress_jobs = &.{};
}

/// Move the cursor up over the currently-drawn block and clear everything
/// below it, so the next redraw starts clean regardless of how many lines
/// the block used last time (job count changes as jobs finish).
fn progressClearLocked() void {
    if (progress_lines_drawn == 0) return;
    var buf: [32]u8 = undefined;
    const up = std.fmt.bufPrint(&buf, "\x1b[{d}A", .{progress_lines_drawn}) catch return;
    std.fs.File.stderr().writeAll(up) catch {};
    std.fs.File.stderr().writeAll("\x1b[J") catch {};
    progress_lines_drawn = 0;
}

fn progressWriteLocked(line: []const u8) void {
    std.fs.File.stderr().writeAll(line) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
}

/// TTY redraw: header line + one spinner line per running job. Called with
/// `progress_mutex` held.
fn progressRedrawLocked() void {
    progressClearLocked();
    if (!progress_cursor_hidden) {
        std.fs.File.stderr().writeAll("\x1b[?25l") catch {};
        progress_cursor_hidden = true;
    }
    const a = progress_arena.allocator();
    const now = std.time.milliTimestamp();
    const elapsed: u64 = @intCast(@max(now - progress_run_started_ms, 0));
    var lines: usize = 0;
    if (std.fmt.allocPrint(a, "jobs: {d}/{d} done \xc2\xb7 elapsed {s}", .{ progress_done, progress_total, fmtDur(a, elapsed) })) |header| {
        progressWriteLocked(header);
        lines += 1;
    } else |_| {}
    for (progress_jobs) |j| {
        if (j.state != .running) continue;
        const job_elapsed: u64 = @intCast(@max(now - j.started_ms, 0));
        const step = if (j.step.len > 0) j.step else "...";
        const line = std.fmt.allocPrint(a, "{s} {s} \xc2\xb7 {s} \xc2\xb7 {s}", .{ spinner_frames[progress_spinner], j.name, step, fmtDur(a, job_elapsed) }) catch continue;
        progressWriteLocked(line);
        lines += 1;
    }
    progress_lines_drawn = lines;
}

/// Non-TTY: at most one heartbeat every 30s, only while something is
/// running (a quiet run between batches or before the first job stays
/// quiet). Called with `progress_mutex` held.
fn progressMaybeHeartbeatLocked() void {
    const now = std.time.milliTimestamp();
    if (now - progress_last_heartbeat_ms < 30_000) return;
    var running: usize = 0;
    for (progress_jobs) |j| {
        if (j.state == .running) running += 1;
    }
    if (running == 0) return;
    progress_last_heartbeat_ms = now;
    const a = progress_arena.allocator();
    var parts: std.ArrayList(u8) = .empty;
    var first = true;
    for (progress_jobs) |j| {
        if (j.state != .running) continue;
        const job_elapsed: u64 = @intCast(@max(now - j.started_ms, 0));
        if (!first) parts.appendSlice(a, ", ") catch {};
        first = false;
        const piece = std.fmt.allocPrint(a, "{s} ({s})", .{ j.name, fmtDur(a, job_elapsed) }) catch continue;
        parts.appendSlice(a, piece) catch {};
    }
    const line = std.fmt.allocPrint(a, "\xe2\x8f\xb3 {d} running: {s} \xc2\xb7 {d}/{d} done", .{ running, parts.items, progress_done, progress_total }) catch return;
    progressWriteLocked(line);
}

fn progressLoop() void {
    while (!progress_stop_flag.load(.acquire)) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        if (progress_stop_flag.load(.acquire)) break;
        progress_mutex.lock();
        defer progress_mutex.unlock();
        if (!progress_active) return;
        progress_spinner = (progress_spinner + 1) % spinner_frames.len;
        if (progress_is_tty) {
            progressRedrawLocked();
        } else {
            progressMaybeHeartbeatLocked();
        }
    }
}

fn progressFindByName(name: []const u8) ?usize {
    for (progress_jobs, 0..) |j, i| {
        if (j.state != .pending and std.mem.eql(u8, j.name, name)) return i;
    }
    return null;
}

/// `RunOptions.progress` sink: routes engine job/step lifecycle events into
/// the module-level state above. See `ProgressEvent` in engine.zig for the
/// string-lifetime contract — names/steps are duped into `progress_arena`
/// since they're kept past the callback.
fn onProgress(ev: engine.ProgressEvent) void {
    progress_mutex.lock();
    defer progress_mutex.unlock();
    if (!progress_active) return;
    const a = progress_arena.allocator();
    switch (ev) {
        .job_started => |e| {
            if (e.index >= progress_jobs.len) return;
            progress_jobs[e.index] = .{
                .name = a.dupe(u8, e.job) catch e.job,
                .state = .running,
                .started_ms = std.time.milliTimestamp(),
            };
            if (progress_is_tty) {
                progressRedrawLocked();
            } else if (std.fmt.allocPrint(a, "\xe2\x96\xb6 {s} started", .{e.job})) |line| {
                progressWriteLocked(line);
            } else |_| {}
        },
        .step_started => |e| {
            const idx = progressFindByName(e.job) orelse return;
            progress_jobs[idx].step = a.dupe(u8, e.step) catch e.step;
            if (progress_is_tty) progressRedrawLocked();
        },
        .step_finished => {},
        .job_finished => |e| {
            if (progressFindByName(e.job)) |i| {
                progress_jobs[i].state = .done;
                progress_jobs[i].ok = e.status == .success;
                progress_jobs[i].wall_ms = e.wall_ms;
            }
            progress_done += 1;
            const mark = if (e.status == .success) "\xe2\x9c\x93" else if (e.status == .skipped) "\xe2\x97\x8b" else "\xe2\x9c\x97";
            const color = if (!progress_use_color) "" else if (e.status == .success) ansi_green else if (e.status == .skipped) ansi_dim_yellow else ansi_red;
            const reset = if (progress_use_color) ansi_reset else "";
            if (progress_is_tty) {
                progressClearLocked();
                if (std.fmt.allocPrint(a, "{s}{s}{s} {s}  {s}", .{ color, mark, reset, e.job, fmtDur(a, e.wall_ms) })) |line| progressWriteLocked(line) else |_| {}
                progressRedrawLocked();
            } else if (std.fmt.allocPrint(a, "{s}{s}{s} {s} {s}", .{ color, mark, reset, e.job, fmtDur(a, e.wall_ms) })) |line| {
                progressWriteLocked(line);
            } else |_| {}
        },
    }
}

fn help() !u8 {
    return print(
        \\jalan — local CI simulator
        \\
        \\usage:
        \\  jalan lint [file] [--json] [--strict] [--backend <name>]
        \\  jalan run [file] [-j <job>] [--step <id>] [--dry-run] [--env K=V]...
        \\            [--secret-file <path>] [--matrix k=v]... [--max-parallel N]
        \\            [--strict] [--no-color] [--backend <name>] [--pull]
        \\            [--snapshot|--no-snapshot] [--cache|--no-cache]
        \\            [--isolate|--no-isolate]
        \\            [--break <job/step>]... [--on-failure shell|stop|continue]
        \\            [--step-all] [--resume <run-id> --at <job/step>]
        \\  jalan debug [file] [same options as jalan run]
        \\            (debug stops only at the first failure by default; pass
        \\            --step-all to break at every step instead)
        \\  jalan translate [file] --to <provider> [-o <path>]
        \\            (providers: gha, gitlab, jenkins, circleci, azure, bitbucket)
        \\  jalan runs [--json]
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

/// Humanize a millisecond duration for display in the summary and the
/// progress renderer. A raw `310117ms` tells a user nothing; `5m10s` does.
/// Buckets: sub-10s keeps one decimal (steps are usually this fast, and the
/// precision matters at that scale), sub-60s whole seconds, sub-1h
/// minutes+seconds, else hours+minutes. See the unit tests below for the
/// exact bucket boundaries (9999/10000, 59999/60000, 3599999/3600000).
pub fn fmtDur(alloc: std.mem.Allocator, ms: u64) []const u8 {
    if (ms < 10_000) {
        return std.fmt.allocPrint(alloc, "{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 }) catch "?s";
    }
    if (ms < 60_000) {
        return std.fmt.allocPrint(alloc, "{d}s", .{ms / 1000}) catch "?s";
    }
    if (ms < 3_600_000) {
        const total_s = ms / 1000;
        return std.fmt.allocPrint(alloc, "{d}m{d:0>2}s", .{ total_s / 60, total_s % 60 }) catch "?m";
    }
    const total_m = ms / 60_000;
    return std.fmt.allocPrint(alloc, "{d}h{d:0>2}m", .{ total_m / 60, total_m % 60 }) catch "?h";
}

test "fmtDur: bucket boundaries" {
    const a = std.testing.allocator;
    const cases = [_]struct { ms: u64, want: []const u8 }{
        .{ .ms = 0, .want = "0.0s" },
        .{ .ms = 9999, .want = "9.9s" },
        .{ .ms = 10000, .want = "10s" },
        .{ .ms = 59999, .want = "59s" },
        .{ .ms = 60000, .want = "1m00s" },
        .{ .ms = 3599999, .want = "59m59s" },
        .{ .ms = 3600000, .want = "1h00m" },
    };
    for (cases) |c| {
        const got = fmtDur(a, c.ms);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

fn onFailureMode(value: []const u8) engine.OnFailure {
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "shell")) return .shell;
    return .continue_;
}

/// Effective `--on-failure` mode: an explicit flag always wins. Left unset,
/// `jalan debug` defaults to `shell` (that's what "debugging" means — stop
/// only at the failure) while plain `jalan run` keeps defaulting to
/// `continue` (unchanged behavior).
pub fn effectiveOnFailure(ra: RunArgs) engine.OnFailure {
    if (!ra.on_failure_explicit and ra.tui) return .shell;
    return onFailureMode(ra.on_failure);
}

fn printResumeInvalid(alloc: std.mem.Allocator, run_id: []const u8) !void {
    _ = try print(try std.fmt.allocPrint(alloc, "error: invalid resume target for run '{s}'\n", .{run_id}));
    const record = runrecord.load(alloc, ".jalan/store", run_id) catch return;
    _ = try print("valid targets:\n");
    for (record.jobs) |job| {
        for (job.steps) |step| {
            if (step.snapshot.len == 0) continue;
            _ = try print(try std.fmt.allocPrint(alloc, "  {s}/{s}\n", .{ job.id, step.id }));
        }
    }
}

pub fn runMain(alloc: std.mem.Allocator, ra: RunArgs) !u8 {
    var recorded_workflow: ?[]const u8 = null;
    if (ra.file == null) {
        if (ra.resume_run) |run_id| {
            const record = runrecord.load(alloc, ".jalan/store", run_id) catch {
                try printResumeInvalid(alloc, run_id);
                return 2;
            };
            recorded_workflow = record.workflow;
        }
    }
    const path = ra.file orelse recorded_workflow orelse (try findDefaultWorkflow(alloc)) orelse {
        _ = try print("error: no workflow found (.github/workflows, .gitlab-ci.yml, Jenkinsfile, .circleci/config.yml, azure-pipelines.yml, bitbucket-pipelines.yml)\n");
        return 2;
    };
    const source = std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024) catch {
        _ = try print(try std.fmt.allocPrint(alloc, "error: cannot read '{s}'\n", .{path}));
        return 3;
    };
    const provider = detectProvider(path, source);
    if (provider == .unknown) {
        _ = try print("error: could not detect CI provider (supported providers: GitHub Actions, GitLab CI, Jenkins, CircleCI, Azure Pipelines, and Bitbucket Pipelines)\n");
        return 2;
    }
    var diags = yaml.Diags.init(alloc);
    const pipeline = parseProvider(alloc, provider, path, source, &diags) catch |e| switch (e) {
        error.ParseFailed => {
            var out: std.ArrayList(u8) = .empty;
            try printDiags(alloc, path, &diags, &out);
            _ = try print(out.items);
            return 2;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    var tui_session = tui.Session.init(alloc, pipeline);
    defer tui_session.deinit();
    {
        var out: std.ArrayList(u8) = .empty;
        try printDiags(alloc, path, &diags, &out);
        if (out.items.len > 0) _ = try print(out.items);
    }
    if (ra.strict and diags.list.items.len > 0) return 2;
    const use_color = colorsEnabled(alloc, ra);

    const cfg = try config.load(alloc);
    var snapshot = resolveToggle(ra.snapshot, cfg.snapshot);
    var cache_enabled = resolveToggle(ra.cache, cfg.cache);
    // Multi-job runs want per-job workspace isolation (parallel jobs racing
    // on one shared build cache is how matrix builds die with AccessDenied),
    // but the engine force-disables isolation whenever snapshot/cache are on
    // — and `Config.snapshot` defaults to true, so without this the config
    // default silently vetoes isolation on every plain matrix run. When
    // snapshots are on ONLY via config default (no explicit --snapshot /
    // --cache) and no debug/resume mode needs the shared timeline, parallel
    // correctness wins: drop snapshot/cache so isolation can engage.
    // Explicit flags keep today's shared-workspace serialized behavior.
    const needs_shared_timeline = ra.resume_run != null or ra.breaks.len > 0 or ra.step_all;
    if (pipeline.jobs.len > 1 and !needs_shared_timeline and
        ra.snapshot == null and ra.cache == null and (ra.isolate orelse true) and
        (snapshot or cache_enabled))
    {
        snapshot = false;
        cache_enabled = false;
        _ = try print("multi-job run: isolating workspaces per job; snapshots/cache off (pass --snapshot to keep them on a shared workspace)\n");
    }
    const backend_choice = resolveBackendChoice(ra.backend, cfg.backend);
    const picked = pickBackend(alloc, backend_choice, cfg, &logToStderr) catch |e| switch (e) {
        error.BackendUnavailable => return 3, // message already printed by pickBackend
        else => return e,
    };
    _ = try print(try std.fmt.allocPrint(alloc, "backend: {s}\n", .{picked.desc}));

    var breakpoints: std.ArrayList(debug_mod.Breakpoint) = .empty;
    for (ra.breaks) |raw| {
        const selector = splitSelector(raw).?;
        try breakpoints.append(alloc, .{ .job_id = selector.job, .step = selector.step });
    }
    const resume_point: ?engine.ResumePoint = if (ra.resume_run) |run_id| blk: {
        const selector = splitSelector(ra.resume_at.?).?;
        break :blk .{ .run_id = run_id, .job_id = selector.job, .step = selector.step };
    } else null;
    const workspace_abs = std.fs.cwd().realpathAlloc(alloc, ".") catch {
        _ = try print("error: cannot resolve workspace path\n");
        return 3;
    };
    if (snapshot and picked.b.kind == .docker)
        logToStderr("warning: snapshots capture only the bind-mounted workspace; container state outside it is not preserved");
    if (resume_point != null and picked.b.kind == .docker)
        logToStderr("warning: docker resume creates a fresh container; state outside the workspace is lost");

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

    // Live progress (spinner/heartbeat) only makes sense for the plain
    // path; `jalan debug`/`--tui` renders its own full-screen view.
    const use_progress = !ra.tui;
    if (use_progress) progressStart(pipeline.jobs.len, tui.isInteractive(), use_color);
    defer if (use_progress) progressStop();
    const run_t0 = std.time.milliTimestamp();

    const report = engine.run(alloc, pipeline, .{
        .job_filter = ra.job,
        .step_filter = ra.step,
        .dry_run = ra.dry_run,
        .max_parallel = ra.max_parallel,
        .extra_env = ra.env,
        .secrets = secrets,
        .matrix_filter = ra.matrix,
        .log = &logToStderr,
        .progress = if (use_progress) &onProgress else null,
        .exec_backend = picked.b,
        .force_pull = ra.pull,
        .snapshot = snapshot,
        .cache = cache_enabled,
        .isolate_workspaces = ra.isolate,
        .workspace_abs = workspace_abs,
        .breakpoints = breakpoints.items,
        .debug_all_steps = ra.step_all,
        .on_failure = effectiveOnFailure(ra),
        .resume_from = resume_point,
        .prompt_fn = if (ra.tui) tui.Session.prompt else if (debug_mod.isTty()) debug_mod.promptOnce else null,
        .prompt_ctx = if (ra.tui) &tui_session else null,
    }) catch |e| switch (e) {
        error.ResumeInvalid => {
            if (ra.resume_run) |run_id| try printResumeInvalid(alloc, run_id) else _ = try print("error: invalid resume target\n");
            return 2;
        },
        error.RestoreFailed, error.StoreIo => {
            _ = try print("error: failed to restore resume snapshot\n");
            return 3;
        },
        error.InternalError => {
            _ = try print("internal error: engine failed\n");
            return 3;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const run_wall_ms: u64 = @intCast(@max(std.time.milliTimestamp() - run_t0, 0));

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

    if (ra.tui) return tui_session.finish(report);

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
                // `wall_ms` (setup+steps+teardown) is the truer number when
                // available — it includes things like a slow image pull that
                // never show up in the per-step sum. Fall back to the sum
                // for older/synthetic results that never went through the
                // wall-clock path (wall_ms stays 0).
                var total_ms: u64 = 0;
                for (j.steps) |s| total_ms += s.duration_ms;
                const shown_ms = if (j.wall_ms > 0) j.wall_ms else total_ms;
                const mark = if (use_color) ansi_green ++ "\xe2\x9c\x93" ++ ansi_reset else "\xe2\x9c\x93";
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s}   {d} steps   {s}\n", .{ mark, j.display_name, j.steps.len, fmtDur(alloc, shown_ms) }));
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
                } else if (j.infra_reason) |reason| {
                    // Backend SETUP failed before any step ran — every step
                    // stays `.skipped`, so without this the job would render
                    // as if nothing went wrong.
                    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s}   failed (backend setup failed: {s})\n", .{ mark, j.display_name, reason }));
                } else {
                    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s}   failed\n", .{ mark, j.display_name }));
                }
                // Per-step duration breakdown so a slow-then-failing job
                // shows where the time went, not just the final verdict.
                for (j.steps) |s| {
                    if (s.status == .skipped) continue;
                    const step_mark = if (s.status == .failed) " \xe2\x9c\x97" else "";
                    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "    {s} {s}{s}\n", .{ s.name, fmtDur(alloc, s.duration_ms), step_mark }));
                }
            },
            .skipped => {
                const mark = if (use_color) ansi_dim_yellow ++ "\xe2\x97\x8b" ++ ansi_reset else "\xe2\x97\x8b";
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s}   skipped\n", .{ mark, j.display_name }));
            },
        }
    }
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "total: {s}\n", .{fmtDur(alloc, run_wall_ms)}));

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

test "parseLintArgs accepts --backend, validates the name, defaults to auto" {
    const la = try parseLintArgs(&[_][]const u8{ "--backend", "docker", "wf.yml" });
    try std.testing.expectEqualStrings("docker", la.backend);
    try std.testing.expectEqualStrings("auto", (try parseLintArgs(&[_][]const u8{"wf.yml"})).backend);
    try std.testing.expectError(error.BadArgs, parseLintArgs(&[_][]const u8{ "--backend", "bogus" }));
    try std.testing.expectError(error.BadArgs, parseLintArgs(&[_][]const u8{"--backend"}));
}

test "runs formatting emits table and JSON; empty store is friendly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]runrecord.StepEntry{.{ .id = "compile", .status = "success" }};
    var jobs = [_]runrecord.JobEntry{.{ .id = "build", .status = "success", .steps = &steps }};
    const records = [_]runrecord.RunRecord{.{
        .run_id = "1234-abcd1234",
        .workflow = ".github/workflows/ci.yml",
        .backend = "native",
        .started_unix = 1234,
        .jobs = &jobs,
    }};
    const table = try formatRuns(a, &records, false);
    try std.testing.expect(std.mem.indexOf(u8, table, "RUN ID\tSTARTED\tBACKEND") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "build=success") != null);
    const json = try formatRuns(a, &records, true);
    try std.testing.expect(std.mem.startsWith(u8, json, "[{\"run_id\":\"1234-abcd1234\""));
    try std.testing.expectEqualStrings("no recorded runs\n", try formatRuns(a, &.{}, false));
    try std.testing.expectEqualStrings("[]\n", try formatRuns(a, &.{}, true));
}

test "parseRunsArgs accepts only one optional --json" {
    try std.testing.expect(!(try parseRunsArgs(&.{})).json);
    try std.testing.expect((try parseRunsArgs(&.{"--json"})).json);
    try std.testing.expectError(error.BadArgs, parseRunsArgs(&.{"--bogus"}));
    try std.testing.expectError(error.BadArgs, parseRunsArgs(&.{ "--json", "--json" }));
}

test "detect provider by path and content" {
    try std.testing.expectEqual(Provider.gha, detectProvider(".github/workflows/ci.yml", ""));
    try std.testing.expectEqual(Provider.gitlab, detectProvider(".gitlab-ci.yml", "stages:\n  - build"));
    try std.testing.expectEqual(Provider.gitlab, detectProvider("dir\\.gitlab-ci.yaml", "stages:\n  - build"));
    try std.testing.expectEqual(Provider.gha, detectProvider("any.yml", "jobs:\n  a:\n    steps:\n      - run: x"));
    try std.testing.expectEqual(Provider.unknown, detectProvider("pipeline.yml", "stages:\n  - build"));
    try std.testing.expectEqual(Provider.jenkins, detectProvider("Jenkinsfile", "node {\n    sh 'echo hi'\n}"));
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
