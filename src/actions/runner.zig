//! Action runner: `action.yml` parsing, composite/node/docker-image action
//! execution, and the small set of GitHub-hosted actions jalan simulates
//! natively (`builtin_*`) instead of fetching + running their real (often
//! Node-based) code.
//!
//! `runUses` is the single dispatch entry point for a `uses:` step. Builtins
//! are matched on `step.uses_ref` *before* any ref resolution/network access
//! happens — `actions/checkout`, `actions/upload-artifact`, and
//! `actions/download-artifact` never hit `resolve.fetch`; `setup-node`/
//! `setup-python`/`setup-go` are intercepted the same way, but only on the
//! nix backend. Everything else is resolved (local path or GitHub tarball,
//! or the ref itself for a bare `docker://...`) and classified (`classify`)
//! by its `action.yml`'s `runs.using` (or the ref, for `docker://`) into
//! `composite`, `node`, or `docker_image`. Phase 2 ships all three, with
//! explicit, logged scope cuts rather than silent no-ops: remote JS actions
//! and `docker://` actions both require specific backends (see
//! `runNodeAction`/`runDockerImageAction`), Dockerfile-built actions and
//! `runs.pre`/`runs.post` aren't executed at all.
const std = @import("std");
const yaml = @import("../yaml.zig");
const ir = @import("../ir.zig");
const expr = @import("../expr.zig");
const backend = @import("../backend.zig");
const resolve = @import("resolve.zig");
const gha = @import("../frontend/gha.zig");
const nix_backend = @import("../backend/nix.zig");

pub const ActionKind = enum {
    composite,
    node,
    docker_image,
    unsupported,
    builtin_checkout,
    builtin_upload_artifact,
    builtin_download_artifact,
};

/// Pure dispatch selection for a resolved `uses:` step: what kind of action
/// `runUsesDepth` should treat this as, given the parsed `action.yml`'s
/// `runs.using` and the resolved ref. A `docker://` ref always wins
/// regardless of `using` — GitHub itself never reads `action.yml` for a
/// `docker://`-prefixed `uses:` line, there is no `action.yml` to read.
/// `using: docker` (with a local/github ref, backed by an `action.yml` with
/// an `image:` field) also classifies as `docker_image`; the Dockerfile-vs-
/// `docker://` distinction lives in the `image:` value, not here — that's
/// `runUsesDepth`'s job once it has `meta.image` in hand. Anything else
/// (`unsupported`) covers actions this task doesn't ship: unknown/missing
/// `using` values (e.g. `node12`, a typo, or a composite/action.yml this
/// parser never populated `using` for).
pub fn classify(meta_using: []const u8, ref: resolve.Ref) ActionKind {
    if (ref == .docker_image) return .docker_image;
    if (std.mem.eql(u8, meta_using, "composite")) return .composite;
    if (std.mem.eql(u8, meta_using, "node20") or std.mem.eql(u8, meta_using, "node16")) return .node;
    if (std.mem.eql(u8, meta_using, "docker")) return .docker_image;
    return .unsupported;
}

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
    /// `runs.image` — only meaningful when `using == "docker"`. A
    /// `docker://...` value runs as-is; anything else (`Dockerfile`, a
    /// relative path) means a build-from-source action, out of phase-2 scope.
    image: []const u8 = "",
    /// `runs.pre` / `runs.post` presence — phase 2 never executes either;
    /// `runUsesDepth` logs a warning and continues when set.
    has_pre: bool = false,
    has_post: bool = false,
    steps: []yaml.Node = &.{},
    input_defaults: []ir.EnvPair = &.{},
};

/// Reads and parses `<dir>/action.yml` (falling back to `action.yaml`) into
/// an `ActionMeta`: `runs.using`, `runs.main`, `runs.image`, `runs.pre`/
/// `runs.post` presence, `runs.steps`, and one `input_defaults` entry per
/// top-level `inputs.<k>` that declares a `default:`.
pub fn parseActionYaml(alloc: std.mem.Allocator, dir: []const u8, diags: *yaml.Diags) !ActionMeta {
    const source = try readActionSource(alloc, dir);
    const root = try yaml.parse(alloc, source, diags);

    const runs = root.get("runs") orelse {
        try diags.add(root.line, root.col, "action.yml missing 'runs'", .{});
        return error.ParseFailed;
    };
    const using = if (runs.get("using")) |u| u.scalarOr("") else "";
    const main = if (runs.get("main")) |m| m.scalarOr("") else "";
    const image = if (runs.get("image")) |m| m.scalarOr("") else "";
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
        .image = image,
        .has_pre = runs.get("pre") != null,
        .has_post = runs.get("post") != null,
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

    // `actions/setup-node`/`setup-python`/`setup-go` on the nix backend are
    // intercepted the same way builtins are — before ref resolution/network
    // — appending the mapped nix package to `handle.nix_packages` so
    // `NixBackend.run` actually picks it up for subsequent steps (see
    // `nixSetupIntercept`). On other backends they fall through to the
    // normal node-action path below (and are subject to the container JS
    // cut there, same as any other JS action).
    if (b.kind == .nix) {
        if (nixSetupMatch(step.uses_ref)) |m| {
            return nixSetupIntercept(alloc, handle, m, opts_log);
        }
    }

    const ref = resolve.parseRef(step.uses_ref) catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "bad uses ref '{s}': {s}", .{ step.uses_ref, @errorName(e) });
        return error.SpawnFailed;
    };

    // A bare `uses: docker://image` has no `action.yml` to read — the ref
    // itself *is* the whole action.
    if (ref == .docker_image) {
        return runDockerImageAction(alloc, ref.docker_image, with, &.{}, b, handle, opts_log, err_msg);
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

    if (meta.has_pre or meta.has_post) {
        if (opts_log) |l| l("action pre/post entrypoints are not executed (phase 2 scope)");
    }

    return switch (classify(meta.using, ref)) {
        .composite => runComposite(alloc, meta, with, b, handle, env, opts_log, force_pull, err_msg, depth),
        .node => runNodeAction(alloc, meta, dir, ref, with, b, handle, opts_log, err_msg),
        .docker_image => blk: {
            if (!std.mem.startsWith(u8, meta.image, "docker://")) {
                if (opts_log) |l| l("Dockerfile-based actions are not supported (docker build is out of phase-2 scope)");
                break :blk .{ .exit_code = 0, .stdout = "", .stderr = "", .outputs = &.{} };
            }
            break :blk runDockerImageAction(alloc, meta.image["docker://".len..], with, meta.input_defaults, b, handle, opts_log, err_msg);
        },
        else => blk: {
            err_msg.* = try std.fmt.allocPrint(alloc, "unsupported action type '{s}'", .{meta.using});
            break :blk error.SpawnFailed;
        },
    };
}

const NixSetupMatch = struct { short_name: []const u8, package: []const u8 };

/// Matches a `uses:` ref (before the `@ref` suffix) against the setup-*
/// actions jalan intercepts on the nix backend, returning both the short
/// display name (for logging) and the nix package it maps to. `null` when
/// `uses_ref` isn't one of these three.
fn nixSetupMatch(uses_ref: []const u8) ?NixSetupMatch {
    const at = std.mem.indexOfScalar(u8, uses_ref, '@') orelse uses_ref.len;
    const path = uses_ref[0..at];
    if (std.mem.eql(u8, path, "actions/setup-node")) return .{ .short_name = "setup-node", .package = "nodejs_20" };
    if (std.mem.eql(u8, path, "actions/setup-python")) return .{ .short_name = "setup-python", .package = "python3" };
    if (std.mem.eql(u8, path, "actions/setup-go")) return .{ .short_name = "setup-go", .package = "go" };
    return null;
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Appends `m.package` to `handle.nix_packages` (per-job, arena-allocated —
/// never touches `NixBackend.cfg`, which is shared across jobs running in
/// parallel; see `JobHandle.nix_packages`'s doc comment) unless it's already
/// there, and logs what actually happened so the log line is never a claim
/// jalan didn't back up. `NixBackend.run` picks the result up via
/// `effectivePackages` on the next step in this job.
fn nixSetupIntercept(alloc: std.mem.Allocator, handle: *backend.JobHandle, m: NixSetupMatch, opts_log: ?backend.LogFn) !backend.StepOutcome {
    const already = containsStr(handle.nix_packages, m.package);
    if (!already) {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(alloc, handle.nix_packages);
        try list.append(alloc, m.package);
        handle.nix_packages = try list.toOwnedSlice(alloc);
    }
    if (opts_log) |l| {
        const msg = if (already)
            try std.fmt.allocPrint(alloc, "{s}: nix package '{s}' already present", .{ m.short_name, m.package })
        else
            try std.fmt.allocPrint(alloc, "{s}: added nix package '{s}' for subsequent steps", .{ m.short_name, m.package });
        l(msg);
    }
    return .{ .exit_code = 0, .stdout = "", .stderr = "", .outputs = &.{} };
}

/// Builds the `INPUT_<NAME>` env pairs a node/docker-image action sees:
/// `defaults` first (only when `with` doesn't already override that input),
/// then every `with` entry — giving `with` precedence, matching GitHub
/// Actions' own default-vs-explicit-input semantics, and (unlike relying on
/// each backend's own env-map overwrite order) works identically regardless
/// of how a given backend happens to apply a list with duplicate keys.
fn buildInputEnv(alloc: std.mem.Allocator, with: []const ir.EnvPair, defaults: []const ir.EnvPair) ![]ir.EnvPair {
    var out: std.ArrayList(ir.EnvPair) = .empty;
    for (defaults) |d| {
        if (withGet(with, d.name) != null) continue;
        try out.append(alloc, .{ .name = try inputEnvName(alloc, d.name), .value = d.value });
    }
    for (with) |w|
        try out.append(alloc, .{ .name = try inputEnvName(alloc, w.name), .value = w.value });
    return out.toOwnedSlice(alloc);
}

/// `node20`/`node16` action: runs `node "<abs main path>"` through the
/// backend's own `runStep` as a synthetic `.run` step (env = `INPUT_*` from
/// `with`/defaults; `GITHUB_OUTPUT` is added by the backend's `runStep`
/// itself, same as any other step).
///
/// SCOPE CUT (explicit, logged, never silent): JS actions run on the NATIVE
/// and NIX backends (host `node`), and on the DOCKER backend only when the
/// action is local to the workspace (a `./`-prefixed `uses:` ref) — its
/// files are already inside the bind-mounted workspace, so no extra copy is
/// needed. A *remote* (github-fetched) action's directory lives in jalan's
/// host-side cache, outside the container entirely; making it visible would
/// need `putArchive`-ing the whole action directory into the container on
/// every step, which is phase 2.1 scope. Remote JS actions on the docker
/// backend warn and skip (exit 0) instead of failing the job outright.
fn runNodeAction(
    alloc: std.mem.Allocator,
    meta: ActionMeta,
    dir: []const u8,
    ref: resolve.Ref,
    with: []const ir.EnvPair,
    b: backend.Backend,
    handle: *backend.JobHandle,
    opts_log: ?backend.LogFn,
    err_msg: *?[]const u8,
) !backend.StepOutcome {
    if (b.kind == .docker and ref != .local) {
        if (opts_log) |l| l("remote JS actions inside containers land in phase 2.1 — run with --backend native for this workflow");
        return .{ .exit_code = 0, .stdout = "", .stderr = "", .outputs = &.{} };
    }
    if (meta.main.len == 0) {
        err_msg.* = "action.yml missing 'main' for a node action";
        return error.SpawnFailed;
    }

    const abs_main = resolveMainPath(alloc, b, dir, meta.main) catch |e| {
        err_msg.* = try std.fmt.allocPrint(alloc, "resolving action main '{s}/{s}' failed: {s}", .{ dir, meta.main, @errorName(e) });
        return error.SpawnFailed;
    };
    const script = try std.fmt.allocPrint(alloc, "node \"{s}\"", .{abs_main});
    const env_pairs = try buildInputEnv(alloc, with, meta.input_defaults);
    const run_step = ir.Step{ .id = "uses-node", .name = "uses-node", .kind = .run, .script = script };
    return b.runStep(alloc, handle, run_step, env_pairs, null, err_msg);
}

/// Resolves `runs.main` to the path `node` should be invoked with. On
/// native/nix, `node` runs on the host — a real host-filesystem realpath.
/// On docker (only reached for a local, workspace-relative action; see
/// `runNodeAction`'s scope-cut comment), `node` runs *inside* the container,
/// where the workspace is bind-mounted at `/github/workspace` — so the path
/// is built by hand from the (already-verified-local) `./`-relative `dir`,
/// not resolved against the host filesystem at all.
fn resolveMainPath(alloc: std.mem.Allocator, b: backend.Backend, dir: []const u8, main: []const u8) ![]const u8 {
    if (b.kind == .docker) {
        const rel = if (std.mem.startsWith(u8, dir, "./")) dir[2..] else dir;
        return std.fmt.allocPrint(alloc, "/github/workspace/{s}/{s}", .{ rel, main });
    }
    const joined = try std.fs.path.join(alloc, &.{ dir, main });
    return std.fs.cwd().realpathAlloc(alloc, joined);
}

/// `docker://image` action (either a bare `uses: docker://...` ref, or
/// `using: docker` with `image: docker://...` in `action.yml`): docker
/// backend only, via the optional `runContainerAction` vtable entry — a
/// one-shot container (create/start/wait/logs/remove), never the job's own
/// long-lived container. `Cmd` comes from `with.args` split on whitespace
/// when present (GitHub Actions' own `args:` -> container args mapping);
/// `env_pairs` are `INPUT_*` from `with`/`defaults` via `buildInputEnv`.
/// Non-docker backends warn and skip (exit 0) — this cut is checked via the
/// vtable itself (`null` on native/nix) rather than `b.kind`, since that's
/// the one fact that actually determines whether the call would work.
fn runDockerImageAction(
    alloc: std.mem.Allocator,
    image: []const u8,
    with: []const ir.EnvPair,
    defaults: []const ir.EnvPair,
    b: backend.Backend,
    handle: *backend.JobHandle,
    opts_log: ?backend.LogFn,
    err_msg: *?[]const u8,
) !backend.StepOutcome {
    if (b.vtable.runContainerAction == null) {
        if (opts_log) |l| l("docker:// actions require --backend docker");
        return .{ .exit_code = 0, .stdout = "", .stderr = "", .outputs = &.{} };
    }

    var cmd_args: []const []const u8 = &.{};
    if (withGet(with, "args")) |args_str| {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, args_str, ' ');
        while (it.next()) |tok| {
            if (tok.len > 0) try list.append(alloc, tok);
        }
        cmd_args = try list.toOwnedSlice(alloc);
    }
    const env_pairs = try buildInputEnv(alloc, with, defaults);

    return b.runContainerAction(alloc, handle, image, cmd_args, env_pairs, err_msg);
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

test "classify: docker:// ref wins regardless of using" {
    const docker_ref = resolve.Ref{ .docker_image = "alpine:3" };
    try std.testing.expectEqual(ActionKind.docker_image, classify("composite", docker_ref));
    try std.testing.expectEqual(ActionKind.docker_image, classify("node20", docker_ref));
    try std.testing.expectEqual(ActionKind.docker_image, classify("", docker_ref));
}

test "classify: using maps to a kind for non-docker refs" {
    const local_ref = resolve.Ref{ .local = "./x" };
    try std.testing.expectEqual(ActionKind.composite, classify("composite", local_ref));
    try std.testing.expectEqual(ActionKind.node, classify("node20", local_ref));
    try std.testing.expectEqual(ActionKind.node, classify("node16", local_ref));
    try std.testing.expectEqual(ActionKind.docker_image, classify("docker", local_ref));
    try std.testing.expectEqual(ActionKind.unsupported, classify("node12", local_ref));
    try std.testing.expectEqual(ActionKind.unsupported, classify("", local_ref));

    const github_ref = resolve.Ref{ .github = .{ .owner = "o", .repo = "r", .subpath = "", .ref = "v1" } };
    try std.testing.expectEqual(ActionKind.composite, classify("composite", github_ref));
    try std.testing.expectEqual(ActionKind.node, classify("node16", github_ref));
    try std.testing.expectEqual(ActionKind.docker_image, classify("docker", github_ref));
}

/// Spawns `node --version`; exit 0 means node is on PATH. Test-only gate,
/// mirrors `backend/native.zig`'s private `onPath` helper.
fn nodeOnPath(alloc: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "node", "--version" },
    }) catch return false;
    return result.term == .Exited and result.term.Exited == 0;
}

test "js node20 local action runs through native backend, INPUT_ mapping works (gated: node on PATH)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (!nodeOnPath(a)) return error.SkipZigTest;

    const b = backend.native();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "./testdata/actions/js-hello" };
    const with = [_]ir.EnvPair{.{ .name = "who", .value = "jalan" }};
    var env = expr.Env{};
    const out = try runUses(a, step, &with, b, &h, &env, null, false, &em);
    if (em) |m| std.debug.print("js-hello run failed: {s}\n", .{m});
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "js says jalan") != null);
}

test "js node20 action falls back to input default when 'with' omits it (gated: node on PATH)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (!nodeOnPath(a)) return error.SkipZigTest;

    const b = backend.native();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "./testdata/actions/js-hello" };
    var env = expr.Env{};
    const out = try runUses(a, step, &.{}, b, &h, &env, null, false, &em);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "js says world") != null);
}

test "node action with runs.pre logs the pre/post warning and still runs (gated: node on PATH)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (!nodeOnPath(a)) return error.SkipZigTest;

    const b = backend.native();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "./testdata/actions/prepost-node" };
    var env = expr.Env{};
    const Capture = struct {
        var lines: [8][]const u8 = undefined;
        var count: usize = 0;
        fn log(line: []const u8) void {
            if (count < lines.len) lines[count] = line;
            count += 1;
        }
    };
    Capture.count = 0;
    const out = try runUses(a, step, &.{}, b, &h, &env, Capture.log, false, &em);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "main ran") != null);
    var saw_warning = false;
    for (Capture.lines[0..Capture.count]) |l| {
        if (std.mem.indexOf(u8, l, "pre/post entrypoints are not executed") != null) saw_warning = true;
    }
    try std.testing.expect(saw_warning);
}

test "docker-using action with image != docker:// warns and skips (Dockerfile actions unsupported)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = backend.native();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "./testdata/actions/dockerfile-action" };
    var env = expr.Env{};
    var logged: ?[]const u8 = null;
    const Capture = struct {
        var msg: ?[]const u8 = null;
        fn log(line: []const u8) void {
            msg = line;
        }
    };
    Capture.msg = null;
    const out = try runUses(a, step, &.{}, b, &h, &env, Capture.log, false, &em);
    logged = Capture.msg;
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(logged != null);
    try std.testing.expect(std.mem.indexOf(u8, logged.?, "Dockerfile-based actions are not supported") != null);
}

test "docker:// action on a non-docker backend warns and skips (bare uses: docker://)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = backend.native();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "docker://alpine:3" };
    var env = expr.Env{};
    const Capture = struct {
        var msg: ?[]const u8 = null;
        fn log(line: []const u8) void {
            msg = line;
        }
    };
    Capture.msg = null;
    const out = try runUses(a, step, &.{}, b, &h, &env, Capture.log, false, &em);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(Capture.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, Capture.msg.?, "docker:// actions require --backend docker") != null);
}

test "docker:// action via using:docker+image on a non-docker backend also warns and skips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = backend.native();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "./testdata/actions/docker-remote" };
    var env = expr.Env{};
    const Capture = struct {
        var msg: ?[]const u8 = null;
        fn log(line: []const u8) void {
            msg = line;
        }
    };
    Capture.msg = null;
    const out = try runUses(a, step, &.{}, b, &h, &env, Capture.log, false, &em);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(Capture.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, Capture.msg.?, "docker:// actions require --backend docker") != null);
}

test "setup-node is intercepted on the nix backend without needing nix installed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nb = nix_backend.NixBackend{};
    const b = nb.backend();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "actions/setup-node@v4" };
    var env = expr.Env{};
    const Capture = struct {
        var msg: ?[]const u8 = null;
        fn log(line: []const u8) void {
            msg = line;
        }
    };
    Capture.msg = null;
    const out = try runUses(a, step, &.{}, b, &h, &env, Capture.log, false, &em);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(Capture.msg != null);
    try std.testing.expectEqualStrings("setup-node: added nix package 'nodejs_20' for subsequent steps", Capture.msg.?);
    try std.testing.expectEqual(@as(usize, 1), h.nix_packages.len);
    try std.testing.expectEqualStrings("nodejs_20", h.nix_packages[0]);
}

test "setup-python on nix actually appends to handle.nix_packages, no duplicate on repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nb = nix_backend.NixBackend{};
    const b = nb.backend();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    var em: ?[]const u8 = null;
    const step = ir.Step{ .id = "u", .name = "u", .kind = .uses, .script = "", .uses_ref = "actions/setup-python@v5" };
    var env = expr.Env{};

    const out1 = try runUses(a, step, &.{}, b, &h, &env, null, false, &em);
    try std.testing.expectEqual(@as(i32, 0), out1.exit_code);
    try std.testing.expectEqual(@as(usize, 1), h.nix_packages.len);
    try std.testing.expect(containsStr(h.nix_packages, "python3"));

    // Second interception for the same job must not duplicate the package.
    const Capture = struct {
        var msg: ?[]const u8 = null;
        fn log(line: []const u8) void {
            msg = line;
        }
    };
    Capture.msg = null;
    const out2 = try runUses(a, step, &.{}, b, &h, &env, Capture.log, false, &em);
    try std.testing.expectEqual(@as(i32, 0), out2.exit_code);
    try std.testing.expectEqual(@as(usize, 1), h.nix_packages.len);
    try std.testing.expectEqualStrings("setup-python: nix package 'python3' already present", Capture.msg.?);
}
