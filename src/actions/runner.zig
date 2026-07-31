//! Action runner: `action.yml` parsing, composite-action execution, and the
//! small set of GitHub-hosted actions jalan simulates natively (`builtin_*`)
//! instead of fetching + running their real (often Node-based) code.
//!
//! `runUses` is the single dispatch entry point for a `uses:` step. Builtins
//! are matched on `step.uses_ref` *before* any ref resolution/network access
//! happens — `actions/checkout`, `actions/upload-artifact`, and
//! `actions/download-artifact` never hit `resolve.fetch`. Everything else is
//! resolved (local path or GitHub tarball) and its `action.yml` is parsed to
//! decide `composite` vs. `node`/`docker` — the latter two are Task 12's
//! job; this task returns a clear placeholder error for them so `classify`
//! (via `runUses`) already reports the right shape of failure.
const std = @import("std");
const yaml = @import("../yaml.zig");
const ir = @import("../ir.zig");
const expr = @import("../expr.zig");
const backend = @import("../backend.zig");
const resolve = @import("resolve.zig");
const gha = @import("../frontend/gha.zig");

pub const ActionKind = enum {
    composite,
    node,
    docker_image,
    builtin_checkout,
    builtin_upload_artifact,
    builtin_download_artifact,
};

/// `INPUT_` + uppercased name with spaces turned into underscores, matching
/// how GitHub Actions exposes `with:` values as env vars to `node`/`docker`
/// actions (`my input` -> `INPUT_MY_INPUT`).
pub fn inputEnvName(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "INPUT_");
    for (input) |c| {
        try out.append(alloc, if (c == ' ') '_' else std.ascii.toUpper(c));
    }
    return out.toOwnedSlice(alloc);
}

pub const ActionMeta = struct {
    using: []const u8,
    main: []const u8 = "",
    steps: []yaml.Node = &.{},
    input_defaults: []ir.EnvPair = &.{},
};

/// Reads and parses `<dir>/action.yml` (falling back to `action.yaml`) into
/// an `ActionMeta`: `runs.using`, `runs.main`, `runs.steps`, and one
/// `input_defaults` entry per top-level `inputs.<k>` that declares a
/// `default:`.
pub fn parseActionYaml(alloc: std.mem.Allocator, dir: []const u8, diags: *yaml.Diags) !ActionMeta {
    const source = try readActionSource(alloc, dir);
    const root = try yaml.parse(alloc, source, diags);

    const runs = root.get("runs") orelse {
        try diags.add(root.line, root.col, "action.yml missing 'runs'", .{});
        return error.ParseFailed;
    };
    const using = if (runs.get("using")) |u| u.scalarOr("") else "";
    const main = if (runs.get("main")) |m| m.scalarOr("") else "";
    var steps: []yaml.Node = &.{};
    if (runs.get("steps")) |sn| switch (sn.data) {
        .seq => |items| steps = items,
        else => {},
    };

    var defaults: std.ArrayList(ir.EnvPair) = .empty;
    if (root.get("inputs")) |inputs_node| switch (inputs_node.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.get("default")) |d|
                    try defaults.append(alloc, .{ .name = e.key_ptr.*, .value = d.scalarOr("") });
            }
        },
        else => {},
    };

    return .{
        .using = using,
        .main = main,
        .steps = steps,
        .input_defaults = try defaults.toOwnedSlice(alloc),
    };
}

fn readActionSource(alloc: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const p1 = try std.fs.path.join(alloc, &.{ dir, "action.yml" });
    return std.fs.cwd().readFileAlloc(alloc, p1, 1024 * 1024) catch |e1| {
        if (e1 != error.FileNotFound) return e1;
        const p2 = try std.fs.path.join(alloc, &.{ dir, "action.yaml" });
        return std.fs.cwd().readFileAlloc(alloc, p2, 1024 * 1024);
    };
}

fn withGet(with: []const ir.EnvPair, name: []const u8) ?[]const u8 {
    for (with) |w| {
        if (std.mem.eql(u8, w.name, name)) return w.value;
    }
    return null;
}

/// Matches `step.uses_ref` (before the `@ref` suffix, if any) against the
/// GitHub-hosted action paths jalan simulates natively.
fn builtinKind(uses_ref: []const u8) ?ActionKind {
    const at = std.mem.indexOfScalar(u8, uses_ref, '@') orelse uses_ref.len;
    const path = uses_ref[0..at];
    if (std.mem.eql(u8, path, "actions/checkout")) return .builtin_checkout;
    if (std.mem.eql(u8, path, "actions/upload-artifact")) return .builtin_upload_artifact;
    if (std.mem.eql(u8, path, "actions/download-artifact")) return .builtin_download_artifact;
    return null;
}

const max_composite_depth: u32 = 10;

/// Dispatches a `uses:` step: builtins first (no resolution/network), then
/// local/GitHub actions resolved via `resolve.zig` and classified by their
/// `action.yml`'s `runs.using`. `env` is the shared expr environment used to
/// interpolate `${{ inputs.* }}` inside composite `run:` steps — callers
/// that don't need composite support may pass an empty `Env`.
pub fn runUses(
    alloc: std.mem.Allocator,
    step: ir.Step,
    with: []const ir.EnvPair,
    b: backend.Backend,
    handle: *backend.JobHandle,
    env: *expr.Env,
    opts_log: ?backend.LogFn,
    force_pull: bool,
    err_msg: *?[]const u8,
) !backend.StepOutcome {
    return runUsesDepth(alloc, step, with, b, handle, env, opts_log, force_pull, err_msg, 0);
}

// `runUsesDepth` and `runComposite` are mutually recursive (a composite
// step's own `uses:` children route back through `runUsesDepth`), so their
// error sets can't be inferred — Zig can't resolve an inferred set that
// depends on itself. `anyerror` breaks the cycle explicitly.
fn runUsesDepth(
    alloc: std.mem.Allocator,
    step: ir.Step,
    with: []const ir.EnvPair,
    b: backend.Backend,
    handle: *backend.JobHandle,
    env: *expr.Env,
    opts_log: ?backend.LogFn,
    force_pull: bool,
    err_msg: *?[]const u8,
    depth: u32,
) anyerror!backend.StepOutcome {
    if (depth >= max_composite_depth) {
        err_msg.* = "composite recursion limit";
        return error.SpawnFailed;
    }

    if (builtinKind(step.uses_ref)) |kind| {
        return switch (kind) {
            .builtin_checkout => runCheckout(alloc, with, handle, opts_log),
            .builtin_upload_artifact => runUploadArtifact(alloc, with, handle, err_msg),
            .builtin_download_artifact => runDownloadArtifact(alloc, with, handle, err_msg),
            else => unreachable,
        };
    }

    const ref = resolve.parseRef(step.uses_ref) catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "bad uses ref '{s}': {s}", .{ step.uses_ref, @errorName(e) });
        return error.SpawnFailed;
    };

    if (ref == .docker_image) {
        err_msg.* = "action type 'docker' lands in Task 12";
        return error.SpawnFailed;
    }

    const dir = switch (ref) {
        .local => |p| p,
        .github => |gh| try resolve.fetch(alloc, gh, force_pull, opts_log, err_msg),
        .docker_image => unreachable,
    };

    var action_diags = yaml.Diags.init(alloc);
    const meta = parseActionYaml(alloc, dir, &action_diags) catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "parsing action.yml in '{s}' failed: {s}", .{ dir, @errorName(e) });
        return error.SpawnFailed;
    };

    if (std.mem.eql(u8, meta.using, "composite"))
        return runComposite(alloc, meta, with, b, handle, env, opts_log, force_pull, err_msg, depth);

    err_msg.* = try std.fmt.allocPrint(alloc, "action type '{s}' lands in Task 12", .{meta.using});
    return error.SpawnFailed;
}

fn setInputsEnv(alloc: std.mem.Allocator, env: *expr.Env, with: []const ir.EnvPair, defaults: []const ir.EnvPair) !void {
    for (defaults) |d|
        try env.put(alloc, try std.fmt.allocPrint(alloc, "inputs.{s}", .{d.name}), d.value);
    for (with) |w|
        try env.put(alloc, try std.fmt.allocPrint(alloc, "inputs.{s}", .{w.name}), w.value);
}

const InputSnapshot = struct {
    path: []const u8,
    had_value: bool,
    value: []const u8 = "",
};

/// Captures the pre-call state of every `inputs.<k>` key `setInputsEnv` is
/// about to write, so `restoreInputs` can put the shared `expr.Env` back the
/// way it found it once this composite call is done. Each composite gets its
/// own `inputs.*` context in real GitHub Actions — without this, a nested
/// composite's `with:` values leak into (and outlive) the caller's context.
fn snapshotInputs(alloc: std.mem.Allocator, env: *expr.Env, with: []const ir.EnvPair, defaults: []const ir.EnvPair) ![]InputSnapshot {
    var out: std.ArrayList(InputSnapshot) = .empty;
    for (defaults) |d| {
        const path = try std.fmt.allocPrint(alloc, "inputs.{s}", .{d.name});
        const prior = try env.lookup(alloc, path);
        try out.append(alloc, .{ .path = path, .had_value = prior != null, .value = prior orelse "" });
    }
    for (with) |w| {
        const path = try std.fmt.allocPrint(alloc, "inputs.{s}", .{w.name});
        const prior = try env.lookup(alloc, path);
        try out.append(alloc, .{ .path = path, .had_value = prior != null, .value = prior orelse "" });
    }
    return out.toOwnedSlice(alloc);
}

/// Restores keys captured by `snapshotInputs`: puts back the prior value, or
/// removes the key entirely if it was absent before this composite call.
/// Duplicate entries (a key present in both `defaults` and `with`) are safe
/// to restore more than once — every entry recorded the *same* pre-call
/// state, so re-applying it is idempotent.
fn restoreInputs(alloc: std.mem.Allocator, env: *expr.Env, snaps: []const InputSnapshot) void {
    for (snaps) |s| {
        if (s.had_value) {
            env.put(alloc, s.path, s.value) catch {};
        } else {
            env.remove(alloc, s.path) catch {};
        }
    }
}

fn runComposite(
    alloc: std.mem.Allocator,
    meta: ActionMeta,
    with: []const ir.EnvPair,
    b: backend.Backend,
    handle: *backend.JobHandle,
    env: *expr.Env,
    opts_log: ?backend.LogFn,
    force_pull: bool,
    err_msg: *?[]const u8,
    depth: u32,
) anyerror!backend.StepOutcome {
    // Snapshot before mutating, restore no matter how this call exits
    // (normal return or an error propagated via `try` below) — each
    // composite invocation gets its own `inputs.*` context; the caller's
    // (or a sibling composite's) `inputs.*` must never leak or get clobbered.
    const snaps = try snapshotInputs(alloc, env, with, meta.input_defaults);
    try setInputsEnv(alloc, env, with, meta.input_defaults);
    defer restoreInputs(alloc, env, snaps);

    var stdout_buf: std.ArrayList(u8) = .empty;
    var stderr_buf: std.ArrayList(u8) = .empty;
    var exit_code: i32 = 0;

    for (meta.steps, 0..) |sn, i| {
        var step_diags = yaml.Diags.init(alloc);
        const child = try gha.lowerStepForComposite(alloc, sn, i, &step_diags);

        const out = if (child.kind == .uses)
            try runUsesDepth(alloc, child, child.with, b, handle, env, opts_log, force_pull, err_msg, depth + 1)
        else blk: {
            var run_step = child;
            run_step.script = try expr.interpolate(alloc, child.script, env);
            break :blk try b.runStep(alloc, handle, run_step, &.{}, run_step.workdir, err_msg);
        };

        try stdout_buf.appendSlice(alloc, out.stdout);
        try stderr_buf.appendSlice(alloc, out.stderr);

        // GHA stops a composite at its first failing step (unless that step
        // tolerates its own failure via continue-on-error) — later steps
        // never run, but output from steps that did run is kept.
        if (out.exit_code != 0 and !child.continue_on_error) {
            exit_code = out.exit_code;
            break;
        }
    }

    return .{
        .exit_code = exit_code,
        .stdout = try stdout_buf.toOwnedSlice(alloc),
        .stderr = try stderr_buf.toOwnedSlice(alloc),
        .outputs = &.{},
    };
}

/// Copies the contents of `src_dir` into `dst_dir`, recursing into
/// subdirectories. `.jalan` (jalan's own scratch/artifact state) is always
/// skipped so checkout/artifact copies never fold jalan's bookkeeping into
/// the thing being copied. `skip` additionally excludes one more top-level
/// entry name — used by `runCheckout` to keep a workspace-relative `path:`
/// destination from being copied into itself.
fn copyDirRecursive(alloc: std.mem.Allocator, src_dir: std.fs.Dir, dst_dir: std.fs.Dir, skip: ?[]const u8) !void {
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".jalan")) continue;
        if (skip) |s| if (std.mem.eql(u8, entry.name, s)) continue;
        switch (entry.kind) {
            .directory => {
                try dst_dir.makePath(entry.name);
                var sub_src = try src_dir.openDir(entry.name, .{ .iterate = true });
                defer sub_src.close();
                var sub_dst = try dst_dir.openDir(entry.name, .{});
                defer sub_dst.close();
                try copyDirRecursive(alloc, sub_src, sub_dst, null);
            },
            .file => try src_dir.copyFile(entry.name, dst_dir, entry.name, .{}),
            else => {},
        }
    }
}

/// `actions/checkout` builtin: the workspace already *is* the checked-out
/// repo (mounted or cwd), so with no `path:` input this is a no-op. A
/// `path:` input recursively copies the workspace into
/// `<workspace>/<path>` — the native path only; container backends are
/// expected to run `cp -r /github/workspace /github/workspace/<path>` inside
/// the container instead (Task 12+ wiring).
fn runCheckout(alloc: std.mem.Allocator, with: []const ir.EnvPair, handle: *backend.JobHandle, opts_log: ?backend.LogFn) !backend.StepOutcome {
    const path = withGet(with, "path") orelse "";
    if (path.len == 0) {
        if (opts_log) |l| l("checkout: using local workspace");
        return .{ .exit_code = 0, .stdout = "", .stderr = "", .outputs = &.{} };
    }

    const first_seg = if (std.mem.indexOfScalar(u8, path, '/')) |i| path[0..i] else path;
    var src_dir = try std.fs.openDirAbsolute(handle.workspace, .{ .iterate = true });
    defer src_dir.close();
    const dest = try std.fs.path.join(alloc, &.{ handle.workspace, path });
    try std.fs.cwd().makePath(dest);
    var dst_dir = try std.fs.cwd().openDir(dest, .{});
    defer dst_dir.close();
    try copyDirRecursive(alloc, src_dir, dst_dir, first_seg);

    if (opts_log) |l| l(try std.fmt.allocPrint(alloc, "checkout: copied workspace into {s}", .{path}));
    return .{ .exit_code = 0, .stdout = "", .stderr = "", .outputs = &.{} };
}

fn resolveWorkspacePath(alloc: std.mem.Allocator, handle: *backend.JobHandle, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path) or handle.workspace.len == 0) return path;
    return std.fs.path.join(alloc, &.{ handle.workspace, path });
}

fn artifactDir(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fs.path.join(alloc, &.{ ".jalan", "artifacts", name });
}

/// Copies the contents of `src_path` into `dst_dir_path` (both resolved
/// relative to cwd if not absolute). A `src_path` that isn't a directory is
/// copied as a single file named by its basename.
fn copyPathInto(alloc: std.mem.Allocator, src_path: []const u8, dst_dir_path: []const u8) !void {
    var src_dir = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch |e| switch (e) {
        error.NotDir => {
            const base = std.fs.path.basename(src_path);
            const dst_path = try std.fs.path.join(alloc, &.{ dst_dir_path, base });
            try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{});
            return;
        },
        else => return e,
    };
    defer src_dir.close();
    var dst_dir = try std.fs.cwd().openDir(dst_dir_path, .{});
    defer dst_dir.close();
    try copyDirRecursive(alloc, src_dir, dst_dir, null);
}

/// `actions/upload-artifact` builtin: copies the `path:` input (resolved
/// against the job workspace when relative) into `.jalan/artifacts/<name>/`.
fn runUploadArtifact(alloc: std.mem.Allocator, with: []const ir.EnvPair, handle: *backend.JobHandle, err_msg: *?[]const u8) !backend.StepOutcome {
    const name = withGet(with, "name") orelse "artifact";
    const path = withGet(with, "path") orelse {
        err_msg.* = "upload-artifact requires a 'path' input";
        return error.SpawnFailed;
    };
    const src = try resolveWorkspacePath(alloc, handle, path);
    const dest = try artifactDir(alloc, name);
    try std.fs.cwd().makePath(dest);
    copyPathInto(alloc, src, dest) catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "upload-artifact: copying '{s}' failed: {s}", .{ src, @errorName(e) });
        return error.SpawnFailed;
    };
    return .{ .exit_code = 0, .stdout = "", .stderr = "", .outputs = &.{} };
}

/// `actions/download-artifact` builtin: copies `.jalan/artifacts/<name>/`
/// back into the `path:` input (default `.`, resolved against the job
/// workspace when relative).
fn runDownloadArtifact(alloc: std.mem.Allocator, with: []const ir.EnvPair, handle: *backend.JobHandle, err_msg: *?[]const u8) !backend.StepOutcome {
    const name = withGet(with, "name") orelse "artifact";
    const path = withGet(with, "path") orelse ".";
    const src = try artifactDir(alloc, name);
    const dest = try resolveWorkspacePath(alloc, handle, path);
    try std.fs.cwd().makePath(dest);
    copyPathInto(alloc, src, dest) catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "download-artifact: copying '{s}' failed: {s}", .{ src, @errorName(e) });
        return error.SpawnFailed;
    };
    return .{ .exit_code = 0, .stdout = "", .stderr = "", .outputs = &.{} };
}

test "inputEnvName: uppercases and turns spaces into underscores" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("INPUT_TOKEN", try inputEnvName(a, "token"));
    try std.testing.expectEqualStrings("INPUT_MY_INPUT", try inputEnvName(a, "my input"));
}

test "parse composite action.yml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const meta = try parseActionYaml(a, "testdata/actions/hello", &diags);
    try std.testing.expectEqualStrings("composite", meta.using);
    try std.testing.expectEqual(@as(usize, 1), meta.steps.len);
    try std.testing.expectEqualStrings("world", meta.input_defaults[0].value);
}

test "composite local action runs through native backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = backend.native();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "./testdata/actions/hello" };
    const with = [_]ir.EnvPair{.{ .name = "who", .value = "jalan" }};
    var env = expr.Env{};
    const out = try runUses(a, step, &with, b, &h, &env, null, false, &em);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "hello jalan") != null);
}

test "nested composite: inputs are isolated per composite boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = backend.native();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    // outer's own `who` (via `with:`) must survive the nested `hello`
    // composite setting its own `who: inner` and returning.
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "./testdata/actions/outer" };
    const with = [_]ir.EnvPair{.{ .name = "who", .value = "caller" }};
    var env = expr.Env{};
    const out = try runUses(a, step, &with, b, &h, &env, null, false, &em);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "before caller") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "after caller") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "after inner") == null);
}

test "composite short-circuits on first failing step (no continue-on-error)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = backend.native();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "./testdata/actions/failmid" };
    var env = expr.Env{};
    const out = try runUses(a, step, &.{}, b, &h, &env, null, false, &em);
    try std.testing.expectEqual(@as(i32, 3), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "MARKER_SHOULD_NOT_APPEAR") == null);
}
